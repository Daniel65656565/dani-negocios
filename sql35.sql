-- DANI Pro — 35: créditos del negocio (31 oct 2026, decidido con Daniel)
-- 1) Regla de conversión: $1 de IA = 500 créditos (creditos_config.creditos_por_usd). Se cambia en un solo lugar.
-- 2) El plan del negocio trae "$X de IA al mes" (ia_bolsa.mensual_usd): se renueva cada mes y NO se acumula.
-- 3) El negocio puede COMPRAR créditos extra (paquete de pago único con para='negocio'): van a ia_bolsa.compra_creditos y NO vencen.
--    Se gasta primero lo del plan del mes y después lo comprado.
-- Se puede correr dos veces.

alter table public.creditos_config add column if not exists creditos_por_usd int not null default 500;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'creditos_config_cpu_check') then
    alter table public.creditos_config add constraint creditos_config_cpu_check check (creditos_por_usd between 10 and 100000);
  end if;
end $$;

alter table public.ia_bolsa add column if not exists compra_creditos int not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ia_bolsa_compra_check') then
    alter table public.ia_bolsa add constraint ia_bolsa_compra_check check (compra_creditos between 0 and 100000000);
  end if;
end $$;

-- los paquetes de pago único ahora también pueden ser de un negocio
alter table public.planes drop constraint if exists planes_unico_persona;
-- de qué negocio fue la compra (para devolver bien si hay reembolso)
alter table public.pagos_aplicados add column if not exists negocio_id uuid;

create or replace function public.cpu() returns int language sql stable security definer set search_path = '' as $$
  select coalesce((select creditos_por_usd from public.creditos_config where id = 1), 500) $$;

-- ¿Puede usar la IA este negocio ahora? (solo el servidor). Cuenta lo del plan del mes + lo comprado.
create or replace function public.ia_bolsa_ok(p_negocio uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b public.ia_bolsa; plan_total numeric; plan_queda numeric; compra_usd numeric;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  b := public.ia_bolsa_al_dia(p_negocio);
  plan_total := b.mensual_usd + b.extra_usd;
  plan_queda := greatest(plan_total - b.gastado_usd, 0);
  compra_usd := b.compra_creditos::numeric / public.cpu();
  if plan_total <= 0 and compra_usd <= 0 then return jsonb_build_object('ok', false, 'motivo', 'sin_plan'); end if;
  if plan_queda <= 0 and compra_usd <= 0 then return jsonb_build_object('ok', false, 'motivo', 'bolsa_vacia'); end if;
  return jsonb_build_object('ok', true, 'queda', round(plan_queda + compra_usd, 4));
end $$;

-- Anota lo que costó: primero del plan del mes, lo que pase de ahí sale de lo comprado. Avisa al dueño al 80% y al 100%.
create or replace function public.ia_bolsa_gastar(p_negocio uuid, p_costo numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b public.ia_bolsa; c numeric := greatest(coalesce(p_costo, 0), 0); plan_total numeric; del_plan numeric; de_compra int;
  pct numeric; neg text; r record; queda_compra int;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  b := public.ia_bolsa_al_dia(p_negocio);
  select * into b from public.ia_bolsa where negocio_id = p_negocio for update;
  plan_total := b.mensual_usd + b.extra_usd;
  del_plan := least(c, greatest(plan_total - b.gastado_usd, 0));
  de_compra := least(b.compra_creditos, ceil((c - del_plan) * public.cpu())::int);
  update public.ia_bolsa set gastado_usd = gastado_usd + c, compra_creditos = compra_creditos - de_compra,
    llamadas = llamadas + 1, actualizado_en = now()
    where negocio_id = p_negocio returning * into b;
  pct := case when plan_total > 0 then least(b.gastado_usd / plan_total, 9) else 1 end;
  queda_compra := b.compra_creditos;
  select nombre into neg from public.negocios where id = p_negocio;
  if pct >= 1 and queda_compra <= 0 and not b.avisado100 then
    update public.ia_bolsa set avisado100 = true, avisado80 = true where negocio_id = p_negocio;
    for r in select user_id from public.negocio_miembros where negocio_id = p_negocio and rol = 'dueno' loop
      perform public.encolar_aviso(r.user_id, 'Se acabaron tus créditos de IA', 'En ' || coalesce(neg, 'tu negocio') || ' se usaron todos los créditos de IA de este mes. Robotito sigue contestando lo que sabe. Si quieres más, compra créditos en tu panel (Mi plan).', './');
    end loop;
  elsif pct >= 0.8 and queda_compra <= 0 and not b.avisado80 then
    update public.ia_bolsa set avisado80 = true where negocio_id = p_negocio;
    for r in select user_id from public.negocio_miembros where negocio_id = p_negocio and rol = 'dueno' loop
      perform public.encolar_aviso(r.user_id, 'Te quedan pocos créditos de IA', 'En ' || coalesce(neg, 'tu negocio') || ' ya se usó el 80% de los créditos de IA del mes.', './');
    end loop;
  end if;
  return jsonb_build_object('pct', round(pct, 3), 'queda', round(greatest(plan_total - b.gastado_usd, 0) + b.compra_creditos::numeric / public.cpu(), 4));
end $$;
revoke all on function public.ia_bolsa_ok(uuid) from public, anon, authenticated;
revoke all on function public.ia_bolsa_gastar(uuid, numeric) from public, anon, authenticated;

-- Lo que ve el dueño en su panel, ya en créditos
create or replace function public.mis_creditos_negocio(p_negocio uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b public.ia_bolsa; k int := public.cpu(); plan_total numeric;
begin
  if auth.uid() is null or not exists (select 1 from public.negocio_miembros where negocio_id = p_negocio and user_id = auth.uid() and rol = 'dueno')
     and not exists (select 1 from public.admins where user_id = auth.uid()) then raise exception 'solo el dueño'; end if;
  b := public.ia_bolsa_al_dia(p_negocio);
  plan_total := b.mensual_usd + b.extra_usd;
  return jsonb_build_object(
    'creditos_por_usd', k,
    'plan_mes', floor(plan_total * k)::int,
    'plan_usado', least(floor(b.gastado_usd * k), floor(plan_total * k))::int,
    'plan_queda', floor(greatest(plan_total - b.gastado_usd, 0) * k)::int,
    'comprados', b.compra_creditos,
    'mes', b.mes);
end $$;
revoke all on function public.mis_creditos_negocio(uuid) from public, anon;
grant execute on function public.mis_creditos_negocio(uuid) to authenticated;

-- El aviso de Stripe da créditos a un negocio (paquete comprado por el dueño). Una sola vez por pago (clave).
create or replace function public.pagos_dar_creditos_negocio(p_negocio uuid, p_user uuid, p_n int, p_clave text, p_detalle text default '', p_pi text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s int;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_negocio is null or p_n is null or p_n < 1 or p_n > 100000000 then raise exception 'cantidad no válida'; end if;
  if not exists (select 1 from public.negocios where id = p_negocio) then return jsonb_build_object('ok', false, 'motivo', 'sin_negocio'); end if;
  insert into public.pagos_aplicados (clave, user_id, negocio_id, creditos, payment_intent) values (p_clave, p_user, p_negocio, p_n, p_pi) on conflict (clave) do nothing;
  if not found then return jsonb_build_object('ok', true, 'repetido', true); end if;
  perform public.ia_bolsa_al_dia(p_negocio);
  update public.ia_bolsa set compra_creditos = compra_creditos + p_n, avisado80 = false, avisado100 = false, actualizado_en = now()
    where negocio_id = p_negocio returning compra_creditos into s;
  return jsonb_build_object('ok', true, 'comprados', s);
end $$;
revoke all on function public.pagos_dar_creditos_negocio(uuid, uuid, int, text, text, text) from public, anon, authenticated;

-- Devoluciones y disputas: si el pago fue de un negocio, se quitan de lo comprado por el negocio
create or replace function public.pagos_quitar_creditos(p_pi text, p_fraccion numeric, p_detalle text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.pagos_aplicados; objetivo int; falta int; s int; quita int;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_pi is null or p_pi !~ '^pi_[A-Za-z0-9]+$' then return jsonb_build_object('ok', false, 'motivo', 'sin_pago'); end if;
  select * into a from public.pagos_aplicados where payment_intent = p_pi order by creado_en limit 1 for update;
  if a.clave is null then return jsonb_build_object('ok', true, 'nada', true); end if;
  objetivo := least(a.creditos, ceil(a.creditos * least(1, greatest(0, coalesce(p_fraccion, 0)))))::int;
  falta := objetivo - a.devueltos;
  if falta <= 0 then return jsonb_build_object('ok', true, 'repetido', true); end if;
  update public.pagos_aplicados set devueltos = objetivo where clave = a.clave;
  if a.negocio_id is not null then
    select compra_creditos into s from public.ia_bolsa where negocio_id = a.negocio_id for update;
    quita := least(falta, coalesce(s, 0));
    if quita > 0 then update public.ia_bolsa set compra_creditos = compra_creditos - quita, actualizado_en = now() where negocio_id = a.negocio_id; end if;
    return jsonb_build_object('ok', true, 'quitados', quita, 'no_alcanzo', falta - quita, 'negocio', true);
  end if;
  select saldo into s from public.creditos where user_id = a.user_id for update;
  quita := least(falta, coalesce(s, 0));
  if quita > 0 then
    update public.creditos set saldo = saldo - quita, actualizado_en = now() where user_id = a.user_id;
    insert into public.creditos_mov (user_id, cambio, motivo, detalle) values (a.user_id, -quita, 'devolucion', left(coalesce(nullif(p_detalle, ''), 'Devolución del pago'), 120));
  end if;
  return jsonb_build_object('ok', true, 'quitados', quita, 'no_alcanzo', falta - quita);
end $$;

-- Ejemplo (apagado) de paquete de créditos para negocios: $5 = 1,000 créditos (con ganancia). Daniel lo prende cuando quiera.
insert into public.planes (id, nombre, nombre_en, descripcion, descripcion_en, para, precio_usd, intervalo, beneficios, activo, orden, ejemplo)
values ('negocio_creditos_5', '1,000 créditos de IA (EJEMPLO)', '1,000 AI credits (EXAMPLE)', 'Créditos extra para tu negocio. No vencen.', 'Extra credits for your business. They don''t expire.',
  'negocio', 5.00, 'unico', '{"creditos":1000}', false, 50, true)
on conflict (id) do nothing;
