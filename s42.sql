-- DANI Pro — 42: "Recomienda y gana" (afiliados) del Panel NinjaTrader (31 oct 2026, Daniel: "empieza con todo")
-- Cómo funciona:
-- - Cada persona usa su mismo código de invitado (invitar_codigos). Comparte panel.html?ref=CODIGO o el QR.
-- - Quien entra con ese código queda "recomendado" por esa persona (gana el primero; si no hay, cuenta el amigo que lo invitó a la app).
-- - Solo se gana cuando el recomendado PAGA el Panel: un % de cada cobro durante N meses desde su primera compra.
-- - Cada comisión espera N días (por devoluciones). Devolución completa o disputa → se cancela. Devolución parcial → se rebaja.
-- - El afiliado tiene que aceptar los términos de afiliados. Nadie gana por comprarse a sí mismo.
-- - Los pagos a los afiliados los marca el administrador (por ahora a mano; luego Stripe Connect).
-- TODO APAGADO hasta que el administrador lo prenda (afiliados_config.activo). Se puede correr dos veces. Necesita 26, 38 y 41.

create table if not exists public.afiliados_config (
  id int primary key default 1 check (id = 1),
  activo boolean not null default false,
  pct numeric(5,2) not null default 20 check (pct between 0 and 90),        -- % de cada cobro
  dias_espera int not null default 30 check (dias_espera between 0 and 180),
  dias_ventana int not null default 60 check (dias_ventana between 1 and 365), -- el código sirve si compra dentro de estos días
  meses int not null default 12 check (meses between 1 and 120),             -- se gana en los cobros de estos meses desde la primera compra
  minimo_pago numeric(8,2) not null default 50 check (minimo_pago between 0 and 10000),
  actualizado_en timestamptz not null default now()
);
insert into public.afiliados_config (id) values (1) on conflict do nothing;

create table if not exists public.afiliados (
  user_id uuid primary key references auth.users on delete cascade,
  acepto_version text not null,
  acepto_en timestamptz not null default now(),
  bloqueado boolean not null default false
);
create table if not exists public.afiliado_ref (
  referido uuid primary key references auth.users on delete cascade,
  afiliado uuid not null references auth.users on delete cascade,
  creado_en timestamptz not null default now(),
  check (referido <> afiliado)
);
create table if not exists public.comisiones (
  id bigint generated always as identity primary key,
  afiliado uuid not null references auth.users on delete cascade,
  referido uuid,
  licencia_id uuid references public.licencias on delete set null,
  pi text not null unique,
  livemode boolean not null default false,
  venta_centavos int not null check (venta_centavos >= 0),
  comision_centavos int not null check (comision_centavos >= 0),
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobada','pagada','cancelada')),
  aprobar_en timestamptz not null,
  pagado_en timestamptz,
  nota text not null default '' check (length(nota) <= 200),
  creado_en timestamptz not null default now()
);
create index if not exists comisiones_afiliado on public.comisiones (afiliado, estado);
do $$ declare t text; begin
  foreach t in array array['afiliados_config','afiliados','afiliado_ref','comisiones'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;

-- el afiliado acepta los términos (versión de terminos-afiliados.html)
create or replace function public.afiliado_aceptar(p_version text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or coalesce((select is_anonymous from auth.users where id = auth.uid()), true) then return jsonb_build_object('ok', false, 'motivo', 'sin_cuenta'); end if;
  if p_version !~ '^afiliados-[0-9-]{10}$' then return jsonb_build_object('ok', false, 'motivo', 'version'); end if;
  insert into public.afiliados (user_id, acepto_version) values (auth.uid(), p_version)
    on conflict (user_id) do update set acepto_version = excluded.acepto_version, acepto_en = now();
  perform public.mi_invitar();   -- asegura que tenga su código
  return jsonb_build_object('ok', true);
end $$;

-- quien entra con un código queda recomendado (gana el primero; no a sí mismo; solo cuentas con correo)
create or replace function public.usar_codigo_afiliado(p_codigo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a uuid;
begin
  if auth.uid() is null or coalesce((select is_anonymous from auth.users where id = auth.uid()), true) then return jsonb_build_object('ok', false, 'motivo', 'sin_cuenta'); end if;
  select user_id into a from public.invitar_codigos where codigo = upper(trim(coalesce(p_codigo, '')));
  if a is null then return jsonb_build_object('ok', false, 'motivo', 'codigo_malo'); end if;
  if a = auth.uid() then return jsonb_build_object('ok', false, 'motivo', 'mismo'); end if;
  insert into public.afiliado_ref (referido, afiliado) values (auth.uid(), a) on conflict (referido) do nothing;
  return jsonb_build_object('ok', true, 'nuevo', found);
end $$;

-- cada cobro de una licencia (licencia_pagos) puede dar una comisión
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
  -- primera compra del referido: tiene que ser dentro de la ventana desde que usó el código
  select min(p.creado_en) into primera from public.licencia_pagos p join public.licencias y on y.id = p.licencia_id where y.user_id = l.user_id and coalesce(p.monto_centavos, 0) > 0;
  primera := coalesce(primera, new.creado_en);
  if primera > desde + make_interval(days => c.dias_ventana) then return null; end if;
  if new.creado_en > primera + make_interval(months => c.meses) then return null; end if;
  com := floor(new.monto_centavos * c.pct / 100.0)::int;
  if com <= 0 then return null; end if;
  insert into public.comisiones (afiliado, referido, licencia_id, pi, livemode, venta_centavos, comision_centavos, aprobar_en)
    values (af, l.user_id, l.id, new.pi, coalesce(l.livemode, false), new.monto_centavos, com, now() + make_interval(days => c.dias_espera))
    on conflict (pi) do nothing;
  return null;
end $$;
drop trigger if exists t_comision_por_pago on public.licencia_pagos;
create trigger t_comision_por_pago after insert or update of monto_centavos on public.licencia_pagos for each row execute function public.t_comision_por_pago();

-- devolución o disputa: se cancela (completa) o se rebaja (parcial). Se llama desde licencia_quitar_por_pago.
create or replace function public.comision_devolucion(p_pi text, p_fraccion numeric, p_por text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_por = 'disputa' or coalesce(p_fraccion, 0) >= 0.99 then
    update public.comisiones set estado = 'cancelada', nota = left(nota || case when estado = 'pagada' then ' | YA PAGADA: descontar del próximo pago' else '' end || ' | ' || p_por, 200)
      where pi = p_pi and estado <> 'cancelada';
  else
    update public.comisiones set comision_centavos = floor(comision_centavos * (1 - greatest(0, least(1, p_fraccion))))::int, nota = left(nota || ' | devolución parcial', 200)
      where pi = p_pi and estado in ('pendiente','aprobada');
  end if;
end $$;

-- licencia_quitar_por_pago (de 38) ahora también toca la comisión
create or replace function public.licencia_quitar_por_pago(p_pi text, p_fraccion numeric, p_por text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  perform public.comision_devolucion(p_pi, p_fraccion, p_por);
  select x.* into l from public.licencias x join public.licencia_pagos lp on lp.licencia_id = x.id where lp.pi = p_pi for update of x;
  if l.id is null then return jsonb_build_object('ok', true, 'nada', true); end if;
  if p_por <> 'disputa' and coalesce(p_fraccion, 0) < 0.99 then return jsonb_build_object('ok', true, 'parcial', true); end if;
  update public.licencias set estado = 'bloqueada', notas = left(notas || ' | ' || case when p_por = 'disputa' then 'disputa' else 'devolución' end || ' ' || to_char(now(), 'YYYY-MM-DD'), 300),
    actualizado_en = now() where id = l.id;
  update public.licencia_maquinas set activa = false where licencia_id = l.id;
  return jsonb_build_object('ok', true, 'bloqueada', true, 'sub', l.stripe_sub);
end $$;

-- reloj diario: pendiente → aprobada cuando pasan los días de espera
create or replace function public.aprobar_comisiones() returns int
language sql security definer set search_path = '' as $$
  with x as (update public.comisiones set estado = 'aprobada' where estado = 'pendiente' and aprobar_en <= now() returning 1) select count(*)::int from x $$;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    execute $q$select cron.unschedule('aprobar-comisiones') from cron.job where jobname = 'aprobar-comisiones'$q$;
    execute $q$select cron.schedule('aprobar-comisiones', '37 14 * * *', 'select public.aprobar_comisiones()')$q$;
  end if;
end $$;

-- lo que ve el afiliado (sin datos de los compradores)
create or replace function public.mis_comisiones() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'activo', (select activo from public.afiliados_config where id = 1),
    'pct', (select pct from public.afiliados_config where id = 1),
    'dias_espera', (select dias_espera from public.afiliados_config where id = 1),
    'minimo', (select minimo_pago from public.afiliados_config where id = 1),
    'acepto', exists (select 1 from public.afiliados a where a.user_id = auth.uid()),
    'codigo', (select codigo from public.invitar_codigos where user_id = auth.uid()),
    'recomendados', (select count(*) from public.afiliado_ref r where r.afiliado = auth.uid()),
    'pendiente', (select coalesce(sum(comision_centavos), 0) from public.comisiones where afiliado = auth.uid() and estado = 'pendiente') / 100.0,
    'aprobada', (select coalesce(sum(comision_centavos), 0) from public.comisiones where afiliado = auth.uid() and estado = 'aprobada') / 100.0,
    'pagada', (select coalesce(sum(comision_centavos), 0) from public.comisiones where afiliado = auth.uid() and estado = 'pagada') / 100.0,
    'lista', (select coalesce(jsonb_agg(jsonb_build_object('fecha', creado_en, 'comision', comision_centavos / 100.0, 'estado', estado, 'aprobar_en', aprobar_en, 'prueba', not livemode) order by creado_en desc), '[]')
              from (select * from public.comisiones where afiliado = auth.uid() order by creado_en desc limit 50) t))
  where auth.uid() is not null $$;

-- administrador
create or replace function public.admin_afiliados() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  return jsonb_build_object('config', (select to_jsonb(c) from public.afiliados_config c where id = 1),
    'afiliados', (select coalesce(jsonb_agg(x order by (x->>'por_pagar')::numeric desc), '[]') from (
      select jsonb_build_object('user_id', a.user_id, 'correo', u.email, 'codigo', ic.codigo, 'bloqueado', a.bloqueado,
        'recomendados', (select count(*) from public.afiliado_ref r where r.afiliado = a.user_id),
        'pendiente', (select coalesce(sum(comision_centavos), 0) from public.comisiones c where c.afiliado = a.user_id and c.estado = 'pendiente') / 100.0,
        'por_pagar', (select coalesce(sum(comision_centavos), 0) from public.comisiones c where c.afiliado = a.user_id and c.estado = 'aprobada' and c.livemode) / 100.0,
        'pagado', (select coalesce(sum(comision_centavos), 0) from public.comisiones c where c.afiliado = a.user_id and c.estado = 'pagada') / 100.0) x
      from public.afiliados a left join auth.users u on u.id = a.user_id left join public.invitar_codigos ic on ic.user_id = a.user_id limit 300) t));
end $$;

create or replace function public.admin_afiliados_config(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  update public.afiliados_config set
    activo = coalesce((p->>'activo')::boolean, activo), pct = coalesce((p->>'pct')::numeric, pct),
    dias_espera = coalesce((p->>'dias_espera')::int, dias_espera), dias_ventana = coalesce((p->>'dias_ventana')::int, dias_ventana),
    meses = coalesce((p->>'meses')::int, meses), minimo_pago = coalesce((p->>'minimo_pago')::numeric, minimo_pago), actualizado_en = now()
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;

-- el administrador ya le pagó (Zelle, PayPal, banco…): las aprobadas de dinero real pasan a pagadas
create or replace function public.admin_comisiones_pagar(p_afiliado uuid, p_nota text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n int; total int;
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  with x as (update public.comisiones set estado = 'pagada', pagado_en = now(), nota = left(nota || ' | ' || coalesce(p_nota, ''), 200)
             where afiliado = p_afiliado and estado = 'aprobada' and livemode returning comision_centavos)
  select count(*), coalesce(sum(comision_centavos), 0) into n, total from x;
  return jsonb_build_object('ok', true, 'n', n, 'total', total / 100.0);
end $$;

create or replace function public.admin_afiliado_bloquear(p_afiliado uuid, p_bloq boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  update public.afiliados set bloqueado = p_bloq where user_id = p_afiliado;
  if p_bloq then update public.comisiones set estado = 'cancelada', nota = left(nota || ' | afiliado bloqueado', 200) where afiliado = p_afiliado and estado in ('pendiente','aprobada'); end if;
  return jsonb_build_object('ok', found);
end $$;

do $$ declare f text; begin
  foreach f in array array['comision_devolucion(text,numeric,text)','aprobar_comisiones()','licencia_quitar_por_pago(text,numeric,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
    execute 'grant execute on function public.' || f || ' to service_role';
  end loop;
  foreach f in array array['afiliado_aceptar(text)','usar_codigo_afiliado(text)','mis_comisiones()','admin_afiliados()','admin_afiliados_config(jsonb)','admin_comisiones_pagar(uuid,text)','admin_afiliado_bloquear(uuid,boolean)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;
