-- 137_riz_almacen_stock_union.sql — [RIZ · CAPA 2 · ALMACEN = STOCK(wh.stock) ∪ DESPACHO] — backward-compatible
-- Módulo de Reposición Inteligente por Zona (RIZ). RE-DEFINE me.zona_panel (última versión = 136) + wrapper mos.zona_panel.
--
-- ⚠️ INERTE igual que 128/135/136: la RPC tiene grant pero el módulo RIZ del frontend está gated OFF (flag mos_zona_modulo).
--    Este archivo NO toca flags/sync/frontend/GAS/version/sw/api.js/app.js. Solo CREATE OR REPLACE de me.zona_panel + wrapper.
--    Patrón intacto: security definer · set search_path='' · gate mos._claim_ok() · grants revoke public + service_role,
--    authenticated · lectura concatena || mos._frescura_sombra().
--
-- ═══ EL PROBLEMA (corregido aquí) ════════════════════════════════════════════════════════════════════════════════════
--   En 136, el "set de STOCK de la zona" (sku_en_zona / cod_arr / el join ez para rotacionCero) sale SIEMPRE de
--   me.stock_zonas. Para ALMACEN, me.stock_zonas tiene 0 filas → el set de stock de ALMACEN es VACÍO → el universo de
--   ALMACEN = solo despacho (rot_desp). Resultado: ALMACEN nunca mostraba rotacionCero (productos con stock en almacén que
--   JAMÁS se despacharon en las 4 semanas = candidatos a anular).
--
-- ═══ EL CAMBIO (SOLO la rama ALMACEN) ════════════════════════════════════════════════════════════════════════════════
--   Para v_es_almacen=true, el "set de stock de la zona" pasa a ser wh.stock (vía sku_en_alm / stock_alm_cod / alm_arr,
--   que YA existen en 136 y desglosan base+equivalentes factor=1, SIN presentaciones — regla en piedra de WH):
--     · Universo  = (despacho SALIDA_ZONA = rot_desp)  ∪  (stock en wh.stock = sku_en_alm)  [∪ esp, igual que antes].
--     · stockZona = el stock de almacén (suma wh.stock de los códigos base+equiv del skuBase) — antes salía de cod_arr
--                   (me.stock_zonas, =0 para ALMACEN). codigos[] de ALMACEN = el mismo desglose que codigosAlmacen[].
--     · rotacionCero = está en wh.stock (sku_en_alm) pero SIN despacho en 4 sem. (Mantiene la semántica de zonas: incluye
--                   códigos en 0/negativo — el stock es el stock; el universo de stock no se filtra por saldo>0.)
--   Las ZONAS normales (ZONA-01, ZONA-02, …) NO cambian: siguen con me.stock_zonas (cod_arr/sku_en_zona) ∪ ventas.
--   stockAlmacen, codigosAlmacen, esperada, brecha, tendencia, bcg, picos, lotes, vencimientos: SIN cambios.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_panel(p jsonb { zona (req), filtro? })  — RE-DEFINE 136. Shape data.items[] idéntico a 136 (backward-compatible):
--     { skuBase, descripcion, stockZona, esperada, brecha, stockNegativo, stockAlmacen, tendencia, bcg, picos[],
--       unidad, esGranel, vencimientoProximo, countLotes, rotacion, rotacionCero,
--       codigos:[{codBarra, descripcion, stock, esEquivalente}],
--       codigosAlmacen:[{codBarra, descripcion, stock, esEquivalente}] }
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona       text := upper(btrim(coalesce(p->>'zona','')));
  v_filtro     text := upper(btrim(coalesce(p->>'filtro','')));
  v_hoy        date := (now() at time zone 'America/Lima')::date;
  v_desde      date := ((now() at time zone 'America/Lima')::date - 28);   -- periodo de rotación: 4 semanas (28 días)
  v_es_almacen boolean := (v_zona = 'ALMACEN');
  v_data       jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  with
  -- resolver de zona inverso (igual a 136): aliases que mapean a la zona canónica para me.stock_zonas.
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
  -- mapa cod_barra → (skuBase, descripción del código, esEquivalente) SOLO de STOCK (sin presentaciones). Igual a 136.
  cb_sku as (
    select distinct on (cb) cb, sku, cb_desc, es_equiv from (
      select upper(btrim(p2.codigo_barra)) cb,
             coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             nullif(btrim(p2.descripcion),'') cb_desc,
             false es_equiv, 0 ord
        from mos.productos p2
        where nullif(btrim(p2.codigo_barra),'') is not null
          and coalesce(p2.factor_conversion,1) = 1                       -- ⭐ sin presentaciones
          and coalesce(p2.tipo_producto::text, 'CANONICO') <> 'PRESENTACION'
      union all
      select upper(btrim(e.codigo_barra)),
             e.sku_base,
             nullif(btrim(e.descripcion),''),
             true, 1
        from mos.equivalencias e
        where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t order by cb, ord
  ),
  -- descripción canónica + unidad/factor del canónico por skuBase (igual a 136).
  sku_meta as (
    select distinct on (sku) sku, descripcion, unidad, factor from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             p2.descripcion,
             coalesce(nullif(btrim(p2.unidad),''),'') as unidad,
             coalesce(p2.factor_conversion,1) as factor,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord,
             p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  -- stock individual por (skuBase, código) en ESTA zona — me.stock_zonas (igual a 136). Para ALMACEN sale 0 filas, pero
  -- igual se computa: la rama ALMACEN no lo usa para el set ni para stockZona (usa el de almacén, abajo).
  stock_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           sum(coalesce(z.cantidad,0)) as cant,
           count(z.cod_barras) as filas_zona
    from cb_sku cs
    left join me.stock_zonas z
      on upper(btrim(z.cod_barras)) = cs.cb
     and upper(btrim(z.zona_id)) in (select alias from zona_aliases)
    group by cs.sku, cs.cb, cs.cb_desc, cs.es_equiv
  ),
  sku_en_zona as (
    select distinct sku_base from stock_cod where filas_zona > 0
  ),
  cod_arr as (
    select sk.sku_base,
           jsonb_agg(jsonb_build_object(
             'codBarra', sk.cod_barra,
             'descripcion', coalesce(sk.cb_desc, sk.cod_barra),
             'stock', sk.cant,
             'esEquivalente', sk.es_equiv
           ) order by sk.es_equiv, sk.cod_barra) as codigos,
           sum(sk.cant) as stock_zona
    from stock_cod sk
    join sku_en_zona ez on ez.sku_base = sk.sku_base
    group by sk.sku_base
  ),
  -- stock de ALMACÉN por (skuBase, código) — wh.stock de cada código base+equivalente (sin presentaciones). Igual a 136.
  stock_alm_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           sum(coalesce(s.cantidad_disponible,0)) as cant,
           count(s.cod_producto) as filas_alm
    from cb_sku cs
    left join wh.stock s on upper(btrim(s.cod_producto)) = cs.cb
    group by cs.sku, cs.cb, cs.cb_desc, cs.es_equiv
  ),
  -- "tiene stock en almacén" = al menos una de sus barras (base/equiv) existe en wh.stock (aunque saldo sea 0/neg).
  sku_en_alm as (
    select distinct sku_base from stock_alm_cod where filas_alm > 0
  ),
  alm_arr as (
    select sa.sku_base,
           jsonb_agg(jsonb_build_object(
             'codBarra', sa.cod_barra,
             'descripcion', coalesce(sa.cb_desc, sa.cod_barra),
             'stock', sa.cant,
             'esEquivalente', sa.es_equiv
           ) order by sa.es_equiv, sa.cod_barra) as codigos_almacen,
           sum(sa.cant) as stock_almacen
    from stock_alm_cod sa
    join sku_en_alm ea on ea.sku_base = sa.sku_base
    group by sa.sku_base
  ),
  -- ── set de STOCK de la zona, EFECTIVO: ALMACEN ⇒ wh.stock (sku_en_alm); zonas normales ⇒ me.stock_zonas (sku_en_zona).
  --    SOLO este selector difiere por rama (el resto del universo es común). ⭐ CAMBIO de 137.
  sku_stock_zona as (
    select sku_base from sku_en_alm  where v_es_almacen
    union
    select sku_base from sku_en_zona where not v_es_almacen
  ),
  -- ── ROTACIÓN del periodo (4 semanas) por skuBase, según la zona (igual a 136) ─────────────────────────────────────
  rot_ventas as (
    select b.sku_base, sum(b.unidades_base) as rotacion
    from me._riz_ventas_base(v_desde, v_hoy) b
    where not v_es_almacen and b.zona_id = v_zona
    group by b.sku_base
  ),
  rot_desp as (
    select cs.sku as sku_base, sum(coalesce(d.cant_recibida,0)) as rotacion
    from wh.guia_detalle d
    join wh.guias g on g.id_guia = d.id_guia
    join cb_sku cs on cs.cb = upper(btrim(d.cod_producto))
    where v_es_almacen
      and g.tipo = 'SALIDA_ZONA'
      and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
      and g.fecha is not null
      and (g.fecha at time zone 'America/Lima')::date >= v_desde
      and (g.fecha at time zone 'America/Lima')::date <= v_hoy
      and upper(coalesce(d.observacion,'')) <> 'ANULADO'
      and coalesce(d.cant_recibida,0) > 0
    group by cs.sku
  ),
  rot as (
    select sku_base, rotacion from rot_ventas
    union all
    select sku_base, rotacion from rot_desp
  ),
  -- lotes de la zona por skuBase (sin cambios).
  lotes as (
    select l.sku_base, min(l.fecha_vencimiento) as venc_prox, count(*) as n
    from me.zona_lotes l
    where upper(btrim(l.zona_id)) = v_zona and coalesce(l.cant_restante,0) > 0
    group by l.sku_base
  ),
  -- esperado materializado (sin cambios).
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.bcg, e.picos
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  -- ── universo = skus con ROTACIÓN ∪ skus con STOCK en la zona (efectivo: wh.stock para ALMACEN) [∪ esp]. ⭐ CAMBIO 137.
  universo as (
    select sku_base from rot
    union select sku_base from sku_stock_zona
    union select sku_base from esp
  ),
  filas as (
    select
      u.sku_base,
      coalesce(sm.descripcion, u.sku_base) as descripcion,
      -- stockZona EFECTIVO: ALMACEN ⇒ stock de almacén (alm_arr); zonas normales ⇒ cod_arr (me.stock_zonas). ⭐ CAMBIO 137.
      (case when v_es_almacen then coalesce(aa.stock_almacen, 0) else coalesce(ca.stock_zona, 0) end) as stock_zona,
      coalesce(es.esperado, 0) as esperada,
      greatest(0, coalesce(es.esperado, 0)
        - greatest((case when v_es_almacen then coalesce(aa.stock_almacen, 0) else coalesce(ca.stock_zona, 0) end), 0)) as brecha,
      ((case when v_es_almacen then coalesce(aa.stock_almacen, 0) else coalesce(ca.stock_zona, 0) end) < 0) as stock_negativo,
      coalesce(aa.stock_almacen, 0) as stock_almacen,
      coalesce(es.tendencia, 'NULA') as tendencia,
      coalesce(es.bcg, 'PERRO') as bcg,
      coalesce(es.picos, '[]'::jsonb) as picos,
      lo.venc_prox,
      coalesce(lo.n, 0) as count_lotes,
      coalesce(sm.unidad, '') as unidad,
      me._riz_es_granel(sm.unidad, sm.factor) as es_granel,
      -- codigos[] EFECTIVO: ALMACEN ⇒ desglose de almacén (codigosAlmacen); zonas normales ⇒ cod_arr. ⭐ CAMBIO 137.
      (case when v_es_almacen then coalesce(aa.codigos_almacen, '[]'::jsonb) else coalesce(ca.codigos, '[]'::jsonb) end) as codigos,
      coalesce(aa.codigos_almacen, '[]'::jsonb) as codigos_almacen,
      coalesce(rt.rotacion, 0) as rotacion,
      -- rotacionCero: está en el set de stock de la zona (ALMACEN ⇒ wh.stock; zonas ⇒ me.stock_zonas) pero NO rotó. ⭐ CAMBIO 137.
      (ss.sku_base is not null and coalesce(rt.rotacion, 0) <= 0) as rotacion_cero
    from universo u
    left join sku_meta       sm on sm.sku = u.sku_base
    left join cod_arr        ca on ca.sku_base = u.sku_base
    left join alm_arr        aa on aa.sku_base = u.sku_base
    left join esp            es on es.sku_base = u.sku_base
    left join lotes          lo on lo.sku_base = u.sku_base
    left join rot            rt on rt.sku_base = u.sku_base
    left join sku_stock_zona ss on ss.sku_base = u.sku_base
  )
  select jsonb_build_object(
    'zona', v_zona,
    'filtro', nullif(v_filtro,''),
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'skuBase', f.sku_base,
      'descripcion', f.descripcion,
      'stockZona', f.stock_zona,
      'esperada', f.esperada,
      'brecha', f.brecha,
      'stockNegativo', f.stock_negativo,
      'stockAlmacen', f.stock_almacen,
      'tendencia', f.tendencia,
      'bcg', f.bcg,
      'picos', f.picos,
      'unidad', f.unidad,
      'esGranel', f.es_granel,
      'rotacion', f.rotacion,
      'rotacionCero', f.rotacion_cero,
      'codigos', f.codigos,
      'codigosAlmacen', f.codigos_almacen,
      'vencimientoProximo', case when f.venc_prox is null then null else jsonb_build_object(
        'fecha', to_char((f.venc_prox at time zone 'America/Lima')::date, 'YYYY-MM-DD'),
        'dias', ((f.venc_prox at time zone 'America/Lima')::date - v_hoy)) end,
      'countLotes', f.count_lotes
    ) order by f.brecha desc, f.rotacion desc, f.stock_zona desc), '[]'::jsonb)
  ) into v_data
  from filas f
  where v_filtro = '' or v_filtro is null
     or (v_filtro = 'BRECHA' and f.brecha > 0)
     or (v_filtro = 'SIN_ROTACION' and f.rotacion_cero)
     or (v_filtro in ('CRECIENTE','DECRECIENTE','ESTABLE') and f.tendencia = v_filtro)
     or (v_filtro in ('ESTRELLA','VACA','INTERROGANTE','PERRO') and f.bcg = v_filtro);

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_panel(jsonb) from public;
grant execute on function me.zona_panel(jsonb) to service_role, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- WRAPPER mos.zona_panel — la firma jsonb NO cambia (pass-through puro). Reafirmado idempotente.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_panel(p);
end;
$fn$;
revoke all on function mos.zona_panel(jsonb) from public;
grant execute on function mos.zona_panel(jsonb) to service_role, authenticated;
