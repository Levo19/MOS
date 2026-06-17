-- 116_mos_proveedores_productos_editados.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA]
-- Replica con PARIDAD dos read-paths GAS de MOS como RPCs PostgreSQL SECURITY DEFINER:
--   · mos.proveedores_que_venden(p)     ← getProveedoresQueVenden     (gas/Proveedores.gs:145)
--   · mos.productos_editados_recientes(p) ← getProductosEditadosRecientes (gas/Productos.gs:397)
--
-- ⚠️ INERTE / NO-APLICAR-AUN: este archivo SOLO define las RPCs con su grant. Nadie las llama todavía
--    (el wiring de js/api.js read-path + el flip de flags es tanda posterior). MOS sigue 100% por GAS.
--    Este SQL NO toca flags, NO toca sync, NO cablea frontend. Idéntico patrón inerte que 94/98/105/.../109.
--
-- ── FUENTES (todas verificadas en 01_schema_compartido.sql / 04_schema_mos.sql) ──────────────────────────────
--   · mos.proveedores_productos (04:262) — id_pp/id_proveedor/sku_base/codigo_barra/descripcion/
--       precio_referencia/minimo_compra/dias_entrega/notas/unidades_por_bulto/activa.
--   · mos.proveedores         (04:21)  — id_proveedor/nombre/ruc (enriquecer matches).
--   · mos.productos           (01:43)  — id_producto/sku_base/descripcion/precio_venta/codigo_producto_base/
--       factor_conversion/es_envasable + historial_cambios jsonb (01:73). ✅ La columna SÍ EXISTE → PORTABLE.
--
-- ── GAP HONESTO ──────────────────────────────────────────────────────────────────────────────────────────────
--   NINGUNO de ausencia de tabla/columna. historial_cambios jsonb EXISTE en mos.productos (verificado en el
--   schema). productos_editados_recientes ES PORTABLE. La única divergencia es de FRESCURA DE SOMBRA: la columna
--   historial_cambios se llena vía el sync GAS→Supabase (dual-write/trigger de catálogo). Si ese sync se atrasa,
--   el "log" de ediciones queda stale respecto a la hoja viva que lee el GAS. Señalado por _frescura_sombra()._fresh.
--   ⇒ Antes del cutover de ESTE getter, el sync de mos.productos (incl. historial_cambios) DEBE estar vivo.

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.proveedores_que_venden(p jsonb) — getProveedoresQueVenden
--   p = { skuBase (opc), codigoBarra (opc) }  → requiere AL MENOS uno.
--   Devuelve proveedores que venden ESE producto específico, enriquecidos con nombre/ruc, ordenados por
--   precioReferencia asc. Shape camelCase paritario.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.proveedores_que_venden(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_sku text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cb  text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_data jsonb;
begin
  -- Gate de app (service_role/GAS o claim app='MOS'); cualquier otro → rechazo.
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Paridad GAS: requiere skuBase O codigoBarra.
  if v_sku is null and v_cb is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere skuBase o codigoBarra');
  end if;

  with matches as (
    select
      pp.id_pp,
      pp.id_proveedor,
      btrim(coalesce(pp.sku_base,''))      as sku_base,
      btrim(coalesce(pp.codigo_barra,''))  as codigo_barra,
      pp.descripcion,
      coalesce(pp.precio_referencia, 0)::numeric as precio_referencia,
      coalesce(pp.minimo_compra, 0)::numeric     as minimo_compra,
      -- GAS: parseInt(diasEntrega) || 0  → entero
      coalesce(floor(coalesce(pp.dias_entrega, 0))::int, 0) as dias_entrega
    from mos.proveedores_productos pp
    where
      (v_sku is not null and btrim(coalesce(pp.sku_base,''))     = v_sku)
      or
      (v_cb  is not null and btrim(coalesce(pp.codigo_barra,'')) = v_cb)
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idPP',             m.id_pp,
             'idProveedor',      m.id_proveedor,
             'skuBase',          m.sku_base,
             'codigoBarra',      m.codigo_barra,
             'descripcion',      m.descripcion,
             'precioReferencia', m.precio_referencia,
             'minimoCompra',     m.minimo_compra,
             'diasEntrega',      m.dias_entrega,
             -- Enriquecido con el master de proveedores (GAS: nombreProveedor = p.nombre || idProveedor; ruc || '')
             'nombreProveedor',  coalesce(nullif(btrim(coalesce(pr.nombre,'')),''), m.id_proveedor),
             'ruc',              coalesce(pr.ruc, '')
           )
           -- GAS: matches.sort por precioReferencia asc (solo si había matches). Desempate estable por id_pp.
           order by m.precio_referencia asc, m.id_pp asc
         ), '[]'::jsonb)
    into v_data
  from matches m
  left join mos.proveedores pr on pr.id_proveedor = m.id_proveedor;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.proveedores_que_venden(jsonb) from public;
grant execute on function mos.proveedores_que_venden(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.productos_editados_recientes(p jsonb) — getProductosEditadosRecientes
--   p = { limit (opc, default 50, min 1, max 500) }
--   Lee mos.productos.historial_cambios (jsonb array), extrae última entrada (ts), ordena por ts desc,
--   recorta a `limit`. Cada item trae el historial COMPLETO para que el front lo expanda.
--   Compat legacy: si NO hay historial pero existe ultimaEdicion → sintetizar 1 entrada. ⚠️ Ver NOTA: el
--   schema de la sombra NO tiene columnas ultima_edicion / ultima_edicion_por, así que esa rama legacy es
--   inalcanzable aquí (los productos sin historial simplemente se filtran, igual que el GAS los descartaría
--   por _ultimaTs null). Documentado como divergencia BENIGNA abajo.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.productos_editados_recientes(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_limit int;
  v_data  jsonb;
begin
  -- Gate de app.
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- limit: parseInt(limit) || 50; if (!limit || <1) 50; if (>500) 500. (paridad)
  v_limit := coalesce(nullif(btrim(coalesce(p->>'limit','')), '')::int, 50);
  if v_limit is null or v_limit < 1 then v_limit := 50; end if;
  if v_limit > 500 then v_limit := 500; end if;

  with base as (
    select
      pr.id_producto,
      pr.sku_base,
      pr.descripcion,
      pr.precio_venta,
      pr.codigo_producto_base,
      pr.factor_conversion,
      pr.es_envasable,
      -- Normalizar historial_cambios → array jsonb (si no es array, []). Paridad con JSON.parse + Array.isArray.
      case
        when jsonb_typeof(pr.historial_cambios) = 'array' then pr.historial_cambios
        else '[]'::jsonb
      end as hist
    from mos.productos pr
  ),
  conhist as (
    select
      b.*,
      jsonb_array_length(b.hist) as n,
      -- última entrada del historial = hist[len-1]  (GAS: hist[hist.length-1])
      case when jsonb_array_length(b.hist) > 0
           then b.hist -> (jsonb_array_length(b.hist) - 1)
           else null end as ultima
    from base b
  ),
  -- GAS: .filter(r => r._ultimaTs)  → descartar los que no tienen ts en la última entrada.
  filtrado as (
    select
      c.*,
      c.ultima ->> 'ts' as ultima_ts
    from conhist c
    where c.n > 0
      and nullif(btrim(coalesce(c.ultima ->> 'ts','')), '') is not null
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idProducto',         f.id_producto,
             'skuBase',            f.sku_base,
             'descripcion',        f.descripcion,
             'precioVenta',        f.precio_venta,
             'historial',          f.hist,                 -- array completo de entradas
             'ultimaEntrada',      f.ultima,
             'codigoProductoBase', coalesce(f.codigo_producto_base, ''),
             'factorConversion',   f.factor_conversion,
             'esEnvasable',        f.es_envasable
           )
           -- GAS: sort por new Date(ts).getTime() desc (los inválidos → 0). Desempate estable por id_producto.
           order by
             coalesce(
               (case when f.ultima_ts ~ '^\d{4}-\d{2}-\d{2}'
                     then (f.ultima_ts)::timestamptz
                     else null end),
               'epoch'::timestamptz
             ) desc,
             f.id_producto asc
         ), '[]'::jsonb)
    into v_data
  from (
    select * from filtrado
    order by
      coalesce(
        (case when (filtrado.ultima_ts) ~ '^\d{4}-\d{2}-\d{2}'
              then (filtrado.ultima_ts)::timestamptz
              else null end),
        'epoch'::timestamptz
      ) desc,
      filtrado.id_producto asc
    limit v_limit
  ) f;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.productos_editados_recientes(jsonb) from public;
grant execute on function mos.productos_editados_recientes(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / DIVERGENCIAS / GAPS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- A) FUENTES — TODAS migradas. No hay GAP de ausencia de tabla NI de columna:
--      · mos.proveedores_productos ✅   · mos.proveedores ✅
--      · mos.productos.historial_cambios jsonb ✅  ← clave: la columna SÍ existe (01_schema_compartido.sql:73).
--    ⇒ productos_editados_recientes ES PORTABLE (NO es no-portable).
--
-- B) FRESCURA DE SOMBRA — no es GAP de datos, es GAP de actualidad. Tanto proveedores_productos como
--    productos.historial_cambios se alimentan por el sync GAS→Supabase. Si el sync se atrasa, los resultados
--    quedan stale respecto a las hojas vivas que lee el GAS. _frescura_sombra() expone _fresh para que el
--    front caiga a GAS si la sombra está congelada. Resultado: { ok, data, _heartbeat, _now, _ttl_min, _fresh }.
--
-- C) proveedores_que_venden — matching EXACTO por sku_base / codigo_barra con TRIM en ambos lados
--    (GAS hace String(cell).trim() === String(param)). Enriquecido: nombreProveedor = nombre || idProveedor,
--    ruc || ''. Orden: precioReferencia asc (igual que matches.sort). El GAS solo ordena/enriquece si
--    matches.length>0; con 0 matches devuelve [] — aquí jsonb_agg sobre 0 filas → '[]' (mismo resultado).
--    diasEntrega = parseInt → entero (floor sobre numeric). minimoCompra/precioReferencia = parseFloat || 0.
--
-- D) productos_editados_recientes · COMPAT LEGACY — el GAS, si un producto NO tiene historial PERO sí
--    r.ultimaEdicion, sintetiza una entrada {ts, usuario, source:'legacy', accion:'editar', cambios:[]}.
--    ⚠️ DIVERGENCIA BENIGNA: la sombra mos.productos NO tiene columnas ultima_edicion / ultima_edicion_por
--    (no están en el schema). Por tanto esa rama es INALCANZABLE en Supabase: un producto sin historial_cambios
--    se filtra (su _ultimaTs sería null) — exactamente lo que el GAS haría tras el filter si tampoco hubiera
--    ultimaEdicion. El único caso donde el GAS mostraría algo que la RPC NO muestra es un producto que en la
--    HOJA tenga ultimaEdicion legacy sin historial. En la práctica el sync de catálogo materializa el historial,
--    así que el impacto esperado es nulo. RIESGO BAJO, documentado. Si se detecta pérdida, añadir columnas
--    ultima_edicion/ultima_edicion_por a la sombra + sync y replicar la síntesis legacy aquí.
--
-- E) ORDEN POR TIMESTAMP — el GAS hace new Date(ts).getTime() (NaN→0) y ordena desc. Aquí parseamos ts a
--    timestamptz SOLO si matchea el prefijo ISO (^YYYY-MM-DD…); si no, cae a 'epoch' (= 0, igual que NaN→0).
--    Los ts del historial los escribe el GAS como ISOString (Date.toISOString()) → siempre ISO, parseables.
--    Desempate estable por id_producto asc (el GAS depende del orden de las filas de la hoja; aquí determinista).
--    El sort se aplica en la subquery (con LIMIT) y se REPITE en el order by del jsonb_agg para garantizar que
--    el array final respete el mismo orden tras el recorte (jsonb_agg no hereda el order de la subquery).
--
-- F) TIPOS NUMÉRICOS — precioVenta/precioReferencia/minimoCompra/factorConversion se emiten como número JSON
--    (paridad con _sheetToObjects que devuelve Number). diasEntrega = entero. esEnvasable = boolean (paridad
--    con el campo boolean del schema; el GAS reexpone r.esEnvasable tal cual). NO se aplica el patrón '1'/'0'
--    aquí: ninguno de los dos getters GAS reexpone booleanos como string '1'/'0' (esEnvasable se pasa crudo).
--
-- G) GATE + ENVOLTORIO — mos._claim_ok() (74) y mos._frescura_sombra() (94) ya existen; este archivo NO los
--    redefine, los consume. TZ Lima: ninguno de los dos getters filtra/agrupa por día calendario, así que no se
--    requiere conversión a America/Lima (el historial usa ts absolutos ISO; el ordenamiento es por instante).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
