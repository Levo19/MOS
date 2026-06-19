-- 192_riz_grupo_canonico_equiv_sin_presentaciones.sql
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- TANDA 1/2 · Mejoras al ajuste de stock del módulo Zona/RIZ (MOS). App de DINERO en PROD.
--
-- CAMBIO A — Grupo de stock de un producto = CANÓNICO + EQUIVALENTES, **NUNCA presentaciones**.
--   El stock por producto en `me.stock_zonas` se calcula sumando el grupo de códigos. Hasta ahora el grupo
--   incluía TODOS los codigo_barra de mos.productos del sku_base — incluidas las PRESENTACIONES (tipo_producto
--   = 'PRESENTACION'), que son sólo una forma de empaque/venta y NO un código de inventario independiente. Eso
--   inflaba/deflactaba el "Stock zona". Ej.: MAGGI LEV1181 ZONA-02 → canónico 7613036452878=0 + equiv
--   8445291365872=−4 ⇒ correcto −4, pero el panel mostraba −13 porque sumaba la presentación PRE346=−9.
--
--   Fix: en me.zona_panel (CTE cb_sku) y en me.zona_kardex_historial (v_codes) la rama de mos.productos
--   EXCLUYE tipo_producto='PRESENTACION'. Los equivalentes (mos.equivalencias) entran igual. Aditivo: no cambia
--   el shape JSON, ni la rama ALMACEN (que usa wh.stock por los mismos códigos), ni ZONA-01.
--
-- LIMPIEZA money-data — anular (set 0) los stocks FANTASMA de presentaciones en me.stock_zonas.
--   Son basura legacy del sync viejo. CONDICIÓN DE SEGURIDAD: sólo se anulan filas cuyo cod_barras
--     (a) mapea EXCLUSIVAMENTE a presentaciones en mos.productos (ningún canónico/derivado con ese código),
--     (b) NO es un equivalente activo, y
--     (c) NO tiene NINGÚN movimiento en me.stock_movimientos (kardex) → es 100% fantasma sin historia.
--   Las presentaciones que SÍ tienen movimientos (p.ej. ventas recientes que descontaron el código de
--   presentación tal cual) se DEJAN INTACTAS — son un bug aparte de me.zona_descontar_venta (no normaliza
--   presentación→canónico), que se atiende en TANDA 2. Idempotente (sólo toca cantidad<>0) y registrado en
--   me.riz_limpieza_presentaciones_log para reversibilidad total.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────

set search_path to '';

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ PARTE 1 · me.zona_panel — grupo de códigos EXCLUYE presentaciones (rama canónico de cb_sku).               ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
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
  --       (tipo_producto='PRESENTACION'): no son códigos de inventario, sólo empaque/venta. Antes inflaban
  --       el "Stock zona" sumando un saldo fantasma de presentación (ej. MAGGI PRE346).
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
  stock_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           sum(coalesce(z.cantidad,0)) as cant
    from cb_sku cs
    join me.stock_zonas z on upper(btrim(z.cod_barras)) = cs.cb
    where upper(btrim(z.zona_id)) in (select alias from zona_aliases)
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
  stock_alm_cod as (
    select cs.sku as sku_base, cs.cb as cod_barra, cs.cb_desc, cs.es_equiv,
           sum(coalesce(s.cantidad_disponible,0)) as cant,
           count(s.cod_producto) as filas_alm
    from cb_sku cs
    join wh.stock s on upper(btrim(s.cod_producto)) = cs.cb
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
    select sku_base from cod_arr         where not v_es_almacen
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

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ PARTE 2 · me.zona_kardex_historial — v_codes (grupo del skuBase) EXCLUYE presentaciones.                   ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
-- Sólo cambia la resolución de v_codes para la ruta por skuBase: el grupo = canónico + (vía el panel) equiv,
-- excluyendo presentaciones. (La ruta por codBarra explícito sigue consultando ese código tal cual.)
-- IMPORTANTE: además del canónico de mos.productos, el grupo del historial DEBE incluir los EQUIVALENTES
-- (mos.equivalencias) para cuadrar con el "Stock zona" del panel (que suma canónico+equiv). Antes v_codes sólo
-- traía mos.productos del sku → con equivalencias el saldo histórico no cuadraba con stock_zonas del grupo.
CREATE OR REPLACE FUNCTION me.zona_kardex_historial(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_cod    text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_codes  text[];
  v_movs   jsonb := '[]'::jsonb;
  v_ev     me._kardex_evento[];
  v_e      me._kardex_evento;
  v_run    numeric(20,3);
  v_antes  numeric(20,3);
  v_sal    numeric(20,3);
  v_acc    jsonb := '[]'::jsonb;
  v_saldo_final numeric(20,3);
  v_stock_zonas numeric(20,3);
  v_base   numeric(20,3);
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  if v_cod is not null then
    v_codes := array[upper(btrim(v_cod))];
  elsif v_sku is not null then
    -- [192] grupo = canónico (mos.productos, EXCLUYE PRESENTACION) ∪ equivalentes activos (mos.equivalencias).
    --        Coincide con el grupo del "Stock zona" del panel → el saldo histórico cuadra con stock_zonas.
    select coalesce(array_agg(distinct cb), array[]::text[]) into v_codes
      from (
        select upper(btrim(pr.codigo_barra)) cb
          from mos.productos pr
         where pr.sku_base = v_sku
           and nullif(btrim(pr.codigo_barra),'') is not null
           and pr.tipo_producto::text is distinct from 'PRESENTACION'
        union
        select upper(btrim(e.codigo_barra))
          from mos.equivalencias e
         where e.sku_base = v_sku
           and coalesce(e.activo,true)
           and nullif(btrim(e.codigo_barra),'') is not null
      ) t;
    if coalesce(array_length(v_codes,1),0) = 0 then
      return jsonb_build_object('ok',false,'error','skuBase sin codigo_barra (canónico/equivalente) en catálogo');
    end if;
    v_cod := v_codes[1];
  else
    return jsonb_build_object('ok',false,'error','Requiere codBarra o skuBase');
  end if;

  with
  dias_reconc as (
    select distinct date(gc.fecha at time zone 'America/Lima') as dia
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and gc.tipo = 'SALIDA_VENTAS' and upper(btrim(gd.cod_barras)) = any(v_codes)
  ),
  eventos as (
    select al.ts                       as fecha,
           'AJUSTE'::text              as tipo,
           al.delta                    as delta,
           al.stock_despues            as saldo_set,
           true                        as es_set,
           true                        as aplicado,
           coalesce(al.usuario,'—')    as usuario,
           ''                          as id_guia,
           'ajuste'                    as fuente
      from me.zona_ajuste_log al
     where al.zona_id = v_zona and upper(btrim(al.cod_barras)) = any(v_codes)
    union all
    select a.fecha,
           'AUDITORIA'::text,
           (a.cant_real - a.cant_sistema),
           a.cant_real,
           true,
           true,
           coalesce(a.vendedor,'—'),
           '',
           'auditoria'
      from me.auditorias a
     where a.zona_id = v_zona and upper(btrim(a.cod_barras)) = any(v_codes)
    union all
    select gc.fecha,
           case
             when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then 'TRASLADO_IN'
             when gc.tipo = 'SALIDA_VENTAS' then 'SALIDA_VENTA'
             when gc.tipo = 'SALIDA_JEFA' then 'SALIDA_JEFA'
             when gc.tipo like 'SALIDA%' then 'TRASLADO_OUT'
             else 'SALIDA_JEFA'
           end,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%'
                then gd.cantidad else -gd.cantidad end,
           null::numeric,
           false,
           true,
           coalesce(gc.vendedor,'—'),
           gc.id_guia,
           'guia'
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and upper(btrim(gd.cod_barras)) = any(v_codes)
    union all
    select v.fecha,
           'SALIDA_VENTA'::text,
           -vd.cantidad,
           null::numeric,
           false,
           (date(v.fecha at time zone 'America/Lima') not in (select dia from dias_reconc)) as aplicado,
           coalesce(v.vendedor,'—'),
           v.id_venta,
           case when date(v.fecha at time zone 'America/Lima') in (select dia from dias_reconc)
                then 'venta' else 'venta-pendiente' end
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where v.zona_id = v_zona and upper(btrim(vd.cod_barras)) = any(v_codes)
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  )
  select array_agg(
           row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
           order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
         into v_ev
    from eventos e;

  -- stock_zonas real (suma sobre el grupo de códigos) — META DE CUADRE.
  select coalesce(sum(cantidad),0) into v_stock_zonas
    from me.stock_zonas where upper(btrim(cod_barras)) = any(v_codes) and upper(btrim(zona_id)) = v_zona;

  v_run := 0;
  if v_ev is not null then
    foreach v_e in array v_ev loop
      v_antes := v_run;
      if (v_e).es_set then
        v_run := (v_e).saldo_set;
        v_sal := v_run;
      elsif (v_e).aplicado then
        v_run := v_run + (v_e).delta;
        v_sal := v_run;
      else
        v_sal := v_run;
      end if;
      v_acc := v_acc || jsonb_build_object(
        'idGuia',        (v_e).id_guia,
        'fecha',         (v_e).fecha,
        'tipo',          me._kardex_label((v_e).tipo, (v_e).delta),
        'tipoOperacion', (v_e).tipo,
        'esIngreso',     ((v_e).delta > 0),
        'cantidad',      abs((v_e).delta),
        'saldo',         v_sal,
        'stockAntes',    v_antes,
        'usuario',       (v_e).usuario,
        'origen',        '',
        'estado',        case when (v_e).fuente = 'venta-pendiente' then 'ABIERTA' else 'CERRADA' end,
        'pendiente',     ((v_e).fuente = 'venta-pendiente'),
        'fuente',        case when (v_e).tipo in ('AJUSTE','AUDITORIA') then 'ajuste'
                              when (v_e).fuente = 'venta-pendiente' then 'venta' else (v_e).fuente end,
        'aplicado',      (v_e).aplicado,
        'idLote',        null);
    end loop;
  end if;

  v_base := round(v_stock_zonas - v_run, 3);
  if v_base <> 0 then
    v_antes := v_run;
    v_run := v_stock_zonas;
    v_acc := v_acc || jsonb_build_object(
      'idGuia', '', 'fecha', now(),
      'tipo', 'CUADRE con stock real (saldo histórico previo)', 'tipoOperacion', 'AJUSTE',
      'esIngreso', (v_base > 0), 'cantidad', abs(v_base),
      'saldo', v_run, 'stockAntes', v_antes, 'usuario', 'sistema-cuadre', 'origen', '',
      'estado', 'CERRADA', 'pendiente', false, 'fuente', 'ajuste', 'aplicado', true, 'idLote', null);
  end if;

  select coalesce(jsonb_agg(elem order by ord desc), '[]'::jsonb) into v_movs
    from jsonb_array_elements(v_acc) with ordinality as t(elem, ord);

  v_saldo_final := v_run;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'reconstruido', true, 'totalMovimientos', jsonb_array_length(v_movs),
      'saldoFinal', v_saldo_final, 'stockZonas', v_stock_zonas,
      'cuadra', (round(v_saldo_final,3) = round(v_stock_zonas,3)),
      'movimientos', v_movs)) || mos._frescura_sombra();
end;
$function$;

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ PARTE 3 · LIMPIEZA money-data — anular stocks FANTASMA de presentaciones (sin kardex), registrado.         ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
-- Log de reversibilidad: guarda qué (cod_barras, zona_id, cantidad) se anuló y cuándo.
create table if not exists me.riz_limpieza_presentaciones_log (
  id            bigserial primary key,
  cod_barras    text not null,
  zona_id       text not null,
  cantidad_prev numeric not null,   -- valor que tenía antes de anular (para revertir: set cantidad = cantidad_prev)
  motivo        text not null default 'presentacion-fantasma-sin-kardex',
  ts            timestamptz not null default now()
);

do $cleanup$
declare
  v_n int;
begin
  with
  cod_map as (
    select upper(btrim(p.codigo_barra)) cb,
           bool_or(p.tipo_producto::text is distinct from 'PRESENTACION') as es_no_pres
      from mos.productos p
     where nullif(btrim(p.codigo_barra),'') is not null
     group by upper(btrim(p.codigo_barra))
  ),
  equiv as (
    select distinct upper(btrim(e.codigo_barra)) cb
      from mos.equivalencias e
     where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null
  ),
  con_movs as (
    select distinct upper(btrim(m.cod_barra)) cb from me.stock_movimientos m
  ),
  -- Filas a anular: el código mapea SÓLO a presentación, NO es equivalente, NO tiene kardex, y cantidad<>0.
  objetivo as (
    select z.cod_barras, z.zona_id, z.cantidad
      from me.stock_zonas z
      join cod_map cm on cm.cb = upper(btrim(z.cod_barras))
     where cm.es_no_pres = false
       and upper(btrim(z.cod_barras)) not in (select cb from equiv)
       and upper(btrim(z.cod_barras)) not in (select cb from con_movs)
       and coalesce(z.cantidad,0) <> 0
  ),
  registro as (
    insert into me.riz_limpieza_presentaciones_log (cod_barras, zona_id, cantidad_prev)
    select o.cod_barras, o.zona_id, o.cantidad from objetivo o
    returning cod_barras, zona_id
  )
  update me.stock_zonas z
     set cantidad = 0, usuario = 'sistema-limpieza-192', fecha_ultimo_registro = now()
    from registro r
   where z.cod_barras = r.cod_barras and z.zona_id = r.zona_id;
  get diagnostics v_n = row_count;
  raise notice '[192] presentaciones fantasma anuladas: % filas', v_n;
end;
$cleanup$;
