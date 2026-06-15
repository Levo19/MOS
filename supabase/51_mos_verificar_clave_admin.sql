-- 51_mos_verificar_clave_admin.sql — [Autorización · F1] RPC central de validación (hash + niveles + auditoría única).
-- Replica EXACTO la lógica de verificarClaveAdmin (MOS gas/Seguridad.gs:189) + _buscarAdminPorPin (169):
--   8 díg; global=substr(1,4) vs ADMIN_GLOBAL_PIN; personal=substr(5,4) vs admin (rol ADMIN/MASTER + estado activo + pin).
-- MEJORA aditiva (lo que pidió el usuario): chequea rol_nivel(admin) >= permisos_accion.nivel_minimo → admin NO puede
-- acciones master-only (cascada). DIVERGENCIA INTENCIONAL con GAS (que autoriza cualquier admin para todo).
-- PINs HASHEADOS (bcrypt): pin_hash en mos.personal, ADMIN_GLOBAL_PIN_HASH en mos.config. Padded a 4 (lpad), igual que padStart(4) de GAS.
-- INERTE: nadie la llama aún (F2 = apps la consumen con fallback a GAS). security definer + gate wh._claim_ok().

-- 1) hash de PINs (poblar desde texto plano actual; lpad 4 = padStart(4) de GAS)
alter table mos.personal add column if not exists pin_hash text;
update mos.personal
  set pin_hash = extensions.crypt(lpad(btrim(pin), 4, '0'), extensions.gen_salt('bf'))
  where pin is not null and btrim(pin) <> '' and pin_hash is null;

-- 2) hash del PIN global (key-value en mos.config). No re-hashea si ya existe (rotación lo regenera aparte).
insert into mos.config (clave, valor, descripcion)
  select 'ADMIN_GLOBAL_PIN_HASH', extensions.crypt(lpad(btrim(c.valor), 4, '0'), extensions.gen_salt('bf')), 'Hash bcrypt del PIN admin global (F1)'
  from mos.config c where c.clave = 'ADMIN_GLOBAL_PIN'
  on conflict (clave) do nothing;

-- 3) RPC central
create or replace function mos.verificar_clave_admin(
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
  v_id text; v_nombre text; v_apellido text; v_rol text;
  v_nivel int; v_nivelmin int; v_tier int; v_idacc text; v_nom text;
begin
  if not wh._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
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

  return jsonb_build_object('ok', true, 'autorizado', true, 'validado_por', 'admin:' || v_nom,
    'id_personal', v_id, 'nombre', v_nom, 'rol', v_rol, 'nivel', v_nivel, 'id_accion', v_idacc);
end;
$fn$;

revoke all on function mos.verificar_clave_admin(text,text,text,text,text,text,int,jsonb) from public;
grant execute on function mos.verificar_clave_admin(text,text,text,text,text,text,int,jsonb) to service_role, authenticated;
