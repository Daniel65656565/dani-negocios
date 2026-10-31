// DANI Pro — SERVIDOR DE VOZ para las llamadas con IA (30 oct 2026).
// Telnyx o Twilio (el número) → aquí → Deepgram (oído) → cerebro "telefono" en Supabase (fichas + motor) → ElevenLabs (voz) → el teléfono.
// De fábrica usa TELNYX (más barato). Con PROVEEDOR=twilio usa Twilio. El negocio desvía su número de siempre al número de aquí.
// Se queda prendido en un servidor pequeño (Fly.io, Railway o similar). Variables en .env (ver .env.ejemplo).
'use strict';
const http = require('http');
const crypto = require('crypto');
const { WebSocketServer, WebSocket } = require('ws');

const E = process.env;
const CFG = {
  puerto: Number(E.PORT || 8080),
  host: E.PUBLIC_HOST || '',                                   // ej.: voz-danipro.fly.dev (sin https://)
  proveedor: (E.PROVEEDOR || 'telnyx').toLowerCase(),
  txKey: E.TELNYX_API_KEY || '', txPublica: E.TELNYX_PUBLIC_KEY || '',   // llave de la API y llave pública de las firmas (Mission Control)
  txApi: E.TELNYX_API || 'https://api.telnyx.com/v2/texml',
  urlClave: E.VOZ_URL_CLAVE || '',   // clave secreta en la dirección del webhook (https://.../voz?k=CLAVE), por si Telnyx no firma TeXML
  twSid: E.TWILIO_ACCOUNT_SID || '', twToken: E.TWILIO_AUTH_TOKEN || '',
  dgKey: E.DEEPGRAM_API_KEY || '', elKey: E.ELEVENLABS_API_KEY || '',
  vozFabrica: E.ELEVENLABS_VOICE_ID || '',
  cerebro: E.CEREBRO_URL || '',                                // https://<proyecto>.supabase.co/functions/v1/telefono
  anon: E.SUPABASE_ANON_KEY || '', secreto: E.TELEFONO_SECRETO || '',
  // para las pruebas (se pueden cambiar por servidores falsos)
  dgUrl: E.DEEPGRAM_URL || 'wss://api.deepgram.com/v1/listen',
  elUrl: E.ELEVENLABS_URL || 'https://api.elevenlabs.io/v1/text-to-speech',
  twApi: E.TWILIO_API || 'https://api.twilio.com/2010-04-01',
  validarFirma: E.VALIDAR_FIRMA !== 'no',
  silencioMs: Number(E.SILENCIO_MS || 15000),
  maxLlamadaMs: Number(E.MAX_LLAMADA_MS || 15 * 60 * 1000),
};

const log = (...a) => console.log(new Date().toISOString(), ...a);
const xml = (s) => String(s).replace(/[<>&"']/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));

// ---------- firmas (para que nadie más pueda usar el servidor) ----------
// Telnyx firma con ED25519 el texto "timestamp|cuerpo"; la llave pública viene en base64 (32 bytes).
function firmaTelnyxOk(cuerpo, firma, tiempo) {
  if (!CFG.validarFirma) return true;
  if (!firma || !tiempo || !CFG.txPublica) return false;
  if (!Number.isFinite(Number(tiempo)) || Math.abs(Date.now() / 1000 - Number(tiempo)) > 300) return false;   // máximo 5 minutos de diferencia
  try {
    const crudo = Buffer.from(CFG.txPublica, 'base64');
    const llave = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), crudo]), format: 'der', type: 'spki' });
    return crypto.verify(null, Buffer.from(`${tiempo}|${cuerpo}`), llave, Buffer.from(String(firma), 'base64'));
  } catch (_) { return false; }
}
function claveUrlOk(url) {
  if (!CFG.urlClave) return false;
  const k = new URLSearchParams(String(url).split('?')[1] || '').get('k') || '';
  const a = Buffer.from(k), b = Buffer.from(CFG.urlClave);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
// Twilio firma con HMAC-SHA1 la dirección + los campos ordenados.
function firmaOk(url, params, firma) {
  if (!CFG.validarFirma) return true;
  if (!firma || !CFG.twToken) return false;
  const datos = url + Object.keys(params).sort().map((k) => k + params[k]).join('');
  const esperada = crypto.createHmac('sha1', CFG.twToken).update(Buffer.from(datos, 'utf-8')).digest('base64');
  const a = Buffer.from(esperada), b = Buffer.from(String(firma));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Cambiar una llamada en curso (pasarla a una persona o colgar). Telnyx usa la misma forma que Twilio (TeXML).
async function cambiarLlamada(ll, twiml) {
  if (CFG.proveedor === 'telnyx') {
    if (!ll.callSid || !ll.cuenta || !CFG.txKey) return false;
    const cuerpo = twiml === 'colgar' ? { Status: 'completed' } : { Texml: twiml };
    const r = await fetch(`${CFG.txApi}/Accounts/${encodeURIComponent(ll.cuenta)}/Calls/${encodeURIComponent(ll.callSid)}`, {
      method: 'POST', headers: { authorization: 'Bearer ' + CFG.txKey, 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(cuerpo).toString(),
    }).catch(() => null);
    return !!(r && r.ok);
  }
  return twilioCambiar(ll.callSid, twiml === 'colgar' ? '<Response><Hangup/></Response>' : twiml);
}

async function twilioCambiar(callSid, twiml) {
  if (!callSid || !CFG.twSid) return false;
  const r = await fetch(`${CFG.twApi}/Accounts/${CFG.twSid}/Calls/${callSid}.json`, {
    method: 'POST',
    headers: { authorization: 'Basic ' + Buffer.from(CFG.twSid + ':' + CFG.twToken).toString('base64'), 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ Twiml: twiml }).toString(),
  }).catch(() => null);
  return !!(r && r.ok);
}

// ---------- el cerebro (función "telefono" de Supabase) ----------
async function cerebro(cuerpo) {
  const ac = new AbortController(); const t = setTimeout(() => ac.abort(), 12000);
  try {
    const r = await fetch(CFG.cerebro, {
      method: 'POST', signal: ac.signal,
      headers: { 'content-type': 'application/json', 'x-voz-secreto': CFG.secreto, authorization: 'Bearer ' + CFG.anon, apikey: CFG.anon },
      body: JSON.stringify(cuerpo),
    });
    return await r.json().catch(() => ({ ok: false }));
  } catch (_) { return { ok: false, motivo: 'sin_cerebro' }; } finally { clearTimeout(t); }
}

// ---------- servidor HTTP: Telnyx/Twilio llaman aquí cuando entra una llamada ----------
function leerCuerpo(req) {
  return new Promise((ok) => {
    let d = '', grande = false;
    req.on('data', (c) => { if (grande) return; d += c; if (d.length > 1e5) { grande = true; ok(null); } });
    req.on('end', () => { if (!grande) ok(d); }); req.on('error', () => ok(null));
  });
}

// Pase de un solo uso: solo la llamada que entró por /voz (con firma buena) puede abrir el audio en /media.
const PASES = new Map();
const VIVAS = new Set();   // callSid de las llamadas que tienen audio abierto
function nuevoPase(datos) {
  for (const [k, v] of PASES) if (datos.sid && v.sid === datos.sid && v.hasta >= Date.now()) return k;   // Telnyx repitió el webhook: el mismo pase
  const t = crypto.randomBytes(24).toString('hex');
  PASES.set(t, { ...datos, hasta: Date.now() + 60000 });
  return t;
}
// Cada 15 s: un pase vencido sin usar = el audio nunca se conectó. En Telnyx se cuelga para que no quede 15 min en silencio cobrando.
setInterval(() => {
  for (const [k, v] of PASES) if (v.hasta < Date.now()) {
    PASES.delete(k);
    if (CFG.proveedor === 'telnyx' && v.sid && !VIVAS.has(v.sid)) { log('audio nunca conectó, se cuelga', v.sid); cambiarLlamada({ callSid: v.sid, cuenta: v.cuenta }, 'colgar').catch(() => {}); }
  }
}, 15000).unref();
function usarPase(t) { const v = t && PASES.get(t); if (!v) return null; PASES.delete(t); return v.hasta >= Date.now() ? v : null; }

const servidor = http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/salud') { res.writeHead(200, { 'content-type': 'text/plain' }); return res.end('ok'); }
    if (req.method === 'POST' && req.url.split('?')[0] === '/voz') {
      const crudo = await leerCuerpo(req);
      if (crudo == null) { res.writeHead(413); return res.end('muy grande'); }
      const params = Object.fromEntries(new URLSearchParams(crudo));
      if (CFG.proveedor === 'telnyx') {
        // vale la firma ED25519 de Telnyx o la clave secreta de la dirección (las dos son secretas; basta una)
        if (!firmaTelnyxOk(crudo, req.headers['telnyx-signature-ed25519'], req.headers['telnyx-timestamp']) && !claveUrlOk(req.url)) { res.writeHead(403); return res.end('firma mala'); }
        const pase = nuevoPase({ sid: params.CallSid || '', cuenta: params.AccountSid || '', de: params.From || '', a: params.To || '' });
        // TeXML: el audio va y viene por WebSocket (rtp, PCMU 8k). <Pause> deja la llamada abierta mientras se habla (un poco más que el máximo).
        const pausa = Math.ceil(CFG.maxLlamadaMs / 1000) + 30;
        const texml = `<?xml version="1.0" encoding="UTF-8"?><Response><Start><Stream url="${xml(`wss://${CFG.host}/media?t=${pase}`)}" track="inbound_track" ` +
          `bidirectionalMode="rtp" bidirectionalCodec="PCMU" bidirectionalSamplingRate="8000"/></Start><Pause length="${pausa}"/><Hangup/></Response>`;
        res.writeHead(200, { 'content-type': 'text/xml' }); return res.end(texml);
      }
      if (!firmaOk(`https://${CFG.host}${req.url}`, params, req.headers['x-twilio-signature'])) { res.writeHead(403); return res.end('firma mala'); }
      const pase = nuevoPase({ sid: params.CallSid || '', cuenta: params.AccountSid || '', de: params.From || '', a: params.To || '' });
      const twiml = `<?xml version="1.0" encoding="UTF-8"?><Response><Connect><Stream url="wss://${xml(CFG.host)}/media">` +
        `<Parameter name="t" value="${pase}"/></Stream></Connect></Response>`;
      res.writeHead(200, { 'content-type': 'text/xml' }); return res.end(twiml);
    }
    res.writeHead(404); res.end();
  } catch (e) { log('http error', e.message); try { res.writeHead(500); res.end(); } catch (_) {} }
});

// ---------- una llamada ----------
class Llamada {
  constructor(tw, pase) {
    this.tw = tw; this.streamSid = null; this.pase = pase || null;   // en Telnyx el pase llega ya revisado; en Twilio llega en "start"
    this.callSid = pase?.sid || null; this.cuenta = pase?.cuenta || null; this.de = pase?.de || ''; this.a = pase?.a || '';
    if (this.callSid) VIVAS.add(this.callSid);
    this.llamadaId = null; this.voz = CFG.vozFabrica; this.transferirA = null; this.idioma = 'es';
    this.dg = null; this.dgVivo = null; this.oido = []; this.pensando = false; this.pendiente = '';
    this.hablando = false; this.ttsCtl = null; this.marcas = new Map(); this.n = 0;
    this.inicio = Date.now(); this.tSilencio = null; this.avisosSilencio = 0; this.cerrada = false; this.pasada = false; this.colgada = false; this.empezo = false;
    tw.on('message', (m) => { this.deTwilio(m).catch((e) => log('error en llamada', e.message)); });
    tw.on('close', () => this.cerrar('twilio_cerro'));
    tw.on('error', () => this.cerrar('twilio_error'));
    this.tMax = setTimeout(() => this.despedir('max'), CFG.maxLlamadaMs);
    this.tStart = setTimeout(() => { if (!this.empezo) { log('no llegó start'); try { this.tw.close(); } catch (_) {} this.cerrar('sin_start'); } }, 10000);
  }

  enviar(o) {
    if (CFG.proveedor === 'telnyx') delete o.streamSid;   // Telnyx no lo usa
    if (this.tw.readyState === WebSocket.OPEN) this.tw.send(JSON.stringify(o));
  }

  async deTwilio(m) {
    let ev; try { ev = JSON.parse(m); } catch (_) { return; }
    if (!ev || typeof ev !== 'object') return;
    if (ev.event === 'start') {
      if (this.empezo) return; this.empezo = true; clearTimeout(this.tStart);   // un segundo "start" no abre otro oído
      if (CFG.proveedor === 'telnyx') { this.streamSid = ev.stream_id || null; }
      else {
        const st = ev.start || {}; const p = usarPase(st.customParameters?.t);
        if (!p) { log('start sin pase válido'); try { this.tw.close(); } catch (_) {} return this.cerrar('sin_pase'); }
        this.streamSid = st.streamSid || null; this.callSid = p.sid || st.callSid || null; this.cuenta = p.cuenta; this.de = p.de; this.a = p.a;
        if (this.callSid) VIVAS.add(this.callSid);
      }
      log('llamada', this.callSid, 'de', String(this.de).slice(0, -4) + '****');
      const r = await cerebro({ accion: 'inicio', numero_llamado: this.a, de: this.de, call_sid: this.callSid });
      if (this.cerrada) {   // colgó mientras se preparaba: se cierra también la llamada en la base
        if (r.ok && r.llamada_id) cerebro({ accion: 'fin', llamada_id: r.llamada_id, duracion_seg: Math.round((Date.now() - this.inicio) / 1000), pasada: false });
        return;
      }
      if (!r.ok) {
        if (r.transferir_a) return this.pasar(r.transferir_a, 'es');
        await this.decir('Lo sentimos, en este momento no podemos atender. Por favor llame más tarde. Sorry, we cannot take your call right now.', 'es');
        return this.colgar();
      }
      this.llamadaId = r.llamada_id; this.voz = r.voz_id || CFG.vozFabrica; this.transferirA = r.transferir_a; this.idioma = r.idioma_inicial || 'es';
      this.abrirOido();
      const otro = this.idioma === 'es' ? ' For English, just speak in English.' : ' Para español, hable en español.';
      const dijo = await this.decir((r.saludo?.[this.idioma] || '') + otro, this.idioma);
      if (dijo === 'error') return this.sinVoz((r.saludo?.[this.idioma] || ''));
      if (!this.cerrada && !this.pensando) this.ponerSilencio();
    } else if (ev.event === 'media') {
      const md = ev.media; if (!md || typeof md.payload !== 'string') return;
      if (md.track && !String(md.track).startsWith('inbound')) return;
      if (this.dg && this.dg.readyState === WebSocket.OPEN) this.dg.send(Buffer.from(md.payload, 'base64'));
    } else if (ev.event === 'mark') {
      const nm = ev.mark?.name; const f = nm && this.marcas.get(nm); if (f) { this.marcas.delete(nm); f(); }
    } else if (ev.event === 'stop') {
      this.colgada = true; this.cerrar('colgo');
    }
  }

  // ---- oído (Deepgram, en vivo, español e inglés mezclados) ----
  abrirOido() {
    if (this.dg || this.cerrada) return;
    const q = new URLSearchParams({ model: 'nova-3', language: 'multi', encoding: 'mulaw', sample_rate: '8000', channels: '1',
      interim_results: 'true', endpointing: '300', utterance_end_ms: '1000', vad_events: 'true', smart_format: 'true', punctuate: 'true' });
    this.dg = new WebSocket(`${CFG.dgUrl}?${q}`, { headers: { authorization: 'Token ' + CFG.dgKey } });
    this.dg.on('message', (m) => { try { this.deOido(m); } catch (e) { log('oido error', e.message); } });
    this.dg.on('error', (e) => log('oido error', e.message));
    this.dg.on('open', () => { this.dgReintentos = 0; });
    this.dg.on('close', () => {
      if (this.cerrada) return;
      clearInterval(this.dgVivo); this.dg = null;
      this.dgReintentos = (this.dgReintentos || 0) + 1;
      if (this.dgReintentos <= 3) { log('oído se cayó, reconectando', this.dgReintentos); setTimeout(() => this.abrirOido(), 300); }
      else if (this.transferirA) this.pasar(this.transferirA, this.idioma);
      else this.despedir('sin_oido');
    });
    this.dgVivo = setInterval(() => { if (this.dg?.readyState === WebSocket.OPEN) this.dg.send(JSON.stringify({ type: 'KeepAlive' })); }, 8000);
  }

  deOido(m) {
    let d; try { d = JSON.parse(m); } catch (_) { return; }
    if (!d || typeof d !== 'object') return;
    if (d.type === 'Results') {
      const t = String(d.channel?.alternatives?.[0]?.transcript || '').trim();
      if (t && this.hablando && t.split(/\s+/).length >= 2) this.callar();   // la persona interrumpe: el robot se calla
      if (t) { this.quitarSilencio(); this.avisosSilencio = 0; }
      if (d.is_final && t) this.oido.push(t);
      if (d.speech_final) this.finFrase();
    } else if (d.type === 'UtteranceEnd') {
      this.finFrase();
    }
  }

  finFrase() {
    const texto = this.oido.join(' ').trim(); this.oido = [];
    if (!texto) { if (!this.pensando && !this.hablando) this.ponerSilencio(); return; }   // ruido o interrupción sin palabras: seguir esperando
    if (this.pensando) { this.pendiente = (this.pendiente + ' ' + texto).trim(); return; }
    this.turno(texto);
  }

  async turno(texto, anteriorNoDicha = false) {
    if (this.cerrada || !this.llamadaId) return;
    this.pensando = true; this.quitarSilencio();
    const r = await cerebro({ accion: 'turno', llamada_id: this.llamadaId, texto, ...(anteriorNoDicha ? { anterior_no_dicha: true } : {}) });
    this.pensando = false;
    if (this.cerrada) return;
    if (this.pendiente) {   // siguió hablando mientras pensábamos: se contesta lo nuevo (lo anterior ya quedó en la conversación)
      const mas = this.pendiente; this.pendiente = '';
      if (r.ok && (r.accion === 'pasar_persona' || r.accion === 'despedir')) {   // pero si ya iba a pasar o colgar, se cumple
        const dijo = r.respuesta ? await this.decir(r.respuesta, r.idioma || this.idioma) : true;
        if (this.cerrada) return;
        if (r.accion === 'pasar_persona' && this.transferirA) return this.pasar(this.transferirA, r.idioma || this.idioma);
        if (r.accion === 'despedir' && dijo !== false) return this.colgar();
      }
      return this.turno(mas, true);
    }
    if (!r.ok) {
      if (this.transferirA) return this.pasar(this.transferirA, this.idioma);
      await this.decir(this.idioma === 'en' ? 'Sorry, I had a problem. Our team will call you back.' : 'Disculpe, tuve un problema. El equipo le devuelve la llamada.', this.idioma);
      return this.colgar();
    }
    this.idioma = r.idioma || this.idioma;
    const dijo = r.respuesta ? await this.decir(r.respuesta, this.idioma) : true;
    if (this.cerrada) return;
    if (dijo === 'error') return this.sinVoz(r.respuesta);
    if (dijo === false) { this.ponerSilencio(); return; }   // la interrumpieron: lo que diga ahora llega como otro turno
    if (r.accion === 'pasar_persona') {
      if (this.transferirA) return this.pasar(this.transferirA, this.idioma);
      await this.decir(this.idioma === 'en' ? 'No one is available right now. Our team will call you back soon. Goodbye.' : 'En este momento no hay nadie disponible. El equipo le devuelve la llamada pronto. Hasta luego.', this.idioma);
      return this.colgar();
    }
    if (r.accion === 'despedir') return this.colgar();
    this.ponerSilencio();
  }

  // ---- voz (ElevenLabs, sale ya en el formato del teléfono) ----
  // Devuelve true (lo dijo completo), false (lo interrumpieron o se colgó) o 'error' (la voz no funcionó).
  async decir(texto, idioma) {
    if (!texto || this.cerrada) return false;
    this.callar(); this.quitarSilencio();
    const ctl = new AbortController(); this.ttsCtl = ctl; this.hablando = true;
    const nombre = 'm' + (++this.n);
    let bytes = 0, fallo = false;
    try {
      const r = await fetch(`${CFG.elUrl}/${encodeURIComponent(this.voz)}/stream?output_format=ulaw_8000`, {
        method: 'POST', signal: ctl.signal,
        headers: { 'xi-api-key': CFG.elKey, 'content-type': 'application/json', accept: 'audio/basic' },
        body: JSON.stringify({ text: texto, model_id: 'eleven_flash_v2_5', language_code: idioma === 'en' ? 'en' : 'es' }),
      });
      if (!r.ok || !r.body) throw new Error('voz ' + r.status);
      for await (const pedazo of r.body) {
        if (ctl.signal.aborted) break;
        bytes += pedazo.length;
        this.enviar({ event: 'media', streamSid: this.streamSid, media: { payload: Buffer.from(pedazo).toString('base64') } });
      }
    } catch (e) { if (!ctl.signal.aborted) { log('voz error', e.message); fallo = true; } }
    if (ctl.signal.aborted) { if (this.ttsCtl === ctl) this.ttsCtl = null; return false; }
    if (fallo || bytes === 0) { if (this.ttsCtl === ctl) { this.hablando = false; this.ttsCtl = null; } return 'error'; }
    // esperar a que el teléfono termine de ponerlo (marca). Si la marca no vuelve, se calcula por lo largo del audio (8000 bytes = 1 s).
    const termino = await new Promise((ok) => {
      let listo = false; const fin = (v) => { if (listo) return; listo = true; clearTimeout(tt); this.marcas.delete(nombre); ok(v); };
      const tt = setTimeout(() => fin(true), Math.ceil(bytes / 8000 * 1000) + 1500);
      this.marcas.set(nombre, () => fin(true));
      ctl.signal.addEventListener('abort', () => fin(false), { once: true });
      this.enviar({ event: 'mark', streamSid: this.streamSid, mark: { name: nombre } });
    });
    if (this.ttsCtl === ctl) { this.hablando = false; this.ttsCtl = null; }
    return termino;
  }

  callar() {
    if (this.ttsCtl) { this.ttsCtl.abort(); this.ttsCtl = null; }
    if (this.hablando) this.enviar({ event: 'clear', streamSid: this.streamSid });
    this.hablando = false;
  }

  // La voz de ElevenLabs falló: que lo diga el teléfono con su propia voz y se pase o se cuelgue.
  async sinVoz(texto) {
    if (this.cerrada) return;
    const lang = this.idioma === 'en' ? 'en-US' : 'es-MX';
    const despues = this.transferirA ? `<Dial timeout="25"${this.a ? ` callerId="${xml(this.a)}"` : ''}>${xml(this.transferirA)}</Dial>` : '<Hangup/>';
    const aviso = this.idioma === 'en' ? 'Sorry, we have a technical problem. ' : 'Disculpe, tenemos un problema técnico. ';
    if (this.transferirA) this.pasada = true; else this.colgando = true;
    const ok = await cambiarLlamada(this, `<Response><Say language="${lang}">${xml(aviso + (this.transferirA ? '' : String(texto || '').slice(0, 300)))}</Say>${despues}</Response>`);
    if (!ok) { this.pasada = false; this.colgando = false; return this.colgar(); }
    this.colgada = true; this.cerrar('sin_voz');
  }

  // ---- silencio: "¿sigue ahí?" y luego se despide ----
  ponerSilencio() {
    this.quitarSilencio();
    if (this.cerrada) return;
    this.tSilencio = setTimeout(async () => {
      this.tSilencio = null;
      if (this.cerrada || this.pensando || this.hablando) return;
      this.avisosSilencio++;
      if (this.avisosSilencio >= 2) return this.despedir('silencio');
      const dijo = await this.decir(this.idioma === 'en' ? 'Are you still there?' : '¿Sigue ahí?', this.idioma);
      if (dijo === 'error') return this.colgar();
      if (!this.cerrada && !this.pensando) this.ponerSilencio();
    }, CFG.silencioMs);
  }
  quitarSilencio() { if (this.tSilencio) { clearTimeout(this.tSilencio); this.tSilencio = null; } }

  async despedir(porque) {
    if (this.cerrada) return;
    log('despedida', porque, this.callSid);
    await this.decir(this.idioma === 'en' ? 'Thank you for calling. Goodbye.' : 'Gracias por llamar. Hasta luego.', this.idioma);
    this.colgar();
  }

  async pasar(numero, idioma) {
    if (this.cerrada || this.colgando || this.pasando) return;
    this.pasando = true;
    const dice = idioma === 'en' ? 'Please hold while I connect you.' : 'Un momento, le comunico.';
    await this.decir(dice, idioma);   // lo decimos con nuestra voz (igual en Telnyx y en Twilio)
    if (this.cerrada) return;   // colgó o se cortó mientras avisábamos: "cerrar" ya colgó la llamada
    this.pasada = true;
    const ok = await cambiarLlamada(this, `<Response><Dial timeout="25"${this.a ? ` callerId="${xml(this.a)}"` : ''}>${xml(numero)}</Dial></Response>`);
    if (!ok) { this.pasada = false; await this.decir(idioma === 'en' ? 'Our team will call you back soon. Goodbye.' : 'El equipo le devuelve la llamada pronto. Hasta luego.', idioma); return this.colgar(); }
    this.colgada = true; this.cerrar('pasada');
  }

  async colgar() {
    if (this.cerrada || this.colgando) return;
    this.colgando = true;
    if (await cambiarLlamada(this, 'colgar')) this.colgada = true;
    else { try { this.tw.close(); } catch (_) {} }
    this.cerrar('colgamos');
  }

  async cerrar(porque) {
    if (this.cerrada) return; this.cerrada = true;
    clearTimeout(this.tMax); clearTimeout(this.tStart); this.quitarSilencio(); clearInterval(this.dgVivo);
    if (this.ttsCtl) this.ttsCtl.abort();
    for (const f of this.marcas.values()) { try { f(); } catch (_) {} } this.marcas.clear();
    try {
      if (this.dg?.readyState === WebSocket.OPEN) { this.dg.send(JSON.stringify({ type: 'CloseStream' })); this.dg.close(); }
      else if (this.dg) this.dg.terminate();
    } catch (_) {}
    // Telnyx: si el audio se cortó y nadie colgó, la llamada seguiría abierta en silencio (y cobrando): se cuelga aquí.
    if (CFG.proveedor === 'telnyx' && !this.colgada && !this.colgando && !this.pasada && this.callSid && porque !== 'sin_pase') {
      this.colgada = await cambiarLlamada(this, 'colgar');
    }
    if (this.callSid) VIVAS.delete(this.callSid);
    log('fin', porque, this.callSid, Math.round((Date.now() - this.inicio) / 1000) + 's');
    if (this.llamadaId) await cerebro({ accion: 'fin', llamada_id: this.llamadaId, duracion_seg: Math.round((Date.now() - this.inicio) / 1000), pasada: this.pasada });
  }
}

const wss = new WebSocketServer({ noServer: true });
servidor.on('upgrade', (req, sock, head) => {
  if (req.url.split('?')[0] !== '/media') return sock.destroy();
  let pase = null;
  if (CFG.proveedor === 'telnyx') {   // Telnyx: el pase viene en la dirección; sin pase válido no se abre nada
    pase = usarPase(new URLSearchParams(req.url.split('?')[1] || '').get('t'));
    if (!pase) { sock.write('HTTP/1.1 403 Forbidden\r\n\r\n'); return sock.destroy(); }
  }
  wss.handleUpgrade(req, sock, head, (ws) => new Llamada(ws, pase));
});

process.on('unhandledRejection', (e) => log('unhandledRejection', e && e.message));   // un error raro no tumba todas las llamadas

if (require.main === module) {
  const faltan = ['host', 'dgKey', 'elKey', 'vozFabrica', 'cerebro', 'anon', 'secreto', ...(CFG.proveedor === 'telnyx' ? ['txKey'] : ['twSid', 'twToken'])].filter((k) => !CFG[k]);
  if (CFG.proveedor === 'telnyx' && !CFG.txPublica && !CFG.urlClave) faltan.push('TELNYX_PUBLIC_KEY o VOZ_URL_CLAVE');
  if (CFG.urlClave && CFG.urlClave.length < 24) faltan.push('VOZ_URL_CLAVE muy corta (mínimo 24 letras)');
  if (faltan.length) log('OJO, faltan variables:', faltan.join(', '));
  servidor.listen(CFG.puerto, () => log('servidor de voz escuchando en', CFG.puerto));
}
module.exports = { servidor, CFG, firmaOk, firmaTelnyxOk };
