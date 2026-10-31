// DANI Pro — "licencia": el "Panel Dani para NinjaTrader" pregunta aquí si su licencia sirve (31 oct 2026).
// Se sube con "Verify JWT" APAGADO: el complemento no lleva ninguna clave de Supabase.
// Acciones: activar, comprobar, soltar, llave (la llave pública, para el programador).
// Contesta firmado con ECDSA P-256 + SHA-256 (firma IEEE P1363 r||s en base64). La llave privada se crea sola la
// primera vez y se guarda en la tabla licencia_llave (RLS: solo el servidor). Nadie la tiene que copiar a mano.
// El complemento solo manda: clave, huella de la máquina (sha256 hex) y versión. Nunca cuentas ni operaciones.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", { auth: { persistSession: false } });
const GRACIA_DIAS = 3;   // sin internet, el complemento sigue funcionando hasta valida_hasta
const RX_CLAVE = /^DANI-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/;
const RX_MAQ = /^[0-9a-f]{64}$/;
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
const b64 = (u: Uint8Array) => { let s = ""; for (const c of u) s += String.fromCharCode(c); return btoa(s); };
const b64deUrl = (s: string) => { const t = s.replace(/-/g, "+").replace(/_/g, "/"); return t + "=".repeat((4 - t.length % 4) % 4); };

let llaveCache: { privada: CryptoKey; pem: string; x: string; y: string } | null = null;
async function llave() {
  if (llaveCache) return llaveCache;
  let { data } = await db.from("licencia_llave").select("privada_jwk,publica_pem,x,y").eq("id", 1).maybeSingle();
  if (!data) {
    // primera vez: se crea la llave y se guarda (si dos la crean a la vez, gana la primera y las dos leen esa)
    const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const jwk = await crypto.subtle.exportKey("jwk", par.privateKey);
    const spki = new Uint8Array(await crypto.subtle.exportKey("spki", par.publicKey));
    const pem = "-----BEGIN PUBLIC KEY-----\n" + (b64(spki).match(/.{1,64}/g) ?? []).join("\n") + "\n-----END PUBLIC KEY-----\n";
    const { error } = await db.rpc("licencia_llave_guardar", { p_privada: jwk, p_pem: pem, p_x: b64deUrl(jwk.x!), p_y: b64deUrl(jwk.y!) });
    if (error) throw new Error("llave_guardar");
    ({ data } = await db.from("licencia_llave").select("privada_jwk,publica_pem,x,y").eq("id", 1).maybeSingle());
    if (!data) throw new Error("llave_leer");
  }
  const privada = await crypto.subtle.importKey("jwk", data.privada_jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  llaveCache = { privada, pem: data.publica_pem, x: data.x, y: data.y };
  return llaveCache;
}

async function firmar(obj: Record<string, unknown>) {
  const k = await llave();
  const bytes = new TextEncoder().encode(JSON.stringify(obj));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k.privada, bytes));   // WebCrypto da r||s (P1363)
  return { token: b64(bytes), firma: b64(sig) };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, estado: "error", motivo: "metodo" }, 405);
  try {
    const b = await req.json().catch(() => ({}));
    const accion = String(b.accion ?? "");
    if (accion === "llave") { const k = await llave(); return json({ ok: true, pem: k.pem, x: k.x, y: k.y, algoritmo: "ECDSA P-256 SHA-256, firma IEEE P1363 (r||s) base64" }); }
    const clave = String(b.clave ?? "").trim().toUpperCase();
    const maquina = String(b.maquina ?? "").trim().toLowerCase();
    const nombre = String(b.nombre ?? "").replace(/[\u0000-\u001f]/g, "").slice(0, 40);
    const version = String(b.version ?? "").replace(/[^\w.\-]/g, "").slice(0, 20);
    if (!["activar", "comprobar", "soltar"].includes(accion) || !RX_CLAVE.test(clave) || !RX_MAQ.test(maquina)) return json({ ok: false, estado: "datos_malos" }, 400);
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim().slice(0, 60);
    const { data: puede } = await db.rpc("licencia_intento", { p_ip: ip, p_clave: clave });
    if (puede !== true) return json({ ok: false, estado: "espera", motivo: "Muchos intentos. Prueba en 10 minutos." }, 429);

    let r: any;
    if (accion === "activar") r = (await db.rpc("licencia_activar", { p_clave: clave, p_maquina: maquina, p_nombre: nombre, p_version: version })).data;
    else if (accion === "comprobar") r = (await db.rpc("licencia_comprobar", { p_clave: clave, p_maquina: maquina, p_version: version })).data;
    else r = (await db.rpc("licencia_soltar", { p_clave: clave, p_maquina: maquina })).data;
    if (!r || typeof r !== "object") throw new Error("rpc");

    const estado = String(r.estado ?? "error");
    const ahora = new Date();
    const activa = estado === "activa";
    let valida = activa ? new Date(ahora.getTime() + GRACIA_DIAS * 86400000) : ahora;
    if (activa && r.vence && new Date(r.vence) < valida) valida = new Date(r.vence);   // nunca más allá de lo pagado
    const cuerpo = { clave, maquina, estado, plan: r.plan ?? null, vence: r.vence ?? null, valida_hasta: valida.toISOString(),
      maquinas_max: r.max ?? null, emitido: ahora.toISOString(), prueba: r.prueba === true };
    const f = await firmar(cuerpo);
    return json({ ok: activa || estado === "soltada", estado, plan: cuerpo.plan, vence: cuerpo.vence,
      maquinas: { usadas: r.usadas ?? 0, max: r.max ?? 0 }, token: f.token, firma: f.firma });
  } catch (e) {
    console.error("licencia", (e as Error)?.message ?? e);
    return json({ ok: false, estado: "error", motivo: "Algo falló. Prueba en un ratito." }, 500);
  }
});
