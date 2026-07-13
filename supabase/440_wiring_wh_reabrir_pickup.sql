-- 440 · Re-verificacion clave (NO-estricto, verifica-si-viene) en wh.reabrir_guia + wh.actualizar_pickup.
-- actualizar_pickup es MIXTA (lock/heartbeat normal SIN clave + eliminar admin CON clave) → non-strict obligatorio.

-- wh.reabrir_guia (accion=REABRIR_GUIA, non-strict)
CREATE OR REPLACE FUNCTION wh.reabrir_guia(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_estado  text;
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'REABRIR_GUIA', coalesce(p->>'idGuia',p->>'idPickup',''), 'warehouseMos', false);
  if v_rvf is not null then return v_rvf; end if;
  if coalesce((select valor from mos.config where clave='WH_REABRIR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REABRIR_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- FOR UPDATE: serializa contra cierre/reapertura concurrente del mismo id.
  select estado into v_estado from wh.guias where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  -- idempotente: si ya ABIERTA, no-op (no toca nada)
  if upper(coalesce(v_estado,'')) = 'ABIERTA' then
    return jsonb_build_object('ok',true,'yaAbierta',true,'estado_previo',v_estado);
  end if;

  -- INVARIANTE: NO se revierte stock, NO se resetea cantidad_aplicada. Solo estado.
  update wh.guias set estado = 'ABIERTA', ultima_actividad = now() where id_guia = v_id;
  return jsonb_build_object('ok',true,'id_guia',v_id,'revertido',false,'estado_previo',v_estado);
end;
$function$
;

-- wh.actualizar_pickup (accion=ELIMINAR_PICKUP, non-strict)
CREATE OR REPLACE FUNCTION wh.actualizar_pickup(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_estado  text := nullif(btrim(coalesce(p->>'estado','')),'');
  v_lock    text := coalesce(p->>'lock_usuario', p->>'lockUsuario', '');
  v_tomar   boolean := coalesce((p->>'tomar_lock')::boolean, (p->>'tomarLock')::boolean, false);
  v_liberar boolean := coalesce((p->>'liberar_lock')::boolean, (p->>'liberarLock')::boolean, false);
  v_atp     text;
  v_now     timestamptz := now();
  v_rvf jsonb;
begin
  v_rvf := mos.reverificar_clave_admin(coalesce(p->>'claveAdmin',''), 'ELIMINAR_PICKUP', coalesce(p->>'idGuia',p->>'idPickup',''), 'warehouseMos', false);
  if v_rvf is not null then return v_rvf; end if;
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select atendido_por into v_atp from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- Conflicto de lock: lo atiende OTRO usuario (no yo en otro device)
  if v_lock <> '' and coalesce(btrim(v_atp),'') <> '' and not wh._pickup_same_user(v_atp, v_lock) then
    return jsonb_build_object('ok',false,'error','Pickup atendido por '||v_atp,'atendidoPor',v_atp,'conflicto',true);
  end if;

  update wh.pickups
     set estado         = coalesce(v_estado, estado),
         fecha_atendido = case when v_estado = 'COMPLETADO' then v_now else fecha_atendido end,
         atendido_por   = case when v_liberar then ''
                               when v_tomar and v_lock <> '' then v_lock
                               else atendido_por end,
         ultima_actividad = v_now
   where id_pickup = v_idp;
  return jsonb_build_object('ok',true);
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$function$
;

