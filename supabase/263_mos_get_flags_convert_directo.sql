-- ════════════════════════════════════════════════════════════════════════════
-- 263 · get_flags += meConvertDirecto (Etapa 4 NV→CPE, gate del front)
-- ════════════════════════════════════════════════════════════════════════════
-- Agrega `meConvertDirecto` (lee MOS_CONVERT_NV_DIRECTO de mos.config) a get_flags,
-- preservando TODAS las keys de 261. El front (api.js _mosConvertDirecto →
-- _mosFlag('me_convert_directo','meConvertDirecto')) la consume → con '1' la conversión
-- NV→CPE va por me.convertir_nv_cpe (SQL 262). Se SIEMBRA en '0' (OFF): la Etapa 4 queda
-- INERTE hasta el go-live fiscal. Doble candado: aunque MOS_CONVERT_NV_DIRECTO='1', la RPC
-- exige fac._on() (FAC_CPE_DIRECTO='1') o devuelve FAC_DESACTIVADO → el front cae a GAS.
-- Activación real = cutover fac.* (token NubeFact + correlativo alineado + FAC_CPE_DIRECTO=1).
-- KILL-SWITCH: update mos.config set valor='0' where clave='MOS_CONVERT_NV_DIRECTO';
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor, descripcion) values
  ('MOS_CONVERT_NV_DIRECTO', '0', 'Etapa 4: conversion NV->CPE por me.convertir_nv_cpe (fac.emitir_cpe). 0=GAS, 1=Supabase directo. Requiere ademas FAC_CPE_DIRECTO=1.')
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
    'meEditDirecto',      coalesce((select valor from f where clave='MOS_EDIT_DIRECTO'),         '0'),
    -- ── [Etapa 4] NV→CPE → me.convertir_nv_cpe ──
    'meConvertDirecto',   coalesce((select valor from f where clave='MOS_CONVERT_NV_DIRECTO'),   '0')
  );
$function$;

revoke all on function mos.get_flags() from public;
grant execute on function mos.get_flags() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
