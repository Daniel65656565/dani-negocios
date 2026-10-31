-- DANI Pro — 37: licencias del "Panel Dani para NinjaTrader" (31 oct 2026)
-- Solo el servidor (función "licencia", con la llave de servicio) lee y escribe estas tablas: RLS prendido y sin permisos para anon/authenticated.
-- Se puede correr dos veces.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.licencias (
  id uuid primary key default gen_random_uuid(),
  clave text not null unique check (clave ~ '^DANI-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$'),
  user_id uuid references auth.users on delete set null,
  producto text not null default 'panel_nt' check (producto in ('panel_nt')),
  plan text not null check (plan in ('mensual','semestral','anual','fundador','prueba')),
  estado text not null default 'activa' check (estado in ('activa','cancelada','bloqueada')),
  vence timestamptz,                         -- fin del período pagado (null = no vence, ej. fundador)
  max_maquinas int not null default 2 check (max_maquinas between 1 and 10),
  prueba boolean not null default false,     -- licencias de prueba: el complemento de verdad las rechaza
  stripe_sub text,                           -- la suscripción de Stripe que la mantiene (cuando se venda)
  notas text not null default '' check (length(notas) <= 300),
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create table if not exists public.licencia_maquinas (
  licencia_id uuid not null references public.licencias on delete cascade,
  maquina text not null check (maquina ~ '^[0-9a-f]{64}$'),
  nombre text not null default '' check (length(nombre) <= 40),
  version text not null default '' check (length(version) <= 20),
  activa boolean not null default true,
  primera timestamptz not null default now(),
  ultima timestamptz not null default now(),
  primary key (licencia_id, maquina)
);
create table if not exists public.licencia_intentos (
  id bigint generated always as identity primary key,
  ip text not null default '',
  clave text not null default '',
  creado_en timestamptz not null default now()
);
create index if not exists licencia_intentos_ip on public.licencia_intentos (ip, creado_en);
create index if not exists licencia_intentos_clave on public.licencia_intentos (clave, creado_en);
create table if not exists public.licencia_llave (
  id int primary key default 1 check (id = 1),
  privada_jwk jsonb not null,
  publica_pem text not null,
  x text not null, y text not null,
  creado_en timestamptz not null default now()
);
do $$ declare t text; begin
  foreach t in array array['licencias','licencia_maquinas','licencia_intentos','licencia_llave'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;

-- estado de verdad (cancelada sigue sirviendo hasta que se acabe lo pagado)
create or replace function public.licencia_efectiva(l public.licencias) returns text language sql stable as $$
  select case when l.estado = 'bloqueada' then 'bloqueada'
              when l.vence is not null and l.vence <= now() then case when l.estado = 'cancelada' then 'cancelada' else 'vencida' end
              else 'activa' end $$;

create or replace function public.licencia_respuesta(l public.licencias, p_estado text) returns jsonb language sql stable as $$
  select jsonb_build_object('estado', p_estado, 'plan', l.plan, 'vence', l.vence, 'prueba', l.prueba,
    'usadas', (select count(*) from public.licencia_maquinas m where m.licencia_id = l.id and m.activa), 'max', l.max_maquinas) $$;

-- límite de intentos: 30 por IP y 30 por clave cada 10 minutos
create or replace function public.licencia_intento(p_ip text, p_clave text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare a int; b int;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select count(*) into a from public.licencia_intentos where ip = left(coalesce(p_ip, ''), 60) and creado_en > now() - interval '10 minutes';
  select count(*) into b from public.licencia_intentos where clave = left(coalesce(p_clave, ''), 30) and creado_en > now() - interval '10 minutes';
  insert into public.licencia_intentos (ip, clave) values (left(coalesce(p_ip, ''), 60), left(coalesce(p_clave, ''), 30));
  if random() < 0.02 then delete from public.licencia_intentos where creado_en < now() - interval '1 day'; end if;
  return a < 30 and b < 30;
end $$;

create or replace function public.licencia_activar(p_clave text, p_maquina text, p_nombre text, p_version text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias; e text; n int;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select * into l from public.licencias where clave = p_clave for update;
  if l.id is null then return jsonb_build_object('estado', 'no_existe'); end if;
  e := public.licencia_efectiva(l);
  if e <> 'activa' then return public.licencia_respuesta(l, e); end if;
  if exists (select 1 from public.licencia_maquinas where licencia_id = l.id and maquina = p_maquina) then
    update public.licencia_maquinas set activa = true, ultima = now(), nombre = left(coalesce(p_nombre, ''), 40), version = left(coalesce(p_version, ''), 20)
      where licencia_id = l.id and maquina = p_maquina and (activa or (select count(*) from public.licencia_maquinas m where m.licencia_id = l.id and m.activa) < l.max_maquinas);
    if not found then return public.licencia_respuesta(l, 'maquinas_llenas'); end if;
    return public.licencia_respuesta(l, 'activa');
  end if;
  select count(*) into n from public.licencia_maquinas where licencia_id = l.id and activa;
  if n >= l.max_maquinas then return public.licencia_respuesta(l, 'maquinas_llenas'); end if;
  insert into public.licencia_maquinas (licencia_id, maquina, nombre, version) values (l.id, p_maquina, left(coalesce(p_nombre, ''), 40), left(coalesce(p_version, ''), 20));
  return public.licencia_respuesta(l, 'activa');
end $$;

create or replace function public.licencia_comprobar(p_clave text, p_maquina text, p_version text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias; e text;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select * into l from public.licencias where clave = p_clave;
  if l.id is null then return jsonb_build_object('estado', 'no_existe'); end if;
  e := public.licencia_efectiva(l);
  if e <> 'activa' then return public.licencia_respuesta(l, e); end if;
  update public.licencia_maquinas set ultima = now(), version = left(coalesce(p_version, ''), 20) where licencia_id = l.id and maquina = p_maquina and activa;
  if not found then return public.licencia_respuesta(l, 'maquina_no_activada'); end if;
  return public.licencia_respuesta(l, 'activa');
end $$;

create or replace function public.licencia_soltar(p_clave text, p_maquina text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare l public.licencias;
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select * into l from public.licencias where clave = p_clave for update;
  if l.id is null then return jsonb_build_object('estado', 'no_existe'); end if;
  update public.licencia_maquinas set activa = false, ultima = now() where licencia_id = l.id and maquina = p_maquina;
  return public.licencia_respuesta(l, 'soltada');
end $$;

-- crear una licencia (lo usa el aviso de Stripe al vender, o el administrador para pruebas)
create or replace function public.licencia_crear(p_user uuid, p_plan text, p_vence timestamptz, p_max int default 2, p_prueba boolean default false, p_notas text default '') returns text
language plpgsql security definer set search_path = '' as $$
declare k text; letras text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea; i int; intento int := 0;
begin
  if auth.uid() is not null and not exists (select 1 from public.admins where user_id = auth.uid()) then raise exception 'solo el servidor'; end if;
  loop
    b := extensions.gen_random_bytes(12); k := 'DANI-';
    for i in 0..11 loop k := k || substr(letras, (get_byte(b, i) % 32) + 1, 1); if i in (3, 7) then k := k || '-'; end if; end loop;
    begin
      insert into public.licencias (clave, user_id, plan, vence, max_maquinas, prueba, notas) values (k, p_user, p_plan, p_vence, coalesce(p_max, 2), coalesce(p_prueba, false), left(coalesce(p_notas, ''), 300));
      return k;
    exception when unique_violation then intento := intento + 1; if intento > 5 then raise; end if; end;
  end loop;
end $$;

-- la llave de firma: se crea sola la primera vez (la función la genera y la guarda aquí)
create or replace function public.licencia_llave_guardar(p_privada jsonb, p_pem text, p_x text, p_y text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  insert into public.licencia_llave (id, privada_jwk, publica_pem, x, y) values (1, p_privada, p_pem, p_x, p_y) on conflict (id) do nothing;
end $$;

do $$ declare f text; begin
  foreach f in array array['licencia_efectiva(public.licencias)','licencia_respuesta(public.licencias,text)','licencia_intento(text,text)','licencia_activar(text,text,text,text)','licencia_comprobar(text,text,text)','licencia_soltar(text,text)',
    'licencia_crear(uuid,text,timestamptz,int,boolean,text)','licencia_llave_guardar(jsonb,text,text,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;
