-- 781 · ME: editar CABECERA de guía por el operador — modelo WH (14-ago-2026, tarea #5).
-- Réplica fiel de wh.actualizar_guia: solo metadata (observación y zona destino del
-- movimiento), JAMÁS toca stock, líneas ni lotes. Solo se actualizan las claves
-- PRESENTES en el payload (mandar '' SÍ limpia — convención WH). Sin clave admin
-- (paridad WH: la cabecera es corregible por el operador libremente).
create or replace function me.editar_guia_cabecera(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_g   me.guias_cabecera%rowtype;
begin
  if me.jwt_app() not in ('mosExpress','MOS') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select * into v_g from me.guias_cabecera where id_guia = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','Guía no encontrada'); end if;

  update me.guias_cabecera set
    observacion  = case when p ? 'observacion' then nullif(btrim(p->>'observacion'),'') else observacion end,
    zona_destino = case when p ? 'zonaDestino' then nullif(btrim(p->>'zonaDestino'),'') else zona_destino end,
    ultima_actividad = now()
  where id_guia = v_id;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia', v_id,
    'observacion',  case when p ? 'observacion'  then nullif(btrim(p->>'observacion'),'')  else v_g.observacion  end,
    'zonaDestino',  case when p ? 'zonaDestino'  then nullif(btrim(p->>'zonaDestino'),'')  else v_g.zona_destino end));
end;
$function$;

revoke all on function me.editar_guia_cabecera(jsonb) from public;
grant execute on function me.editar_guia_cabecera(jsonb) to authenticated, service_role;
