-- 343: push best-effort en _validar_clave_admin_core (#16 acciones money -> admins). Cero-GAS.
CREATE OR REPLACE FUNCTION mos._validar_clave_admin_core(p_clave text, p_accion text DEFAULT 'GENERICA'::text, p_ref text DEFAULT ''::text, p_app text DEFAULT ''::text, p_device text DEFAULT ''::text, p_detalle text DEFAULT ''::text, p_tier integer DEFAULT NULL::integer, p_cliente_meta jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_global text; v_user text; v_ghash text;
  v_id text; v_nombre text; v_apellido text; v_rol text;
  v_nivel int; v_nivelmin int; v_tier int; v_idacc text; v_nom text;
begin
  -- (SIN gate de claim — esa es la única diferencia con verificar_clave_admin; la barrera real es el bcrypt de abajo)
  -- formato 8 dígitos (igual que GAS)
  if p_clave is null or length(btrim(p_clave)) <> 8 or btrim(p_clave) !~ '^\d{8}$' then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'La clave debe ser de 8 dígitos numéricos');
  end if;
  v_global := substr(btrim(p_clave), 1, 4);
  v_user   := substr(btrim(p_clave), 5, 4);

  -- global vs hash
  select valor into v_ghash from mos.config where clave = 'ADMIN_GLOBAL_PIN_HASH' limit 1;
  if v_ghash is null then
    return jsonb_build_object('ok', false, 'error', 'ADMIN_GLOBAL_PIN_HASH no configurado en MOS');
  end if;
  if v_ghash <> extensions.crypt(v_global, v_ghash) then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Clave incorrecta');
  end if;

  -- admin por pin personal (hash), rol nivel>=2 (ADMIN/MASTER), estado activo
  select p.id_personal, p.nombre, p.apellido, p.rol
    into v_id, v_nombre, v_apellido, v_rol
    from mos.personal p
   where mos.rol_nivel(p.rol) >= 2
     and p.estado = true
     and p.pin_hash is not null
     and p.pin_hash = extensions.crypt(v_user, p.pin_hash)
   limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Clave incorrecta');
  end if;

  -- nivel requerido por la acción (default admin=2 si no está en catálogo)
  v_nivel := mos.rol_nivel(v_rol);
  select nivel_minimo, tier into v_nivelmin, v_tier from mos.permisos_accion where accion = upper(coalesce(p_accion,'')) limit 1;
  v_nivelmin := coalesce(v_nivelmin, 2);
  if v_nivel < v_nivelmin then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'NIVEL_INSUFICIENTE',
      'requiere', case when v_nivelmin >= 3 then 'master' else 'admin' end, 'rol_actor', v_rol);
  end if;

  -- auditoría única (no bloquea el resultado si algo raro pasa con la inserción)
  v_nom  := btrim(v_nombre || ' ' || coalesce(v_apellido, ''));
  v_tier := coalesce(p_tier, v_tier, 2);
  v_idacc := 'AUD' || to_char(now(), 'YYYYMMDDHH24MISSMS') || substr(md5(random()::text), 1, 4);
  begin
    insert into mos.auditoria_admin (id_accion, accion, ref_documento, id_personal_autoriza, nombre_autoriza,
      rol_autoriza, nivel_autoriza, app_origen, dispositivo, tier, device_id, cliente_meta, detalle)
    values (v_idacc, upper(coalesce(p_accion,'GENERICA')), p_ref, v_id, v_nom, v_rol, v_nivel,
      p_app, p_device, v_tier, p_device, p_cliente_meta, p_detalle);
  exception when others then null;
  end;

  -- [CERO-GAS push #16] aviso a admins/master de acciones sensibles (money). Best-effort, NUNCA rompe la auth.
  begin
    if upper(coalesce(p_accion,'')) in ('ANULAR_PAGO','ANULAR_VENTA','ANULAR','CERRAR_CAJA_FORZADO','VETAR_LIQUIDACION_DIA','DESVETAR_LIQUIDACION_DIA','PAGO_JORNAL','DESBLOQUEO_TEMPORAL') then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '🔐 Acción admin autorizada',
        'cuerpo', v_nom || ' autorizó: ' || upper(coalesce(p_accion,'')),
        'data', jsonb_build_object('tipo','admin_auth','accion',upper(coalesce(p_accion,'')))));
    end if;
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'autorizado', true, 'validado_por', 'admin:' || v_nom,
    'id_personal', v_id, 'nombre', v_nom, 'rol', v_rol, 'nivel', v_nivel, 'id_accion', v_idacc);
end;
$function$
;
