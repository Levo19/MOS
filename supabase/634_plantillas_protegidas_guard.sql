CREATE OR REPLACE FUNCTION mos.adhesivo_plantilla_eliminar(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id text := nullif(p->>'idPlantilla','');
  v_prot boolean;
begin
  -- [634] PLANTILLA DE SISTEMA: metadata.protegida=true → NO se elimina jamás
  -- (las fabrica Claude por encargo del dueño; las del Estudio sí son borrables).
  if exists (select 1 from mos.adhesivo_plantillas ap
              where ap.id_plantilla = btrim(coalesce(p->>'idPlantilla',''))
                and coalesce((ap.json->'metadata'->>'protegida')::boolean, false) = true) then
    return jsonb_build_object('ok', false, 'error', 'PLANTILLA_PROTEGIDA: es de sistema, no se puede eliminar');
  end if;

  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idPlantilla requerido'); end if;
  select coalesce((json #>> '{metadata,protegida}')::boolean, false) into v_prot
    from mos.adhesivo_plantillas where id_plantilla = v_id and activo;
  if coalesce(v_prot,false) then
    return jsonb_build_object('ok', false, 'error', 'PROTEGIDA',
      'detalle', 'Esta plantilla base no se puede eliminar. Duplícala (⎘) para crear una nueva.');
  end if;
  update mos.adhesivo_plantillas set activo = false where id_plantilla = v_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no encontrada: ' || v_id); end if;
  return jsonb_build_object('ok', true, 'eliminado', v_id);
end;
$function$
