-- ════════════════════════════════════════════════════════════════════════════
-- 261 · get_flags += meEditDirecto (FLIP del cutover ventas-ME Etapa 3)
-- ════════════════════════════════════════════════════════════════════════════
-- Agrega la key `meEditDirecto` (lee MOS_EDIT_DIRECTO de mos.config) a get_flags,
-- preservando TODAS las keys existentes (verbatim de 236). El front (api.js
-- _mosEditDirecto → _mosFlag('me_edit_directo','meEditDirecto')) la consume → con '1'
-- las 3 ediciones de ticket (forma pago / cliente / anular) van por RPCs me.* (SQL 260)
-- en vez del GAS bridge.
--
-- PRECONDICIÓN CUMPLIDA: `ventas` ya está en ME_SYNC_OFF_TABLAS (activarMEVentasDirecto
-- corrido en el editor ME → "stock_zonas,guias_cabecera,guias_detalle,ventas ✓"), así
-- que una edición directa NO se revierte. Dispositivos con api.js viejo (<2.43.358) NO
-- tienen las branches → ignoran el flag → siguen por GAS bridge (que patchea la sombra
-- directo igual) = coexistencia coherente, sin pérdida de datos.
--
-- Se SIEMBRA en '1' (ON). KILL-SWITCH inmediato (vuelve a GAS al próximo poll del flag):
--   update mos.config set valor='0' where clave='MOS_EDIT_DIRECTO';
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor, descripcion) values
  ('MOS_EDIT_DIRECTO', '1', 'Cutover ventas-ME Etapa 3: edicion de ticket (forma pago/cliente/anular) por RPCs me.* (SQL 260). 0=GAS bridge, 1=Supabase directo. Requiere ventas en ME_SYNC_OFF_TABLAS.')
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
    'sunatEdge',          coalesce((select valor from f where clave='MOS_SUNAT_EDGE'),          '0'),
    -- ── [Cutover ventas-ME Etapa 3] edicion de ticket → RPCs me.* ──
    'meEditDirecto',      coalesce((select valor from f where clave='MOS_EDIT_DIRECTO'),         '0')
  );
$function$;

revoke all on function mos.get_flags() from public;
grant execute on function mos.get_flags() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
