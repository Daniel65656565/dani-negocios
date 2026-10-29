-- DANI Pro — 29: el MOTOR (modelo pequeño por uso, 29 oct 2026, decidido con Daniel)
-- Orden de Robotito: 1) fichas (gratis)  2) motor (centavos: lee las fichas parecidas y contesta natural)  3) IA grande.
-- De fábrica APAGADO. Se prende cuando Daniel pegue la llave (secreto MOTOR_API_KEY) y lo prenda en su panel.
-- Quién paga: dentro de un negocio con bolsita, la bolsita del negocio (costo real, centavos).
--             Si no hay bolsita (o fuera de un negocio): el presupuesto del motor de Daniel (tope del mes).
-- El cliente NO gasta créditos en el motor. Seguros: tope del mes en dólares, tope por persona al día.
-- Pegar entero en Supabase > SQL Editor. Se puede correr dos veces sin problema.

create table if not exists public.motor_config (
  id int primary key default 1 check (id = 1),
  prendido boolean not null default false,
  url text not null default 'https://api.groq.com/openai/v1/chat/completions',
  modelo text not null default 'openai/gpt-oss-20b',
  precio_in numeric not null default 0.075,    -- dólares por millón (Groq, oct 2026)
  precio_out numeric not null default 0.30,
  tope_mes_usd numeric(8,2) not null default 5 check (tope_mes_usd between 0 and 1000),
  tope_dia_persona int not null default 40 check (tope_dia_persona between 0 and 1000),
  admin_paga boolean not null default true,     -- si el negocio no tiene bolsita, paga el presupuesto del motor
  parecido_min real not null default 0.12,      -- fichas con menos parecido no se le mandan al motor
  actualizado_en timestamptz not null default now()
);
insert into public.motor_config (id) values (1) on conflict do nothing;
alter table public.motor_config enable row level security;
revoke all on public.motor_config from anon, authenticated;
grant all on public.motor_config to service_role;

create table if not exists public.motor_gasto (
  mes text primary key,
  costo numeric(12,6) not null default 0,          -- todo lo del motor
  costo_admin numeric(12,6) not null default 0,    -- solo lo que pagó el presupuesto de Daniel (es lo que cuenta para su tope)
  llamadas int not null default 0,
  contesto int not null default 0,     -- veces que el motor supo contestar
  no_supo int not null default 0
);
alter table public.motor_gasto enable row level security;
revoke all on public.motor_gasto from anon, authenticated;
grant all on public.motor_gasto to service_role;

alter table public.motor_gasto add column if not exists costo_admin numeric(12,6) not null default 0;

create table if not exists public.motor_uso (
  user_id uuid not null references auth.users on delete cascade,
  dia date not null default (now() at time zone 'America/New_York')::date,
  n int not null default 0,
  primary key (user_id, dia)
);
alter table public.motor_uso enable row level security;
revoke all on public.motor_uso from anon, authenticated;
grant all on public.motor_uso to service_role;

-- ¿Se puede usar el motor ahora? Reserva una vuelta. (solo el servidor)
create or replace function public.motor_reservar(p_user uuid, p_negocio uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.motor_config; m text := to_char(now() at time zone 'America/New_York', 'YYYY-MM');
  d date := (now() at time zone 'America/New_York')::date; gastado numeric; k int; b jsonb; paga text := 'admin';
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  select * into c from public.motor_config where id = 1;
  if not coalesce(c.prendido, false) then return jsonb_build_object('ok', false, 'motivo', 'apagado'); end if;
  select u.n into k from public.motor_uso u where u.user_id = p_user and u.dia = d;
  if coalesce(k, 0) >= c.tope_dia_persona then return jsonb_build_object('ok', false, 'motivo', 'tope_persona'); end if;
  if p_negocio is not null then
    b := public.ia_bolsa_ok(p_negocio);
    if coalesce((b->>'ok')::boolean, false) then paga := 'negocio'; end if;
  end if;
  if paga = 'admin' then
    if not c.admin_paga then return jsonb_build_object('ok', false, 'motivo', 'sin_bolsa'); end if;
    select x.costo_admin into gastado from public.motor_gasto x where x.mes = m;
    if coalesce(gastado, 0) >= c.tope_mes_usd then return jsonb_build_object('ok', false, 'motivo', 'tope_mes'); end if;
  end if;
  insert into public.motor_uso (user_id, dia, n) values (p_user, d, 1)
    on conflict (user_id, dia) do update set n = public.motor_uso.n + 1;
  return jsonb_build_object('ok', true, 'paga', paga, 'url', c.url, 'modelo', c.modelo,
    'precio_in', c.precio_in, 'precio_out', c.precio_out, 'parecido_min', c.parecido_min);
end $$;
revoke all on function public.motor_reservar(uuid, uuid) from public, anon, authenticated;
grant execute on function public.motor_reservar(uuid, uuid) to service_role;

-- Anota lo que costó. Si pagó el negocio, también se descuenta de su bolsita. (solo el servidor)
create or replace function public.motor_anotar(p_negocio uuid, p_paga text, p_costo numeric, p_supo boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare m text := to_char(now() at time zone 'America/New_York', 'YYYY-MM');
begin
  if auth.uid() is not null then raise exception 'solo el servidor'; end if;
  insert into public.motor_gasto (mes, costo, costo_admin, llamadas, contesto, no_supo)
    values (m, greatest(coalesce(p_costo, 0), 0), case when p_paga = 'negocio' then 0 else greatest(coalesce(p_costo, 0), 0) end, 1, case when p_supo then 1 else 0 end, case when p_supo then 0 else 1 end)
    on conflict (mes) do update set costo = public.motor_gasto.costo + excluded.costo, costo_admin = public.motor_gasto.costo_admin + excluded.costo_admin, llamadas = public.motor_gasto.llamadas + 1,
      contesto = public.motor_gasto.contesto + excluded.contesto, no_supo = public.motor_gasto.no_supo + excluded.no_supo;
  if p_paga = 'negocio' and p_negocio is not null then perform public.ia_bolsa_gastar(p_negocio, p_costo); end if;
end $$;
revoke all on function public.motor_anotar(uuid, text, numeric, boolean) from public, anon, authenticated;
grant execute on function public.motor_anotar(uuid, text, numeric, boolean) to service_role;

-- Panel del administrador: ver y cambiar el motor (prender, topes, modelo)
create or replace function public.admin_motor(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.motor_config; g public.motor_gasto; m text := to_char(now() at time zone 'America/New_York', 'YYYY-MM');
begin
  if not public.es_admin() then raise exception 'Solo el administrador'; end if;
  update public.motor_config set
    prendido = coalesce((p->>'prendido')::boolean, prendido),
    tope_mes_usd = greatest(0, least(1000, coalesce((p->>'tope_mes_usd')::numeric, tope_mes_usd))),
    tope_dia_persona = greatest(0, least(1000, coalesce((p->>'tope_dia_persona')::int, tope_dia_persona))),
    admin_paga = coalesce((p->>'admin_paga')::boolean, admin_paga),
    modelo = coalesce(nullif(p->>'modelo', ''), modelo),
    precio_in = coalesce((p->>'precio_in')::numeric, precio_in),
    precio_out = coalesce((p->>'precio_out')::numeric, precio_out),
    actualizado_en = now()
  where id = 1 returning * into c;
  select * into g from public.motor_gasto where mes = m;
  return jsonb_build_object('prendido', c.prendido, 'modelo', c.modelo, 'tope_mes_usd', c.tope_mes_usd, 'tope_dia_persona', c.tope_dia_persona,
    'admin_paga', c.admin_paga, 'gastado_mes', coalesce(g.costo, 0), 'pagado_por_ti_mes', coalesce(g.costo_admin, 0), 'llamadas_mes', coalesce(g.llamadas, 0),
    'contesto_mes', coalesce(g.contesto, 0), 'no_supo_mes', coalesce(g.no_supo, 0));
end $$;
revoke all on function public.admin_motor(jsonb) from public, anon;
grant execute on function public.admin_motor(jsonb) to authenticated;

notify pgrst, 'reload schema';
