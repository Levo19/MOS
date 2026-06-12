-- 20_fase2_flags.sql — Interruptor CENTRAL de la flota ME. Los flags viven en mos.config (key-value) y el
-- frontend los lee al arrancar + cada ~2min vía me.get_flags(). Flip/kill instantáneo desde pg:
--   update mos.config set valor='1' where clave='ME_ESCRITURA_DIRECTA';   -- prender en TODOS
--   update mos.config set valor='0' where clave='ME_ESCRITURA_DIRECTA';   -- KILL-SWITCH instantáneo
-- El frontend hace `serverFlag || localStorage` → localStorage sigue sirviendo como override por-dispositivo
-- (piloto). Los flags NO son sensibles (solo on/off de features) → legibles por anon (sin mint).

-- Semilla idempotente (default OFF — se prende deliberadamente con un update)
insert into mos.config (clave, valor, descripcion) values
  ('ME_ESCRITURA_DIRECTA','0','ME: ventas NV directas a Supabase (toda la flota)'),
  ('ME_LECTURA_DIRECTA','0','ME: lectura de ventas directa de Supabase (toda la flota)'),
  ('ME_IMPRESION_DIRECTA','0','ME: impresion via Edge Function (toda la flota)')
on conflict (clave) do nothing;

-- RPC: devuelve los flags ME_* como objeto jsonb. security definer (lee mos.config aunque anon no tenga grant
-- de tabla). Fail-safe: si no hay filas, devuelve {} → el frontend cae a localStorage (default OFF) = seguro.
create or replace function me.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
  from mos.config where clave like 'ME\_%';
$fn$;

revoke all on function me.get_flags() from public;
grant execute on function me.get_flags() to anon, authenticated;
