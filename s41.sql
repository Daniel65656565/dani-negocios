-- DANI Pro — 41: tienda del Panel, parte 3 (31 oct 2026, Daniel: "empieza con todo")
-- 1) Cuánto se cobró en cada pago (para el cuadrito de ventas).
-- 2) Aviso al teléfono cuando sale la licencia, y 7 días antes de que se renueve o se venza (reloj diario).
-- 3) Cuadrito de ventas para el administrador.
-- 4) Ejemplo de plan de pago único "de por vida" (APAGADO).
-- Se puede correr dos veces. Necesita 38.

alter table public.licencia_pagos add column if not exists monto_centavos int;
alter table public.licencias add column if not exists avisado_vence date;

insert into public.planes (id, nombre, nombre_en, descripcion, descripcion_en, para, precio_usd, intervalo, beneficios, orden, producto, maquinas) values
  ('panel_unico', 'Panel Dani — de por vida (EJEMPLO)', 'Dani Panel — lifetime (EXAMPLE)', 'Pagas una sola vez y es tuyo. Hasta 2 computadoras.', 'Pay once and it is yours. Up to 2 computers.', 'persona', 799.00, 'unico', '{}', 230, 'panel_nt', 2)
on conflict (id) do nothing;

drop function if exists public.licencia_desde_stripe(uuid, text, text, text, timestamptz, text, text, boolean);
-- lo llama el aviso de Stripe (solo el servidor). Suscripción (p_sub) o pago único (p_pago).
create or replace function public.licencia_desde_stripe(p_user uuid, p_plan text, p_sub text, p_estado text, p_periodo_fin timestamptz,
  p_pago text, p_pi text, p_live boolean, p_monto int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.planes; l public.licencias; k text; nueva boolean := false;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select * into p from public.planes where id = p_plan;
  if p.id is null or p.producto <> 'panel_nt' then return jsonb_build_object('ok', false, 'motivo', 'no_es_panel'); end if;
  if p_sub is null and p_pago is null then raise exception 'falta el pago'; end if;
  perform pg_advisory_xact_lock(hashtext('lic:' || coalesce(p_sub, p_pago)));
  if p_sub is not null then
    if p_sub !~ '^sub_[A-Za-z0-9]+$' then raise exception 'suscripción no válida'; end if;
    select * into l from public.licencias where stripe_sub = p_sub for update;
    if l.id is null then
      if p_estado not in ('active','trialing') then return jsonb_build_object('ok', true, 'nada', true); end if;
      k := public.licencia_crear(p_user, public.licencia_plan_de(p), p_periodo_fin, p.maquinas, false, 'Stripe ' || p_sub);
      update public.licencias set stripe_sub = p_sub, plan_id = p.id, livemode = p_live where clave = k returning * into l;
      nueva := true;
    elsif p_estado in ('active','trialing') then
      update public.licencias set estado = case when estado = 'bloqueada' then 'bloqueada' else 'activa' end,
        vence = coalesce(greatest(vence, p_periodo_fin), p_periodo_fin, vence), actualizado_en = now() where id = l.id returning * into l;
    elsif p_estado in ('canceled','incomplete_expired') then
      -- sigue sirviendo hasta el final de lo pagado (licencia_efectiva)
      update public.licencias set estado = case when estado = 'bloqueada' then 'bloqueada' else 'cancelada' end, actualizado_en = now() where id = l.id returning * into l;
    end if;   -- past_due, unpaid, paused, incomplete: no se alarga; se vence sola al final del período
  else
    select * into l from public.licencias where stripe_pago = p_pago for update;
    if l.id is null then
      k := public.licencia_crear(p_user, public.licencia_plan_de(p), case when p.intervalo = 'unico' then null else p_periodo_fin end, p.maquinas, false, 'Stripe ' || left(p_pago, 60));
      update public.licencias set stripe_pago = p_pago, plan_id = p.id, livemode = p_live where clave = k returning * into l;
      nueva := true;
    end if;
  end if;
  if l.id is not null and p_pi ~ '^pi_[A-Za-z0-9]+$' then
    insert into public.licencia_pagos (pi, licencia_id, monto_centavos) values (p_pi, l.id, case when p_monto between 0 and 100000000 then p_monto end)
      on conflict (pi) do update set monto_centavos = coalesce(public.licencia_pagos.monto_centavos, excluded.monto_centavos);
  end if;
  -- (41) aviso al teléfono: la licencia ya está lista
  if nueva and l.user_id is not null then
    perform public.encolar_aviso(l.user_id, 'Tu licencia del Panel Dani está lista', 'Ábrela en el menú de Robotito → Panel NinjaTrader. Tu clave: ' || l.clave, './#panel');
  end if;
  return jsonb_build_object('ok', true, 'clave', l.clave, 'nueva', nueva);
end $$;


-- avisos de 7 días (una vez por fecha)
create or replace function public.avisar_licencias() returns int
language plpgsql security definer set search_path = '' as $$
declare l record; k int := 0;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  for l in select x.* from public.licencias x where x.user_id is not null and x.vence between now() + interval '6 days' and now() + interval '7 days'
      and x.avisado_vence is distinct from (x.vence at time zone 'America/New_York')::date and public.licencia_efectiva(x) = 'activa' loop
    if l.stripe_sub is not null and l.estado = 'activa' then
      perform public.encolar_aviso(l.user_id, 'Tu Panel Dani se renueva en 7 días', 'Se cobra solo el ' || to_char(l.vence at time zone 'America/New_York', 'DD/MM/YYYY') || '. Si no quieres renovar, cancélalo en la app antes de esa fecha.', './#panel');
    else
      perform public.encolar_aviso(l.user_id, 'Tu Panel Dani se vence en 7 días', 'Tu licencia sirve hasta el ' || to_char(l.vence at time zone 'America/New_York', 'DD/MM/YYYY') || '. Renuévala en la app para no quedarte sin el Panel.', './#panel');
    end if;
    update public.licencias set avisado_vence = (l.vence at time zone 'America/New_York')::date where id = l.id;
    k := k + 1;
  end loop;
  return k;
end $$;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    execute $q$select cron.unschedule('avisar-licencias') from cron.job where jobname = 'avisar-licencias'$q$;
    execute $q$select cron.schedule('avisar-licencias', '27 14 * * *', 'select public.avisar_licencias()')$q$;  -- 10:27 a.m. en Tampa (verano)
  end if;
end $$;

-- cuadrito de ventas (solo el modo de la llave puesta: prueba o real)
create or replace function public.admin_ventas_panel() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v boolean;
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  v := coalesce((select live from public.pagos_modo where id = 1), false);
  return jsonb_build_object('live', v,
    'vendidas', (select count(*) from public.licencias l where l.livemode = v and (l.stripe_sub is not null or l.stripe_pago is not null)),
    'activas', (select count(*) from public.licencias l where l.livemode = v and (l.stripe_sub is not null or l.stripe_pago is not null) and public.licencia_efectiva(l) = 'activa'),
    'bloqueadas', (select count(*) from public.licencias l where l.livemode = v and l.estado = 'bloqueada'),
    'por_plan', (select coalesce(jsonb_object_agg(plan_id, n), '{}') from (select l.plan_id, count(*) n from public.licencias l where l.livemode = v and l.plan_id is not null group by l.plan_id) t),
    'dinero_mes', (select coalesce(sum(p.monto_centavos), 0) from public.licencia_pagos p join public.licencias l on l.id = p.licencia_id
                   where l.livemode = v and p.creado_en >= date_trunc('month', now() at time zone 'America/New_York') at time zone 'America/New_York') / 100.0,
    'dinero_total', (select coalesce(sum(p.monto_centavos), 0) from public.licencia_pagos p join public.licencias l on l.id = p.licencia_id where l.livemode = v) / 100.0,
    'fundadores_quedan', public.panel_cupo_libre('panel_fundador'));
end $$;

do $$ declare f text; begin
  foreach f in array array['licencia_desde_stripe(uuid,text,text,text,timestamptz,text,text,boolean,int)','avisar_licencias()'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
    execute 'grant execute on function public.' || f || ' to service_role';
  end loop;
  execute 'revoke all on function public.admin_ventas_panel() from public, anon';
  execute 'grant execute on function public.admin_ventas_panel() to authenticated, service_role';
end $$;
