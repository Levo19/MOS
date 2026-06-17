-- 126_riz_fundacion_ventas_base.sql — [RIZ · CAPA 1 · FUNDACIÓN A — VENTAS NORMALIZADAS POR FACTOR]
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md (Parte 1.2, 2.2, 4.1).
--
-- ⚠️ INERTE: crear esta función NO cambia el comportamiento de producción. NADIE la llama todavía (las RPCs de
--    RIZ — 128/129 — la consumen, pero esas tampoco están cableadas al frontend ni a ningún flag). MOS opera
--    100% por GAS. Este archivo NO toca api.js / sw.js / version.json / GAS / flags / sync. Es pura definición SQL.
--
-- ── QUÉ ES (la fuente ÚNICA de verdad de "rotación de zona") ────────────────────────────────────────────────
--   me._riz_ventas_base(p_desde date, p_hasta date) → TABLA (sku_base, zona_id, dia, unidades_base).
--   Da las UNIDADES BASE vendidas por (skuBase × zona × día de negocio TZ Lima) en [p_desde, p_hasta].
--
--   ⭐ NORMALIZACIÓN POR FACTOR (DECISIÓN CERRADA #1 del diseño, VERIFICADA en datos):
--       ME registra el CONTEO DE LA PRESENTACIÓN (ej. 4 tripacks = me.ventas_detalle.cantidad = 4).
--       unidades_base = me.ventas_detalle.cantidad × mos.productos.factor_conversion
--       (4 tripacks × factor 3 = 12 unidades base). factor null/0 → se trata como 1.
--       Se agregan TODAS las presentaciones (cada cod_barra propio con su factor) Y TODOS los equivalentes
--       (mos.equivalencias, factor=1) al skuBase del producto base.
--
--   ⭐ REEMPLAZA el conteo crudo: las RPCs de almacén actuales (mos.rotacion_*, mos.stock_unificado,
--      mos.productos_sin_venta, etc.) SUMAN `cantidad` SIN aplicar factor (GAP CRÍTICO #1 del diseño, §2.2).
--      Para RIZ eso es incorrecto: toda la lógica de pico/esperado se basa en unidades base. Esta función es la
--      ÚNICA fuente correcta para RIZ. NO se reescriben las RPCs viejas aquí (fuera de alcance Capa 1/2); RIZ
--      simplemente NO las usa para "rotación de zona".
--
-- ── RESOLUCIÓN DE ZONA ──────────────────────────────────────────────────────────────────────────────────────
--   Mismo patrón `zona_resolver` que las RPCs existentes (117_mos_vistas_almacen.sql ~L140-166): me.ventas.estacion
--   (texto, ej. "Estacion 01"/"Estación 02") se mapea al id_zona canónico vía mos.zonas + mos.estaciones, con
--   `distinct on (raw)` para NO fan-out cuando un nombre de estación se repite entre zonas. Fallback: si la
--   estacion no resuelve, se usa UPPER(TRIM(estacion)) como zona cruda (paridad con las RPCs en prod).
--   ⚠️ Se prioriza me.ventas.zona_id si viene poblado (RLS-ready); si está vacío se cae a `estacion` (lo que hoy
--      tiene data: 02_schema_me.sql:37 dice zona_id RLS-ready, y en prod el grueso de ventas trae solo estacion).
--
-- ── DÍA DE NEGOCIO ──────────────────────────────────────────────────────────────────────────────────────────
--   dia = (me.ventas.fecha at time zone 'America/Lima')::date  (igual que todo el ecosistema).
--   Excluye ventas ANULADAS (upper(estado_envio) <> 'ANULADO') — paridad con las RPCs de almacén.
--
-- ── PARÁMETROS ──────────────────────────────────────────────────────────────────────────────────────────────
--   p_desde / p_hasta: rango de DÍA de negocio (inclusive). La función filtra fecha por [p_desde, p_hasta].
--   security definer + search_path='' (mismo endurecimiento del proyecto). No tiene gate de claim propio: es un
--   HELPER interno consumido SOLO por RPCs definer (128/129) que SÍ aplican mos._claim_ok(). Grants restringidos
--   a service_role/authenticated, revoke public — pero como no devuelve nada hasta que una RPC definer la invoca,
--   no expone datos por sí sola.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function me._riz_ventas_base(p_desde date, p_hasta date)
returns table(sku_base text, zona_id text, dia date, unidades_base numeric)
language sql
stable
security definer
set search_path = ''
as $fn$
  with
  -- ── Resolver de zona (idéntico patrón a 117) ──────────────────────────────────────────────────────────────
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true
  ),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (
    select distinct on (raw) raw, canon_id from zona_resolver order by raw, canon_id
  ),
  -- ── Mapa cod_barra → (skuBase, factor). Presentaciones propias (cada una con su factor) + equivalentes (f=1). ─
  --    Para un cod_barra repetido entre principal y equivalencia, gana el principal (ord 0).
  cb_map as (
    select distinct on (cb) cb, sku, factor from (
      select upper(btrim(p.codigo_barra)) as cb,
             coalesce(nullif(btrim(p.sku_base),''), p.id_producto) as sku,
             case when coalesce(p.factor_conversion,0) = 0 then 1 else p.factor_conversion end as factor,
             0 as ord
      from mos.productos p where nullif(btrim(p.codigo_barra),'') is not null
      union all
      -- también se puede vender por id_producto (algunos detalles traen sku = id_producto)
      select upper(btrim(p.id_producto)) as cb,
             coalesce(nullif(btrim(p.sku_base),''), p.id_producto) as sku,
             case when coalesce(p.factor_conversion,0) = 0 then 1 else p.factor_conversion end as factor,
             1 as ord
      from mos.productos p where nullif(btrim(p.id_producto),'') is not null
      union all
      select upper(btrim(e.codigo_barra)) as cb,
             e.sku_base as sku,
             1::numeric as factor,
             2 as ord
      from mos.equivalencias e
      where coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t
    order by cb, ord
  ),
  -- ── Ventas válidas en rango (día de negocio Lima, no anuladas). Zona = zona_id si viene, si no estacion. ──
  ventas_val as (
    select v.id_venta,
           (v.fecha at time zone 'America/Lima')::date as dia,
           upper(btrim(coalesce(nullif(btrim(v.zona_id),''), v.estacion))) as raw_zona
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= p_desde
      and (v.fecha at time zone 'America/Lima')::date <= p_hasta
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(coalesce(nullif(btrim(v.zona_id),''), v.estacion)),'') is not null
  ),
  -- ── Detalle normalizado: une por sku o cod_barras al cb_map; aplica factor. ──
  detalle as (
    select
      coalesce(zr.canon_id, vv.raw_zona) as zona_id,
      cm.sku as sku_base,
      vv.dia,
      coalesce(d.cantidad,0) * cm.factor as base
    from me.ventas_detalle d
    join ventas_val vv on vv.id_venta = d.id_venta
    join cb_map cm on cm.cb = upper(btrim(coalesce(nullif(btrim(d.cod_barras),''), d.sku)))
    left join zona_resolver_u zr on zr.raw = vv.raw_zona
    where coalesce(d.cantidad,0) <> 0
  )
  select sku_base, zona_id, dia, sum(base) as unidades_base
  from detalle
  where nullif(btrim(zona_id),'') is not null and nullif(btrim(sku_base),'') is not null
  group by sku_base, zona_id, dia;
$fn$;

revoke all on function me._riz_ventas_base(date, date) from public;
grant execute on function me._riz_ventas_base(date, date) to service_role, authenticated;
