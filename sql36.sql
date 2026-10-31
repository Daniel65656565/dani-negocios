-- DANI Pro — 36: memoria de la charla en el servidor (31 oct 2026)
-- Lo que la persona preguntó y lo que Robotito contestó, 12 horas, por persona y por negocio ("general" = inicio).
-- Solo la usa el servidor (función asistente). "Olvida todo" la borra. Se puede correr dos veces.
create table if not exists public.charla_srv (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  clave text not null check (length(clave) between 3 and 60),
  q text not null check (length(q) <= 300),
  a text not null check (length(a) <= 400),
  creado_en timestamptz not null default now()
);
create index if not exists charla_srv_buscar on public.charla_srv (user_id, clave, creado_en desc);
create index if not exists charla_srv_viejas on public.charla_srv (creado_en);
alter table public.charla_srv enable row level security;
revoke all on public.charla_srv from anon, authenticated;
grant all on public.charla_srv to service_role;
