// DANI Pro — stripe-webhook: partes "puras" para probarlas solas (firma de Stripe y qué hacer con cada aviso).
// Firma: Stripe-Signature = "t=<segundos>,v1=<hex>[,v1=...][,v0=...]". Se firma "<t>.<cuerpo crudo>" con HMAC-SHA256
// y la clave whsec_... Solo vale v1. Se compara en tiempo constante. Tolerancia: 5 minutos (como las librerías de Stripe).

export const TOLERANCIA_SEG = 300;
const enc = new TextEncoder();

function hex(buf: ArrayBuffer): string { return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join(""); }
function igualesTiempoConstante(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function firmar(secreto: string, t: number | string, cuerpo: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", enc.encode(secreto), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(`${t}.${cuerpo}`)));
}

export async function verificarFirma(cuerpo: string, cabecera: string | null, secreto: string, ahoraSeg = Math.floor(Date.now() / 1000), tolerancia = TOLERANCIA_SEG): Promise<{ ok: true } | { ok: false; motivo: string }> {
  if (!secreto) return { ok: false, motivo: "sin_secreto" };
  if (!cabecera || cabecera.length > 2000) return { ok: false, motivo: "sin_firma" };
  let t: number | null = null; const v1: string[] = [];
  for (const parte of cabecera.split(",")) {
    const i = parte.indexOf("="); if (i < 1) continue;
    const k = parte.slice(0, i).trim(), v = parte.slice(i + 1).trim();
    if (k === "t" && /^\d{1,12}$/.test(v)) t = Number(v);
    else if (k === "v1" && /^[0-9a-f]{64}$/.test(v)) v1.push(v);
  }
  if (t === null || !v1.length) return { ok: false, motivo: "firma_mal_formada" };
  if (!(tolerancia > 0) || Math.abs(ahoraSeg - t) > tolerancia) return { ok: false, motivo: "vieja" };
  const esperada = await firmar(secreto, t, cuerpo);
  let ok = false; for (const s of v1) if (igualesTiempoConstante(s, esperada)) ok = true;   // revisa todas (no se sale antes)
  return ok ? { ok: true } : { ok: false, motivo: "firma" };
}

// ----- qué hacer con cada aviso -----
export type Accion =
  | { tipo: "nada"; por: string }
  | { tipo: "sync_sub"; sub_id: string; customer?: string | null; meta?: Record<string, string>; factura?: string | null; creditos_factura?: boolean; session_id?: string | null }
  | { tipo: "creditos"; user_id: string; plan_id: string; creditos: number | null; clave: string; customer?: string | null; pi: string | null; negocio_id?: string | null }
  | { tipo: "devolucion"; pi: string; fraccion: number; por: "reembolso" | "disputa" }
  | { tipo: "licencia_unica"; user_id: string; plan_id: string; clave: string; pi: string | null };   // (31 oct 2026) Panel NinjaTrader, pago único

const RX_SUB = /^sub_[A-Za-z0-9]+$/, RX_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const idDe = (v: unknown): string | null => typeof v === "string" ? v : (v && typeof v === "object" && typeof (v as { id?: unknown }).id === "string") ? (v as { id: string }).id : null;
const metaDe = (v: unknown): Record<string, string> => { const m: Record<string, string> = {}; if (v && typeof v === "object") for (const [k, x] of Object.entries(v as Record<string, unknown>)) if (typeof x === "string") m[k] = x; return m; };

export function queHacer(ev: { id?: string; type?: string; data?: { object?: Record<string, unknown> } }): Accion {
  const o = (ev?.data?.object ?? {}) as Record<string, unknown>;
  switch (ev?.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      const meta = metaDe(o.metadata);
      if (meta.app !== "dani_pro") return { tipo: "nada", por: "otra_app" };
      if (o.mode === "subscription") {
        const sub = idDe(o.subscription); if (!sub || !RX_SUB.test(sub)) return { tipo: "nada", por: "sin_suscripcion" };
        return { tipo: "sync_sub", sub_id: sub, customer: idDe(o.customer), meta, session_id: typeof o.id === "string" ? o.id : null };
      }
      if (o.mode === "payment") {
        if (o.payment_status !== "paid") return { tipo: "nada", por: "no_pagado_todavia" };   // pagos de banco: llega luego async_payment_succeeded
        const user = meta.user_id || (typeof o.client_reference_id === "string" ? o.client_reference_id : "");
        if (!RX_UUID.test(user) || !meta.plan_id || typeof o.id !== "string") return { tipo: "nada", por: "datos" };
        if (meta.tipo === "panel") return { tipo: "licencia_unica", user_id: user.toLowerCase(), plan_id: meta.plan_id, clave: o.id, pi: idDe(o.payment_intent) };
        const n = /^\d{1,7}$/.test(meta.creditos ?? "") ? Number(meta.creditos) : null;
        const neg = RX_UUID.test(meta.negocio_id ?? "") ? meta.negocio_id!.toLowerCase() : null;   // paquete de créditos de un negocio (31 oct 2026)
        return { tipo: "creditos", user_id: user.toLowerCase(), plan_id: meta.plan_id, creditos: n, clave: o.id, customer: idDe(o.customer), pi: idDe(o.payment_intent), negocio_id: neg };
      }
      return { tipo: "nada", por: "modo" };
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const sub = idDe(o.id); if (!sub || !RX_SUB.test(sub)) return { tipo: "nada", por: "datos" };
      const meta = metaDe(o.metadata); if (meta.app !== "dani_pro") return { tipo: "nada", por: "otra_app" };
      return { tipo: "sync_sub", sub_id: sub, customer: idDe(o.customer), meta };
    }
    case "invoice.paid":
    case "invoice.payment_failed": {
      // desde la versión Basil la suscripción está en parent.subscription_details; antes en invoice.subscription
      const par = (o.parent ?? {}) as Record<string, unknown>; const sd = (par.subscription_details ?? {}) as Record<string, unknown>;
      const sub = idDe(sd.subscription) ?? idDe(o.subscription);
      if (!sub || !RX_SUB.test(sub)) return { tipo: "nada", por: "sin_suscripcion" };
      // créditos del mes: solo con el primer cobro o la renovación, y si de verdad se pagó algo
      const pagada = ev.type === "invoice.paid" && typeof o.id === "string";
      const conCreditos = pagada && (o.billing_reason === "subscription_create" || o.billing_reason === "subscription_cycle") && typeof o.amount_paid === "number" && o.amount_paid > 0;
      return { tipo: "sync_sub", sub_id: sub, customer: idDe(o.customer), meta: metaDe(sd.metadata), factura: pagada ? o.id as string : null, creditos_factura: conCreditos };
    }
    case "charge.refunded": {
      const pi = idDe(o.payment_intent); if (!pi || !/^pi_[A-Za-z0-9]+$/.test(pi)) return { tipo: "nada", por: "sin_pago" };
      const total = typeof o.amount === "number" ? o.amount : 0, dev = typeof o.amount_refunded === "number" ? o.amount_refunded : 0;
      if (!(total > 0) || !(dev > 0)) return { tipo: "nada", por: "monto" };
      return { tipo: "devolucion", pi, fraccion: Math.min(1, dev / total), por: "reembolso" };
    }
    case "charge.dispute.created": {
      const pi = idDe(o.payment_intent); if (!pi || !/^pi_[A-Za-z0-9]+$/.test(pi)) return { tipo: "nada", por: "sin_pago" };
      return { tipo: "devolucion", pi, fraccion: 1, por: "disputa" };
    }
  }
  return { tipo: "nada", por: "tipo" };
}

// de una suscripción de Stripe a lo que guarda la base de datos
export function datosSuscripcion(s: Record<string, unknown>) {
  const meta = metaDe(s.metadata);
  const items = ((s.items as { data?: unknown[] } | undefined)?.data ?? []) as Record<string, unknown>[];
  const it = items[0] ?? {};
  const fin = (typeof it.current_period_end === "number" ? it.current_period_end : null) ?? (typeof s.current_period_end === "number" ? s.current_period_end : null);
  const price = idDe(it.price);
  const user = RX_UUID.test(meta.user_id ?? "") ? meta.user_id.toLowerCase() : null;
  const neg = RX_UUID.test(meta.negocio_id ?? "") ? meta.negocio_id.toLowerCase() : null;
  return {
    sub_id: String(s.id ?? ""), customer: idDe(s.customer), user_id: user, negocio_id: neg,
    plan_meta: /^[a-z0-9_-]{2,40}$/.test(meta.plan_id ?? "") ? meta.plan_id : null, price_id: price,
    estado: String(s.status ?? ""), periodo_fin: fin ? new Date(fin * 1000).toISOString() : null,
    cancela: !!s.cancel_at_period_end, app: meta.app ?? "", tipo: meta.tipo ?? "",
    livemode: typeof s.livemode === "boolean" ? s.livemode : null, ultima_factura: idDe(s.latest_invoice),
  };
}

// lo poquito que se guarda del aviso (nada personal)
export function recorte(ev: { id?: string; type?: string; livemode?: boolean; data?: { object?: Record<string, unknown> } }) {
  const o = ev?.data?.object ?? {};
  return { objeto: typeof o.object === "string" ? o.object : null, id: typeof o.id === "string" ? o.id : null, livemode: !!ev?.livemode };
}

// ¿el aviso es del mismo modo que la llave? (prueba con prueba, real con real)
export function mismoModo(ev: { livemode?: unknown }, live: boolean | null): boolean {
  return live !== null && typeof ev?.livemode === "boolean" && ev.livemode === live;
}

// el pago (payment_intent) de una factura, para devolverlo. Forma nueva: invoice.payments; forma vieja: invoice.payment_intent
export function pagoDeFactura(inv: Record<string, unknown> | null | undefined): string | null {
  if (!inv) return null;
  const pays = ((inv.payments as { data?: unknown[] } | undefined)?.data ?? []) as Record<string, unknown>[];
  for (const p of pays) { const pay = (p.payment ?? {}) as Record<string, unknown>; const pi = idDe(pay.payment_intent);
    if (pi && /^pi_[A-Za-z0-9]+$/.test(pi) && (p.status === undefined || p.status === "paid")) return pi; }
  const viejo = idDe(inv.payment_intent);
  return viejo && /^pi_[A-Za-z0-9]+$/.test(viejo) ? viejo : null;
}

// modo de la llave de Stripe: true = real, false = prueba, null = no sirve (igual que en funciones/pagos/logica.ts)
export function modoLlave(k: string | undefined | null): boolean | null {
  if (!k) return null;
  if (/^(sk|rk)_live_[A-Za-z0-9]+$/.test(k)) return true;
  if (/^(sk|rk)_test_[A-Za-z0-9]+$/.test(k)) return false;
  return null;
}
