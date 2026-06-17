-- 136_riz_filtro_rotacion.sql — [RIZ · CAPA 2 · CORRECCIÓN DE LÓGICA DEL PANEL — 3 reglas del dueño] — backward-compatible
-- Módulo de Reposición Inteligente por Zona (RIZ). RE-DEFINE me.zona_panel (última versión = 135) + wrapper mos.zona_panel.
--
-- ⚠️ INERTE igual que 128/135: la RPC tiene grant pero el módulo RIZ del frontend está gated OFF (flag mos_zona_modulo).
--    Este archivo NO toca flags/sync/frontend/GAS/version/sw. Solo CREATE OR REPLACE de me.zona_panel + wrapper mos.*.
--    Patrón intacto: security definer · set search_path='' · gate mos._claim_ok() · grants revoke public + service_role,
--    authenticated · lectura concatena || mos._frescura_sombra().
--
-- ═══ REGLA EN PIEDRA (de WH, confirmada en datos) ═════════════════════════════════════════════════════════════════
--   STOCK = canónicos (factor_conversion=1) + equivalentes ACTIVOS. Las PRESENTACIONES (factor≠1 / tipo_producto
--   'PRESENTACION') NO son stock — son solo un factor del base para ventas. Verificado en prod: las 535 presentaciones
--   tienen factor≠1 y SU PROPIO codigo_barra (PRE013, PRE504, …) que SÍ aparece en me.stock_zonas (136 filas, casi todas
--   negativas) → la versión 128/135 las sumaba al stockZona (BUG). Aquí se EXCLUYEN del set de códigos.
--
-- ═══ LOS 3 CAMBIOS ════════════════════════════════════════════════════════════════════════════════════════════════
--   CAMBIO 1 — CONJUNTO DE ITEMS = UNIÓN (rotación ∪ stock), con flag `rotacionCero`:
--     Antes el universo = (esperado materializado) ∪ (stock en zona). Ahora el universo = (ROTACIÓN en zona) ∪ (STOCK en
--     zona). Cada item trae:
--       · `rotacion`     (numeric) — unidades BASE del periodo (4 semanas), VENTAS o DESPACHO según la zona.
--       · `rotacionCero` (bool)    — true si tiene stock en la zona pero SIN rotación en el periodo.
--     FUENTE DE ROTACIÓN según la zona:
--       · ZONA normal (ZONA-01, ZONA-02…): ventas por ticket = me._riz_ventas_base (me.ventas_detalle) de ESA zona, 4
--         semanas, unidades base por factor. unidades>0 ⇒ rota.
--       · ALMACEN (id_zona='ALMACEN'): GUÍA DE SALIDA A ZONA (despacho), NO ventas. Suma cant_recibida de wh.guia_detalle
--         de guías wh.guias.tipo='SALIDA_ZONA' (estado CERRADA/AUTOCERRADA) en el periodo, mapeando cod_producto→skuBase.
--         (El almacén casi no tiene "ventas"; su rotación real es lo que DESPACHA a las zonas.) Verificado: 'SALIDA_ZONA'
--         es el tipo de despacho almacén→zona (285 guías cerradas); el id_zona de la guía es el DESTINO (no se filtra por
--         destino: la rotación del almacén = todo lo que salió, a cualquier zona). Se excluyen SALIDA_ENVASADO/JEFATURA/
--         DEVOLUCION y líneas ANULADO / cant_recibida<=0 (idéntico criterio a wh.rotacion_semanal, 11_fase1d).
--   CAMBIO 2 — codigos[] y stockZona = base + EQUIVALENTES, SIN presentaciones (CRÍTICO):
--     codigos[] = código de barra CANÓNICO del skuBase (factor=1) + equivalentes ACTIVOS de mos.equivalencias (mismo
--     skuBase). NUNCA presentaciones (factor≠1). stockZona global = SUMA del stock (me.stock_zonas) de ESOS códigos.
--     Cada item de codigos[]: {codBarra, descripcion, stock, esEquivalente}.
--   CAMBIO 3 — desglose de STOCK ALMACÉN por código:
--     codigosAlmacen:[{codBarra, descripcion, stock, esEquivalente}] = stock de wh.stock por cada código base+equivalente
--     del skuBase (mismo criterio: SIN presentaciones). stockAlmacen global = suma.
--
--   Se MANTIENE intacto lo correcto: esperada (global del skuBase desde me.zona_esperado), brecha = greatest(0, esperada −
--   greatest(stockZona,0)), stockNegativo, unidad/esGranel, picos, bcg, tendencia, vencimientoProximo, countLotes.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_panel(p jsonb { zona (req), filtro? })  — RE-DEFINE 135 con la lógica de unión rotación∪stock y el filtro de
--   presentaciones. Shape data.items[] (AMPLIADO, backward-compatible):
--     { skuBase, descripcion, stockZona, esperada, brecha, stockNegativo, stockAlmacen, tendencia, bcg, picos[],
--       unidad, esGranel, vencimientoProximo, countLotes,                      ← TODOS los de antes
--       rotacion:numeric, rotacionCero:bool,                                   ← CAMBIO 1 (nuevos)
--       codigos:[{codBarra, descripcion, stock, esEquivalente}],               ← CAMBIO 2 (corregido: sin presentaciones)
--       codigosAlmacen:[{codBarra, descripcion, stock, esEquivalente}] }       ← CAMBIO 3 (nuevo)
--   filtro (opc, sin cambios de semántica): 'BRECHA' (brecha>0) · 'SIN_ROTACION' (rotación 0) · CRECIENTE/DECRECIENTE/
--   ESTABLE (tendencia) · ESTRELLA/VACA/INTERROGANTE/PERRO (bcg).  NOTA: 'SIN_ROTACION' ahora usa rotacionCero (rotación
--   real del periodo) en vez de la etiqueta tendencia='NULA' (que era una aproximación). Más fiel al dueño.
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
  -- resolver de zona inverso (igual a 128/135): aliases que mapean a la zona canónica para me.stock_zonas.
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
  -- ── CAMBIO 2/3: mapa cod_barra → (skuBase, descripción del código, esEquivalente) SOLO de STOCK:
  --    canónico/derivado (factor=1) + equivalentes ACTIVOS. EXCLUYE presentaciones (factor≠1 / 'PRESENTACION') —
  --    sus barcodes (PRE…) viven en me.stock_zonas pero NO son stock (regla en piedra de WH). Para un código repetido
  --    entre principal y equivalencia, gana el principal (ord 0).
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
  -- descripción canónica + unidad/factor del canónico por skuBase (CAMBIO 2 de 135, intacto). canónico = factor 1 / sin base.
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
  -- stock individual por (skuBase, código) en ESTA zona (CAMBIO 2). LEFT JOIN: TODO código base+equivalente aparece
  -- aunque no tenga fila en me.stock_zonas (stock=0) — el dueño edita/ajusta cada código por separado (aunque esté en
  -- 0). Solo se restringe el set por zona: si un sku NO tiene ninguna de sus barras en ESTA zona, no entra a cod_arr
  -- (el universo lo trae igual por rotación/esperado, con codigos[]=[]). Suma por si hubiese filas duplicadas.
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
  -- skus que tienen AL MENOS una de sus barras (base/equiv) registrada en ESTA zona (define "tiene stock en zona").
  sku_en_zona as (
    select distinct sku_base from stock_cod where filas_zona > 0
  ),
  -- desglose codigos[] por skuBase (CAMBIO 2): {codBarra, descripcion, stock, esEquivalente} + stockZona = suma.
  -- Solo para skus presentes en la zona (sku_en_zona); ahí se listan TODOS sus códigos (los de 0 incluidos).
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
  -- ── CAMBIO 3: stock de ALMACÉN por (skuBase, código) — wh.stock de cada código base+equivalente (sin presentaciones).
  --    LEFT JOIN igual que la zona: para un skuBase con presencia en almacén, se listan TODOS sus códigos (los de 0
  --    incluidos). filas_alm cuenta si esa barra existe en wh.stock para acotar a skus realmente presentes en almacén.
  stock_alm_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           sum(coalesce(s.cantidad_disponible,0)) as cant,
           count(s.cod_producto) as filas_alm
    from cb_sku cs
    left join wh.stock s on upper(btrim(s.cod_producto)) = cs.cb
    group by cs.sku, cs.cb, cs.cb_desc, cs.es_equiv
  ),
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
  -- ── CAMBIO 1: ROTACIÓN del periodo (4 semanas) por skuBase, según la zona ─────────────────────────────────────────
  -- (a) VENTAS de la zona (zonas normales) — unidades base por factor desde me._riz_ventas_base.
  rot_ventas as (
    select b.sku_base, sum(b.unidades_base) as rotacion
    from me._riz_ventas_base(v_desde, v_hoy) b
    where not v_es_almacen and b.zona_id = v_zona
    group by b.sku_base
  ),
  -- (b) DESPACHO almacén→zona (SALIDA_ZONA) — solo cuando la zona pedida es ALMACEN. Suma cant_recibida (unidades base
  --     reales: las guías registran el codigoBarra canónico/equivalente, factor=1) mapeada a skuBase vía cb_sku.
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
  -- ── CAMBIO 1: universo = skus con ROTACIÓN ∪ skus con STOCK en la zona. (Se agrega esp para no perder un sku
  --    esperado-pero-sin-stock-ni-rotación, manteniendo backward-compat con el universo previo; igual queda rotacionCero
  --    si tiene stock. esp NO infla con basura: solo skus que el recompute ya consideró de esta zona.)
  universo as (
    select sku_base from rot
    union select sku_base from cod_arr
    union select sku_base from esp
  ),
  filas as (
    select
      u.sku_base,
      coalesce(sm.descripcion, u.sku_base) as descripcion,
      coalesce(ca.stock_zona, 0) as stock_zona,
      coalesce(es.esperado, 0) as esperada,
      greatest(0, coalesce(es.esperado, 0) - greatest(coalesce(ca.stock_zona, 0), 0)) as brecha,
      (coalesce(ca.stock_zona, 0) < 0) as stock_negativo,
      coalesce(aa.stock_almacen, 0) as stock_almacen,
      coalesce(es.tendencia, 'NULA') as tendencia,
      coalesce(es.bcg, 'PERRO') as bcg,
      coalesce(es.picos, '[]'::jsonb) as picos,
      lo.venc_prox,
      coalesce(lo.n, 0) as count_lotes,
      coalesce(sm.unidad, '') as unidad,
      me._riz_es_granel(sm.unidad, sm.factor) as es_granel,
      coalesce(ca.codigos, '[]'::jsonb) as codigos,                       -- CAMBIO 2
      coalesce(aa.codigos_almacen, '[]'::jsonb) as codigos_almacen,       -- CAMBIO 3
      coalesce(rt.rotacion, 0) as rotacion,                              -- CAMBIO 1
      -- rotacionCero: está registrado en la zona (tiene al menos una barra en me.stock_zonas, aunque el saldo sea 0/neg)
      -- pero NO rotó en el periodo → stock muerto / a revisar. Se basa en presencia en zona, no en stock<>0, para
      -- delatar también un código en 0 exacto que sigue ocupando espacio del catálogo de la zona.
      (ez.sku_base is not null and coalesce(rt.rotacion, 0) <= 0) as rotacion_cero  -- CAMBIO 1
    from universo u
    left join sku_meta   sm on sm.sku = u.sku_base
    left join cod_arr    ca on ca.sku_base = u.sku_base
    left join alm_arr    aa on aa.sku_base = u.sku_base
    left join esp        es on es.sku_base = u.sku_base
    left join lotes      lo on lo.sku_base = u.sku_base
    left join rot        rt on rt.sku_base = u.sku_base
    left join sku_en_zona ez on ez.sku_base = u.sku_base
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
-- WRAPPER mos.zona_panel — la firma jsonb NO cambia (pass-through puro a me.zona_panel). Se reafirma idempotente para
-- que un deploy de SOLO este archivo deje el wrapper apuntando a la versión nueva.
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
