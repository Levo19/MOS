-- 53_mos_autorizacion_fix_rls.sql — [Autorización · FIX 40x] Cierra brecha CRÍTICA hallada en auditoría adversarial.
-- mos.auditoria_admin y mos.permisos_accion se crearon en 49/50 DESPUÉS del loop `enable row level security` de
-- 04_schema_mos.sql → quedaron SIN RLS. auditoria_admin tenía insert/select para authenticated → cualquier token
-- del fleet podía FORJAR/LEER la auditoría de acciones de dinero. Fix: habilitar RLS (deny-all a authenticated, igual
-- que el resto de mos.*) + revocar grants a authenticated. La RPC verificar_clave_admin es security definer (escribe/lee
-- como owner, bypassa RLS) → sigue funcionando sin grants a authenticated.

alter table mos.auditoria_admin enable row level security;
alter table mos.permisos_accion enable row level security;

-- auditoría: nadie escribe/lee directo; solo la RPC (definer) y diagnóstico service_role.
revoke insert, select on mos.auditoria_admin from authenticated;
-- catálogo de permisos: lo consume la RPC (definer); el front no lo lee directo por ahora.
revoke select on mos.permisos_accion from authenticated;
