// Prueba del servidor de voz SIN gastar: Telnyx/Twilio, Deepgram, ElevenLabs y el cerebro son de mentira (aquí mismo).
// Correr: node prueba_servidor.js telnyx   (o twilio)
'use strict';
const http = require('http');
const crypto = require('crypto');
const { WebSocketServer, WebSocket } = require('ws');
const assert = require('assert');

const eventos = [];   // lo que pasó, para revisar al final
const anotar = (x) => eventos.push(x);
const PROV = process.argv[2] || 'telnyx';
const TX = PROV === 'telnyx';
const par = crypto.generateKeyPairSync('ed25519');
const pubRaw = par.publicKey.export({ format: 'der', type: 'spki' }).slice(-32).toString('base64');
const esperar = (ms) => new Promise((ok) => setTimeout(ok, ms));

// --- Deepgram de mentira: cuando llega audio, "oye" la frase que toque ---
const frases = ['quiero una cita para un presupuesto', 'muchas gracias, adiós'];
let bytesOidos = 0, fraseN = 0, oyendo = false, dgAbiertos = 0;
const dgSockets = [];
const dg = new WebSocketServer({ port: 0 });
dg.on('connection', (ws, req) => {
  anotar({ dg_conecto: req.url, auth: req.headers.authorization }); dgAbiertos++; dgSockets.push(ws);
  ws.on('close', () => dgAbiertos--);
  ws.on('message', (m, esBin) => {
    if (!esBin) { anotar({ dg_control: String(m) }); return; }
    bytesOidos += m.length;
    if (oyendo) return; oyendo = true;
    setTimeout(() => {
      const t = frases[fraseN++] || '';
      if (ws.readyState !== WebSocket.OPEN) { oyendo = false; return; }
      ws.send(JSON.stringify({ type: 'Results', is_final: false, speech_final: false, channel: { alternatives: [{ transcript: t.split(' ').slice(0, 2).join(' ') }] } }));
      ws.send(JSON.stringify({ type: 'Results', is_final: true, speech_final: true, channel: { alternatives: [{ transcript: t }] } }));
      oyendo = false;
    }, 50);
  });
});

// --- ElevenLabs, cerebro y API del teléfono de mentira ---
const api = [];
const cerebroPedidos = [];
let inicioLento = 0;
const otro = http.createServer(async (req, res) => {
  let d = ''; for await (const c of req) d += c;
  if (req.url.startsWith('/tts/')) {
    const tx = JSON.parse(d).text;
    anotar({ tts: tx.slice(0, 40), voz: req.url.split('/')[2], key: req.headers['xi-api-key'] });
    if (tx.includes('FALLAVOZ')) { res.writeHead(500); return res.end('error'); }
    res.writeHead(200, { 'content-type': 'audio/basic' });
    for (let i = 0; i < 3; i++) { res.write(Buffer.alloc(800, 0xff)); await esperar(10); }
    return res.end();
  }
  if (req.url === '/cerebro') {
    const b = JSON.parse(d); cerebroPedidos.push({ b, secreto: req.headers['x-voz-secreto'] });
    if (b.accion === 'inicio' && inicioLento) await esperar(inicioLento);
    res.writeHead(200, { 'content-type': 'application/json' });
    if (b.accion === 'inicio') return res.end(JSON.stringify({ ok: true, llamada_id: 'L-' + b.call_sid, saludo: { es: 'Gracias por llamar a Paneles Sol.', en: 'Thanks for calling.' }, idioma_inicial: 'es', voz_id: 'VOZ1', transferir_a: '+18135550000' }));
    if (b.accion === 'turno') {
      if (/persona/.test(b.texto)) return res.end(JSON.stringify({ ok: true, respuesta: 'Claro.', idioma: 'es', accion: 'pasar_persona' }));
      if (/adiós/.test(b.texto)) return res.end(JSON.stringify({ ok: true, respuesta: 'Gracias a usted, hasta luego.', idioma: 'es', accion: 'despedir' }));
      if (/vacio/.test(b.texto)) return res.end(JSON.stringify({ ok: true, respuesta: '', idioma: 'es', accion: 'despedir' }));
      if (/rompe/.test(b.texto)) return res.end(JSON.stringify({ ok: true, respuesta: 'FALLAVOZ hola', idioma: 'es', accion: 'ninguna' }));
      return res.end(JSON.stringify({ ok: true, respuesta: 'Con gusto. ¿Cuál es su nombre?', idioma: 'es', accion: 'ninguna' }));
    }
    return res.end(JSON.stringify({ ok: true }));
  }
  if (req.url.startsWith('/2010-04-01/Accounts/') || req.url.startsWith('/texml/Accounts/')) { api.push({ url: req.url, body: decodeURIComponent(d.replace(/\+/g, ' ')) }); res.writeHead(201); return res.end('{}'); }
  res.writeHead(404); res.end();
});

(async () => {
  await new Promise((ok) => otro.listen(0, ok));
  const P = otro.address().port;
  Object.assign(process.env, {
    PUBLIC_HOST: 'voz.ejemplo.com', TWILIO_ACCOUNT_SID: 'AC123', TWILIO_AUTH_TOKEN: 'secreto_tw', DEEPGRAM_API_KEY: 'DGK', ELEVENLABS_API_KEY: 'ELK',
    ELEVENLABS_VOICE_ID: 'VOZFAB', CEREBRO_URL: `http://127.0.0.1:${P}/cerebro`, SUPABASE_ANON_KEY: 'anon', TELEFONO_SECRETO: 'S3',
    DEEPGRAM_URL: `ws://127.0.0.1:${dg.address().port}/v1/listen`, ELEVENLABS_URL: `http://127.0.0.1:${P}/tts`, TWILIO_API: `http://127.0.0.1:${P}/2010-04-01`,
    SILENCIO_MS: '100000', VOZ_URL_CLAVE: 'clave-secreta-de-prueba-123456', PROVEEDOR: PROV, TELNYX_API_KEY: 'TXK', TELNYX_PUBLIC_KEY: pubRaw, TELNYX_API: `http://127.0.0.1:${P}/texml`,
  });
  const { servidor, firmaOk, CFG } = require('./servidor.js');
  await new Promise((ok) => servidor.listen(0, ok));
  const SP = servidor.address().port;

  // --- ayudantes: entra una llamada por /voz (con firma) y se abre el audio con el pase que da el servidor ---
  const post = (cuerpo, h) => new Promise((ok) => { const r = http.request({ port: SP, path: '/voz', method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', ...h } }, (res) => { let d = ''; res.on('data', (c) => d += c); res.on('end', () => ok({ s: res.statusCode, d })); }); r.end(cuerpo); });
  const firmar = (params) => {
    const cuerpo = new URLSearchParams(params).toString();
    if (TX) { const ts = String(Math.floor(Date.now() / 1000)); return { cuerpo, h: { 'telnyx-signature-ed25519': crypto.sign(null, Buffer.from(ts + '|' + cuerpo), par.privateKey).toString('base64'), 'telnyx-timestamp': ts } }; }
    return { cuerpo, h: { 'x-twilio-signature': crypto.createHmac('sha1', 'secreto_tw').update('https://voz.ejemplo.com/voz' + Object.keys(params).sort().map((k) => k + params[k]).join('')).digest('base64') } };
  };
  async function entrar(sid, opciones = {}) {
    const params = { CallSid: sid, AccountSid: 'ACC9', From: '+18135551234', To: '+18135559999' };
    const f = firmar(params); const r = await post(f.cuerpo, f.h);
    assert.strictEqual(r.s, 200, 'webhook ' + sid);
    const pase = TX ? (r.d.match(/media\?t=([0-9a-f]+)/) || [])[1] : (r.d.match(/name="t" value="([0-9a-f]+)"/) || [])[1];
    assert.ok(pase, 'hay pase: ' + r.d);
    const ws = new WebSocket(`ws://127.0.0.1:${SP}/media${TX ? '?t=' + pase : ''}`);
    const L = { ws, eventos: [], marcas: 0, clears: 0, bytes: 0, conStreamSid: 0 };
    ws.on('message', (m) => {
      const e = JSON.parse(m); L.eventos.push(e.event); if (e.streamSid) L.conStreamSid++;
      if (e.event === 'media') L.bytes += Buffer.from(e.media.payload, 'base64').length;
      if (e.event === 'clear') L.clears++;
      if (e.event === 'mark') { L.marcas++; if (!opciones.sinMarcas) setTimeout(() => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ event: 'mark', mark: { name: e.mark.name } })), 20); }
    });
    ws.on('error', () => {});
    await new Promise((ok, mal) => { ws.on('open', ok); ws.on('unexpected-response', () => mal(new Error('no abrió'))); });
    L.start = () => ws.send(JSON.stringify(TX ? { event: 'start', sequence_number: '1', stream_id: 'S-' + sid, start: { user_id: 'u', call_control_id: 'cc', from: '+18135551234', to: '+18135559999', media_format: { encoding: 'PCMU', sample_rate: 8000, channels: 1 } } }
      : { event: 'start', start: { streamSid: 'MZ-' + sid, callSid: sid, customParameters: { t: pase } } }));
    L.audio = () => ws.send(JSON.stringify({ event: 'media', media: { track: 'inbound', payload: Buffer.alloc(160, 0x7f).toString('base64') } }));
    return L;
  }
  const colgados = (sid) => api.filter((t) => t.url.includes('/Calls/' + sid) && (TX ? t.body === 'Status=completed' : t.body.includes('<Hangup/>')));

  // 1) Webhook: sin firma → 403; firma vieja → 403 (Telnyx); firma alterada no pasa (Twilio)
  {
    const params = { CallSid: 'CA0', AccountSid: 'ACC9', From: '+1', To: '+18135559999' };
    const f = firmar(params);
    assert.strictEqual((await post(f.cuerpo, {})).s, 403, 'sin firma debe dar 403');
    if (TX) {
      const ts = String(Math.floor(Date.now() / 1000) - 1000);
      assert.strictEqual((await post(f.cuerpo, { 'telnyx-signature-ed25519': crypto.sign(null, Buffer.from(ts + '|' + f.cuerpo), par.privateKey).toString('base64'), 'telnyx-timestamp': ts })).s, 403, 'firma vieja no pasa');
      assert.strictEqual((await post(f.cuerpo, { ...f.h, 'telnyx-timestamp': 'abc' })).s, 403, 'tiempo raro no pasa');
      const conClave = (k) => new Promise((ok) => { const r = http.request({ port: SP, path: '/voz?k=' + k, method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' } }, (res) => { res.resume(); res.on('end', () => ok(res.statusCode)); }); r.end(f.cuerpo); });
      assert.strictEqual(await conClave('clave-secreta-de-prueba-123456'), 200, 'con la clave de la dirección entra (sin firma)');
      assert.strictEqual(await conClave('clave-equivocada-000000000000'), 403, 'clave equivocada no entra');
      const r = await post(f.cuerpo, f.h);
      assert.ok(r.d.includes('bidirectionalMode="rtp"') && r.d.includes('<Pause length="930"/>') && r.d.includes('<Hangup/>') && !r.d.includes('CA0'), 'TeXML con pase (sin datos de la llamada en la dirección): ' + r.d);
    } else {
      assert.ok(!firmaOk('https://voz.ejemplo.com/voz', params, f.h['x-twilio-signature'].replace(/.$/, 'x')), 'firma alterada no pasa');
    }
    const grande = await post('x'.repeat(200000), f.h); assert.strictEqual(grande.s, 413, 'cuerpo muy grande: 413');
    console.log('PRUEBA 1 (firmas) OK');
  }

  // 2) Sin pase no se abre el audio (nadie puede gastar ni hacerse pasar por un negocio)
  {
    if (TX) {
      const ws = new WebSocket(`ws://127.0.0.1:${SP}/media?t=inventado`); let abrio = false;
      ws.on('open', () => { abrio = true; }); ws.on('error', () => {}); ws.on('unexpected-response', () => {});
      await esperar(200); assert.ok(!abrio, 'sin pase no abre');
      const ws2 = new WebSocket(`ws://127.0.0.1:${SP}/media?sid=VICTIMA&cuenta=ACC9&a=%2B1999`); let abrio2 = false;
      ws2.on('open', () => { abrio2 = true; }); ws2.on('error', () => {}); ws2.on('unexpected-response', () => {});
      await esperar(200); assert.ok(!abrio2, 'con datos inventados no abre');
    } else {
      const ws = new WebSocket(`ws://127.0.0.1:${SP}/media`); await new Promise((ok) => ws.on('open', ok)); let cerro = false; ws.on('close', () => { cerro = true; });
      ws.send(JSON.stringify({ event: 'start', start: { streamSid: 'MZX', callSid: 'VICTIMA', customParameters: { t: 'inventado' } } }));
      await esperar(200); assert.ok(cerro, 'start sin pase válido se cierra');
    }
    // el mismo pase no sirve dos veces
    const L = await entrar('CAP'); await esperar(50);
    assert.ok(!cerebroPedidos.some((x) => x.b.call_sid === 'VICTIMA'), 'no llamó al cerebro con datos inventados');
    L.ws.close(); await esperar(100);
    console.log('PRUEBA 2 (pase de un solo uso) OK');
  }

  // 3) Llamada completa
  {
    frases.length = 0; frases.push('quiero una cita para un presupuesto', 'muchas gracias, adiós'); fraseN = 0;
    const L = await entrar('CA1'); L.start(); await esperar(300);
    for (let i = 0; i < 5; i++) L.audio(); await esperar(500);
    for (let i = 0; i < 5; i++) L.audio(); await esperar(800);
    const turnos = cerebroPedidos.filter((x) => x.b.accion === 'turno' && x.b.llamada_id === 'L-CA1').map((x) => x.b.texto);
    assert.deepStrictEqual(turnos, ['quiero una cita para un presupuesto', 'muchas gracias, adiós'], 'dos turnos: ' + JSON.stringify(turnos));
    const ini = cerebroPedidos.find((x) => x.b.accion === 'inicio' && x.b.call_sid === 'CA1');
    assert.ok(ini && ini.secreto === 'S3' && ini.b.numero_llamado === '+18135559999' && ini.b.de === '+18135551234', 'inicio con los datos del webhook');
    const tts = eventos.filter((e) => e.tts).map((e) => e.tts);
    assert.ok(tts.some((t) => t.startsWith('Gracias por llamar a Paneles Sol')) && tts.some((t) => t.startsWith('Con gusto')), 'saludo y respuesta');
    assert.ok(eventos.some((e) => e.dg_conecto && e.dg_conecto.includes('language=multi') && e.auth === 'Token DGK'), 'oído en español e inglés');
    assert.ok(L.bytes >= 2400 * 3 && L.marcas >= 3, 'la voz llegó con marcas');
    assert.strictEqual(colgados('CA1').length, 1, 'colgó una sola vez al despedirse: ' + JSON.stringify(api));
    if (TX) assert.strictEqual(L.conStreamSid, 0, 'a Telnyx no se le manda streamSid');
    await esperar(200);
    const fin = cerebroPedidos.filter((x) => x.b.accion === 'fin' && x.b.llamada_id === 'L-CA1');
    assert.ok(fin.length === 1 && fin[0].b.pasada === false, 'un solo fin');
    console.log('PRUEBA 3 (llamada completa) OK');
  }

  // 4) Interrupción: si la persona habla mientras el robot habla, se manda "clear"
  {
    frases.length = 0; frases.push('oiga espere un momento'); fraseN = 0;
    const L = await entrar('CA2', { sinMarcas: true }); L.start(); await esperar(300);
    L.audio(); await esperar(400);
    assert.ok(L.clears >= 1, 'se calló cuando lo interrumpieron');
    L.ws.close(); await esperar(150);
    console.log('PRUEBA 4 (interrupción) OK');
  }

  // 5) Pasar a una persona
  {
    frases.length = 0; frases.push('quiero hablar con una persona'); fraseN = 0;
    const L = await entrar('CA3'); L.start(); await esperar(300);
    L.audio(); await esperar(900);
    const dial = api.find((t) => t.url.includes('CA3') && t.body.includes('<Dial'));
    assert.ok(dial && dial.body.includes('+18135550000') && dial.body.includes('callerId="+18135559999"'), 'pasó la llamada: ' + JSON.stringify(api.slice(-2)));
    assert.ok(eventos.some((e) => e.tts && e.tts.startsWith('Un momento, le comunico')), 'avisó con nuestra voz');
    L.ws.close(); await esperar(150);
    assert.strictEqual(colgados('CA3').length, 0, 'no colgó una llamada que se pasó');
    console.log('PRUEBA 5 (pasar a persona) OK');
  }

  // 6) Mensajes rotos no tumban el servidor
  {
    const L = await entrar('CA4'); L.start(); await esperar(200);
    for (const m of ['null', '{"event":"media"}', '{"event":"start"}', '{"event":"media","media":{"payload":5}}', '[]', '"hola"', '{"event":"mark"}']) L.ws.send(m);
    await esperar(200);
    const L2 = await entrar('CA5'); L2.start(); await esperar(300);
    assert.ok(cerebroPedidos.some((x) => x.b.accion === 'inicio' && x.b.call_sid === 'CA5'), 'el servidor sigue vivo');
    L.ws.close(); L2.ws.close(); await esperar(150);
    console.log('PRUEBA 6 (mensajes rotos) OK');
  }

  // 7) Cuelga mientras el cerebro prepara el saludo: no queda el oído abierto
  {
    await esperar(200); const antes = dgAbiertos; inicioLento = 500;
    const L = await entrar('CA6'); L.start(); await esperar(100);
    L.ws.send(JSON.stringify({ event: 'stop' })); L.ws.close(); await esperar(900); inicioLento = 0;
    assert.strictEqual(dgAbiertos, antes, 'no quedó Deepgram abierto (antes ' + antes + ', ahora ' + dgAbiertos + ')');
    assert.ok(cerebroPedidos.some((x) => x.b.accion === 'fin' && x.b.llamada_id === 'L-CA6'), 'la llamada se cerró también en la base');
    console.log('PRUEBA 7 (cuelga durante el saludo) OK');
  }

  // 8) Si el cerebro dice "despedir" sin texto, igual cuelga
  {
    frases.length = 0; frases.push('vacio'); fraseN = 0;
    const L = await entrar('CA7'); L.start(); await esperar(300); L.audio(); await esperar(500);
    assert.strictEqual(colgados('CA7').length, 1, 'colgó aunque la respuesta venía vacía');
    console.log('PRUEBA 8 (despedir sin texto) OK');
  }

  // 9) Silencio: pregunta "¿sigue ahí?" después del saludo y luego se despide y cuelga; el contador vuelve a 0 si habla
  {
    CFG.silencioMs = 300;
    const L = await entrar('CA8'); L.start(); await esperar(1600);
    const ttsLlamada = eventos.filter((e) => e.tts).map((e) => e.tts);
    assert.ok(ttsLlamada.filter((t) => t.startsWith('¿Sigue ahí?')).length >= 1, 'preguntó si sigue ahí');
    assert.strictEqual(colgados('CA8').length, 1, 'colgó por silencio');
    CFG.silencioMs = 100000;
    console.log('PRUEBA 9 (silencio) OK');
  }

  // 10) Telnyx: si se corta el audio sin "stop", se cuelga la llamada (no queda abierta en silencio)
  if (TX) {
    const L = await entrar('CA9'); L.start(); await esperar(300);
    L.ws.terminate(); await esperar(300);
    assert.strictEqual(colgados('CA9').length, 1, 'colgó la llamada huérfana');
    console.log('PRUEBA 10 (audio cortado) OK');
  }

  // 11) Si la voz falla, el teléfono lo dice con su propia voz y pasa la llamada
  {
    frases.length = 0; frases.push('rompe la voz'); fraseN = 0;
    const L = await entrar('CA10'); L.start(); await esperar(300); L.audio(); await esperar(600);
    const r = api.find((t) => t.url.includes('CA10') && t.body.includes('<Say'));
    assert.ok(r && r.body.includes('<Dial') && r.body.includes('problema técnico'), 'respaldo con <Say> y pasa la llamada: ' + JSON.stringify(api.slice(-2)));
    L.ws.close(); await esperar(150);
    console.log('PRUEBA 11 (falla la voz) OK');
  }

  // 12) Las marcas que nunca vuelven no dejan la llamada esperando 60 segundos
  {
    frases.length = 0; frases.push('quiero una cita para un presupuesto'); fraseN = 0;
    const L = await entrar('CA11', { sinMarcas: true }); L.start(); await esperar(300);
    const t0 = Date.now(); L.audio();
    while (!cerebroPedidos.some((x) => x.b.accion === 'turno' && x.b.llamada_id === 'L-CA11') && Date.now() - t0 < 5000) await esperar(50);
    assert.ok(Date.now() - t0 < 4000, 'el siguiente turno no esperó 60 s');
    L.ws.close(); await esperar(150);
    console.log('PRUEBA 12 (marcas perdidas) OK');
  }

  // 13) Si Deepgram se cae a mitad de llamada, se reconecta y sigue oyendo
  {
    frases.length = 0; frases.push('quiero una cita para un presupuesto'); fraseN = 0;
    const L = await entrar('CA12'); L.start(); await esperar(300);
    const conexAntes = eventos.filter((e) => e.dg_conecto).length;
    dgSockets[dgSockets.length - 1].close(); await esperar(600);
    assert.ok(eventos.filter((e) => e.dg_conecto).length === conexAntes + 1, 'volvió a conectar el oído');
    L.audio(); await esperar(500);
    assert.ok(cerebroPedidos.some((x) => x.b.accion === 'turno' && x.b.llamada_id === 'L-CA12'), 'siguió oyendo después de reconectar');
    L.ws.close(); await esperar(150);
    console.log('PRUEBA 13 (oído reconecta) OK');
  }

  // 14) Telnyx repite el webhook: la llamada viva no se cuelga y el pase es el mismo
  if (TX) {
    const params = { CallSid: 'CA13', AccountSid: 'ACC9', From: '+1', To: '+18135559999' };
    const f1 = firmar(params); const r1 = await post(f1.cuerpo, f1.h); const f2 = firmar(params); const r2 = await post(f2.cuerpo, f2.h);
    const p1 = (r1.d.match(/media\?t=([0-9a-f]+)/) || [])[1], p2 = (r2.d.match(/media\?t=([0-9a-f]+)/) || [])[1];
    assert.ok(p1 && p1 === p2, 'el webhook repetido da el mismo pase');
    console.log('PRUEBA 14 (webhook repetido) OK');
  }

  // 15) El oído se cae 5 veces separadas: como cada vez reconecta, la llamada sigue
  {
    const L = await entrar('CA14'); L.start(); await esperar(300);
    for (let i = 0; i < 5; i++) { dgSockets[dgSockets.length - 1].close(); await esperar(500); }
    assert.ok(!api.some((t) => t.url.includes('CA14')), 'no colgó ni pasó la llamada por caídas que sí reconectaron');
    L.ws.close(); await esperar(150);
    console.log('PRUEBA 15 (varias caídas del oído) OK');
  }

  await esperar(300);
  assert.strictEqual(dgAbiertos, 0, 'al final no queda ningún oído abierto (' + dgAbiertos + ')');
  console.log('TODAS LAS PRUEBAS PASARON (' + PROV + ')');
  process.exit(0);
})().catch((e) => { console.error('FALLÓ:', e.message); console.error(JSON.stringify(eventos.slice(-8))); process.exit(1); });
