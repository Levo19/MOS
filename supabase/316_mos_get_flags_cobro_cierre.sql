-- ════════════════════════════════════════════════════════════════════════════
-- 316 · get_flags += meCobroDirecto + meCierreForzadoDirecto (control fleet-wide)
-- ════════════════════════════════════════════════════════════════════════════
-- Hasta ahora el gate cliente del cobro (_meCobroDirecto) dependía SOLO de localStorage
-- por-dispositivo (canary): el flag server ME_COBRO_DIRECTO='1' controlaba las RPCs pero
-- NO llegaba al front vía get_flags → el cutover no era determinístico en la flota.
-- Este get_flags expone AMBOS (leyendo el config server, no MOS_*), preservando TODAS las
-- keys de 263. Con ME_COBRO_DIRECTO='1' (ya activado por el dueño) el cobro-directo pasa a
-- estar controlado por server para toda la flota; ME_CIERRE_FORZADO_DIRECTO habilita el
-- cierre forzado directo (me.cerrar_caja_forzado, SQL 315).
-- KILL-SWITCH: update mos.config set valor='0' where clave in
--   ('ME_COBRO_DIRECTO','ME_CIERRE_FORZADO_DIRECTO');
-- ════════════════════════════════════════════════════════════════════════════

create or replace function mos.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $function$
  with f as (
    select clave, valor from mos.config
     where clave like 'MOS\_%' or clave = 'DEVICE_VERIFY_VERSION'
        or clave in ('ME_COBRO_DIRECTO','ME_CIERRE_FORZADO_DIRECTO')
  ),
  rev as (
    select id_dispositivo from mos.dispositivos
     where estado in ('INACTIVO','SUSPENDIDO')
       and ultima_conexion > now() - interval '30 days'
     order by ultima_conexion desc
     limit 500
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
    'pagosJornalDirecto', coalesce((select valor from f where clave='MOS_PAGOS_JORNAL_DIRECTO'),'0'),
    'lecturaNavegador',   coalesce((select valor from f where clave='MOS_LECTURA_NAVEGADOR'),   '0'),
    'proveedoresLectura', coalesce((select valor from f where clave='MOS_PROVEEDORES_LECTURA'), '0'),
    'pedidosLectura',     coalesce((select valor from f where clave='MOS_PEDIDOS_LECTURA'),     '0'),
    'pagosLectura',       coalesce((select valor from f where clave='MOS_PAGOS_LECTURA'),       '0'),
    'provprodLectura',    coalesce((select valor from f where clave='MOS_PROVPROD_LECTURA'),    '0'),
    'jornadasLectura',    coalesce((select valor from f where clave='MOS_JORNADAS_LECTURA'),    '0'),
    'evalLectura',        coalesce((select valor from f where clave='MOS_EVAL_LECTURA'),         '0'),
    'horarioLectura',     coalesce((select valor from f where clave='MOS_HORARIO_LECTURA'),     '0'),
    'device_verify_version',  coalesce((select valor from f where clave='DEVICE_VERIFY_VERSION'), '1'),
    'dispositivos_revocados', coalesce((select jsonb_agg(id_dispositivo) from rev), '[]'::jsonb),
    'sunatEdge',          coalesce((select valor from f where clave='MOS_SUNAT_EDGE'),          '0'),
    'meEditDirecto',      coalesce((select valor from f where clave='MOS_EDIT_DIRECTO'),         '0'),
    'meConvertDirecto',   coalesce((select valor from f where clave='MOS_CONVERT_NV_DIRECTO'),   '0'),
    -- ── [316] cobro + cierre forzado, control fleet-wide desde el config server ──
    'meCobroDirecto',         coalesce((select valor from f where clave='ME_COBRO_DIRECTO'),           '0'),
    'meCierreForzadoDirecto', coalesce((select valor from f where clave='ME_CIERRE_FORZADO_DIRECTO'), '0')
  );
$function$;

revoke all on function mos.get_flags() from public;
grant execute on function mos.get_flags() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
