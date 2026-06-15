-- 75_mos_productos_master_rls.sql — [MIGRACIÓN MOS · FASE 1 (PILOTO)] Lectura directa del CATÁLOGO MAESTRO.
-- Espeja la acción GAS `getProductosMaster` (gas/Productos.gs) = _sheetToObjects(PRODUCTOS_MASTER) → {ok,data:[...]}.
--
-- ⚠️ INERTE por diseño: esta RPC existe pero NADIE la llama hasta que el frontend de MOS active el flag
--    por-acción `mos_catalogo_directo` (default OFF). MOS sigue 100% por GAS mientras tanto.
--
-- ── POR QUÉ UNA RPC NUEVA (y no reusar mos.catalogo_wh_rls) ──────────────────────────────────────────────
--   mos.catalogo_wh_rls() (48/74) sirve a WH: devuelve un BUNDLE (productos+equivalencias+proveedores+personal+
--   impresoras+zonas) con filtros y exclusiones pensados para el almacén. getProductosMaster de MOS quiere
--   SOLO el array de productos COMPLETO (sin filtrar por estado — el front filtra client-side / por params GAS).
--   Reusar el bundle = payload de más + exponer datasets que esta lectura no necesita + un shape distinto.
--   Por eso esta RPC es dedicada y minimalista: productos crudo + señal de frescura.
--
-- ── SHAPE QUE DEVUELVE ──────────────────────────────────────────────────────────────────────────────────
--   { ok:true, productos:[ <fila cruda snake_case de mos.productos> ... ],
--     _count:int, _heartbeat:timestamptz|null, _max_updated:timestamptz|null, _now:timestamptz, _fresh:boolean }
--   El FRONT mapea snake→shape-hoja camelCase con el inverso de _CAT_SPECS.productos (MigracionCatalogo.gs)
--   y CONVIERTE bools estado/es_envasable a '1'/'0' (el front compara String(estado), nunca true/false).
--   IDs/codigo_barra ya son `text` en la tabla → el front los pasa por String() defensivo igualmente.
--
-- ── GATE DE FRESCURA (obligatorio — memoria architecture_mos_sync_triggers_mueren) ──────────────────────
--   La sombra mos.productos se llena por el trigger horario GAS `syncCatalogoSupabase` (upsert merge-duplicates).
--   Ese trigger PUEDE morir en silencio (Google desactiva los time-based). Si la sombra está congelada y
--   servimos el catálogo directo, MOS mostraría datos viejos (precios/estados desactualizados) → PELIGRO.
--   updated_at NO sirve de latido: el upsert merge-duplicates NO bumpea updated_at en filas sin cambios
--   (verificado: 2357/2368 filas siguen en el timestamp del backfill del 2026-06-08). Un catálogo que de
--   verdad no cambió en días es FRESCO, no stale → un gate sobre updated_at daría falso-stale.
--   LATIDO REAL = la CORRIDA del sync. `syncCatalogoSupabase` estampa now() en mos.config[CATALOGO_SYNC_HEARTBEAT]
--   en cada corrida OK (ver gas/MigracionCatalogo.gs). Esta RPC lo lee y declara:
--     _fresh = (heartbeat presente) AND (now()-heartbeat < TTL) AND (_count>0)
--   TTL configurable en mos.config[CATALOGO_SYNC_TTL_MIN] (default 180 min = 3 corridas horarias perdidas).
--   Si _fresh=false (heartbeat ausente/viejo o sombra vacía) → el FRONT cae a GAS (no sirve datos viejos).
--   El campo es informativo: la RPC SIEMPRE devuelve los productos (no falla); el front decide con _fresh.

create or replace function mos.productos_master_rls()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prod   jsonb;
  v_count  int;
  v_max    timestamptz;
  v_hb     timestamptz;
  v_ttl    int;
  v_fresh  boolean;
begin
  -- Gate de claim: service_role/GAS (sin claim) o JWT app='MOS'. Cualquier otro → rechazado.
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Productos COMPLETOS (sin filtro de estado — paridad con getProductosMaster, que devuelve todo y el
  -- frontend/params filtran). Orden estable por id_producto para diffs deterministas en el front.
  select coalesce(jsonb_agg(to_jsonb(t) order by t.id_producto), '[]'::jsonb), count(*)
    into v_prod, v_count
    from mos.productos t;

  select max(updated_at) into v_max from mos.productos;

  -- Latido del sync (timestamptz almacenado como texto ISO en mos.config). Tolerante a parseo.
  begin
    select (valor)::timestamptz into v_hb from mos.config where clave = 'CATALOGO_SYNC_HEARTBEAT' limit 1;
  exception when others then v_hb := null;
  end;

  -- TTL configurable (minutos). Default 180 (3 corridas horarias). Acota a [15, 1440].
  begin
    select (valor)::int into v_ttl from mos.config where clave = 'CATALOGO_SYNC_TTL_MIN' limit 1;
  exception when others then v_ttl := null;
  end;
  v_ttl := coalesce(v_ttl, 180);
  if v_ttl < 15 then v_ttl := 15; end if;
  if v_ttl > 1440 then v_ttl := 1440; end if;

  v_fresh := (v_hb is not null)
         and (now() - v_hb < make_interval(mins => v_ttl))
         and (v_count > 0);

  return jsonb_build_object(
    'ok', true,
    'productos', v_prod,
    '_count', v_count,
    '_heartbeat', v_hb,
    '_max_updated', v_max,
    '_now', now(),
    '_ttl_min', v_ttl,
    '_fresh', v_fresh
  );
end;
$fn$;

revoke all on function mos.productos_master_rls() from public;
grant execute on function mos.productos_master_rls() to service_role, authenticated;

-- Semilla del TTL (idempotente). El HEARTBEAT lo escribe el sync GAS; aquí solo dejamos el TTL configurable.
insert into mos.config (clave, valor, descripcion)
values ('CATALOGO_SYNC_TTL_MIN', '180',
        'FASE1 lectura directa MOS: minutos máx desde la última corrida de syncCatalogoSupabase para considerar la sombra FRESCA. >TTL → el front cae a GAS.')
on conflict (clave) do nothing;
