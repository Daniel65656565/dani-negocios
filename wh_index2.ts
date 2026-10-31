// DANI Pro — "stripe-webhook": Stripe avisa aquí cuando alguien paga, cancela, le falla el pago, le devuelven el dinero o hay disputa.
// SE DESPLIEGA CON verify_jwt APAGADO (Stripe no manda token de Supabase; se revisa la firma de Stripe).
// - Revisa la firma (STRIPE_WEBHOOK_SECRET, 5 minutos).
// - Solo atiende avisos del mismo modo que la llave (prueba con sk_test_, real con sk_live_).
// - No repite avisos: el id del evento se guarda "procesando" y luego "hecho". Si llega otra vez mientras se procesa, contesta 500
//   para que Stripe lo mande más tarde.
// - Siempre trae la suscripción fresca de Stripe (los avisos pueden llegar desordenados).
// - Si aparece un SEGUNDO plan vivo para el mismo negocio (o persona), lo cancela enseguida y devuelve el dinero.
// - Los avisos se atienden aunque cobro_activo esté apagado: una cancelación tiene que apagar el plan igual.
// Nunca devuelve detalles de errores. Si algo falla, contesta 500 y Stripe lo vuelve a mandar después.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { verificarFirma, queHacer, datosSuscripcion, recorte, mismoModo, modoLlave, pagoDeFactura } from "./logica.ts";

const STRIPE_VERSION = "2026-10-28.endive";
const VIVOS = ["active", "trialing", "past_due", "unpaid", "incomplete", "paused"];
function claveServidor(): string {
  try { const d = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}"); const v = Object.values(d)[0]; if (typeof v === "string" && v) return v; } catch (_) { /* sigue */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}
const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", claveServidor(), { auth: { persistSession: false } });
const resp = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
const LLAVE = () => Deno.env.get("STRIPE_SECRET_KEY") ?? "";

class ErrorStripe extends Error { constructor(public status: number, public codigo: string) { super("stripe_" + status); } }
async function stripe(metodo: "GET" | "POST" | "DELETE", ruta: string, params?: Record<string, string>, idem?: string): Promise<Record<string, unknown>> {
  const h: Record<string, string> = { Authorization: "Bearer " + LLAVE(), "Stripe-Version": STRIPE_VERSION };
  if (params) h["Content-Type"] = "application/x-www-form-urlencoded";
  if (idem) h["Idempotency-Key"] = idem;
  const r = await fetch("https://api.stripe.com/v1/" + ruta, { method: metodo, headers: h, body: params ? new URLSearchParams(params).toString() : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new ErrorStripe(r.status, String(j?.error?.code ?? j?.error?.type ?? ""));
  return j;
}

async function planDe(price: string | null, meta: string | null): Promise<string | null> {
  if (price) { const { data } = await db.from("planes").select("id").eq("stripe_price_id", price).eq("intervalo", "mes").maybeSingle(); if (data?.id) return data.id; }
  return meta;
}
const creditosDe = (b: Record<string, unknown> | null | undefined) => Math.floor((typeof b?.creditos === "number" ? b.creditos : 0) + (typeof b?.regalo === "number" ? b.regalo : 0));

// segundo plan del mismo negocio/persona: se cancela ya y se devuelve lo que se cobró
async function cancelarYDevolver(s: ReturnType<typeof datosSuscripcion>) {
  if (s.estado !== "canceled" && s.estado !== "incomplete_expired") {
    try { await stripe("DELETE", "subscriptions/" + encodeURIComponent(s.sub_id)); }
    catch (e) { if (!(e instanceof ErrorStripe && e.status === 404)) throw e; }
  }
  if (!s.ultima_factura) return;
  const inv = await stripe("GET", "invoices/" + encodeURIComponent(s.ultima_factura) + "?expand[]=payments");
  const pi = pagoDeFactura(inv);
  if (!pi || !(typeof inv.amount_paid === "number" && inv.amount_paid > 0)) return;
  try { await stripe("POST", "refunds", { payment_intent: pi, reason: "duplicate", "metadata[app]": "dani_pro", "metadata[motivo]": "plan_duplicado" }, "reembolso-" + s.sub_id); }
  catch (e) { if (!(e instanceof ErrorStripe && e.codigo === "charge_already_refunded")) throw e; }
  console.log("plan duplicado cancelado y devuelto", s.sub_id);
}

async function sincronizar(live: boolean, subId: string, factura: string | null, conCreditos: boolean, sessionId: string | null) {
  const s = datosSuscripcion(await stripe("GET", "subscriptions/" + encodeURIComponent(subId)));
  if (s.app !== "dani_pro") return;                      // otra cosa de la cuenta de Stripe
  if (s.livemode !== null && s.livemode !== live) return;
  const plan = await planDe(s.price_id, s.plan_meta);
  const { data, error } = await db.rpc("pagos_sync_suscripcion", { p_sub: s.sub_id, p_customer: s.customer, p_user: s.user_id, p_negocio: s.negocio_id, p_plan: plan,
    p_estado: s.estado, p_periodo_fin: s.periodo_fin, p_cancela: s.cancela, p_live: live });
  if (error) throw new Error("sync");
  if (sessionId) await db.from("pagos_pendientes").delete().eq("session_id", sessionId);
  if (data?.duplicada) { if (VIVOS.includes(s.estado) || factura) await cancelarYDevolver(s); return; }
  // esta sí quedó: las otras (sin pagar o incompletas) se marcaron duplicadas y se cancelan (y se devuelve si algo se pagó)
  for (const otra of (Array.isArray(data?.cancelar) ? data.cancelar : []) as unknown[]) {
    if (typeof otra !== "string" || !/^sub_[A-Za-z0-9]+$/.test(otra)) continue;
    await cancelarYDevolver(datosSuscripcion(await stripe("GET", "subscriptions/" + encodeURIComponent(otra))));
  }
  // plan con créditos cada mes: solo primer cobro y renovaciones con dinero (lo decide queHacer), una vez por factura.
  // No depende del estado de la suscripción (puede venir atrasado): la factura ya está pagada.
  if (factura && conCreditos && data?.user_id && data?.plan_id) {
    const { data: p } = await db.from("planes").select("beneficios").eq("id", data.plan_id).maybeSingle();
    const n = creditosDe(p?.beneficios);
    if (n > 0) {
      // el pago de la factura queda anotado: si se devuelve o hay disputa, se quitan estos créditos
      const pi = pagoDeFactura(await stripe("GET", "invoices/" + encodeURIComponent(factura) + "?expand[]=payments"));
      const { error: e2 } = await db.rpc("pagos_dar_creditos", { p_user: data.user_id, p_n: Math.min(n, 1000000), p_clave: factura, p_detalle: "Plan " + data.plan_id, p_pi: pi });
      if (e2) throw new Error("creditos");
    }
  }
}

async function darCreditos(a: { user_id: string; plan_id: string; creditos: number | null; clave: string; pi: string | null; negocio_id?: string | null }) {
  const { data: p } = await db.from("planes").select("beneficios,para").eq("id", a.plan_id).maybeSingle();
  let n = a.creditos;
  if (!n) n = creditosDe(p?.beneficios);
  if (!n || n < 1) throw new Error("paquete_sin_creditos");
  // paquete de un NEGOCIO: los créditos van a la bolsa del negocio y no vencen (solo si el plan de verdad es de negocio)
  if (p?.para === "negocio" && a.negocio_id) {
    const { data: r, error: en } = await db.rpc("pagos_dar_creditos_negocio", { p_negocio: a.negocio_id, p_user: a.user_id, p_n: Math.min(n, 100000000), p_clave: a.clave, p_detalle: "Paquete " + a.plan_id, p_pi: a.pi });
    if (en) throw new Error("creditos_negocio");
    if (r?.ok === false) console.error("creditos negocio no aplicados", r?.motivo);
    return;
  }
  const { error } = await db.rpc("pagos_dar_creditos", { p_user: a.user_id, p_n: Math.min(n, 1000000), p_clave: a.clave, p_detalle: "Paquete " + a.plan_id, p_pi: a.pi });
  if (error) throw new Error("creditos");
}

async function quitarCreditos(a: { pi: string; fraccion: number; por: string }) {
  const { error } = await db.rpc("pagos_quitar_creditos", { p_pi: a.pi, p_fraccion: a.fraccion, p_detalle: a.por === "disputa" ? "Disputa del pago" : "Devolución del pago" });
  if (error) throw new Error("devolucion");
}

// ¿se puede atender este evento? (lo marca "procesando"). "repetido" = ya está hecho; "ocupado" = otro lo está procesando ahora
async function tomarEvento(ev: { id: string; type: string; livemode?: boolean; data?: { object?: Record<string, unknown> } }): Promise<"si" | "repetido" | "ocupado" | "error"> {
  const { error } = await db.from("pagos_eventos").insert({ id: ev.id, tipo: ev.type.slice(0, 80), estado: "procesando", payload: recorte(ev) });
  if (!error) return "si";
  if (error.code !== "23505") { console.error("webhook guardar", error.code); return "error"; }
  const { data } = await db.from("pagos_eventos").select("estado").eq("id", ev.id).maybeSingle();
  if (data?.estado === "hecho") return "repetido";
  // se quedó "procesando" más de 5 minutos (la función se cayó): se vuelve a tomar
  const { data: tomado } = await db.from("pagos_eventos").update({ creado_en: new Date().toISOString() }).eq("id", ev.id).eq("estado", "procesando")
    .lt("creado_en", new Date(Date.now() - 5 * 60_000).toISOString()).select("id");
  return tomado?.length ? "si" : "ocupado";
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return resp({ ok: false }, 405);
  const secreto = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
  const live = modoLlave(LLAVE());
  if (!secreto || live === null) return resp({ ok: false, motivo: "cobro_apagado" }, 503);
  const cuerpo = await req.text();                        // crudo: la firma se calcula sobre el texto exacto
  if (cuerpo.length > 512 * 1024) return resp({ ok: false }, 413);
  const f = await verificarFirma(cuerpo, req.headers.get("Stripe-Signature"), secreto);
  if (!f.ok) return resp({ ok: false }, 400);
  let ev: { id: string; type: string; livemode?: boolean; data?: { object?: Record<string, unknown> } };
  try { ev = JSON.parse(cuerpo); } catch (_) { return resp({ ok: false }, 400); }
  if (typeof ev?.id !== "string" || !/^evt_[A-Za-z0-9]+$/.test(ev.id) || typeof ev.type !== "string") return resp({ ok: false }, 400);
  if (!mismoModo(ev, live)) return resp({ ok: true, ignorado: "modo" });   // aviso de prueba con llave real (o al revés): no se toca nada

  const t = await tomarEvento(ev);
  if (t === "repetido") return resp({ ok: true, repetido: true });
  if (t !== "si") return resp({ ok: false }, 500);
  try {
    const a = queHacer(ev);
    if (a.tipo === "sync_sub") await sincronizar(live, a.sub_id, a.factura ?? null, !!a.creditos_factura, a.session_id ?? null);
    else if (a.tipo === "creditos") await darCreditos(a);
    else if (a.tipo === "devolucion") await quitarCreditos(a);
    await db.from("pagos_eventos").update({ estado: "hecho" }).eq("id", ev.id);
    return resp({ ok: true });
  } catch (e) {
    console.error("webhook", ev.type, (e as Error)?.message ?? "error");
    await db.from("pagos_eventos").delete().eq("id", ev.id);   // así, cuando Stripe lo mande otra vez, se intenta de nuevo
    return resp({ ok: false }, 500);
  }
});
