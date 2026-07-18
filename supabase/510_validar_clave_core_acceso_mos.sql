-- ============================================================================
-- 510_validar_clave_core_acceso_mos.sql
-- ----------------------------------------------------------------------------
-- Cierra el ÚLTIMO hueco del ASCENSO DUAL (acceso_mos): mos._validar_clave_admin_core
-- —el corazón de TODA validación de clave admin de 8 díg (extender horario, vetar,
-- aprobar dispositivo, etc.)— filtraba el personal por `rol_nivel(p.rol) >= 2` SIN
-- honrar acceso_mos. Un operador ascendido (ej. Jorgenis OP001, ALMACENERO +
-- acceso_mos=true) NO matcheaba → su clave se rechazaba como "Clave incorrecta" y el
-- modal de extensión de horario rebotaba. 501 arregló get_clave_admin_global y
-- login_pin_wh con el mismo patrón, pero NO tocó la core.
--
-- Fix (idéntico patrón a 501):
--   (a) lookup por rol nivel>=2 O acceso_mos=true.
--   (b) rol EFECTIVO: ascendido (rol_nivel<2 AND acceso_mos) se presenta como 'ADMIN'
--       → el chequeo de nivel_minimo de la acción usa el nivel efectivo (ADMIN=2).
--       El rol REAL (mos.personal.rol) queda intacto → pago/asistencia sin cambios.
-- Master (nivel 3) sigue exclusivo: un ascendido efectivo-ADMIN NO pasa acciones tier 3.
-- 100% Supabase. Cero cambio para admins/master reales (la rama OR no los afecta).
-- ============================================================================
create or replace function mos._validar_clave_admin_core(
  p_clave       text,
  p_accion      text    default 'GENERICA',
  p_ref         text    default '',
  p_app         text    default '',
  p_device      text    default '',
  p_detalle     text    default '',
  p_tier        int     default null,
  p_cliente_meta jsonb  default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_global text; v_user text; v_ghash text;
  v_id text; v_nombre text; v_apellido text; v_rol text; v_acceso boolean;
  v_nivel int; v_nivelmin int; v_tier int; v_idacc text; v_nom text;
begin
  -- (SIN gate de claim — esa es la única diferencia con verificar_clave_admin; la barrera real es el bcrypt de abajo)
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

  -- [FIX 510] admin por rol (nivel>=2) O ascendido (acceso_mos): un operador ascendido
  -- valida su clave admin igual que un admin/master. estado activo + pin personal (hash).
  select p.id_personal, p.nombre, p.apellido, p.rol, coalesce(p.acceso_mos,false)
    into v_id, v_nombre, v_apellido, v_rol, v_acceso
    from mos.personal p
   where (mos.rol_nivel(p.rol) >= 2 or coalesce(p.acceso_mos, false) = true)
     and p.estado = true
     and p.pin_hash is not null
     and p.pin_hash = extensions.crypt(v_user, p.pin_hash)
   limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Clave incorrecta');
  end if;

  -- [FIX 510] rol EFECTIVO: el ascendido (rol_nivel<2 AND acceso_mos) se presenta como 'ADMIN'
  -- para el chequeo de nivel de la acción (el rol REAL queda intacto para pago/asistencia).
  if mos.rol_nivel(v_rol) < 2 and v_acceso then v_rol := 'ADMIN'; end if;

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

  return jsonb_build_object('ok', true, 'autorizado', true, 'validado_por', 'admin:' || v_nom,
    'id_personal', v_id, 'nombre', v_nom, 'rol', v_rol, 'nivel', v_nivel, 'id_accion', v_idacc);
end;
$fn$;
revoke all on function mos._validar_clave_admin_core(text,text,text,text,text,text,int,jsonb) from public, anon, authenticated;
grant execute on function mos._validar_clave_admin_core(text,text,text,text,text,text,int,jsonb) to service_role;
