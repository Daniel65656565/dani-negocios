-- DANI Pro — 38: tienda del "Panel Dani para NinjaTrader" (31 oct 2026, Daniel: "empieza con todo")
-- 1) planes: producto (dani | panel_nt), intervalos de 6 meses y anual, cupo y fecha de fin (Fundadores), computadoras por licencia.
-- 2) Ejemplos del Panel, TODOS APAGADOS (activo = false). Daniel pone los precios y los prende desde el panel de administrador.
-- 3) Licencias ligadas a Stripe: al pagar se crea la licencia sola; al renovar se alarga; al cancelar se acaba al final de lo pagado;
--    devolución completa o disputa → bloqueada.
-- 4) El cliente ve sus licencias y suelta computadoras (mis_licencias, licencia_soltar_mia).
-- 5) El administrador: guarda precios y prende/apaga planes, ve licencias, crea licencias (de prueba o regaladas) y las bloquea.
-- Se puede correr dos veces. Necesita 33, 35 y 37.

/* ---------- 1. planes ---------- */
alter table public.planes add column if not exists producto text not null default 'dani';
alter table public.planes add column if not exists cupo_max int;            -- Fundadores: cuántos se pueden vender (vacío = sin límite)
alter table public.planes add column if not exists vende_hasta timestamptz; -- Fundadores: hasta cuándo se vende (vacío = siempre)
alter table public.planes add column if not exists maquinas int not null default 2;   -- Panel: computadoras a la vez por licencia
alter table public.planes drop constraint if exists planes_intervalo_check;
alter table public.planes drop constraint if exists planes_precio_usd_check;
alter table public.planes drop constraint if exists planes_producto_check;
alter table public.planes drop constraint if exists planes_panel_check;
alter table public.planes drop constraint if exists planes_extra_check;
alter table public.planes add constraint planes_intervalo_check check (intervalo in ('mes','6meses','anual','unico'));
alter table public.planes add constraint planes_precio_usd_check check (precio_usd between 0.50 and 9999.99);
alter table public.planes add constraint planes_producto_check check (producto in ('dani','panel_nt'));
-- Dani Pro sigue igual (mes o pago único). El Panel es siempre de una persona.
alter table public.planes add constraint planes_panel_check check ((producto = 'dani' and intervalo in ('mes','unico')) or (producto = 'panel_nt' and para = 'persona'));
alter table public.planes add constraint planes_extra_check check ((cupo_max is null or cupo_max between 1 and 100000) and maquinas between 1 and 10);

-- EJEMPLOS del Panel (apagados; precios de ejemplo). No se pisan si ya existen.
insert into public.planes (id, nombre, nombre_en, descripcion, descripcion_en, para, precio_usd, intervalo, beneficios, orden, producto, maquinas, cupo_max, vende_hasta) values
  ('panel_mensual', 'Panel Dani — mensual (EJEMPLO)', 'Dani Panel — monthly (EXAMPLE)', 'El Panel Dani para NinjaTrader 8. Hasta 2 computadoras.', 'Dani Panel for NinjaTrader 8. Up to 2 computers.', 'persona', 49.00, 'mes', '{}', 200, 'panel_nt', 2, null, null),
  ('panel_6meses', 'Panel Dani — 6 meses (EJEMPLO)', 'Dani Panel — 6 months (EXAMPLE)', 'Pagas cada 6 meses y ahorras. Hasta 2 computadoras.', 'Pay every 6 months and save. Up to 2 computers.', 'persona', 249.00, '6meses', '{}', 210, 'panel_nt', 2, null, null),
  ('panel_anual', 'Panel Dani — anual (EJEMPLO)', 'Dani Panel — yearly (EXAMPLE)', 'Pagas una vez al año y ahorras más. Hasta 2 computadoras.', 'Pay once a year and save more. Up to 2 computers.', 'persona', 449.00, 'anual', '{}', 220, 'panel_nt', 2, null, null),
  ('panel_fundador', 'Panel Dani — Fundador (EJEMPLO)', 'Dani Panel — Founder (EXAMPLE)', 'Solo para los primeros 100. Tu precio no sube mientras no canceles. Hasta 2 computadoras.', 'Only for the first 100. Your price never goes up while you stay. Up to 2 computers.', 'persona', 29.00, 'mes', '{}', 190, 'panel_nt', 2, 100, null)
on conflict (id) do nothing;

/* ---------- 2. licencias ligadas a Stripe ---------- */
alter table public.licencias add column if not exists plan_id text;
alter table public.licencias add column if not exists livemode boolean;
alter table public.licencias add column if not exists stripe_pago text;      -- pago único (id de la sesión de pago)
create unique index if not exists licencias_stripe_sub on public.licencias (stripe_sub) where stripe_sub is not null;
create unique index if not exists licencias_stripe_pago on public.licencias (stripe_pago) where stripe_pago is not null;
create index if not exists licencias_user on public.licencias (user_id);
create index if not exists licencias_plan on public.licencias (plan_id);

-- cada cobro (payment_intent) que pagó una licencia: para bloquearla si se devuelve el dinero o hay disputa
create table if not exists public.licencia_pagos (
  pi text primary key check (pi ~ '^pi_[A-Za-z0-9]+$'),
  licencia_id uuid not null references public.licencias on delete cascade,
  creado_en timestamptz not null default now()
);
alter table public.licencia_pagos enable row level security;
revoke all on public.licencia_pagos from anon, authenticated;
grant all on public.licencia_pagos to service_role;

-- qué tipo de licencia da un plan
create or replace function public.licencia_plan_de(p public.planes) returns text language sql immutable as $$
  select case when p.cupo_max is not null then 'fundador' when p.intervalo = 'mes' then 'mensual' when p.intervalo = '6meses' then 'semestral'
              when p.intervalo = 'anual' then 'anual' else 'fundador' end $$;

-- cuántos quedan de un plan con cupo (Fundadores). null = sin límite. Las de prueba no cuentan.
create or replace function public.panel_cupo_libre(p_plan text) returns int
language sql stable security definer set search_path = '' as $$
  select case when p.cupo_max is null then null
              else greatest(0, p.cupo_max - (select count(*) from public.licencias l where l.plan_id = p.id and not l.prueba))::int end
  from public.planes p where p.id = p_plan $$;

-- lo llama el aviso de Stripe (solo el servidor). Suscripción (p_sub) o pago único (p_pago).
create or replace function public.licencia_desde_stripe(p_user uuid, p_plan text, p_sub text, p_estado text, p_periodo_fin timestamptz,
  p_pago text, p_pi text, p_live boolean) returns jsonb
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
    insert into public.licencia_pagos (pi, licencia_id) values (p_pi, l.id) on conflict (pi) do nothing;
  end if;
  return jsonb_build_object('ok', true, 'clave', l.clave, 'nueva', nueva);
end $$;

-- devolución o disputa de un cobro: si fue completa (o disputa), la licencia queda bloqueada y se cancela la suscripción
create or replace function public.licencia_quitar_por_pago(p_pi text, p_fraccion numeric, p_por text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select x.* into l from public.licencias x join public.licencia_pagos lp on lp.licencia_id = x.id where lp.pi = p_pi for update of x;
  if l.id is null then return jsonb_build_object('ok', true, 'nada', true); end if;
  if p_por <> 'disputa' and coalesce(p_fraccion, 0) < 0.99 then return jsonb_build_object('ok', true, 'parcial', true); end if;
  update public.licencias set estado = 'bloqueada', notas = left(notas || ' | ' || case when p_por = 'disputa' then 'disputa' else 'devolución' end || ' ' || to_char(now(), 'YYYY-MM-DD'), 300),
    actualizado_en = now() where id = l.id;
  update public.licencia_maquinas set activa = false where licencia_id = l.id;
  return jsonb_build_object('ok', true, 'bloqueada', true, 'sub', l.stripe_sub);
end $$;

/* ---------- 3. el cliente ---------- */
create or replace function public.mis_licencias() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('clave', l.clave, 'plan', l.plan, 'plan_id', l.plan_id, 'estado', public.licencia_efectiva(l),
    'vence', l.vence, 'max', l.max_maquinas, 'prueba', l.prueba, 'renueva', l.stripe_sub is not null and l.estado = 'activa',
    'maquinas', (select coalesce(jsonb_agg(jsonb_build_object('maquina', m.maquina, 'nombre', m.nombre, 'version', m.version, 'ultima', m.ultima) order by m.ultima desc), '[]')
                 from public.licencia_maquinas m where m.licencia_id = l.id and m.activa)) order by l.creado_en desc), '[]')
  from public.licencias l where auth.uid() is not null and l.user_id = auth.uid() $$;

create or replace function public.licencia_soltar_mia(p_clave text, p_maquina text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (select 1 from public.licencias where clave = p_clave and user_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'motivo', 'no_es_tuya'); end if;
  update public.licencia_maquinas m set activa = false, ultima = now() from public.licencias l
    where l.id = m.licencia_id and l.clave = p_clave and m.maquina = p_maquina;
  return jsonb_build_object('ok', true);
end $$;

/* ---------- 4. el administrador ---------- */
-- guarda un plan (precio, nombres, prender/apagar, cupo, fecha fin, computadoras). No deja prender un plan que todavía dice EJEMPLO.
create or replace function public.admin_plan_guardar(p_id text, p_precio numeric, p_activo boolean, p_nombre text, p_nombre_en text,
  p_descripcion text, p_descripcion_en text, p_cupo int, p_vende_hasta timestamptz, p_maquinas int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.planes;
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  select * into p from public.planes where id = p_id for update;
  if p.id is null then return jsonb_build_object('ok', false, 'motivo', 'no_existe'); end if;
  if p_activo and (coalesce(p_nombre, p.nombre) ~* 'EJEMPLO' or coalesce(p_nombre_en, p.nombre_en) ~* 'EXAMPLE') then
    return jsonb_build_object('ok', false, 'motivo', 'quita_ejemplo'); end if;
  update public.planes set
    precio_usd = coalesce(p_precio, precio_usd),
    -- si cambia el precio, se deja de usar el precio fijo de Stripe (se cobra el de la tabla); los que ya pagan siguen con el suyo
    stripe_price_id = case when p_precio is not null and p_precio <> precio_usd then null else stripe_price_id end,
    activo = coalesce(p_activo, activo),
    nombre = coalesce(nullif(trim(p_nombre), ''), nombre), nombre_en = coalesce(p_nombre_en, nombre_en),
    descripcion = coalesce(p_descripcion, descripcion), descripcion_en = coalesce(p_descripcion_en, descripcion_en),
    cupo_max = case when producto = 'panel_nt' then p_cupo else cupo_max end,
    vende_hasta = case when producto = 'panel_nt' then p_vende_hasta else vende_hasta end,
    maquinas = case when producto = 'panel_nt' then coalesce(p_maquinas, maquinas) else maquinas end,
    ejemplo = false, actualizado_en = now()
  where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_licencias(p_buscar text default '') returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not public.es_admin() then '[]'::jsonb else coalesce((select jsonb_agg(x order by x->>'creado' desc) from (
    select jsonb_build_object('clave', l.clave, 'correo', u.email, 'plan', l.plan, 'plan_id', l.plan_id, 'estado', public.licencia_efectiva(l),
      'vence', l.vence, 'max', l.max_maquinas, 'prueba', l.prueba, 'notas', l.notas, 'creado', l.creado_en, 'stripe', l.stripe_sub is not null or l.stripe_pago is not null,
      'usadas', (select count(*) from public.licencia_maquinas m where m.licencia_id = l.id and m.activa)) x
    from public.licencias l left join auth.users u on u.id = l.user_id
    where coalesce(p_buscar, '') = '' or l.clave ilike '%' || p_buscar || '%' or u.email ilike '%' || p_buscar || '%'
    order by l.creado_en desc limit 200) t), '[]') end $$;

-- crear una licencia a mano: de prueba, o regalada a un correo que ya tiene cuenta. Días vacío = no vence.
create or replace function public.admin_licencia_crear(p_correo text, p_plan text, p_dias int, p_max int, p_prueba boolean, p_notas text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid; k text;
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  if p_plan not in ('mensual','semestral','anual','fundador','prueba') then return jsonb_build_object('ok', false, 'motivo', 'plan'); end if;
  if coalesce(trim(p_correo), '') <> '' then
    select id into u from auth.users where lower(email) = lower(trim(p_correo)) limit 1;
    if u is null then return jsonb_build_object('ok', false, 'motivo', 'sin_cuenta'); end if;
  end if;
  k := public.licencia_crear(u, p_plan, case when p_dias is null then null else now() + make_interval(days => least(greatest(p_dias, 1), 3650)) end,
    least(greatest(coalesce(p_max, 2), 1), 10), coalesce(p_prueba, true), left(coalesce(p_notas, 'hecha a mano'), 300));
  return jsonb_build_object('ok', true, 'clave', k);
end $$;

create or replace function public.admin_licencia_estado(p_clave text, p_estado text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  if p_estado not in ('activa','cancelada','bloqueada','soltar_todas') then return jsonb_build_object('ok', false); end if;
  if p_estado = 'soltar_todas' then
    update public.licencia_maquinas m set activa = false from public.licencias l where l.id = m.licencia_id and l.clave = p_clave;
  else
    update public.licencias set estado = p_estado, actualizado_en = now() where clave = p_clave;
  end if;
  return jsonb_build_object('ok', found);
end $$;

/* ---------- 5. permisos (después del error del 31 oct: dar permiso explícito a service_role) ---------- */
do $$ declare f text; begin
  foreach f in array array['licencia_plan_de(public.planes)','panel_cupo_libre(text)','licencia_desde_stripe(uuid,text,text,text,timestamptz,text,text,boolean)','licencia_quitar_por_pago(text,numeric,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
    execute 'grant execute on function public.' || f || ' to service_role';
  end loop;
  foreach f in array array['mis_licencias()','licencia_soltar_mia(text,text)','admin_plan_guardar(text,numeric,boolean,text,text,text,text,int,timestamptz,int)',
    'admin_licencias(text)','admin_licencia_crear(text,text,int,int,boolean,text)','admin_licencia_estado(text,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated, service_role';
  end loop;
end $$;
