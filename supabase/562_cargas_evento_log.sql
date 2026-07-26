-- ════════════════════════════════════════════════════════════════════
-- 562 — Cargas como LOG DE EVENTOS. Un cargador puede hacer VARIAS cargas al día;
-- cada carga tiene su propio nivel (termómetro %), sus fotos y su hora de registro.
-- Reutiliza la tabla wh.cargadores_log: ahora cada fila = UNA CARGA (evento), con
-- id_log = id_carga ÚNICO por evento (lo genera el cliente, idempotente/offline).
-- Las filas migradas (1 por cargador/día) siguen valiendo como "1 carga".
-- Cero GAS. security definer + _claim_ok + gates existentes.
-- ════════════════════════════════════════════════════════════════════

-- ── Registrar/actualizar una CARGA puntual (upsert por id_carga). Crea la fila si
--    falta (nivel provisional) o actualiza su nivel. El cliente manda id_carga único. ──
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
  insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, estado, nivel, fotos)
  values (v_idcarga, v_fecha, v_idc, v_nom, v_user, v_dev, now(), 'ACTIVO', v_niv, '[]'::jsonb)
  on conflict (id_log) do update
    set nivel = excluded.nivel, estado = 'ACTIVO', ts = now(),
        nombre = coalesce(excluded.nombre, wh.cargadores_log.nombre);
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idCarga',v_idcarga,'idCargador',v_idc,'nivel',v_niv,'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

-- ── Agregar foto a una CARGA puntual (upsert de la fila si aún no existe). ──
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
  insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, estado, nivel, fotos)
  values (v_idcarga, v_fecha, v_idc, v_nom, v_user, v_dev, now(), 'ACTIVO', 0, to_jsonb(array[v_url]))
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

-- ── Quitar (marcar ELIMINADO) una CARGA puntual por id_carga. ──
create or replace function wh.cargador_carga_quitar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_idcarga text := nullif(btrim(p->>'idCarga'),'');
begin
  if coalesce((select valor from mos.config where clave='WH_REMOVE_CARGADOR_DIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REMOVE_CARGADOR_DIA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idcarga is null then return jsonb_build_object('ok',false,'error','FALTAN_DATOS'); end if;
  update wh.cargadores_log set estado='ELIMINADO', ts=now() where id_log = v_idcarga;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idCarga',v_idcarga));
end; $function$;

-- ── Resumen del día AGRUPADO POR CARGADOR con sus cargas (hora, nivel, fotos). ──
--    Protagonista del modal. cargadores por actividad reciente; cargas cronológicas.
create or replace function wh.resumen_cargas_dia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_dia date := wh._carg_dia(p->>'fecha');
  v_cargadores jsonb; v_tot_cargas int; v_tot_cargadores int;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with cargas as (
    select id_log as id_carga, id_cargador,
           max(nombre) over (partition by id_cargador) as nombre,
           coalesce(nivel,0) as nivel, coalesce(fotos,'[]'::jsonb) as fotos, ts
      from wh.cargadores_log
     where upper(coalesce(estado,'')) = 'ACTIVO'
       and (fecha at time zone 'America/Lima')::date = v_dia
  ),
  por_cargador as (
    select id_cargador,
           coalesce(nullif(btrim(max(nombre)),''), id_cargador) as nombre,
           max(ts) as ult_ts,
           count(*)::int as n_cargas,
           jsonb_agg(jsonb_build_object(
             'idCarga', id_carga,
             'nivel', nivel,
             'fotos', fotos,
             'ts', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
             'hora', to_char(ts at time zone 'America/Lima','HH24:MI')
           ) order by ts asc) as cargas
      from cargas
     group by id_cargador
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCargador', id_cargador,
           'nombre', nombre,
           'nCargas', n_cargas,
           'cargas', cargas
         ) order by ult_ts desc nulls last, nombre), '[]'::jsonb),
         coalesce(sum(n_cargas),0)::int,
         coalesce(count(*),0)::int
    into v_cargadores, v_tot_cargas, v_tot_cargadores
    from por_cargador;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'fecha', to_char(v_dia,'YYYY-MM-DD'),
    'totalCargas', v_tot_cargas,
    'totalCargadores', v_tot_cargadores,
    'cargadores', v_cargadores));
end; $function$;

grant execute on function wh.cargador_carga_set_nivel(jsonb) to anon, authenticated, service_role;
grant execute on function wh.cargador_carga_add_foto(jsonb)  to anon, authenticated, service_role;
grant execute on function wh.cargador_carga_quitar(jsonb)    to anon, authenticated, service_role;
grant execute on function wh.resumen_cargas_dia(jsonb)       to anon, authenticated, service_role;
