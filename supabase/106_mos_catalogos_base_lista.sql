-- 106_mos_catalogos_base_lista.sql — [Optimización MOS · lecturas directas catálogos base]
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- getEquivalencias (Productos.gs:822) y getCategorias (Categorias.gs:95) leen sus hojas por GAS. Esta
-- tanda da las RPCs de lectura directa con paridad de shape (mapeo canónico _CAT_SPECS de MigracionCatalogo.gs).
--
-- ⚠️ BOOLS COMO '1'/'0' (no boolean) — CRÍTICO 40x: el front consume estos bools como STRING:
--   · getEquivalencias: `String(r.activo) === String(params.activo)` (filtro)
--   · getCategorias:    `String(a.estado) === '1'` (orden activos-primero)
--   Devolver boolean rompería filtro/orden. Por eso emitimos '1'/'0' (igual criterio que catalogo_wh_rls bool10).
-- Gate _claim_ok + frescura (caen a GAS si la sombra está stale). Shape camelCase paritario con _sheetToObjects.

create or replace function mos.equivalencias_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_act  text := nullif(btrim(coalesce(p->>'activo','')), '');   -- '1'/'0' opcional (paridad con getEquivalencias)
  v_arr  jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
           'idEquiv',     coalesce(e.id_equiv,''),
           'skuBase',     coalesce(e.sku_base,''),
           'codigoBarra', coalesce(e.codigo_barra,''),
           'descripcion', coalesce(e.descripcion,''),
           'activo',      case when coalesce(e.activo,false) then '1' else '0' end
         ) order by e.sku_base, e.codigo_barra), '[]'::jsonb) into v_arr
  from mos.equivalencias e
  where (v_sku is null or e.sku_base = v_sku)
    and (v_cod is null or e.codigo_barra = v_cod)
    and (v_act is null or (case when coalesce(e.activo,false) then '1' else '0' end) = v_act);
  return jsonb_build_object('ok', true, 'data', v_arr) || v_fr;
end;
$fn$;
revoke all on function mos.equivalencias_lista(jsonb) from public;
grant execute on function mos.equivalencias_lista(jsonb) to anon, authenticated, service_role;

create or replace function mos.categorias_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  -- Orden: activos primero (estado='1'), luego alfabético por nombre — = sort de getCategorias.
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCategoria',  coalesce(c.id_categoria,''),
           'nombre',       coalesce(c.nombre,''),
           'modoVenta',    coalesce(c.modo_venta,''),
           'margenPct',    coalesce(c.margen_pct,0),
           'precioTope',   coalesce(c.precio_tope,0),
           'descripcion',  coalesce(c.descripcion,''),
           'estado',       case when coalesce(c.estado,false) then '1' else '0' end,
           'fechaCreacion', case when c.fecha_creacion is null then '' else to_char(c.fecha_creacion at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') end
         ) order by (case when coalesce(c.estado,false) then 0 else 1 end), c.nombre), '[]'::jsonb) into v_arr
  from mos.categorias c;
  return jsonb_build_object('ok', true, 'data', v_arr) || v_fr;
end;
$fn$;
revoke all on function mos.categorias_lista(jsonb) from public;
grant execute on function mos.categorias_lista(jsonb) to anon, authenticated, service_role;
