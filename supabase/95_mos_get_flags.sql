-- 95_mos_get_flags.sql — INTERRUPTOR CENTRAL de la flota MOS (réplica fiel de me.get_flags() del 20_fase2_flags).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- PROBLEMA: el cutover de ESCRITURA de un módulo MOS exige (a) prender la escritura directa Y (b) apagar el sync
-- Hoja→Supabase de esa tabla (mos.config.MOS_SYNC_OFF_TABLAS, global server-side). Pero hoy el gate de escritura
-- del frontend se decide POR DISPOSITIVO (_mosFlag: localStorage || window.MOS_CONFIG). Si flipeo sync-off pero un
-- dispositivo viejo (Service Worker NO actualizado) sigue escribiendo por GAS→hoja, ese dato se PIERDE de la
-- sombra (sync apagado) → incoherencia/duplicación. Solución (igual que ME): un flag de SERVIDOR leído al arrancar
-- y cada ~2min vía esta RPC → flip/kill de TODA la flota INSTANTÁNEO, sin depender del rollout del SW.
--
-- USO (flip atómico de un módulo, SIN tocar frontend):
--   begin;
--     update mos.config set valor='1' where clave='MOS_GASTOS_DIRECTO';                 -- (a) prender escritura directa (flota)
--     update mos.config set valor='gastos' where clave='MOS_SYNC_OFF_TABLAS';           -- (b) apagar sync Hoja→Supabase de esa tabla
--   commit;                                                                              -- los dos en la MISMA tx → sin ventana de incoherencia
--   -- KILL-SWITCH instantáneo: update mos.config set valor='0' where clave='MOS_GASTOS_DIRECTO';
--
-- El frontend hace `serverFlag === '1' || localStorage || MOS_CONFIG` → el server prende/apaga a TODOS desde pg,
-- y localStorage/MOS_CONFIG siguen como override por-dispositivo (piloto). Los flags NO son sensibles (solo on/off
-- de features booleanas) → legibles por anon SIN token, igual que me.get_flags() (se leen al arrancar, antes del mint).
--
-- ⚠️ INERTE: todas las claves MOS_*_DIRECTO están en '0' (verificado). Con todo en '0' esta RPC devuelve todo '0' →
--    cada _mosFlag(...) sigue decidiéndose por localStorage/MOS_CONFIG exactamente como hoy. El CATÁLOGO sigue vivo
--    por window.MOS_CONFIG.catalogoDirecto=true (cliente), NO por esta RPC (MOS_CATALOGO_DIRECTO sigue '0' en server,
--    por lo que el término server de catálogo es '0' → no enciende ni duplica nada; el OR con MOS_CONFIG lo mantiene).

-- Las claves ya están sembradas por los SQL 78-86 (MOS_*_DIRECTO, default '0'). No se siembra nada nuevo acá.

-- RPC: devuelve un objeto jsonb keyed por el cfgKey camelCase que consume el frontend (_mosFlag(...,cfgKey)),
-- mapeando server clave → cfgKey. SECURITY DEFINER (lee mos.config aunque anon no tenga grant de tabla),
-- STABLE, search_path=''. Fail-safe: cada valor cae a '0' si la clave no existe (coalesce) → default OFF = seguro.
-- NO expone secretos: solo los flags MOS_*_DIRECTO (booleanos '0'/'1'); deja FUERA PIN/hash/heartbeat/sync-off/ttl.
create or replace function mos.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with f as (
    select clave, valor from mos.config where clave like 'MOS\_%\_DIRECTO'
  )
  select jsonb_build_object(
    'catalogoDirecto',    coalesce((select valor from f where clave='MOS_CATALOGO_DIRECTO'),    '0'),
    'proveedoresDirecto', coalesce((select valor from f where clave='MOS_PROVEEDORES_DIRECTO'), '0'),
    'pedidosDirecto',     coalesce((select valor from f where clave='MOS_PEDIDOS_DIRECTO'),     '0'),
    'pagosDirecto',       coalesce((select valor from f where clave='MOS_PAGOS_DIRECTO'),       '0'),
    'provprodDirecto',    coalesce((select valor from f where clave='MOS_PROVPROD_DIRECTO'),    '0'),
    'gastosDirecto',      coalesce((select valor from f where clave='MOS_GASTOS_DIRECTO'),      '0'),
    'evalDirecto',        coalesce((select valor from f where clave='MOS_EVAL_DIRECTO'),        '0'),
    'horarioDirecto',     coalesce((select valor from f where clave='MOS_HORARIO_DIRECTO'),     '0'),
    'jornadasDirecto',    coalesce((select valor from f where clave='MOS_JORNADAS_DIRECTO'),    '0'),
    'liqdiaDirecto',      coalesce((select valor from f where clave='MOS_LIQDIA_DIRECTO'),      '0'),
    'pagosJornalDirecto', coalesce((select valor from f where clave='MOS_PAGOS_JORNAL_DIRECTO'),'0')
    -- NOTA: MOS_ETIQ_DIRECTO se omite a propósito (sin consumidor front: las etiquetas nacen del hook GAS).
  );
$fn$;

-- Grants: callable SIN token al arrancar (anon), igual que me.get_flags(). No hay nada sensible que proteger.
revoke all on function mos.get_flags() from public;
grant execute on function mos.get_flags() to anon, authenticated, service_role;
