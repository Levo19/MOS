-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 198_riz_fix_universo_zona_no_inflar.sql — FIX regresión introducida por SQL 197 en me.zona_panel (Zona/RIZ MOS).
-- App de DINERO en PROD · SOLO LECTURA (no escribe stock/dinero/sync). Corrige el UNIVERSO de las pestañas de ZONA.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- BUG (introducido por 197)
--   SQL 197 cambió `stock_cod` (CTE de stock por código en ZONA) de INNER JOIN a LEFT JOIN anclado en `cb_sku`
--   (todos los códigos del grupo) para que el array `codigos[]` muestre TODOS los códigos del grupo (incl. los que
--   están en 0). Eso es correcto para el DESGLOSE. PERO el universo de productos de ZONA se arma así:
--       universo (no almacén) = esp (me.zona_esperado)  ∪  cod_arr  (← derivado de stock_cod)
--   Al pasar stock_cod a LEFT JOIN sobre cb_sku, `cod_arr` dejó de contener "SKUs con fila real de stock en la
--   zona" y pasó a contener EL CATÁLOGO COMPLETO (1751 SKUs). Resultado: el panel de cada zona se infló de
--   ~124/~844 a 1751 ítems, llenándose de productos fantasma con stockZona=0, esperada=0, brecha=0 (ruido).
--   Medido: ZONA-01 124→1751 (+1627 fantasmas, todos 0), ZONA-02 844→1751 (+907 fantasmas, todos 0).
--   NO corrompió números (stock/brecha/esperada/tendencia/bcg/grupo idénticos en los ítems reales; 0 diffs), pero
--   rompe el universo del panel (VECTOR 5) y lo vuelve inusable para decidir compras.
--   ALMACÉN no se vio afectado: su universo usa desp_uni ∪ sku_stock_alm (Σ stock ≠ 0), no cod_arr.
--
-- FIX (este archivo)
--   Se separa "desglose" de "universo" en ZONA, igual que en ALMACÉN:
--     · `cod_arr` (LEFT JOIN, todos los códigos del grupo) SIGUE construyendo `codigos[]` + la suma del grupo
--       (stock_zona) para los productos que SÍ están en el universo. Sin cambios — el desglose de 197 se conserva.
--     · NUEVA CTE `sku_stock_zona` = SKUs que tienen AL MENOS UNA fila real en me.stock_zonas para la zona (≡ el
--       comportamiento del INNER JOIN previo a 197). El universo de zona pasa a ser:
--           esp  ∪  sku_stock_zona
--       en vez de `esp ∪ cod_arr`. Esto reproduce EXACTAMENTE el universo pre-197 (verificado: ZONA-01 124=124,
--       ZONA-02 844=844, 0 diferencias).
--
-- 🔴 GARANTÍA money (intacta): ningún código con stock ≠ 0 puede quedar oculto. Si un código tiene stock en la
--    zona, su SKU está por definición en `sku_stock_zona` → el producto permanece en el universo y su `codigos[]`
--    (vía cod_arr, super-conjunto) se muestra completo. Verificado: 0 códigos con stock ocultos en las 3 pestañas.
--    La mejora de 197 (mostrar también los códigos en 0 del grupo de un producto YA listado) se conserva 1:1.
--
-- IDEMPOTENTE (create or replace). Regenera me.zona_panel completa = versión live SQL 197 + esta CTE/cambio de
-- universo. mos.zona_panel (wrapper) sin cambios. No toca firmas públicas, flags, sync ni dinero.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

set search_path to '';

CREATE OR REPLACE FUNCTION me.zona_panel(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona       text := upper(btrim(coalesce(p->>'zona','')));
  v_filtro     text := upper(btrim(coalesce(p->>'filtro','')));
  v_hoy        date := (now() at time zone 'America/Lima')::date;
  v_es_almacen boolean := (v_zona = 'ALMACEN');
  v_lunes_act  date := (date_trunc('week', (now() at time zone 'America/Lima'))::date);
  v_desde_obj  date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) - 28;
  v_hasta_obj  date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) - 1;
  v_umbral     numeric := 0.10;
  v_colchon    numeric := 0.20;
  v_data       jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  with
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
  -- mapa cod_barra → (skuBase, descripción del código, esEquivalente).
  -- [192] El grupo de stock de un producto = CANÓNICO + EQUIVALENTES. Se EXCLUYEN las PRESENTACIONES
  --       (tipo_producto='PRESENTACION'): no son códigos de inventario, sólo empaque/venta.
  cb_sku as (
    select distinct on (cb) cb, sku, cb_desc, es_equiv from (
      select upper(btrim(p2.codigo_barra)) cb,
             coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             nullif(btrim(p2.descripcion),'') cb_desc,
             false es_equiv, 0 ord
        from mos.productos p2
       where nullif(btrim(p2.codigo_barra),'') is not null
         and p2.tipo_producto::text is distinct from 'PRESENTACION'
      union all
      select upper(btrim(e.codigo_barra)),
             e.sku_base,
             nullif(btrim(e.descripcion),''),
             true, 1
        from mos.equivalencias e
        where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t order by cb, ord
  ),
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
  -- [197] ZONA · TODOS los códigos del grupo (cb_sku), LEFT JOIN a me.stock_zonas. El filtro de zona va en la
  --        condición del JOIN (no en WHERE) para preservar el LEFT JOIN. Códigos sin fila → cant=0 (no se omiten).
  --        Alimenta el DESGLOSE codigos[] + la suma del grupo (stock_zona), NO el universo (ver sku_stock_zona).
  stock_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           coalesce(sum(z.cantidad), 0) as cant
    from cb_sku cs
    left join me.stock_zonas z
           on upper(btrim(z.cod_barras)) = cs.cb
          and upper(btrim(z.zona_id)) in (select alias from zona_aliases)
    group by cs.sku, cs.cb, cs.cb_desc, cs.es_equiv
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
    group by sk.sku_base
  ),
  -- [198] UNIVERSO de zona: SKUs con AL MENOS UNA fila real en me.stock_zonas para la zona (≡ INNER JOIN pre-197).
  --        Se separa del desglose (cod_arr, super-conjunto LEFT JOIN) para NO inflar el panel con el catálogo
  --        completo. Money-safe: un código con stock implica su SKU acá → el producto y su codigos[] se muestran.
  sku_stock_zona as (
    select distinct cs.sku as sku_base
    from cb_sku cs
    join me.stock_zonas z
      on upper(btrim(z.cod_barras)) = cs.cb
     and upper(btrim(z.zona_id)) in (select alias from zona_aliases)
  ),
  -- [197] ALMACÉN · TODOS los códigos del grupo (cb_sku), LEFT JOIN a wh.stock. Códigos sin fila → cant=0,
  --        filas_alm=0 (no se omiten). GARANTÍA money: ningún código con stock ≠ 0 puede faltar.
  stock_alm_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           coalesce(sum(s.cantidad_disponible), 0) as cant,
           count(s.cod_producto) as filas_alm
    from cb_sku cs
    left join wh.stock s on upper(btrim(s.cod_producto)) = cs.cb
    group by cs.sku, cs.cb, cs.cb_desc, cs.es_equiv
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
    group by sa.sku_base
  ),
  -- Universo de almacén: SKU que tiene Σ stock ≠ 0 (qué PRODUCTOS aparecen). Sin cambios — esto NO oculta
  -- códigos dentro de un producto ya mostrado; sólo decide qué productos listar.
  sku_stock_alm as (
    select sku_base from stock_alm_cod group by sku_base having sum(coalesce(cant,0)) <> 0
  ),
  desp_base as (
    select cs.sku as sku_base,
           (g.fecha at time zone 'America/Lima')::date as dia,
           coalesce(d.cant_recibida,0) as u
    from wh.guia_detalle d
    join wh.guias g on g.id_guia = d.id_guia
    join cb_sku cs on cs.cb = upper(btrim(d.cod_producto))
    where v_es_almacen
      and g.tipo in ('SALIDA_ZONA','SALIDA_JEFATURA')
      and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
      and g.fecha is not null
      and upper(coalesce(d.observacion,'')) <> 'ANULADO'
      and coalesce(d.cant_recibida,0) > 0
      and (g.fecha at time zone 'America/Lima')::date >= v_desde_obj
      and (g.fecha at time zone 'America/Lima')::date <= v_hasta_obj
  ),
  desp_uni as (
    select distinct sku_base from desp_base
  ),
  desp_dia as (
    select sku_base, dia, sum(u) as u_dia
    from desp_base
    where dia >= v_desde_obj and dia <= v_hasta_obj
    group by sku_base, dia
  ),
  desp_sem as (
    select sku_base, to_char(dia,'IYYY"-W"IW') as sem, max(u_dia) as pico_sem, sum(u_dia) as vol_sem
    from desp_dia group by sku_base, to_char(dia,'IYYY"-W"IW')
  ),
  desp_semanas as (
    select w, to_char((v_desde_obj + (w*7))::date,'IYYY"-W"IW') as lbl
    from generate_series(0,3) as w
  ),
  desp_skus as (select distinct sku_base from desp_sem),
  desp_serie as (
    select s.sku_base, sl.w, coalesce(ds.pico_sem,0) as pico
    from desp_skus s
    cross join desp_semanas sl
    left join desp_sem ds on ds.sku_base = s.sku_base and ds.sem = sl.lbl
  ),
  desp_agg as (
    select se.sku_base,
           array_agg(se.pico order by se.w) as picos,
           (array_agg(se.pico order by se.w))[4] as pico_ultima,
           avg(se.pico) as media_pico,
           case when var_pop(se.w) > 0 then regr_slope(se.pico, se.w) else 0 end as pendiente
    from desp_serie se group by se.sku_base
  ),
  desp_vol as (
    select sku_base, sum(vol_sem) as volumen from desp_sem group by sku_base
  ),
  desp_med as (
    select percentile_cont(0.5) within group (order by volumen) as mediana from desp_vol where volumen > 0
  ),
  desp_obj as (
    select a.sku_base,
           coalesce(a.picos, '{}') as picos,
           coalesce(a.pico_ultima,0) as pico_ultima,
           coalesce(v.volumen,0) as volumen,
           ceil(coalesce(a.pico_ultima,0) * (1 + v_colchon))::numeric as esperado,
           case
             when coalesce(v.volumen,0) <= 0 then 'NULA'
             when a.media_pico > 0 and (a.pendiente / a.media_pico) >=  v_umbral then 'CRECIENTE'
             when a.media_pico > 0 and (a.pendiente / a.media_pico) <= -v_umbral then 'DECRECIENTE'
             else 'ESTABLE'
           end as tendencia,
           case
             when coalesce(v.volumen,0) <= 0 then 'PERRO'
             else case
               when (a.media_pico > 0 and (a.pendiente / a.media_pico) >= v_umbral)
                 then case when coalesce(v.volumen,0) >= coalesce((select mediana from desp_med),0) then 'ESTRELLA' else 'INTERROGANTE' end
               when (a.media_pico > 0 and (a.pendiente / a.media_pico) <= -v_umbral)
                 then 'PERRO'
               else case when coalesce(v.volumen,0) >= coalesce((select mediana from desp_med),0) then 'VACA' else 'PERRO' end
             end
           end as bcg
    from desp_agg a
    left join desp_vol v on v.sku_base = a.sku_base
  ),
  lotes as (
    select l.sku_base, min(l.fecha_vencimiento) as venc_prox, count(*) as n
    from me.zona_lotes l
    where upper(btrim(l.zona_id)) = v_zona and coalesce(l.cant_restante,0) > 0
    group by l.sku_base
  ),
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.bcg, e.picos, e.volumen_4sem
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  accion as (
    select a.sku_base, a.accion from me.zona_accion_perro a where upper(btrim(a.zona_id)) = v_zona
  ),
  ped_raw as (
    select pl.sku_base, (pl.ts at time zone 'America/Lima')::date as dia, pl.ts
    from me.zona_pedido_log pl
    where upper(btrim(pl.zona_id)) = v_zona
      and (pl.ts at time zone 'America/Lima')::date >= (v_hoy - 6)
  ),
  ped_dias as (
    select pr.sku_base,
           array_agg(distinct pr.dia order by pr.dia desc) as dias,
           count(distinct pr.dia) as veces,
           max(pr.ts) as ultimo_ts
    from ped_raw pr group by pr.sku_base
  ),
  ped as (
    select pd.sku_base, pd.veces, pd.ultimo_ts, pd.dias,
           (
             select string_agg(lbl, ' y ' order by ord)
             from (
               select d.dia,
                      row_number() over (order by d.dia desc) as ord,
                      case
                        when d.dia = v_hoy     then 'hoy'
                        when d.dia = v_hoy - 1 then 'ayer'
                        else 'el ' || (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])
                                       [extract(dow from d.dia)::int + 1]
                      end as lbl
               from unnest(pd.dias) as d(dia)
               order by d.dia desc
               limit 3
             ) x
           ) as etiqueta_dias
    from ped_dias pd
  ),
  universo as (
    select sku_base from desp_uni        where v_es_almacen
    union
    select sku_base from sku_stock_alm   where v_es_almacen
    union
    select sku_base from esp             where not v_es_almacen
    union
    select sku_base from sku_stock_zona  where not v_es_almacen
  ),
  filas as (
    select
      u.sku_base,
      coalesce(sm.descripcion, u.sku_base) as descripcion,
      (case when v_es_almacen then coalesce(aa.stock_almacen, 0) else coalesce(ca.stock_zona, 0) end) as stock_zona,
      (case when v_es_almacen then coalesce(dob.esperado, 0) else coalesce(es.esperado, 0) end) as esperada,
      greatest(0,
        (case when v_es_almacen then coalesce(dob.esperado, 0) else coalesce(es.esperado, 0) end)
        - greatest((case when v_es_almacen then coalesce(aa.stock_almacen, 0) else coalesce(ca.stock_zona, 0) end), 0)) as brecha,
      ((case when v_es_almacen then coalesce(aa.stock_almacen, 0) else coalesce(ca.stock_zona, 0) end) < 0) as stock_negativo,
      coalesce(aa.stock_almacen, 0) as stock_almacen,
      (case when v_es_almacen then coalesce(dob.tendencia, 'NULA') else coalesce(es.tendencia, 'NULA') end) as tendencia,
      (case when v_es_almacen then coalesce(dob.bcg, 'PERRO')      else coalesce(es.bcg, 'PERRO')      end) as bcg,
      (case when v_es_almacen then coalesce(to_jsonb(dob.picos), '[]'::jsonb) else coalesce(es.picos, '[]'::jsonb) end) as picos,
      (case when v_es_almacen then coalesce(dob.volumen, 0)        else coalesce(es.volumen_4sem, 0)   end) as volumen,
      lo.venc_prox,
      coalesce(lo.n, 0) as count_lotes,
      coalesce(sm.unidad, '') as unidad,
      me._riz_es_granel(sm.unidad, sm.factor) as es_granel,
      (case when v_es_almacen then coalesce(aa.codigos_almacen, '[]'::jsonb) else coalesce(ca.codigos, '[]'::jsonb) end) as codigos,
      ac.accion as accion_perro,
      pe.veces      as ped_veces,
      pe.ultimo_ts  as ped_ultimo_ts,
      pe.dias       as ped_dias,
      pe.etiqueta_dias as ped_etiqueta,
      (case when v_es_almacen
            then (case when coalesce(dob.volumen,0) > 0 then 'ROTADO' else 'PARADO' end)
            else (case when coalesce(es.volumen_4sem,0) > 0 then 'ROTADO' else 'PARADO' end)
       end) as grupo
    from universo u
    left join sku_meta   sm  on sm.sku = u.sku_base
    left join cod_arr    ca  on ca.sku_base = u.sku_base
    left join alm_arr    aa  on aa.sku_base = u.sku_base
    left join desp_obj   dob on dob.sku_base = u.sku_base
    left join esp        es  on es.sku_base = u.sku_base
    left join lotes      lo  on lo.sku_base = u.sku_base
    left join accion     ac  on ac.sku_base = u.sku_base
    left join ped        pe  on pe.sku_base = u.sku_base
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
      'volumen', f.volumen,
      'unidad', f.unidad,
      'esGranel', f.es_granel,
      'codigos', f.codigos,
      'accionPerro', f.accion_perro,
      'grupo', f.grupo,
      'pedidoEstado', case when coalesce(f.ped_veces,0) > 0 then jsonb_build_object(
        'veces', f.ped_veces,
        'ultimoTs', to_char((f.ped_ultimo_ts at time zone 'America/Lima'), 'YYYY-MM-DD"T"HH24:MI:SS'),
        'dias', to_jsonb(f.ped_dias),
        'etiqueta', 'Pedido ' || coalesce(f.ped_etiqueta, 'hoy')
      ) else null end,
      'vencimientoProximo', case when f.venc_prox is null then null else jsonb_build_object(
        'fecha', to_char((f.venc_prox at time zone 'America/Lima')::date, 'YYYY-MM-DD'),
        'dias', ((f.venc_prox at time zone 'America/Lima')::date - v_hoy)) end,
      'countLotes', f.count_lotes
    ) order by f.brecha desc, f.volumen desc, f.stock_zona desc), '[]'::jsonb)
  ) into v_data
  from filas f
  where v_filtro = '' or v_filtro is null
     or (v_filtro = 'BRECHA' and f.brecha > 0)
     or (v_filtro = 'SIN_ROTACION' and f.tendencia = 'NULA')
     or (v_filtro in ('CRECIENTE','DECRECIENTE','ESTABLE') and f.tendencia = v_filtro)
     or (v_filtro in ('ESTRELLA','VACA','INTERROGANTE','PERRO') and f.bcg = v_filtro);

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$;
