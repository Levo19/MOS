-- 99_mos_get_flags_lectura.sql — DUAL-WRITE: expone los flags de LECTURA por módulo en mos.get_flags().
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- CONTEXTO: en el modelo DUAL-WRITE la ESCRITURA de un módulo va SIEMPRE por GAS (que hace _dualWriteMOS →
-- espeja la sombra Supabase); SOLO la LECTURA se activa directo a PostgREST. Por eso el frontend (js/api.js)
-- dejó de gatear la lectura con los flags MOS_*_DIRECTO (que ahora solo gobernarían una escritura-directa-pura
-- que el dual-write NO usa) y la gatea con nuevos flags de LECTURA: por módulo `MOS_<MODULO>_LECTURA` (cfgKey
-- camelCase `<modulo>Lectura`) o el MAESTRO `MOS_LECTURA_NAVEGADOR` (cfgKey `lecturaNavegador`) que enciende la
-- lectura directa de TODOS los módulos a la vez.
--
-- ESTA RPC: re-define mos.get_flags() para que ADEMÁS de los MOS_*_DIRECTO existentes (NO se rompen: se siguen
-- exponiendo igual, por compat/diagnóstico) exponga el maestro + los flags de lectura por módulo. Idéntico
-- patrón/grants/seguridad que el 95 (SECURITY DEFINER, STABLE, search_path='', callable por anon sin token).
--
-- ACTIVAR la lectura directa de un módulo (SIN tocar su escritura, que sigue por GAS dual-write):
--   update mos.config set valor='1' where clave='MOS_PROVEEDORES_LECTURA';   -- solo proveedores
--   -- o el maestro (TODOS los módulos a la vez):
--   update mos.config set valor='1' where clave='MOS_LECTURA_NAVEGADOR';
--   -- KILL-SWITCH: poner la clave de vuelta en '0' → el módulo vuelve a leer por GAS al siguiente refresh (~2min).
-- El catálogo/finanzas/historial ya tienen sus propios flags (MOS_CATALOGO_DIRECTO/MOS_FINANZAS_DIRECTO/
-- MOS_HISTORIAL_DIRECTO) que el maestro también enciende vía el OR del frontend → no se duplican acá.
--
-- ⚠️ INERTE: las nuevas claves se siembran en '0' (default OFF). Con todas en '0' la RPC las devuelve '0' →
--    cada _mos<Modulo>Lectura(...) del frontend cae a localStorage/MOS_CONFIG (también OFF) → la lectura va por
--    GAS exactamente como hoy. NO se toca ningún MOS_*_DIRECTO (siguen '0').

-- 1) Sembrar las claves de lectura en '0' (idempotente: on conflict no pisa un valor ya puesto).
insert into mos.config (clave, valor) values
  ('MOS_LECTURA_NAVEGADOR',   '0'),
  ('MOS_PROVEEDORES_LECTURA', '0'),
  ('MOS_PEDIDOS_LECTURA',     '0'),
  ('MOS_PAGOS_LECTURA',       '0'),
  ('MOS_PROVPROD_LECTURA',    '0'),
  ('MOS_JORNADAS_LECTURA',    '0'),
  ('MOS_EVAL_LECTURA',        '0'),
  ('MOS_HORARIO_LECTURA',     '0')
on conflict (clave) do nothing;

-- 2) Re-definir get_flags(): MOS_*_DIRECTO (sin cambios) + maestro de lectura + MOS_*_LECTURA por módulo.
--    Lee TODAS las claves MOS_* (no solo *_DIRECTO) para poder mapear también las *_LECTURA y el maestro.
--    Cada valor cae a '0' por coalesce si la clave no existe (fail-safe = default OFF = seguro).
create or replace function mos.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with f as (
    select clave, valor from mos.config where clave like 'MOS\_%'
  )
  select jsonb_build_object(
    -- ── flags *_DIRECTO existentes (NO romper: mismos cfgKey que ya consume el frontend) ──
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
    -- NOTA: MOS_ETIQ_DIRECTO se omite a propósito (sin consumidor front: las etiquetas nacen del hook GAS).
    -- ── [DUAL-WRITE] maestro + flags de LECTURA por módulo (gobiernan los read-paths del frontend) ──
    'lecturaNavegador',   coalesce((select valor from f where clave='MOS_LECTURA_NAVEGADOR'),   '0'),
    'proveedoresLectura', coalesce((select valor from f where clave='MOS_PROVEEDORES_LECTURA'), '0'),
    'pedidosLectura',     coalesce((select valor from f where clave='MOS_PEDIDOS_LECTURA'),     '0'),
    'pagosLectura',       coalesce((select valor from f where clave='MOS_PAGOS_LECTURA'),       '0'),
    'provprodLectura',    coalesce((select valor from f where clave='MOS_PROVPROD_LECTURA'),    '0'),
    'jornadasLectura',    coalesce((select valor from f where clave='MOS_JORNADAS_LECTURA'),    '0'),
    'evalLectura',        coalesce((select valor from f where clave='MOS_EVAL_LECTURA'),         '0'),
    'horarioLectura',     coalesce((select valor from f where clave='MOS_HORARIO_LECTURA'),     '0')
  );
$fn$;

-- 3) Grants: callable SIN token al arrancar (anon), igual que el 95. No hay nada sensible que proteger.
revoke all on function mos.get_flags() from public;
grant execute on function mos.get_flags() to anon, authenticated, service_role;
