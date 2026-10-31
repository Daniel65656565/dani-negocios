// DANI Pro — "pagos": la persona paga sola con Stripe (planes del negocio, planes de persona y paquetes de créditos).
// Acciones (en el cuerpo): "estado" (pública), "pagar" y "portal" (con la sesión de la persona).
// Todo está APAGADO hasta que exista la llave STRIPE_SECRET_KEY y creditos_config.cobro_activo = true:
// mientras tanto contesta {ok:false, motivo:"cobro_apagado"} y la app no enseña nada de pagos.
// Los precios salen SIEMPRE de la tabla planes; nunca de la app. Ver sql/33_pagos_stripe.sql y LEEME_PAGOS.md.
// Modo de prueba y modo real no se mezclan: solo se usan filas con el mismo livemode que la llave.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { APP_URL, ESTADOS_VIVOS, esPanel, clavePendiente, decidirPendiente, form, modoLlave, paramsCheckout, planPublico, precioCoincide, revisarPlan, validarPedido, VENCE_SEG, type Plan } from "./logica.ts";

const STRIPE_VERSION = "2026-10-28.endive";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
function json(b: unknown, s = 200) { return new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } }); }
function claveServidor(): string {
  try { const d = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}"); const v = Object.values(d)[0]; if (typeof v === "string" && v) return v; } catch (_) { /* sigue */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}
const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", claveServidor(), { auth: { persistSession: false } });
const COLS = "id,nombre,nombre_en,descripcion,descripcion_en,para,precio_usd,intervalo,stripe_price_id,beneficios,activo,orden,producto,maquinas,cupo_max,vende_hasta";
const LLAVE = () => Deno.env.get("STRIPE_SECRET_KEY") ?? "";

class ErrorStripe extends Error { constructor(public status: number, public codigo: string) { super("stripe"); } }
async function stripe(ruta: string, params: Record<string, unknown> | null, idem?: string) {
  const h: Record<string, string> = { Authorization: "Bearer " + LLAVE(), "Stripe-Version": STRIPE_VERSION };
  if (params) h["Content-Type"] = "application/x-www-form-urlencoded";
  if (idem) h["Idempotency-Key"] = idem;
  const r = await fetch("https://api.stripe.com/v1/" + ruta, { method: params ? "POST" : "GET", headers: h, body: params ? form(params) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new ErrorStripe(r.status, String(j?.error?.code ?? j?.error?.type ?? ""));
  return j;
}

// ¿se puede cobrar? llave puesta (de prueba o real) Y cobro_activo prendido. Devuelve el modo, o null si está apagado.
let modoAnotado: boolean | null = null;   // lo último que esta función anotó en pagos_modo (para no llamar cada vez)
async function anotarModo(live: boolean) {
  if (modoAnotado === live) return;
  const { error } = await db.rpc("pagos_anotar_modo", { p_live: live });   // en la base solo escribe si cambió
  if (!error) modoAnotado = live;
}
async function modoCobro(): Promise<boolean | null> {
  const live = modoLlave(LLAVE()); if (live === null) return null;
  await anotarModo(live);
  const { data } = await db.from("creditos_config").select("cobro_activo").eq("id", 1).maybeSingle();
  return data?.cobro_activo ? live : null;
}

async function clienteDe(user: string, correo: string, live: boolean): Promise<string> {
  const ver = async () => (await db.from("clientes_stripe").select("stripe_customer_id").eq("user_id", user).eq("livemode", live).maybeSingle()).data?.stripe_customer_id as string | undefined;
  const ya = await ver(); if (ya) return ya;
  const c = await stripe("customers", { email: correo, metadata: { app: "dani_pro", user_id: user } }, "cliente-" + user + "-" + (live ? "live" : "test"));
  const { error } = await db.from("clientes_stripe").insert({ user_id: user, livemode: live, stripe_customer_id: c.id });
  if (error) { const d2 = await ver(); if (d2) return d2; throw new Error("cliente"); }
  return c.id;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "accion" }, 405);
  try {
    const live = await modoCobro();
    if (live === null) return json({ ok: false, motivo: "cobro_apagado" });
    const b = await req.json().catch(() => null);
    const v = validarPedido(b);
    if (!v.ok) return json({ ok: false, motivo: v.motivo }, 400);

    if (v.accion === "estado") {
      const { data } = await db.from("planes").select(COLS).eq("activo", true).order("orden");
      const todos = (data ?? []) as Plan[];
      const dani = todos.filter((p) => !esPanel(p));
      // (31 oct 2026) planes del Panel NinjaTrader: aparte, sin los que ya se vencieron, con cuántos quedan (Fundadores)
      const panel = [];
      for (const p of todos.filter((x) => esPanel(x) && !(x.vende_hasta && !(Date.parse(x.vende_hasta) > Date.now())))) {
        let quedan: number | null = null;
        if (p.cupo_max != null) { const { data: c } = await db.rpc("panel_cupo_libre", { p_plan: p.id }); quedan = typeof c === "number" ? c : 0; if (quedan < 1) continue; }
        panel.push({ ...planPublico(p), quedan });
      }
      return json({ ok: true, live, planes: dani.filter((p) => p.intervalo === "mes").map(planPublico), paquetes: dani.filter((p) => p.intervalo === "unico").map(planPublico), panel });
    }

    // de aquí para abajo hace falta la sesión de la persona
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(token);
    const user = u?.user?.id; const correo = u?.user?.email ?? "";
    if (!user) return json({ error: "Entra a la app otra vez y vuelve a probar." }, 401);
    if (u.user.is_anonymous || !correo) return json({ ok: false, motivo: "necesita_cuenta" });
    const esDueno = async (neg: string) => (await db.from("negocio_miembros").select("rol").eq("negocio_id", neg).eq("user_id", user).maybeSingle()).data?.rol === "dueno";

    if (v.accion === "portal") {
      let customer: string | undefined;
      if (v.negocio_id) {   // plan de un negocio: el portal es de quien lo pagó
        if (!(await esDueno(v.negocio_id))) return json({ ok: false, motivo: "no_dueno" });
        const { data: s } = await db.from("suscripciones").select("user_id,stripe_customer_id").eq("negocio_id", v.negocio_id).eq("livemode", live).eq("duplicada", false)
          .order("actualizado_en", { ascending: false }).limit(1).maybeSingle();
        if (!s) return json({ ok: false, motivo: "sin_pagos" });
        if (s.user_id !== user) return json({ ok: false, motivo: "otro_pago" });
        customer = s.stripe_customer_id;
      } else {
        customer = (await db.from("clientes_stripe").select("stripe_customer_id").eq("user_id", user).eq("livemode", live).maybeSingle()).data?.stripe_customer_id;
      }
      if (!customer) return json({ ok: false, motivo: "sin_pagos" });
      const s = await stripe("billing_portal/sessions", { customer, return_url: APP_URL, locale: v.idioma });
      return json({ ok: true, url: s.url });
    }

    // pagar
    const { data: plan } = await db.from("planes").select(COLS).eq("id", v.plan_id!).maybeSingle();
    const rp = revisarPlan(plan as Plan | null, v.negocio_id ?? null);
    if (!rp.ok) return json({ ok: false, motivo: rp.motivo });
    const p = plan as Plan;
    if (esPanel(p)) {
      if (p.cupo_max != null) { const { data: c } = await db.rpc("panel_cupo_libre", { p_plan: p.id }); if (!(typeof c === "number" && c > 0)) return json({ ok: false, motivo: "agotado" }); }
    } else if (p.para === "negocio") {
      if (!(await esDueno(v.negocio_id!))) return json({ ok: false, motivo: "no_dueno" });
      // (31 oct 2026) paquete de créditos para el negocio: se puede comprar aunque ya tenga plan
      if (p.intervalo === "mes") {
      const { data: ya } = await db.from("suscripciones").select("id").eq("negocio_id", v.negocio_id!).eq("livemode", live).eq("duplicada", false).in("estado", ESTADOS_VIVOS).limit(1);
      if (ya?.length) return json({ ok: false, motivo: "ya_tiene_plan" });
      }
    } else if (p.intervalo === "mes") {
      const { data: ya } = await db.from("suscripciones").select("id").eq("user_id", user).is("negocio_id", null).eq("livemode", live).eq("duplicada", false).in("estado", ESTADOS_VIVOS).limit(1);
      if (ya?.length) return json({ ok: false, motivo: "ya_tiene_plan" });
    }
    // si el plan usa un precio de Stripe, tiene que cobrar lo mismo que dice la tabla
    if (p.stripe_price_id) {
      let pr: Record<string, unknown> | null = null;
      try { pr = await stripe("prices/" + encodeURIComponent(p.stripe_price_id), null); } catch (e) { if (!(e instanceof ErrorStripe && e.status === 404)) throw e; }
      const pc = precioCoincide(p, pr);
      if (!pc.ok) { console.error("precio no coincide", p.id, pc.por); return json({ ok: false, motivo: "precio_no_coincide" }); }
    }
    // una sola sesión abierta por negocio (o persona): la anterior se vence antes de abrir otra
    const clave = clavePendiente(p, user, v.negocio_id ?? null);
    if (clave) {
      const { data: pen } = await db.from("pagos_pendientes").select("session_id,url,intento,user_id,expira").eq("clave", clave).eq("livemode", live).maybeSingle();
      const d = decidirPendiente(pen, { ahoraMs: Date.now(), intento: v.intento!, user_id: user });
      if (d === "reusar") return json({ ok: true, url: pen!.url });
      if (d === "expirar") {
        try { await stripe("checkout/sessions/" + encodeURIComponent(pen!.session_id) + "/expire", {}); }
        catch (e) {
          if (!(e instanceof ErrorStripe)) throw e;
          const ses = await stripe("checkout/sessions/" + encodeURIComponent(pen!.session_id), null);
          if (ses.status === "complete") return json({ ok: false, motivo: "pago_en_camino" });   // ya pagaron: el aviso de Stripe viene en camino
          if (ses.status !== "expired") throw e;
        }
      }
    }
    const customer = await clienteDe(user, correo, live);
    const ahora = Math.floor(Date.now() / 1000);
    const params = paramsCheckout(p, { user_id: user, negocio_id: v.negocio_id ?? null, customer, idioma: v.idioma, ahoraSeg: ahora });
    // la misma "intento" (un toque del botón) siempre da la misma sesión: tocar dos veces no cobra dos veces
    const s = await stripe("checkout/sessions", params, "pagar-" + user + "-" + p.id + "-" + v.intento);
    if (clave) await db.from("pagos_pendientes").upsert({ clave, livemode: live, session_id: s.id, url: s.url, intento: v.intento, user_id: user, expira: new Date((ahora + VENCE_SEG) * 1000).toISOString() });
    return json({ ok: true, url: s.url });
  } catch (e) {
    if (e instanceof ErrorStripe) { console.error("stripe", e.status, e.codigo); return json({ ok: false, motivo: "stripe" }); }
    console.error("pagos", (e as Error)?.message ?? e);
    return json({ ok: false, motivo: "error" }, 500);
  }
});
