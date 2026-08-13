-- 763 · Foto de cargador resiliente (13-ago-2026) — "No se subió la foto: FALTAN_DATOS".
-- La RPC exigía idCargador SIEMPRE, pero el front lo deriva de su lista local en memoria:
-- si la carga no está en esa lista (carga optimista con id ya definitivo, vista desfasada),
-- mandaba vacío y el server rechazaba — aunque la carga YA EXISTE en la base con su
-- id_cargador guardado. Ahora: si falta idCargador, se RESUELVE de la propia carga;
-- FALTAN_DATOS solo si la carga no existe Y no hay forma de saber de quién es.
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
