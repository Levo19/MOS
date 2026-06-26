-- ════════════════════════════════════════════════════════════════════════════
-- 236 · get_flags += sunatEdge (flip global de #6 SUNAT/RENIEC → Edge consultar-documento)
-- ════════════════════════════════════════════════════════════════════════════
-- Agrega la key `sunatEdge` (lee MOS_SUNAT_EDGE de mos.config) a get_flags, preservando
-- TODAS las keys existentes (verbatim de la def viva). El front (api.js _mosSunatEdge →
-- _mosFlag('mos_sunat_edge','sunatEdge')) la consume → con '1' el live-lookup de
-- meConsultarCliente va al Edge `consultar-documento` (con GAS como red de seguridad).
-- Secret APISPERU_TOKEN ya seteado + Edge verificado E2E (RUC/DNI ok). Se SIEMBRA en '1' (ON).
-- KILL-SWITCH: update mos.config set valor='0' where clave='MOS_SUNAT_EDGE'; → vuelve a GAS al refresh.
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor, descripcion) values
  ('MOS_SUNAT_EDGE', '1', '#6: meConsultarCliente usa el Edge consultar-documento (SUNAT/RENIEC) en vez de GAS. 0=GAS, 1=Edge (con GAS de red de seguridad).')
on conflict (clave) do update set valor = excluded.valor;

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
    -- ── [#6 SUNAT/RENIEC] meConsultarCliente → Edge consultar-documento ──
    'sunatEdge',          coalesce((select valor from f where clave='MOS_SUNAT_EDGE'),          '0')
  );
$function$;

revoke all on function mos.get_flags() from public;
grant execute on function mos.get_flags() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
