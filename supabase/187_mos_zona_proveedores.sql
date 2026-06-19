-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 187_mos_zona_proveedores.sql — RIZ/ALMACEN · proveedores REALES por canónico (sku_base) — LECTURA, lazy-load.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- CONTEXTO (mejora UX #4): en el ámbito ALMACEN, la card del panel RIZ mostraba "Almacén: X" (stock), que es
-- redundante porque YA estás viendo el inventario del almacén. Se reemplaza por la LISTA DE PROVEEDORES REALES
-- del canónico (agrupando todos los codigo_barra del grupo). El front la pide perezosamente por card (no encarece
-- el panel — esta RPC es independiente y solo se invoca al renderizar/expandir la card del almacén).
--
-- QUÉ HACE: recibe {sku} (uno) o {skus:[...]} (varios) y devuelve, por canónico, los proveedores DISTINTOS reales
--   (mos.proveedores_productos.activa<>false, join mos.proveedores por id_proveedor), OCULTANDO los que se llaman
--   "PROVEEDOR DESCONOCIDO" (case-insensitive, con/sin tilde) o sin nombre. Suma, si existe, precio_referencia
--   (mínimo del grupo proveedor↔producto) y dias_entrega (mínimo) como datos informativos. Empareja por sku_base
--   directo Y por codigo_barra del grupo del canónico (mos.productos.sku_base = sku) — porque proveedores_productos
--   a veces guarda el código y no el sku_base. NO inventa columnas: usa id_proveedor, sku_base, codigo_barra,
--   precio_referencia, dias_entrega, activa (todas reales en supabase/04_schema_mos.sql).
--
-- SHAPE: { ok, data: { proveedores: { "<sku>": [ {nombre, idProveedor, precioRef|null, diasEntrega|null} ] } } }
--   · siempre incluye una clave por cada sku pedido (array vacío si no hay proveedor real → el front muestra el
--     hint "sin proveedor registrado"). Orden: por nombre asc.
--
-- PATRÓN del proyecto: security definer · set search_path='' · gate mos._claim_ok() · revoke public + grants
--   service_role/authenticated. SOLO LECTURA (no toca stock/dinero/sync/flags). Money-safe.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;

create or replace function mos.zona_proveedores(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_skus  text[];
  v_data  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- Conjunto de skus pedidos: {sku} (uno) ∪ {skus:[...]} (varios). Normaliza (trim, no vacíos, distinct).
  select coalesce(array_agg(distinct s), array[]::text[]) into v_skus
  from (
    select nullif(btrim(p->>'sku'),'') as s
    union all
    select nullif(btrim(x.value::text),'') from jsonb_array_elements_text(coalesce(p->'skus','[]'::jsonb)) as x(value)
  ) t
  where t.s is not null;

  if coalesce(array_length(v_skus,1),0) = 0 then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('proveedores', '{}'::jsonb)) || mos._frescura_sombra();
  end if;

  with
  -- Universo de códigos del canónico: el propio sku_base + todos los codigo_barra de su grupo en catálogo.
  cod_de_sku as (
    select pr.sku_base as sku, upper(btrim(pr.codigo_barra)) as cb
    from mos.productos pr
    where pr.sku_base = any(v_skus) and nullif(btrim(pr.codigo_barra),'') is not null
  ),
  -- Relación proveedor↔producto que empareja por sku_base directo O por algún código del grupo.
  pp as (
    select distinct pp.id_proveedor,
           coalesce(nullif(pp.sku_base,''), cs.sku) as sku,    -- sku objetivo (directo o derivado del código)
           pp.precio_referencia, pp.dias_entrega
    from mos.proveedores_productos pp
    left join cod_de_sku cs on cs.cb = upper(btrim(pp.codigo_barra))
    where coalesce(pp.activa, true)
      and nullif(btrim(pp.id_proveedor),'') is not null
      and (pp.sku_base = any(v_skus) or cs.sku is not null)
  ),
  -- Proveedor REAL: nombre presente y distinto de "PROVEEDOR DESCONOCIDO" (con/sin tilde, case-insensitive).
  prov_real as (
    select pp.sku, pp.id_proveedor,
           btrim(pr.nombre) as nombre,
           min(pp.precio_referencia) as precio_ref,
           min(pp.dias_entrega) as dias_entrega
    from pp
    join mos.proveedores pr on pr.id_proveedor = pp.id_proveedor
    where nullif(btrim(pr.nombre),'') is not null
      and translate(upper(btrim(pr.nombre)), 'ÁÉÍÓÚ', 'AEIOU') <> 'PROVEEDOR DESCONOCIDO'
    group by pp.sku, pp.id_proveedor, btrim(pr.nombre)
  ),
  por_sku as (
    select pr.sku,
           jsonb_agg(jsonb_build_object(
             'nombre',      pr.nombre,
             'idProveedor', pr.id_proveedor,
             'precioRef',   pr.precio_ref,
             'diasEntrega', pr.dias_entrega
           ) order by pr.nombre) as lista
    from prov_real pr
    group by pr.sku
  )
  -- Siempre una clave por cada sku pedido (vacío si no hay proveedor real → el front muestra el hint).
  select jsonb_build_object('proveedores', coalesce(
    jsonb_object_agg(s.sku, coalesce(ps.lista, '[]'::jsonb)),
    '{}'::jsonb)) into v_data
  from unnest(v_skus) as s(sku)
  left join por_sku ps on ps.sku = s.sku;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.zona_proveedores(jsonb) from public;
grant execute on function mos.zona_proveedores(jsonb) to service_role, authenticated;
