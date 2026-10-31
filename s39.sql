-- DANI Pro — 39: descarga segura del instalador del Panel Dani (31 oct 2026)
-- Guardado PRIVADO "instalador". Daniel sube ahí el archivo (Storage → instalador → Upload). Nadie lo ve por fuera.
-- Solo quien tiene una licencia ACTIVA puede pedir un enlace, y el enlace se vence a los 10 minutos.
-- Se puede correr dos veces.

insert into storage.buckets (id, name, public) values ('instalador', 'instalador', false) on conflict (id) do nothing;

create or replace function public.tiene_licencia_activa() returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (select 1 from public.licencias l where l.user_id = auth.uid() and public.licencia_efectiva(l) = 'activa') $$;
revoke all on function public.tiene_licencia_activa() from public, anon;
grant execute on function public.tiene_licencia_activa() to authenticated, service_role;

-- el archivo más nuevo (o null si no tiene licencia activa o todavía no hay archivo)
create or replace function public.instalador_archivo() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not public.tiene_licencia_activa() then jsonb_build_object('ok', false, 'motivo', 'sin_licencia')
    else coalesce((select jsonb_build_object('ok', true, 'nombre', o.name, 'fecha', o.created_at) from storage.objects o
                   where o.bucket_id = 'instalador' and o.name !~ '(^|/)\.' order by o.created_at desc limit 1),
                  jsonb_build_object('ok', false, 'motivo', 'sin_archivo')) end $$;
revoke all on function public.instalador_archivo() from public, anon;
grant execute on function public.instalador_archivo() to authenticated, service_role;

-- leer (y firmar enlaces de) ese guardado: solo con licencia activa. Subir, cambiar o borrar: solo el administrador.
drop policy if exists instalador_leer on storage.objects;
create policy instalador_leer on storage.objects for select to authenticated
  using (bucket_id = 'instalador' and (public.tiene_licencia_activa() or public.es_admin()));
drop policy if exists instalador_admin on storage.objects;
create policy instalador_admin on storage.objects for all to authenticated
  using (bucket_id = 'instalador' and public.es_admin()) with check (bucket_id = 'instalador' and public.es_admin());
