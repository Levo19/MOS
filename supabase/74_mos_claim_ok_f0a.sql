-- 74_mos_claim_ok_f0a.sql — [MIGRACIÓN MOS · FASE 0A] Cimientos de auth/claim para MOS directo a Supabase.
-- Replica el patrón ya probado de WH (wh._claim_ok + Edge mint-wh) para que la PWA de MOS pueda, en fases
-- siguientes, hablar directo con PostgREST/RPC con un JWT propio (claim app='MOS') en vez de saltar a GAS.
--
-- ⚠️ INERTE: este SQL NO cambia el comportamiento de producción.
--   · MOS sigue operando 100% por GAS (service_role, sin claim app → coalesce(...,'') = '' → pasa todos los gates).
--   · Las RPCs que ya consumía WH siguen pasando IGUAL: el gate cambia de `wh._claim_ok()` a
--     `wh._claim_ok() OR mos._claim_ok()`, que es un SUPERCONJUNTO (todo lo que pasaba antes, sigue pasando).
--   · Nadie emite todavía un token con claim app='MOS' hasta que la Edge mint-mos exista y el frontend la use.
--
-- APP-ID DE MOS — CONFIRMADO CONTRA DATOS REALES (mos.dispositivos):
--   distinct app = {'MOS','mosExpress','warehouseMos'}.  MOS usa 'MOS' en MAYÚSCULAS (NO 'mos').
--   Evidencia adicional en GAS: Config.gs registra dispositivos con `app:'MOS'`; Config.gs:2283 trata
--   `app === 'MOS' || app === ''` como MOS → el fallback de app vacía pertenece a MOS, igual que a WH/service_role.
--   Por eso el claim aceptado es coalesce(me.jwt_app(),'') in ('', 'MOS').

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) Gate reutilizable de MOS — análogo a wh._claim_ok(): service_role/GAS (sin claim app) o JWT app='MOS'.
--    Cualquier otro claim (warehouseMos, mosExpress, ...) → false.
--    security definer + search_path='' por endurecimiento declarativo (la función no toca tablas, pero fija
--    el contrato igual que las RPCs del proyecto). me.jwt_app() ya está schema-qualified, así que el
--    search_path vacío no la afecta.
create or replace function mos._claim_ok()
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(me.jwt_app(), '') in ('', 'MOS');
$fn$;
revoke all on function mos._claim_ok() from public;
grant execute on function mos._claim_ok() to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2) Re-gate de las RPCs que MOS necesitará leer directo y que HOY también sirven a WH.
--    Cambio: `wh._claim_ok()` → `wh._claim_ok() OR mos._claim_ok()`.  Es un superconjunto:
--      · claim warehouseMos  → wh._claim_ok()=true  → sigue pasando (WH NO se rompe).
--      · claim '' / service_role → ambos true       → sigue pasando (GAS NO se rompe).
--      · claim 'MOS' (futuro) → mos._claim_ok()=true → NUEVO acceso habilitado para la PWA de MOS.
--      · otro claim (mosExpress) → ambos false       → rechazado (igual que antes).

-- 2a) mos.catalogo_wh_rls() — catálogo (productos/equivalencias/proveedores/personal/impresoras/zonas).
--     Cuerpo IDÉNTICO a 48_mos_catalogo_wh_rls.sql salvo el gate. Exclusiones de seguridad intactas
--     (numero_cuenta/cci de proveedores; pin/pin_hash de personal).
create or replace function mos.catalogo_wh_rls()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prod jsonb;
  v_equiv jsonb;
  v_prov jsonb;
  v_pers jsonb;
  v_impr jsonb;
  v_zonas jsonb;
begin
  if not (wh._claim_ok() or mos._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.id_producto), '[]'::jsonb) into v_prod
    from mos.productos t;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.id_equiv), '[]'::jsonb) into v_equiv
    from mos.equivalencias e where e.activo = true;                 -- solo activas
  -- ⚠ SEGURIDAD: excluir datos bancarios (numero_cuenta/cci) — WH/MOS-PWA no los necesitan para operar.
  select coalesce(jsonb_agg((to_jsonb(p) - 'numero_cuenta' - 'cci') order by p.id_proveedor), '[]'::jsonb) into v_prov
    from mos.proveedores p;                                          -- todos
  -- ⚠ SEGURIDAD: excluir pin y pin_hash del personal (NUNCA exponer PINs al navegador).
  select coalesce(jsonb_agg((to_jsonb(p) - 'pin' - 'pin_hash') order by p.id_personal), '[]'::jsonb) into v_pers
    from mos.personal p where p.estado = true;                       -- activos
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id_impresora), '[]'::jsonb) into v_impr
    from mos.impresoras i where lower(coalesce(i.app_origen,'')) = 'warehousemos' and i.activo = true;
  select coalesce(jsonb_agg(to_jsonb(z) order by z.id_zona), '[]'::jsonb) into v_zonas
    from mos.zonas z where z.estado = true;                          -- activas
  return jsonb_build_object('ok', true,
    'productos', v_prod, 'equivalencias', v_equiv, 'proveedores', v_prov,
    'personal', v_pers, 'impresoras', v_impr, 'zonas', v_zonas);
end;
$fn$;
revoke all on function mos.catalogo_wh_rls() from public;
grant execute on function mos.catalogo_wh_rls() to service_role, authenticated;

-- 2b) mos.verificar_clave_admin(...) — RPC central de validación de clave admin (hash + niveles + auditoría).
--     Cuerpo IDÉNTICO a 51_mos_verificar_clave_admin.sql salvo el gate. NO re-hashea PINs (eso lo hizo el 51);
--     este archivo solo redefine la función para ampliar el gate. Firma 8-arg sin cambios.
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
  if not (wh._claim_ok() or mos._claim_ok()) then
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

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3) PENDIENTE FASE 1 (NO se toca acá — inerte por diseño):
--    · mos.finanzas_rango(...)        (13_mos_finanzas_rango.sql)   — hoy grant SOLO service_role.
--    · mos.historial_precios_lista(...) (12_fase1d_mos_historial.sql) — hoy grant SOLO service_role.
--    Para que la PWA de MOS las lea directo habrá que, EN FASE 1 (con el flag de cutover):
--      a) grant execute ... to authenticated;
--      b) agregar gate `if not mos._claim_ok() then return APP_NO_AUTORIZADA`.
--    No se hace ahora porque exponen datos (finanzas / historial de precios) y el principio F0 es 0 exposición.
