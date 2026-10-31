// DANI Pro — pagos: partes "puras" (sin red ni base de datos) para poder probarlas solas con Node o Deno.
// Las usa funciones/pagos/index.ts. No hay llaves aquí.

export const APP_URL = "https://daniel65656565.github.io/dani-negocios/";
export const RX_PLAN = /^[a-z0-9_-]{2,40}$/;
export const RX_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const RX_INTENTO = /^[A-Za-z0-9-]{8,64}$/;
export const ESTADOS_ON = ["active", "trialing"];
export const ESTADOS_VIVOS = ["active", "trialing", "past_due", "unpaid", "incomplete", "paused"];   // con uno de estos no se puede comprar otro igual

export type Plan = { id: string; nombre: string; nombre_en?: string; para: "negocio" | "persona"; precio_usd: number | string; intervalo: "mes" | "unico"; stripe_price_id?: string | null; beneficios?: Record<string, unknown>; activo?: boolean };
export type Pedido = { ok: true; accion: string; plan_id?: string; negocio_id?: string | null; intento?: string; idioma: "es" | "en" } | { ok: false; motivo: string };

// revisa lo que manda la app. Nunca se acepta un precio de la app: solo el id del plan.
export function validarPedido(b: unknown): Pedido {
  if (!b || typeof b !== "object" || Array.isArray(b)) return { ok: false, motivo: "datos" };
  const o = b as Record<string, unknown>;
  const accion = o.accion;
  if (accion !== "estado" && accion !== "pagar" && accion !== "portal") return { ok: false, motivo: "accion" };
  const idioma = o.idioma === "en" ? "en" : "es";
  if (accion === "estado") return { ok: true, accion, idioma };
  if (accion === "portal") {   // portal: opcionalmente de un negocio (abre el portal de quien pagó ese plan)
    for (const k of Object.keys(o)) if (!["accion", "negocio_id", "idioma"].includes(k)) return { ok: false, motivo: "datos" };
    if (o.negocio_id == null || o.negocio_id === "") return { ok: true, accion, negocio_id: null, idioma };
    if (typeof o.negocio_id !== "string" || !RX_UUID.test(o.negocio_id)) return { ok: false, motivo: "negocio" };
    return { ok: true, accion, negocio_id: o.negocio_id.toLowerCase(), idioma };
  }
  for (const k of Object.keys(o)) if (!["accion", "plan_id", "negocio_id", "intento", "idioma"].includes(k)) return { ok: false, motivo: "datos" };
  if (typeof o.plan_id !== "string" || !RX_PLAN.test(o.plan_id)) return { ok: false, motivo: "plan" };
  let negocio_id: string | null = null;
  if (o.negocio_id != null && o.negocio_id !== "") { if (typeof o.negocio_id !== "string" || !RX_UUID.test(o.negocio_id)) return { ok: false, motivo: "negocio" }; negocio_id = o.negocio_id.toLowerCase(); }
  if (typeof o.intento !== "string" || !RX_INTENTO.test(o.intento)) return { ok: false, motivo: "intento" };
  return { ok: true, accion, plan_id: o.plan_id, negocio_id, intento: o.intento, idioma };
}

// ¿el plan sirve para este pedido? (el plan ya viene de la base de datos)
export function revisarPlan(plan: Plan | null | undefined, negocio_id: string | null): { ok: true } | { ok: false; motivo: string } {
  if (!plan || !plan.activo) return { ok: false, motivo: "plan" };
  const p = Number(plan.precio_usd);
  if (!(p >= 0.5 && p <= 999.99)) return { ok: false, motivo: "plan" };
  if (plan.para === "negocio" && !negocio_id) return { ok: false, motivo: "negocio" };
  if (plan.para === "persona" && negocio_id) return { ok: false, motivo: "negocio" };
  if (plan.intervalo === "unico" && creditosDePlan(plan) < 1) return { ok: false, motivo: "plan" };
  return { ok: true };
}

export function creditosDePlan(plan: Plan): number {
  const b = (plan.beneficios ?? {}) as Record<string, unknown>;
  const n = (typeof b.creditos === "number" ? b.creditos : 0) + (typeof b.regalo === "number" ? b.regalo : 0);
  return Number.isFinite(n) && n > 0 ? Math.min(1000000, Math.floor(n)) : 0;
}

// los parámetros de la sesión de pago de Stripe (Checkout)
export const VENCE_SEG = 31 * 60;   // Stripe pide por lo menos 30 minutos; la sesión se vence sola a los 31
export function paramsCheckout(plan: Plan, x: { user_id: string; negocio_id: string | null; customer: string; idioma: "es" | "en"; base?: string; ahoraSeg?: number }): Record<string, unknown> {
  const base = x.base ?? APP_URL;
  const meta: Record<string, string> = { app: "dani_pro", user_id: x.user_id, plan_id: plan.id, tipo: plan.intervalo === "mes" ? "plan" : "paquete" };
  if (x.negocio_id) meta.negocio_id = x.negocio_id;
  if (plan.intervalo === "unico") meta.creditos = String(creditosDePlan(plan));
  const nombre = (x.idioma === "en" && plan.nombre_en) ? plan.nombre_en : plan.nombre;
  const linea: Record<string, unknown> = { quantity: 1 };
  if (plan.stripe_price_id) linea.price = plan.stripe_price_id;
  else linea.price_data = { currency: "usd", unit_amount: Math.round(Number(plan.precio_usd) * 100), product_data: { name: nombre.slice(0, 120) }, ...(plan.intervalo === "mes" ? { recurring: { interval: "month" } } : {}) };
  const p: Record<string, unknown> = {
    mode: plan.intervalo === "mes" ? "subscription" : "payment",
    customer: x.customer,
    client_reference_id: x.user_id,
    line_items: [linea],
    success_url: base + "?pago=ok&que=" + meta.tipo,
    cancel_url: base + "?pago=cancelado",
    locale: x.idioma,
    metadata: meta,
    allowed_payment_method_types: ["card"],          // solo tarjeta: el pago queda listo al momento (nombre nuevo de la versión Endive)
    expires_at: (x.ahoraSeg ?? Math.floor(Date.now() / 1000)) + VENCE_SEG,
  };
  if (plan.intervalo === "mes") p.subscription_data = { metadata: meta };
  else p.payment_intent_data = { metadata: meta };
  return p;
}

// convierte {a:{b:1}, c:[{d:2}]} en "a[b]=1&c[0][d]=2" (así lo pide Stripe)
export function form(obj: Record<string, unknown>): string {
  const out: string[] = [];
  const add = (k: string, v: unknown) => {
    if (v === undefined || v === null) return;
    if (Array.isArray(v)) v.forEach((x, i) => add(`${k}[${i}]`, x));
    else if (typeof v === "object") for (const [kk, vv] of Object.entries(v as Record<string, unknown>)) add(`${k}[${kk}]`, vv);
    else out.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(v)));
  };
  for (const [k, v] of Object.entries(obj)) add(k, v);
  return out.join("&");
}

// lo que se le enseña a la app de un plan (sin ids de Stripe)
export function planPublico(p: Plan & { descripcion?: string; descripcion_en?: string; orden?: number }) {
  return { id: p.id, nombre: p.nombre, nombre_en: p.nombre_en ?? "", descripcion: p.descripcion ?? "", descripcion_en: p.descripcion_en ?? "", para: p.para, precio_usd: Number(p.precio_usd), intervalo: p.intervalo, beneficios: p.beneficios ?? {}, orden: p.orden ?? 0 };
}

// modo de la llave de Stripe: true = real (sk_live_/rk_live_), false = prueba (sk_test_/rk_test_), null = no sirve
export function modoLlave(k: string | undefined | null): boolean | null {
  if (!k) return null;
  if (/^(sk|rk)_live_[A-Za-z0-9]+$/.test(k)) return true;
  if (/^(sk|rk)_test_[A-Za-z0-9]+$/.test(k)) return false;
  return null;
}

// una sola sesión de pago abierta por negocio (o por persona en planes de persona). Los paquetes no la necesitan.
export function clavePendiente(plan: Plan, user_id: string, negocio_id: string | null): string | null {
  if (plan.intervalo !== "mes") return null;
  return plan.para === "negocio" && negocio_id ? "n:" + negocio_id : "u:" + user_id;
}
// qué hacer con la sesión que ya está abierta: "reusar" (mismo toque del botón), "expirar" (otra), "libre" (no hay o ya se venció)
export function decidirPendiente(pen: { session_id: string; intento: string; user_id: string; expira: string } | null | undefined, x: { ahoraMs: number; intento: string; user_id: string }): "reusar" | "expirar" | "libre" {
  if (!pen) return "libre";
  if (!(Date.parse(pen.expira) > x.ahoraMs)) return "libre";
  if (pen.intento === x.intento && pen.user_id === x.user_id) return "reusar";
  return "expirar";
}

// si el plan tiene stripe_price_id, el precio en Stripe tiene que ser igual al de la tabla
export function precioCoincide(plan: Plan, price: Record<string, unknown> | null | undefined): { ok: true } | { ok: false; por: string } {
  if (!price || price.id !== plan.stripe_price_id) return { ok: false, por: "no_existe" };
  if (price.active === false) return { ok: false, por: "apagado" };
  if (String(price.currency ?? "").toLowerCase() !== "usd") return { ok: false, por: "moneda" };
  if (price.unit_amount !== Math.round(Number(plan.precio_usd) * 100)) return { ok: false, por: "monto" };
  const r = price.recurring as { interval?: string; interval_count?: number } | null | undefined;
  if (plan.intervalo === "mes") { if (!r || r.interval !== "month" || (r.interval_count ?? 1) !== 1) return { ok: false, por: "intervalo" }; }
  else if (r) return { ok: false, por: "intervalo" };
  return { ok: true };
}
