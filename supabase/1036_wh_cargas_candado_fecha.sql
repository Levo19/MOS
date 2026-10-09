-- 1036 · WH cargadores: candado de fecha en el server (2026-10-08)
-- Causa: en la mañana el 1er pill 🛺 de la lista de guías es el de AYER → 31/71 cargas quedaron con la
-- fecha del día anterior (corregidas el 08-oct; respaldo backup_cargas_fechas.json).
-- Front WH 2.13.602 manda p.tarde=true solo si eligen "Registrar tarde".
-- Partido de pg_get_functiondef (versión VIVA). Grants intactos (create or replace).
begin;
CREATE OR REPLACE FUNCTION wh.cargador_carga_set_nivel(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- [1036] Candado de fecha: una carga NUEVA para un día pasado solo entra si el operador eligió
  -- "Registrar tarde" (p.tarde=true). Si no, va a HOY (Lima). Evita el pill 🛺 de AYER en la mañana
  -- y protege aunque el celular tenga una versión vieja de WH. Solo aplica al INSERT (on conflict no toca fecha).
  if v_dia < (now() at time zone 'America/Lima')::date and coalesce(p->>'tarde','') <> 'true'
     and not exists (select 1 from wh.cargadores_log where id_log = v_idcarga) then
    v_dia   := (now() at time zone 'America/Lima')::date;
    v_fecha := (v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima';
  end if;
  insert into wh.cargadores_log (id_log, fecha, id_cargador, nombre, added_by, device_id, ts, creado_ts, estado, nivel, fotos)
  values (v_idcarga, v_fecha, v_idc, v_nom, v_user, v_dev, now(), now(), 'ACTIVO', v_niv, '[]'::jsonb)
  on conflict (id_log) do update
    set nivel = excluded.nivel, estado = 'ACTIVO', ts = now(),
        nombre = coalesce(excluded.nombre, wh.cargadores_log.nombre);
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idCarga',v_idcarga,'idCargador',v_idc,'nivel',v_niv,'fecha',to_char(v_dia,'YYYY-MM-DD')));
end; $function$;

CREATE OR REPLACE FUNCTION wh.cargador_carga_add_foto(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if v_idcarga is null or v_url is null then return jsonb_build_object('ok',false,'error','FALTAN_DATOS'); end if;

  -- [763] idCargador ausente → resolverlo de la carga existente (el server es la verdad)
  if v_idc is null then
    select id_cargador, coalesce(v_nom, nombre) into v_idc, v_nom
      from wh.cargadores_log where id_log = v_idcarga limit 1;
    if v_idc is null then
      return jsonb_build_object('ok',false,'error','CARGA_NO_ENCONTRADA','detalle','Esa carga ya no existe — refresca la vista y reintenta');
    end if;
  end if;

  -- [1036] Candado de fecha: una carga NUEVA para un día pasado solo entra si el operador eligió
  -- "Registrar tarde" (p.tarde=true). Si no, va a HOY (Lima). Evita el pill 🛺 de AYER en la mañana
  -- y protege aunque el celular tenga una versión vieja de WH. Solo aplica al INSERT (on conflict no toca fecha).
  if v_dia < (now() at time zone 'America/Lima')::date and coalesce(p->>'tarde','') <> 'true'
     and not exists (select 1 from wh.cargadores_log where id_log = v_idcarga) then
    v_dia   := (now() at time zone 'America/Lima')::date;
    v_fecha := (v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima';
  end if;
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

commit;

-- ROLLBACK: reaplicar las definiciones sin el bloque [1036] (quitar el if ... end if;).
