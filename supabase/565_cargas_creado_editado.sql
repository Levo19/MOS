-- ════════════════════════════════════════════════════════════════════
-- 565 — Cargas: separar HORA DE REGISTRO (creación) de ÚLTIMA EDICIÓN.
-- Antes `ts` se pisaba en cada edición (nivel/foto), así la "hora" saltaba.
-- Añade creado_ts (fijo al crear); ts sigue siendo la última edición.
-- Reescribe los RPCs de escritura (no tocar creado_ts en update) y de lectura
-- (hora=creado, editado=ts, orden cronológico por creación) + `generado` al ticket.
-- ════════════════════════════════════════════════════════════════════

alter table wh.cargadores_log add column if not exists creado_ts timestamptz;
update wh.cargadores_log set creado_ts = ts where creado_ts is null;   -- backfill: mejor dato disponible

-- ── set_nivel: INSERT fija creado_ts; UPDATE solo ts (última edición). ──
create or replace function wh.cargador_carga_set_nivel(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_idcarga text := nullif(btrim(p->>'idCarga'),'');
  v_idc     text := nullif(btrim(p->>'idCargador'),'');
  v_nom     text := nullif(btrim(p->>'nombre'),'');
  v_niv     int  := greatest(0, least(100, coalesce((p->>'nivel')::int, 0)));
  v_dia     date := wh._carg_dia(p->>'fecha');
  v_fecha   timestamptz := (v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima';
  v_user    text := nullif(btrim(p->>'usuario'),'');
  v_dev     text := nullif(btrim(p->>'deviceId'),'');
begin
  if coalesce((select valor from mos.config where clave='WH_ADD_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ADD_CARGADOR_DIA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idcarga is null or v_idc is null then return jsonb_build_object('ok',false,'error','FALTAN_DATOS'); end if;
  insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, creado_ts, estado, nivel, fotos)
  values (v_idcarga, v_fecha, v_idc, v_nom, v_user, v_dev, now(), now(), 'ACTIVO', v_niv, '[]'::jsonb)
  on conflict (id_log) do update
    set nivel = excluded.nivel, estado = 'ACTIVO', ts = now(),
        nombre = coalesce(excluded.nombre, wh.cargadores_log.nombre);
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idCarga',v_idcarga,'idCargador',v_idc,'nivel',v_niv,'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

-- ── add_foto: INSERT fija creado_ts; UPDATE solo ts. ──
create or replace function wh.cargador_carga_add_foto(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_idcarga text := nullif(btrim(p->>'idCarga'),'');
  v_idc     text := nullif(btrim(p->>'idCargador'),'');
  v_nom     text := nullif(btrim(p->>'nombre'),'');
  v_url     text := nullif(btrim(p->>'url'),'');
  v_dia     date := wh._carg_dia(p->>'fecha');
  v_fecha   timestamptz := (v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima';
  v_user    text := nullif(btrim(p->>'usuario'),'');
  v_dev     text := nullif(btrim(p->>'deviceId'),'');
  v_fotos   jsonb;
begin
  if coalesce((select valor from mos.config where clave='WH_ADD_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ADD_CARGADOR_DIA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idcarga is null or v_idc is null or v_url is null then return jsonb_build_object('ok',false,'error','FALTAN_DATOS'); end if;
  insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, creado_ts, estado, nivel, fotos)
  values (v_idcarga, v_fecha, v_idc, v_nom, v_user, v_dev, now(), now(), 'ACTIVO', 0, to_jsonb(array[v_url]))
  on conflict (id_log) do update
    set fotos = case when wh.cargadores_log.fotos @> to_jsonb(array[v_url])
                     then wh.cargadores_log.fotos
                     else coalesce(wh.cargadores_log.fotos,'[]'::jsonb) || to_jsonb(v_url) end,
        estado = 'ACTIVO', ts = now(),
        nombre = coalesce(excluded.nombre, wh.cargadores_log.nombre)
  returning fotos into v_fotos;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idCarga',v_idcarga,'fotos',coalesce(v_fotos,'[]'::jsonb),'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

-- ── resumen_cargas_dia: hora=creación, editado=última edición, orden cronológico. ──
create or replace function wh.resumen_cargas_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_dia date := wh._carg_dia(p->>'fecha');
  v_cargadores jsonb; v_tot_cargas int; v_tot_cargadores int;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with cargas as (
    select id_log as id_carga, id_cargador, coalesce(nivel,0) as nivel,
           coalesce(fotos,'[]'::jsonb) as fotos, ts, coalesce(creado_ts, ts) as creado,
           max(nombre) over (partition by id_cargador) as nombre
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia
  ),
  por_cargador as (
    select id_cargador, coalesce(nullif(btrim(max(nombre)),''), id_cargador) as nombre,
           max(ts) as ult_ts, count(*)::int as n_cargas,
           jsonb_agg(jsonb_build_object(
             'idCarga', id_carga, 'nivel', nivel, 'fotos', fotos,
             'hora', to_char(creado at time zone 'America/Lima','HH24:MI'),
             'editado', to_char(ts at time zone 'America/Lima','HH24:MI'),
             'edito', (ts > creado + interval '1 minute'),
             'ts', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS')
           ) order by creado asc) as cargas
      from cargas group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCargador', id_cargador, 'nombre', nombre, 'nCargas', n_cargas, 'cargas', cargas)
           order by ult_ts desc nulls last, nombre), '[]'::jsonb),
         coalesce(sum(n_cargas),0)::int, coalesce(count(*),0)::int
    into v_cargadores, v_tot_cargas, v_tot_cargadores from por_cargador;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'fecha', to_char(v_dia,'YYYY-MM-DD'), 'totalCargas', v_tot_cargas,
    'totalCargadores', v_tot_cargadores, 'cargadores', v_cargadores,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI')));
end; $function$;

-- ── reporte público: idem (hora/editado por carga) + generado ya presente. ──
create or replace function public.reporte_cargadores_dia(p_fecha text default null)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_dia date := wh._carg_dia(p_fecha);
  v_cargadores jsonb; v_tot_cargas int; v_tot_cargadores int; v_avg numeric;
begin
  with cargas as (
    select id_log as id_carga, id_cargador, coalesce(nivel,0) as nivel,
           coalesce(fotos,'[]'::jsonb) as fotos, ts, coalesce(creado_ts, ts) as creado,
           max(nombre) over (partition by id_cargador) as nombre
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia
  ),
  por_cargador as (
    select id_cargador, coalesce(nullif(btrim(max(nombre)),''), id_cargador) as nombre,
           max(ts) as ult_ts, count(*)::int as n_cargas,
           jsonb_agg(jsonb_build_object(
             'hora', to_char(creado at time zone 'America/Lima','HH24:MI'),
             'editado', to_char(ts at time zone 'America/Lima','HH24:MI'),
             'edito', (ts > creado + interval '1 minute'),
             'nivel', nivel, 'fotos', fotos) order by creado asc) as cargas
      from cargas group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'nCargas', n_cargas, 'cargas', cargas)
           order by ult_ts desc nulls last, nombre), '[]'::jsonb),
         coalesce(sum(n_cargas),0)::int, coalesce(count(*),0)::int
    into v_cargadores, v_tot_cargas, v_tot_cargadores from por_cargador;
  select coalesce(round(avg(coalesce(nivel,0))),0) into v_avg
    from wh.cargadores_log
   where upper(coalesce(estado,''))='ACTIVO' and (fecha at time zone 'America/Lima')::date = v_dia;
  return jsonb_build_object('ok', true, 'fecha', to_char(v_dia,'YYYY-MM-DD'),
    'totalCargas', v_tot_cargas, 'totalCargadores', v_tot_cargadores, 'promedio', v_avg,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
    'cargadores', v_cargadores);
end; $function$;

-- ── ticket ESC/POS: cargas con hora/editado (fotos como conteo) + generado. ──
create or replace function wh.cargadores_ticket_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_dia date := wh._carg_dia(p->>'fecha');
  v_cargadores jsonb; v_tot_cargas int; v_tot_cargadores int; v_prom numeric;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with cargas as (
    select id_cargador, coalesce(nivel,0) as nivel,
           jsonb_array_length(coalesce(fotos,'[]'::jsonb)) as nfotos, ts, coalesce(creado_ts, ts) as creado,
           max(nombre) over (partition by id_cargador) as nombre
      from wh.cargadores_log
     where upper(coalesce(estado,''))='ACTIVO' and (fecha at time zone 'America/Lima')::date = v_dia
  ),
  por_cargador as (
    select id_cargador, coalesce(nullif(btrim(max(nombre)),''), id_cargador) as nombre,
           max(ts) as ult_ts, count(*)::int as n_cargas,
           jsonb_agg(jsonb_build_object(
             'hora', to_char(creado at time zone 'America/Lima','HH24:MI'),
             'editado', to_char(ts at time zone 'America/Lima','HH24:MI'),
             'edito', (ts > creado + interval '1 minute'),
             'nivel', nivel, 'fotos', nfotos) order by creado asc) as cargas
      from cargas group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'nCargas', n_cargas, 'cargas', cargas)
           order by ult_ts desc nulls last, nombre), '[]'::jsonb),
         coalesce(sum(n_cargas),0)::int, coalesce(count(*),0)::int
    into v_cargadores, v_tot_cargas, v_tot_cargadores from por_cargador;
  select coalesce(round(avg(coalesce(nivel,0))),0) into v_prom
    from wh.cargadores_log
   where upper(coalesce(estado,''))='ACTIVO' and (fecha at time zone 'America/Lima')::date = v_dia;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'fecha',to_char(v_dia,'YYYY-MM-DD'), 'totalCargas',v_tot_cargas,'totalCargadores',v_tot_cargadores,
    'promedio',v_prom, 'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
    'cargadores',v_cargadores));
end; $function$;

grant execute on function wh.cargador_carga_set_nivel(jsonb) to anon, authenticated, service_role;
grant execute on function wh.cargador_carga_add_foto(jsonb)  to anon, authenticated, service_role;
grant execute on function wh.resumen_cargas_dia(jsonb)       to anon, authenticated, service_role;
grant execute on function public.reporte_cargadores_dia(text) to anon, authenticated, service_role;
grant execute on function wh.cargadores_ticket_dia(jsonb)    to anon, authenticated, service_role;
