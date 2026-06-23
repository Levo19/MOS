-- FIX (v2.8.30 review): me.reabrir_guia_zona rechazaba app='mosExpress'.
-- El frontend ME llama /rpc/reabrir_guia_zona con Content-Profile 'me' (→ me.reabrir_guia_zona)
-- y token de dispositivo (app='mosExpress'). El gate era mos._claim_ok() que SOLO acepta
-- ('', 'MOS') → APP_NO_AUTORIZADA → el botón Reabrir SIEMPRE fallaba.
-- Sus RPC hermanas de escritura (recibir_guia_wh / recibir_guia_wh_cerrar / zona_guia_registrar_meta)
-- usan me._claim_zona_ok() que acepta ('', 'MOS', 'mosExpress'). Alineamos el gate.
-- El wrapper mos.reabrir_guia_zona (gate mos._claim_ok para MOS) queda intacto.

CREATE OR REPLACE FUNCTION me.reabrir_guia_zona(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idGuia', p->>'idGuiaWH', '')), '');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_estado text;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select estado into v_estado from me.guias_cabecera where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  if upper(coalesce(v_estado,'')) = 'ABIERTA' then
    return jsonb_build_object('ok',true,'dedup',true,'idGuia',v_id,'estado','ABIERTA','eraEstado',v_estado);
  end if;

  -- reabrir + tocar el reloj (para que el autocierre vuelva a contar la inactividad desde ahora).
  update me.guias_cabecera set estado = 'ABIERTA', ultima_actividad = now() where id_guia = v_id;

  return jsonb_build_object('ok',true,'idGuia',v_id,'estado','ABIERTA','eraEstado',v_estado,'reabiertoPor',v_user);
end;
$function$;
