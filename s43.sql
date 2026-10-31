-- DANI Pro — 43: arreglos de la revisión de seguridad (31 oct 2026)
-- 1) La licencia solo se alarga con un cobro PAGADO (antes se alargaba al empezar el período nuevo, aunque la tarjeta fallara).
--    El webhook manda la fecha del período solo cuando llega la factura pagada; sin fecha no se crea ni se alarga.
-- 2) Afiliados: la primera compra tiene que ser DESPUÉS de usar el código (no se cobra comisión de clientes que ya pagaban).
-- 3) Devolución o disputa que llega ANTES que el pago: se guarda y se aplica cuando llegue el pago.
-- 4) Límite para soltar computadoras: 4 cada 30 días por licencia (para que una clave no rote por muchas PCs).
-- 5) Devoluciones parciales de comisiones: se calcula sobre la comisión original (no se rebaja dos veces).
-- 6) Una licencia "cancelada" que no vence (de por vida o hecha a mano) ya no sirve.
-- Se puede correr dos veces. Necesita 37, 38, 41 y 42.

/* 6) licencia_efectiva */
create or replace function public.licencia_efectiva(l public.licencias) returns text language sql stable as $$
  select case when l.estado = 'bloqueada' then 'bloqueada'
              when l.estado = 'cancelada' and l.vence is null then 'cancelada'
              when l.vence is not null and l.vence <= now() then case when l.estado = 'cancelada' then 'cancelada' else 'vencida' end
              else 'activa' end $$;

/* 1) licencia_desde_stripe */
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
      -- (43) solo se crea con un cobro ya pagado (el webhook manda la fecha solo cuando la factura se pagó)
      if p_estado not in ('active','trialing') or p_periodo_fin is null then return jsonb_build_object('ok', true, 'nada', true); end if;
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
  return jsonb_build_object('ok', true, 'clave', l.clave, 'nueva', nueva, 'bloqueada', l.estado = 'bloqueada');
end $$;



/* 3) devoluciones que llegan antes que el pago */
create table if not exists public.licencia_devol_pend (
  pi text primary key check (pi ~ '^pi_[A-Za-z0-9]+$'),
  fraccion numeric not null default 1,
  por text not null,
  creado_en timestamptz not null default now()
);
alter table public.licencia_devol_pend enable row level security;
revoke all on public.licencia_devol_pend from anon, authenticated;
grant all on public.licencia_devol_pend to service_role;

/* 5) comisión original */
alter table public.comisiones add column if not exists original_centavos int;
update public.comisiones set original_centavos = comision_centavos where original_centavos is null;
create or replace function public.t_comision_original() returns trigger language plpgsql as $$
begin if new.original_centavos is null then new.original_centavos := new.comision_centavos; end if; return new; end $$;
drop trigger if exists t_comision_original on public.comisiones;
create trigger t_comision_original before insert on public.comisiones for each row execute function public.t_comision_original();

create or replace function public.comision_devolucion(p_pi text, p_fraccion numeric, p_por text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_por = 'disputa' or coalesce(p_fraccion, 0) >= 0.99 then
    update public.comisiones set estado = 'cancelada', nota = left(nota || case when estado = 'pagada' then ' | YA PAGADA: descontar del próximo pago' else '' end || ' | ' || p_por, 200)
      where pi = p_pi and estado <> 'cancelada';
  else
    update public.comisiones set comision_centavos = floor(coalesce(original_centavos, comision_centavos) * (1 - greatest(0, least(1, p_fraccion))))::int,
      nota = left(nota || case when estado = 'pagada' then ' | devolución parcial de una YA PAGADA: descontar' else ' | devolución parcial' end, 200)
      where pi = p_pi and estado in ('pendiente','aprobada','pagada');
  end if;
end $$;

create or replace function public.licencia_quitar_por_pago(p_pi text, p_fraccion numeric, p_por text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  perform public.comision_devolucion(p_pi, p_fraccion, p_por);
  select x.* into l from public.licencias x join public.licencia_pagos lp on lp.licencia_id = x.id where lp.pi = p_pi for update of x;
  if l.id is null then
    -- todavía no llega el pago: se guarda para aplicarlo cuando llegue (si nunca llega, no pasa nada)
    if p_pi ~ '^pi_[A-Za-z0-9]+$' then
      insert into public.licencia_devol_pend (pi, fraccion, por) values (p_pi, coalesce(p_fraccion, 1), p_por)
        on conflict (pi) do update set fraccion = greatest(public.licencia_devol_pend.fraccion, excluded.fraccion),
          por = case when excluded.por = 'disputa' then 'disputa' else public.licencia_devol_pend.por end;
    end if;
    return jsonb_build_object('ok', true, 'nada', true);
  end if;
  if p_por <> 'disputa' and coalesce(p_fraccion, 0) < 0.99 then return jsonb_build_object('ok', true, 'parcial', true); end if;
  update public.licencias set estado = 'bloqueada', notas = left(notas || ' | ' || case when p_por = 'disputa' then 'disputa' else 'devolución' end || ' ' || to_char(now(), 'YYYY-MM-DD'), 300),
    actualizado_en = now() where id = l.id;
  update public.licencia_maquinas set activa = false where licencia_id = l.id;
  return jsonb_build_object('ok', true, 'bloqueada', true, 'sub', l.stripe_sub);
end $$;

-- cuando llega el pago, se aplica la devolución que estaba esperando (después de crear la comisión: "t_z" va de último)
create or replace function public.t_z_devol_pendiente() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d public.licencia_devol_pend;
begin
  select * into d from public.licencia_devol_pend where pi = new.pi;
  if d.pi is null then return null; end if;
  delete from public.licencia_devol_pend where pi = new.pi;
  perform public.licencia_quitar_por_pago(d.pi, d.fraccion, d.por);
  return null;
end $$;
drop trigger if exists t_z_devol_pendiente on public.licencia_pagos;
create trigger t_z_devol_pendiente after insert on public.licencia_pagos for each row execute function public.t_z_devol_pendiente();

/* 2) afiliados: la primera compra tiene que ser después de usar el código */
create or replace function public.t_comision_por_pago() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.afiliados_config; l public.licencias; af uuid; desde timestamptz; primera timestamptz; com int;
begin
  select * into c from public.afiliados_config where id = 1;
  if not coalesce(c.activo, false) or coalesce(new.monto_centavos, 0) <= 0 then return null; end if;
  select * into l from public.licencias where id = new.licencia_id;
  if l.user_id is null or l.prueba then return null; end if;
  select r.afiliado, r.creado_en into af, desde from public.afiliado_ref r where r.referido = l.user_id;
  if af is null then select i.invitador, i.creado_en into af, desde from public.invitaciones i where i.invitado = l.user_id; end if;
  if af is null or af = l.user_id then return null; end if;
  if not exists (select 1 from public.afiliados x where x.user_id = af and not x.bloqueado) then return null; end if;
  select min(p.creado_en) into primera from public.licencia_pagos p join public.licencias y on y.id = p.licencia_id where y.user_id = l.user_id and coalesce(p.monto_centavos, 0) > 0;
  primera := coalesce(primera, new.creado_en);
  if primera < desde or primera > desde + make_interval(days => c.dias_ventana) then return null; end if;
  if new.creado_en > primera + make_interval(months => c.meses) then return null; end if;
  com := floor(new.monto_centavos * c.pct / 100.0)::int;
  if com <= 0 then return null; end if;
  insert into public.comisiones (afiliado, referido, licencia_id, pi, livemode, venta_centavos, comision_centavos, aprobar_en)
    values (af, l.user_id, l.id, new.pi, coalesce(l.livemode, false), new.monto_centavos, com, now() + make_interval(days => c.dias_espera))
    on conflict (pi) do nothing;
  return null;
end $$;

/* 4) límite para soltar computadoras */
create table if not exists public.licencia_soltadas (
  id bigint generated always as identity primary key,
  licencia_id uuid not null references public.licencias on delete cascade,
  creado_en timestamptz not null default now()
);
create index if not exists licencia_soltadas_lic on public.licencia_soltadas (licencia_id, creado_en);
alter table public.licencia_soltadas enable row level security;
revoke all on public.licencia_soltadas from anon, authenticated;
grant all on public.licencia_soltadas to service_role;

create or replace function public.licencia_soltar_limite(p_lic uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select count(*) from public.licencia_soltadas s where s.licencia_id = p_lic and s.creado_en > now() - interval '30 days') < 4 $$;

create or replace function public.licencia_soltar(p_clave text, p_maquina text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select * into l from public.licencias where clave = p_clave for update;
  if l.id is null then return jsonb_build_object('estado', 'no_existe'); end if;
  if exists (select 1 from public.licencia_maquinas where licencia_id = l.id and maquina = p_maquina and activa) then
    if not public.licencia_soltar_limite(l.id) then return public.licencia_respuesta(l, 'soltar_limite'); end if;
    update public.licencia_maquinas set activa = false, ultima = now() where licencia_id = l.id and maquina = p_maquina;
    insert into public.licencia_soltadas (licencia_id) values (l.id);
  end if;
  return public.licencia_respuesta(l, 'soltada');
end $$;

create or replace function public.licencia_soltar_mia(p_clave text, p_maquina text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias;
begin
  select * into l from public.licencias where clave = p_clave and user_id = auth.uid() for update;
  if auth.uid() is null or l.id is null then return jsonb_build_object('ok', false, 'motivo', 'no_es_tuya'); end if;
  if not exists (select 1 from public.licencia_maquinas where licencia_id = l.id and maquina = p_maquina and activa) then return jsonb_build_object('ok', true); end if;
  if not public.licencia_soltar_limite(l.id) then return jsonb_build_object('ok', false, 'motivo', 'soltar_limite'); end if;
  update public.licencia_maquinas set activa = false, ultima = now() where licencia_id = l.id and maquina = p_maquina;
  insert into public.licencia_soltadas (licencia_id) values (l.id);
  return jsonb_build_object('ok', true);
end $$;

do $$ declare f text; begin
  foreach f in array array['licencia_efectiva(public.licencias)','licencia_desde_stripe(uuid,text,text,text,timestamptz,text,text,boolean,int)','comision_devolucion(text,numeric,text)',
    'licencia_quitar_por_pago(text,numeric,text)','licencia_soltar(text,text)','licencia_soltar_limite(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
    execute 'grant execute on function public.' || f || ' to service_role';
  end loop;
  execute 'revoke all on function public.licencia_soltar_mia(text,text) from public, anon';
  execute 'grant execute on function public.licencia_soltar_mia(text,text) to authenticated, service_role';
end $$;
