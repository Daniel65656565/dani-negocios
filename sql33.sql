-- DANI Pro — 33: PAGOS SOLOS con Stripe (planes del negocio, planes de persona y paquetes de créditos).
-- La persona paga sola, sin que el administrador apruebe. El plan se prende al pagar y se apaga solo si cancela o si falla el pago.
-- Todo queda ESCONDIDO hasta que: (1) la llave STRIPE_SECRET_KEY esté puesta en Supabase y (2) creditos_config.cobro_activo = true.
-- Los planes de abajo son de EJEMPLO (activo = false). Daniel pone los precios de verdad.
-- Modo de prueba y modo real NO se mezclan: cada fila lleva livemode (false = prueba, true = real), según la llave de Stripe.
-- Pegar entero en Supabase > SQL Editor. Se puede correr dos veces sin problema (no borra lo que Daniel cambie).

/* ---------- 1. Planes y paquetes (lo que se vende) ---------- */
create table if not exists public.planes (
  id text primary key check (id ~ '^[a-z0-9_-]{2,40}$'),
  nombre text not null check (length(nombre) between 2 and 60),
  nombre_en text not null default '' check (length(nombre_en) <= 60),
  descripcion text not null default '' check (length(descripcion) <= 300),
  descripcion_en text not null default '' check (length(descripcion_en) <= 300),
  para text not null check (para in ('negocio','persona')),
  precio_usd numeric(8,2) not null check (precio_usd between 0.50 and 999.99),
  intervalo text not null check (intervalo in ('mes','unico')),
  stripe_price_id text check (stripe_price_id is null or stripe_price_id ~ '^price_[A-Za-z0-9]{6,}$'),  -- si está vacío se cobra con precio_usd
  beneficios jsonb not null default '{}' check (jsonb_typeof(beneficios) = 'object'),  -- {"ia_mensual_usd":5,"minutos_llamadas":400,"creditos":500,"regalo":0}
  activo boolean not null default false,
  orden int not null default 0,
  ejemplo boolean not null default true,              -- true = lo puso Claude de ejemplo; Daniel lo cambia a false cuando lo decida
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  constraint planes_unico_persona check (intervalo = 'mes' or para = 'persona')   -- los paquetes (pago de una vez) son de créditos de una persona
);
alter table public.planes enable row level security;
revoke all on public.planes from anon, authenticated;
grant select on public.planes to anon, authenticated;
grant all on public.planes to service_role;
drop policy if exists planes_ver on public.planes;
create policy planes_ver on public.planes for select to anon, authenticated using (activo or public.es_admin());

-- EJEMPLOS (apagados). No se pisan si ya existen.
insert into public.planes (id, nombre, nombre_en, descripcion, descripcion_en, para, precio_usd, intervalo, beneficios, orden) values
  ('negocio_basico', 'Básico (EJEMPLO)', 'Basic (EXAMPLE)', 'Robotito con inteligencia artificial para tu negocio.', 'Robotito with artificial intelligence for your business.', 'negocio', 9.99, 'mes', '{"ia_mensual_usd":3}', 10),
  ('negocio_pro', 'Pro (EJEMPLO)', 'Pro (EXAMPLE)', 'Más inteligencia artificial y teléfono que contesta solo.', 'More artificial intelligence and a phone that answers by itself.', 'negocio', 29.99, 'mes', '{"ia_mensual_usd":8,"minutos_llamadas":400}', 20),
  ('negocio_max', 'Grande (EJEMPLO)', 'Large (EXAMPLE)', 'Para negocios con muchas llamadas.', 'For businesses with many calls.', 'negocio', 59.99, 'mes', '{"ia_mensual_usd":15,"minutos_llamadas":1000}', 30),
  ('creditos_5', '5 dólares de créditos (EJEMPLO)', '$5 of credits (EXAMPLE)', '', '', 'persona', 5.00, 'unico', '{"creditos":500,"regalo":0}', 100),
  ('creditos_10', '10 dólares de créditos (EJEMPLO)', '$10 of credits (EXAMPLE)', '', '', 'persona', 10.00, 'unico', '{"creditos":1000,"regalo":100}', 110),
  ('creditos_20', '20 dólares de créditos (EJEMPLO)', '$20 of credits (EXAMPLE)', '', '', 'persona', 20.00, 'unico', '{"creditos":2000,"regalo":300}', 120)
on conflict (id) do nothing;

/* ---------- 2. Clientes de Stripe (una persona = un cliente de Stripe en cada modo) ---------- */
create table if not exists public.clientes_stripe (
  user_id uuid not null references auth.users on delete cascade,
  livemode boolean not null default false,
  stripe_customer_id text not null unique check (stripe_customer_id ~ '^cus_[A-Za-z0-9]+$'),
  creado_en timestamptz not null default now(),
  primary key (user_id, livemode)
);
-- por si ya existía una versión vieja de esta tabla (ronda 1: llave primaria solo user_id)
alter table public.clientes_stripe add column if not exists user_id uuid;
alter table public.clientes_stripe add column if not exists livemode boolean not null default false;
alter table public.clientes_stripe add column if not exists stripe_customer_id text;
alter table public.clientes_stripe add column if not exists creado_en timestamptz not null default now();
do $$ declare pk text; cols name[];
begin
  select c.conname, array_agg(a.attname order by a.attname) into pk, cols
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    where c.conrelid = 'public.clientes_stripe'::regclass and c.contype = 'p' group by c.conname;
  if pk is not null and cols = array['livemode','user_id']::name[] then return; end if;
  if pk is not null then execute format('alter table public.clientes_stripe drop constraint %I', pk); end if;
  alter table public.clientes_stripe add primary key (user_id, livemode);
end $$;
alter table public.clientes_stripe enable row level security;
revoke all on public.clientes_stripe from anon, authenticated;
grant select on public.clientes_stripe to authenticated;
grant all on public.clientes_stripe to service_role;
drop policy if exists cs_ver on public.clientes_stripe;
create policy cs_ver on public.clientes_stripe for select to authenticated using (user_id = auth.uid() or public.es_admin());

/* ---------- 3. Suscripciones (de un negocio o de una persona) ----------
   Sin llaves foráneas a negocios/usuarios a propósito: los ids originales se quedan aunque se borre el negocio,
   así un plan de negocio nunca se vuelve "plan de persona". Y mientras haya un plan vivo, no se deja borrar (ver 6). */
create table if not exists public.suscripciones (
  id bigint generated always as identity primary key,
  stripe_subscription_id text not null unique check (stripe_subscription_id ~ '^sub_[A-Za-z0-9]+$'),
  stripe_customer_id text not null,
  livemode boolean not null default false,
  user_id uuid,                     -- quien paga
  negocio_id uuid,                  -- vacío = plan de una persona
  plan_id text,
  estado text not null check (estado in ('active','trialing','past_due','unpaid','canceled','incomplete','incomplete_expired','paused')),
  periodo_fin timestamptz,
  cancela_al_final boolean not null default false,
  duplicada boolean not null default false,   -- segundo plan del mismo negocio/persona: se cancela y se devuelve el dinero
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
-- por si ya existía una versión vieja de esta tabla
alter table public.suscripciones add column if not exists stripe_subscription_id text;
alter table public.suscripciones add column if not exists stripe_customer_id text;
alter table public.suscripciones add column if not exists livemode boolean not null default false;
alter table public.suscripciones add column if not exists user_id uuid;
alter table public.suscripciones add column if not exists negocio_id uuid;
alter table public.suscripciones add column if not exists plan_id text;
alter table public.suscripciones add column if not exists estado text;
alter table public.suscripciones add column if not exists periodo_fin timestamptz;
alter table public.suscripciones add column if not exists cancela_al_final boolean not null default false;
alter table public.suscripciones add column if not exists duplicada boolean not null default false;
alter table public.suscripciones add column if not exists creado_en timestamptz not null default now();
alter table public.suscripciones add column if not exists actualizado_en timestamptz not null default now();
alter table public.suscripciones drop constraint if exists suscripciones_user_id_fkey;
alter table public.suscripciones drop constraint if exists suscripciones_negocio_id_fkey;
create index if not exists suscripciones_negocio on public.suscripciones (negocio_id, estado);
create index if not exists suscripciones_user on public.suscripciones (user_id, estado);
alter table public.suscripciones enable row level security;
revoke all on public.suscripciones from anon, authenticated;
grant select on public.suscripciones to authenticated;
grant all on public.suscripciones to service_role;
drop policy if exists sus_ver on public.suscripciones;
-- los pagos de un negocio los ve el dueño (no los empleados); los de una persona, ella; el administrador, todo
create policy sus_ver on public.suscripciones for select to authenticated
  using ((negocio_id is null and user_id = auth.uid()) or (negocio_id is not null and public.es_dueno(negocio_id)) or public.es_admin());

/* ---------- 4. Eventos de Stripe ya recibidos (para no hacer nada dos veces) ---------- */
create table if not exists public.pagos_eventos (
  id text primary key check (id ~ '^evt_[A-Za-z0-9]+$'),
  tipo text not null check (length(tipo) <= 80),
  estado text not null default 'procesando' check (estado in ('procesando','hecho')),
  creado_en timestamptz not null default now(),
  payload jsonb not null default '{}'          -- solo lo mínimo (tipo de objeto, id, modo prueba); nada de tarjetas ni direcciones
);
alter table public.pagos_eventos add column if not exists estado text not null default 'procesando' check (estado in ('procesando','hecho'));
alter table public.pagos_eventos enable row level security;
revoke all on public.pagos_eventos from anon, authenticated;
grant select on public.pagos_eventos to authenticated;
grant all on public.pagos_eventos to service_role;
drop policy if exists pe_admin on public.pagos_eventos;
create policy pe_admin on public.pagos_eventos for select to authenticated using (public.es_admin());

-- créditos entregados por cada pago (clave = id de la sesión de pago o de la factura): nunca dos veces.
-- payment_intent sirve para quitar los créditos si se devuelve el dinero o hay una disputa.
create table if not exists public.pagos_aplicados (
  clave text primary key check (length(clave) between 3 and 200),
  user_id uuid,
  creditos int not null default 0,
  payment_intent text,
  devueltos int not null default 0,
  creado_en timestamptz not null default now()
);
alter table public.pagos_aplicados add column if not exists payment_intent text;
alter table public.pagos_aplicados add column if not exists devueltos int not null default 0;
create index if not exists pagos_aplicados_pi on public.pagos_aplicados (payment_intent);
alter table public.pagos_aplicados enable row level security;
revoke all on public.pagos_aplicados from anon, authenticated;
grant all on public.pagos_aplicados to service_role;

-- una sola sesión de pago abierta por negocio (o por persona, en planes de persona): la anterior se vence antes de abrir otra
create table if not exists public.pagos_pendientes (
  clave text not null check (clave ~ '^(n|u):[0-9a-f-]{36}$'),
  livemode boolean not null default false,
  session_id text not null check (session_id ~ '^cs_[A-Za-z0-9_]+$'),
  url text not null,
  intento text not null,
  user_id uuid not null,
  expira timestamptz not null,
  creado_en timestamptz not null default now(),
  primary key (clave, livemode)
);
alter table public.pagos_pendientes enable row level security;
revoke all on public.pagos_pendientes from anon, authenticated;
grant all on public.pagos_pendientes to service_role;

-- cómo estaba el negocio ANTES del plan, y qué le puso el plan (para devolverlo igual y no pisar cambios del administrador)
-- minutos: {"+18135550000": {"antes": 600, "aplicado": 1000, "manual": false}}
create table if not exists public.pagos_beneficios_antes (
  negocio_id uuid primary key references public.negocios on delete cascade,
  livemode boolean not null default false,
  ia_antes numeric(8,2) not null default 0,
  ia_aplicado numeric(8,2),
  ia_manual boolean not null default false,
  minutos jsonb not null default '{}',
  creado_en timestamptz not null default now()
);
alter table public.pagos_beneficios_antes add column if not exists livemode boolean not null default false;
alter table public.pagos_beneficios_antes add column if not exists ia_antes numeric(8,2) not null default 0;
alter table public.pagos_beneficios_antes add column if not exists ia_aplicado numeric(8,2);
alter table public.pagos_beneficios_antes add column if not exists ia_manual boolean not null default false;
alter table public.pagos_beneficios_antes add column if not exists minutos jsonb not null default '{}';
alter table public.pagos_beneficios_antes add column if not exists creado_en timestamptz not null default now();
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pagos_beneficios_antes' and column_name = 'ia_mensual_usd') then
    execute 'update public.pagos_beneficios_antes set ia_antes = coalesce(ia_mensual_usd, 0)';
    alter table public.pagos_beneficios_antes drop column ia_mensual_usd;
  end if;
  -- minutos viejos {"+1813...": 600} → {"+1813...": {"antes": 600, "aplicado": null, "manual": false}}
  update public.pagos_beneficios_antes b set minutos = (select coalesce(jsonb_object_agg(k, case when jsonb_typeof(v) = 'number'
      then jsonb_build_object('antes', v, 'aplicado', null, 'manual', false) else v end), '{}'::jsonb) from jsonb_each(b.minutos) as x(k, v))
    where exists (select 1 from jsonb_each(b.minutos) as y(k, v) where jsonb_typeof(v) = 'number');
end $$;
alter table public.pagos_beneficios_antes enable row level security;
revoke all on public.pagos_beneficios_antes from anon, authenticated;
grant all on public.pagos_beneficios_antes to service_role;

-- el modo de la llave de Stripe que está puesta ahora (lo anota el servidor en cada aviso). Nadie lo escoge a mano.
create table if not exists public.pagos_modo (
  id int primary key default 1 check (id = 1),
  live boolean not null,
  actualizado_en timestamptz not null default now()
);
alter table public.pagos_modo enable row level security;
revoke all on public.pagos_modo from anon, authenticated;
grant all on public.pagos_modo to service_role;

-- anota el modo de la llave. Solo escribe (y solo bloquea la fila) si cambió: así los avisos no se ponen en fila.
create or replace function public.pagos_anotar_modo(p_live boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_live is null then return; end if;
  insert into public.pagos_modo (id, live) values (1, p_live) on conflict (id) do nothing;
  update public.pagos_modo set live = p_live, actualizado_en = now() where id = 1 and live <> p_live;
end $$;
revoke all on function public.pagos_anotar_modo(boolean) from public, anon, authenticated;
grant execute on function public.pagos_anotar_modo(boolean) to service_role;

/* ---------- 5. Lo que hace el servidor cuando Stripe avisa ---------- */
create or replace function public.pagos_num(b jsonb, k text) returns numeric
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(b->k) = 'number' then (b->>k)::numeric else null end;
$$;

/* Beneficios del negocio (lo que se decidió):
   - Con plan: cada beneficio queda en el MAYOR entre "lo de antes" y "lo del plan". Si el plan no trae ese beneficio, queda lo de antes.
   - Un teléfono nuevo puesto durante el plan recibe los minutos del plan (y se guarda su valor de antes).
   - Si el administrador cambia un valor durante el plan, GANA el administrador: ese valor ya no se toca (ni al cobrar ni al cancelar).
   - Sin plan: se devuelve lo de antes, menos lo que el administrador cambió a mano. */
create or replace function public.pagos_recalcular_interno(p_negocio uuid, p_live boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b jsonb; a public.pagos_beneficios_antes; cur numeric; ia numeric; mi numeric; obj numeric; t record; e jsonb; m jsonb := '{}';
begin
  if p_negocio is null or not exists (select 1 from public.negocios where id = p_negocio) then return jsonb_build_object('ok', false); end if;
  select p.beneficios into b from public.suscripciones s join public.planes p on p.id = s.plan_id
    where s.negocio_id = p_negocio and s.livemode = p_live and not s.duplicada and s.estado in ('active','trialing') and p.para = 'negocio'
    order by p.precio_usd desc, s.actualizado_en desc limit 1;
  select * into a from public.pagos_beneficios_antes where negocio_id = p_negocio for update;
  if a.negocio_id is not null and a.livemode <> p_live then
    -- lo guardado es del otro modo. Si en ese modo todavía hay un plan que da beneficios, no se toca (se arregla con pagos_borrar_pruebas()).
    if exists (select 1 from public.suscripciones x join public.planes p on p.id = x.plan_id where x.negocio_id = p_negocio and x.livemode = a.livemode
               and not x.duplicada and x.estado in ('active','trialing') and p.para = 'negocio') then
      return jsonb_build_object('ok', false, 'motivo', 'otro_modo');
    end if;
    -- si no, se adopta: el "antes" guardado sigue valiendo, solo cambia de modo
    update public.pagos_beneficios_antes set livemode = p_live where negocio_id = p_negocio;
    a.livemode := p_live;
  end if;
  select mensual_usd into cur from public.ia_bolsa where negocio_id = p_negocio;

  if b is null then   -- ya no tiene plan: volver a como estaba
    if a.negocio_id is null then return jsonb_build_object('ok', true, 'activo', false); end if;
    if not a.ia_manual and (a.ia_aplicado is null or cur is not distinct from a.ia_aplicado) then
      update public.ia_bolsa set mensual_usd = a.ia_antes, actualizado_en = now() where negocio_id = p_negocio;
    end if;
    for t in select numero, minutos_mes_tope from public.telefonos_negocio where negocio_id = p_negocio loop
      e := a.minutos->t.numero;
      if e is null or coalesce((e->>'manual')::boolean, false) then continue; end if;
      if jsonb_typeof(e->'aplicado') = 'number' and t.minutos_mes_tope <> (e->>'aplicado')::int then continue; end if;   -- lo cambió el administrador
      update public.telefonos_negocio set minutos_mes_tope = (e->>'antes')::int where numero = t.numero;
    end loop;
    delete from public.pagos_beneficios_antes where negocio_id = p_negocio;
    return jsonb_build_object('ok', true, 'activo', false);
  end if;

  -- con plan
  if a.negocio_id is null then
    insert into public.pagos_beneficios_antes (negocio_id, livemode, ia_antes) values (p_negocio, p_live, coalesce(cur, 0)) returning * into a;
  end if;
  ia := public.pagos_num(b, 'ia_mensual_usd'); mi := public.pagos_num(b, 'minutos_llamadas');
  if a.ia_aplicado is not null and cur is distinct from a.ia_aplicado then a.ia_manual := true; end if;
  if not a.ia_manual then
    obj := case when ia is null then a.ia_antes else greatest(a.ia_antes, round(least(500, greatest(0, ia)), 2)) end;
    insert into public.ia_bolsa (negocio_id) values (p_negocio) on conflict do nothing;
    update public.ia_bolsa set mensual_usd = obj,
      avisado80 = case when obj > mensual_usd then false else avisado80 end, avisado100 = case when obj > mensual_usd then false else avisado100 end,
      actualizado_en = now() where negocio_id = p_negocio;
    a.ia_aplicado := obj;
  end if;
  for t in select numero, minutos_mes_tope from public.telefonos_negocio where negocio_id = p_negocio loop
    e := a.minutos->t.numero;
    if e is null then e := jsonb_build_object('antes', t.minutos_mes_tope, 'aplicado', null, 'manual', false);
    elsif jsonb_typeof(e->'aplicado') = 'number' and t.minutos_mes_tope <> (e->>'aplicado')::int then e := e || '{"manual": true}'; end if;
    if not coalesce((e->>'manual')::boolean, false) then
      obj := case when mi is null then (e->>'antes')::numeric else greatest((e->>'antes')::numeric, least(100000, greatest(0, mi))) end;
      update public.telefonos_negocio set minutos_mes_tope = obj::int where numero = t.numero;
      e := e || jsonb_build_object('aplicado', obj::int);
    end if;
    m := m || jsonb_build_object(t.numero, e);
  end loop;
  update public.pagos_beneficios_antes set livemode = p_live, ia_aplicado = a.ia_aplicado, ia_manual = a.ia_manual, minutos = m where negocio_id = p_negocio;
  return jsonb_build_object('ok', true, 'activo', true);
end $$;
revoke all on function public.pagos_recalcular_interno(uuid, boolean) from public, anon, authenticated;
grant execute on function public.pagos_recalcular_interno(uuid, boolean) to service_role;

-- lo puede correr el servidor o el administrador. El modo NO lo escoge quien llama: es el de la llave puesta
-- (lo último que anotó el servidor) o, si todavía no hay, el de lo guardado de ese negocio.
drop function if exists public.pagos_recalcular_negocio(uuid, boolean);
create or replace function public.pagos_recalcular_negocio(p_negocio uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v boolean;
begin
  if auth.uid() is not null and not public.es_admin() then raise exception 'Solo el administrador'; end if;
  v := coalesce((select live from public.pagos_modo where id = 1), (select livemode from public.pagos_beneficios_antes where negocio_id = p_negocio));
  if v is null then return jsonb_build_object('ok', false, 'motivo', 'sin_modo'); end if;
  return public.pagos_recalcular_interno(p_negocio, v);
end $$;

-- un teléfono puesto durante el plan recibe los minutos del plan
create or replace function public.pagos_tel_nuevo() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a public.pagos_beneficios_antes;
begin
  select * into a from public.pagos_beneficios_antes where negocio_id = new.negocio_id;
  if a.negocio_id is null then return null; end if;
  if a.livemode <> coalesce((select live from public.pagos_modo where id = 1), a.livemode) then return null; end if;   -- lo guardado es del otro modo
  -- si el número ya estuvo antes (se quitó y se volvió a poner), se olvida lo viejo: recibe los minutos del plan
  update public.pagos_beneficios_antes set minutos = minutos - new.numero where negocio_id = new.negocio_id;
  perform public.pagos_recalcular_interno(new.negocio_id, a.livemode);
  return null;
end $$;
drop trigger if exists pagos_tel_nuevo on public.telefonos_negocio;
create trigger pagos_tel_nuevo after insert on public.telefonos_negocio for each row execute function public.pagos_tel_nuevo();

-- guarda cómo está una suscripción (lo que dice Stripe) y prende o apaga el plan del negocio.
-- Si ya hay OTRO plan vivo para el mismo negocio (o persona), esta queda "duplicada": no da nada y el servidor la cancela y devuelve el dinero.
create or replace function public.pagos_sync_suscripcion(p_sub text, p_customer text, p_user uuid, p_negocio uuid, p_plan text,
  p_estado text, p_periodo_fin timestamptz, p_cancela boolean, p_live boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.suscripciones; dup boolean := false; vivos text[] := array['active','trialing','past_due','unpaid','incomplete','paused'];
  otros text[]; ninguno_activo boolean; cancelar text[] := '{}';
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_sub !~ '^sub_[A-Za-z0-9]+$' then raise exception 'suscripción no válida'; end if;
  if p_estado not in ('active','trialing','past_due','unpaid','canceled','incomplete','incomplete_expired','paused') then raise exception 'estado no válido'; end if;
  if p_live is null then raise exception 'falta el modo'; end if;
  if p_plan is not null and not exists (select 1 from public.planes where id = p_plan and intervalo = 'mes') then p_plan := null; end if;
  select * into s from public.suscripciones where stripe_subscription_id = p_sub for update;
  if s.id is not null and s.livemode <> p_live then raise exception 'modo distinto'; end if;
  p_negocio := coalesce(s.negocio_id, p_negocio); p_user := coalesce(s.user_id, p_user);   -- un plan no cambia de negocio ni de dueño
  -- candado: dos avisos al mismo tiempo para el mismo negocio (o persona) van uno detrás del otro
  if p_negocio is not null then perform pg_advisory_xact_lock(hashtext(p_negocio::text));
  elsif p_user is not null then perform pg_advisory_xact_lock(hashtext('u:' || p_user::text)); end if;
  perform public.pagos_anotar_modo(p_live);   -- solo escribe si cambió
  -- ¿hay OTRO plan vivo para el mismo negocio (o persona)?
  if p_estado = any(vivos) and not coalesce(s.duplicada, false) and (p_negocio is not null or p_user is not null) then
    select array_agg(x.stripe_subscription_id), bool_and(x.estado not in ('active','trialing')) into otros, ninguno_activo
      from public.suscripciones x
      where x.livemode = p_live and x.stripe_subscription_id <> p_sub and not x.duplicada and x.estado = any(vivos)
        and (case when p_negocio is not null then x.negocio_id = p_negocio else x.negocio_id is null and x.user_id = p_user end);
    if otros is not null then
      if p_estado in ('active','trialing') and ninguno_activo then
        -- esta está pagada y las otras no (sin pagar, incompletas…): se quedan las otras como duplicadas y se cancelan
        update public.suscripciones set duplicada = true, actualizado_en = now() where stripe_subscription_id = any(otros);
        cancelar := otros;
      else
        dup := true;   -- ya había una buena: esta es la duplicada
      end if;
    end if;
  end if;
  insert into public.suscripciones (stripe_subscription_id, stripe_customer_id, livemode, user_id, negocio_id, plan_id, estado, periodo_fin, cancela_al_final, duplicada)
    values (p_sub, coalesce(p_customer, ''), p_live, p_user, p_negocio, p_plan, p_estado, p_periodo_fin, coalesce(p_cancela, false), dup)
  on conflict (stripe_subscription_id) do update set
    stripe_customer_id = coalesce(nullif(excluded.stripe_customer_id, ''), public.suscripciones.stripe_customer_id),
    plan_id = coalesce(excluded.plan_id, public.suscripciones.plan_id),
    estado = excluded.estado, periodo_fin = coalesce(excluded.periodo_fin, public.suscripciones.periodo_fin),
    cancela_al_final = excluded.cancela_al_final, duplicada = public.suscripciones.duplicada or excluded.duplicada, actualizado_en = now()
  returning * into s;
  -- si esta es la buena, cancelar también las duplicadas que sigan vivas (por si un intento anterior se cayó antes de cancelarlas)
  if not s.duplicada and s.estado = any(vivos) and (s.negocio_id is not null or s.user_id is not null) then
    select coalesce(array_agg(distinct z), '{}') into cancelar from unnest(cancelar || coalesce((select array_agg(x.stripe_subscription_id)
      from public.suscripciones x where x.livemode = p_live and x.stripe_subscription_id <> p_sub and x.duplicada and x.estado = any(vivos)
        and (case when s.negocio_id is not null then x.negocio_id = s.negocio_id else x.negocio_id is null and x.user_id = s.user_id end)), '{}')) as z;
  end if;
  if s.negocio_id is not null then perform public.pagos_recalcular_interno(s.negocio_id, p_live); end if;
  return jsonb_build_object('ok', true, 'activo', s.estado in ('active','trialing') and not s.duplicada, 'duplicada', s.duplicada,
    'negocio_id', s.negocio_id, 'plan_id', s.plan_id, 'user_id', s.user_id, 'cancelar', to_jsonb(cancelar));
end $$;
drop function if exists public.pagos_sync_suscripcion(text, text, uuid, uuid, text, text, timestamptz, boolean);

-- suma créditos por un pago (una sola vez por clave)
create or replace function public.pagos_dar_creditos(p_user uuid, p_n int, p_clave text, p_detalle text default '', p_pi text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s int;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_user is null or p_n is null or p_n < 1 or p_n > 1000000 then raise exception 'cantidad no válida'; end if;
  if not exists (select 1 from auth.users where id = p_user) then return jsonb_build_object('ok', false, 'motivo', 'sin_usuario'); end if;
  insert into public.pagos_aplicados (clave, user_id, creditos, payment_intent) values (p_clave, p_user, p_n, p_pi) on conflict (clave) do nothing;
  if not found then return jsonb_build_object('ok', true, 'repetido', true); end if;
  insert into public.creditos (user_id, saldo) values (p_user, 0) on conflict do nothing;
  update public.creditos set saldo = saldo + p_n, recargas = recargas + 1, actualizado_en = now() where user_id = p_user returning saldo into s;
  insert into public.creditos_mov (user_id, cambio, motivo, detalle) values (p_user, p_n, 'recarga', left(coalesce(nullif(p_detalle, ''), 'Pago con tarjeta'), 120));
  return jsonb_build_object('ok', true, 'saldo', s);
end $$;
drop function if exists public.pagos_dar_creditos(uuid, int, text, text);

-- quita créditos (de un paquete o del mes de un plan) si se devolvió el dinero (p_fraccion = parte devuelta, 0 a 1) o hubo disputa (1).
-- Nunca deja el saldo debajo de 0. Se puede llamar muchas veces: solo quita lo que falta.
create or replace function public.pagos_quitar_creditos(p_pi text, p_fraccion numeric, p_detalle text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.pagos_aplicados; objetivo int; falta int; s int; quita int;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  if p_pi is null or p_pi !~ '^pi_[A-Za-z0-9]+$' then return jsonb_build_object('ok', false, 'motivo', 'sin_pago'); end if;
  select * into a from public.pagos_aplicados where payment_intent = p_pi order by creado_en limit 1 for update;
  if a.clave is null then return jsonb_build_object('ok', true, 'nada', true); end if;          -- ese pago no dio créditos
  objetivo := least(a.creditos, ceil(a.creditos * least(1, greatest(0, coalesce(p_fraccion, 0)))))::int;
  falta := objetivo - a.devueltos;
  if falta <= 0 then return jsonb_build_object('ok', true, 'repetido', true); end if;
  update public.pagos_aplicados set devueltos = objetivo where clave = a.clave;
  select saldo into s from public.creditos where user_id = a.user_id for update;
  quita := least(falta, coalesce(s, 0));
  if quita > 0 then
    update public.creditos set saldo = saldo - quita, actualizado_en = now() where user_id = a.user_id;
    insert into public.creditos_mov (user_id, cambio, motivo, detalle) values (a.user_id, -quita, 'devolucion', left(coalesce(nullif(p_detalle, ''), 'Devolución del pago'), 120));
  end if;
  return jsonb_build_object('ok', true, 'quitados', quita, 'no_alcanzo', falta - quita);
end $$;

revoke all on function public.pagos_recalcular_negocio(uuid), public.pagos_sync_suscripcion(text, text, uuid, uuid, text, text, timestamptz, boolean, boolean),
  public.pagos_dar_creditos(uuid, int, text, text, text), public.pagos_quitar_creditos(text, numeric, text) from public, anon, authenticated;
grant execute on function public.pagos_recalcular_negocio(uuid), public.pagos_sync_suscripcion(text, text, uuid, uuid, text, text, timestamptz, boolean, boolean),
  public.pagos_dar_creditos(uuid, int, text, text, text), public.pagos_quitar_creditos(text, numeric, text) to service_role;
grant execute on function public.pagos_recalcular_negocio(uuid) to authenticated;   -- adentro revisa que sea el administrador

-- después de pasar a modo real: borra lo que quedó de las pruebas y vuelve a calcular cada negocio afectado (servidor o administrador)
create or replace function public.pagos_borrar_pruebas() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n uuid; negs uuid[]; c int;
begin
  if auth.uid() is not null and not public.es_admin() then raise exception 'Solo el administrador'; end if;
  select coalesce(array_agg(distinct negocio_id) filter (where negocio_id is not null), '{}') into negs from public.suscripciones where not livemode;
  negs := negs || coalesce((select array_agg(negocio_id) from public.pagos_beneficios_antes where not livemode), '{}');
  delete from public.suscripciones where not livemode; get diagnostics c = row_count;
  delete from public.clientes_stripe where not livemode;
  delete from public.pagos_pendientes where not livemode;
  for n in select negocio_id from public.pagos_beneficios_antes where not livemode loop perform public.pagos_recalcular_interno(n, false); end loop;   -- sin planes de prueba: vuelve a como estaba
  foreach n in array negs loop perform public.pagos_recalcular_interno(n, true); end loop;                                                                -- y si tiene un plan real, se pone
  return jsonb_build_object('ok', true, 'suscripciones_borradas', c, 'negocios_recalculados', coalesce(array_length(negs, 1), 0));
end $$;
revoke all on function public.pagos_borrar_pruebas() from public, anon;
grant execute on function public.pagos_borrar_pruebas() to authenticated, service_role;

/* ---------- 6. No se puede borrar un negocio ni una cuenta con un plan pagado vivo ---------- */
create or replace function public.pagos_no_borrar_negocio() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.suscripciones where negocio_id = old.id and livemode and estado in ('active','trialing','past_due','unpaid','incomplete','paused')) then
    raise exception 'Este negocio tiene un plan pagado. Primero cancela el plan (Mi plan → Administrar mi plan) y después lo puedes borrar.';
  end if;
  return old;
end $$;
drop trigger if exists pagos_no_borrar_negocio on public.negocios;
create trigger pagos_no_borrar_negocio before delete on public.negocios for each row execute function public.pagos_no_borrar_negocio();

create or replace function public.pagos_no_borrar_usuario() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.suscripciones where user_id = old.id and livemode and estado in ('active','trialing','past_due','unpaid','incomplete','paused')) then
    raise exception 'Tienes un plan pagado. Primero cancélalo (Administrar mi plan) y después puedes borrar tu cuenta.';
  end if;
  return old;
end $$;
drop trigger if exists pagos_no_borrar_usuario on auth.users;
create trigger pagos_no_borrar_usuario before delete on auth.users for each row execute function public.pagos_no_borrar_usuario();

-- Borrar la cuenta (función "cuenta"): se revisa ANTES de borrar nada, para que la persona vea el motivo y no quede a medias.
-- Es la misma de sql/20_auditoria.sql, con una sola línea nueva al principio (el plan pagado).
create or replace function public.preparar_borrado(p_user uuid) returns setof text
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.suscripciones where user_id = p_user and livemode and estado in ('active','trialing','past_due','unpaid','incomplete','paused')) then
    raise exception 'Tienes un plan pagado. Primero cancélalo (Administrar mi plan) y después puedes borrar tu cuenta.';
  end if;
  if exists (select 1 from public.negocio_miembros where user_id = p_user and rol = 'dueno') then
    raise exception 'Esta cuenta es dueña de un negocio. Primero pásale el negocio a otra persona o escríbenos.';
  end if;
  if exists (select 1 from public.admins where user_id = p_user) then
    raise exception 'La cuenta del administrador no se puede borrar desde aquí.';
  end if;
  delete from public.negocio_miembros where user_id = p_user;   -- si era empleado de algún negocio
  -- lo que la agencia debe guardar por ley se archiva sin la cuenta (10 años)
  insert into public.pedidos_archivo (id, negocio_id, numero, tipo, datos, total, creado_en)
  select p.id, p.negocio_id, p.numero, p.tipo, p.datos, p.total, p.creado_en
  from public.pedidos p where p.cliente_id = p_user and p.tipo in ('envio', 'dinero', 'recarga')
  on conflict (id) do nothing;
  -- lo que no está atado a la cuenta y se quedaría
  delete from public.notas_internas where ref = p_user
     or ref in (select id from public.pedidos where cliente_id = p_user)
     or ref in (select id from public.citas where cliente_id = p_user);
  delete from public.solicitudes where user_id = p_user;
  delete from public.llegadas where user_id = p_user;
  delete from public.ayudante_log where user_id = p_user;
  return query select p.id::text from public.pedidos p where p.cliente_id = p_user;
end $$;
revoke all on function public.preparar_borrado(uuid) from public, anon, authenticated;
grant execute on function public.preparar_borrado(uuid) to service_role;

-- El cobro sigue APAGADO. Daniel lo prende cuando todo esté listo (ver funciones/pagos/LEEME_PAGOS.md):
--   update public.creditos_config set cobro_activo = true where id = 1;

notify pgrst, 'reload schema';
