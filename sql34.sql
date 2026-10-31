-- DANI Pro — 34: el cargador de fichas de los obreros respeta el tipo de negocio (solar, taller, comida, servicios).
-- Cada fila: [tema, preguntas_es, preguntas_en, respuesta_es, respuesta_en, delicado(0/1), tipo_negocio]. Si falta el tipo -> 'general'.
-- Se puede correr dos veces sin problema.
create or replace function public.cargar_fichas_otra_cuenta(p jsonb, p_lote bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb; x jsonb; nuevas int := 0; repetidas int := 0; malas int := 0; t text;
begin
  if auth.uid() is not null and not public.es_admin() then raise exception 'no permitido'; end if;
  for x in select * from jsonb_array_elements(p) loop
    t := coalesce(nullif(x->>6, ''), 'general');
    if t not in ('general', 'solar', 'taller', 'comida', 'servicios') then t := 'general'; end if;
    r := public.importar_fichas(jsonb_build_array(jsonb_build_object('tipo_negocio', t, 'tema', x->>0, 'preguntas_es', x->1, 'preguntas_en', x->2, 'respuesta_es', x->>3, 'respuesta_en', x->>4,
           'cuidado', case when (x->>5) = '1' then 'delicado' else null end)), 'otra_cuenta', p_lote);
    nuevas := nuevas + (r->>'nuevas')::int; repetidas := repetidas + (r->>'repetidas')::int; malas := malas + (r->>'malas')::int;
  end loop;
  update public.biblioteca set estado = 'prueba', activo = (cuidado is distinct from 'delicado'), revisar_en = (now() + interval '120 days')::date
    where fuente = 'otra_cuenta' and lote_id = p_lote and creado_en = now();
  return jsonb_build_object('nuevas', nuevas, 'repetidas', repetidas, 'malas', malas);
end $$;
revoke all on function public.cargar_fichas_otra_cuenta(jsonb, bigint) from public, anon, authenticated;
