-- ════════════════════════════════════════════════════════════════════════════
-- 249 · mos.get_flags += purgaDirecto (MOS_PURGA_DIRECTO) — REPARACIÓN #7
-- ════════════════════════════════════════════════════════════════════════════
-- Expone el flag de cutover de la PURGA directa (SQL 248) por mos.get_flags() para que el front
-- (_mosFlag('mos_purga_directo','purgaDirecto')) lo lea como _serverFlags['purgaDirecto'] y un flip
-- server-side en mos.config.MOS_PURGA_DIRECTO='1' llegue a toda la flota MOS. Mantengo TODAS las
-- claves existentes (copia fiel de la def viva) + agrego SOLO 'purgaDirecto'. Default '0' = GAS (inerte).
-- ════════════════════════════════════════════════════════════════════════════

create or replace function mos.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $function$
  with f as (
    select clave, valor from mos.config where clave like 'MOS\_%' or clave = 'DEVICE_VERIFY_VERSION'
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
    'purgaDirecto',       coalesce((select valor from f where clave='MOS_PURGA_DIRECTO'),       '0'),
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
    'adhesivosEdge',      coalesce((select valor from f where clave='MOS_ADHESIVOS_EDGE'),      '0')
  );
$function$;

notify pgrst, 'reload schema';
