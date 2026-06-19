-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 189_riz_panel_almacen_ventana_4iso.sql
-- 🎯 UNIFICACIÓN VENTANA · me.zona_panel rama ALMACEN → universo en "4 semanas ISO CERRADAS" (lunes_actual-28 ..
--    lunes_actual-1), IDÉNTICA a me._riz_picos / el objetivo del propio panel / el ticket (188). SOLO LECTURA.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 ASIMETRÍA (verificada): la rama ALMACEN del panel construía el UNIVERSO (desp_uni) con una ventana rolling-28
--    anclada a HOY (v_desde_uni = hoy-28 .. v_hoy) PERO el OBJETIVO/serie de picos (desp_dia/sem/...) usa la ventana
--    4-ISO-CERRADA (v_desde_obj .. v_hasta_obj). Universo y objetivo en ventanas distintas → un sku despachado solo
--    en la semana EN CURSO entraba al universo (con esperada=0/tendencia=NULA por no tener picos en la ventana ISO),
--    desalineando el panel respecto del ticket (188) y de _riz_picos.
--
-- ✅ FIX (additivo, SOLO LECTURA — no toca stock/escritura/dinero/sync/flags; firma y shape intactos): el UNIVERSO
--    de despacho (desp_base, y por ende desp_uni) usa AHORA la MISMA ventana 4-ISO-CERRADA (v_desde_obj..v_hasta_obj)
--    que el objetivo. Resultado: universo == despacho-4-ISO ∪ wh.stock (la rama de stock NO cambia). ZONA (no almacén)
--    NO cambia (sigue por snapshot me.zona_esperado / me.stock_zonas). El campo `grupo` (ROTADO/PARADO), objetivo,
--    tendencia y BCG conservan su matemática; solo se recorta la semana en curso del universo para alinear todo.
--    Se elimina la variable v_desde_uni (ya no se usa). IDEMPOTENTE (create or replace).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

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
  -- ventana ÚNICA (universo + objetivo) = 4 semanas ISO CERRADAS — misma técnica que me._riz_picos / ticket 188.
  -- La semana EN CURSO NO cuenta (estable lun-dom; avanza solo el lunes).
  v_lunes_act  date := (date_trunc('week', (now() at time zone 'America/Lima'))::date);
  v_desde_obj  date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) - 28;  -- 4 sem antes del lunes actual
  v_hasta_obj  date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) - 1;    -- domingo de la última sem cerrada
  v_umbral     numeric := 0.10;  -- mismo umbral de tendencia que _riz_picos/zona_esperado
  v_colchon    numeric := 0.20;  -- mismo colchón (×1.2) que 137/128
  v_data       jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  with
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
  -- mapa cod_barra → (skuBase, descripción del código, esEquivalente) — IDÉNTICO a 173 (incluye presentaciones).
  cb_sku as (
    select distinct on (cb) cb, sku, cb_desc, es_equiv from (
      select upper(btrim(p2.codigo_barra)) cb,
             coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             nullif(btrim(p2.descripcion),'') cb_desc,
             false es_equiv, 0 ord
        from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
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
  -- ── STOCK DE ZONA (me.stock_zonas) — para ZONAS normales (IDÉNTICO a 173) ──────────────────────────────────
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
  -- ── STOCK DE ALMACÉN (wh.stock) — por (skuBase, código). Para ALMACEN es el stock de zona; para todas las
  --    zonas es el campo informativo stockAlmacen/codigos[] de almacén. (Mismo origen que 173: stock_alm.) ────
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
  -- "tiene stock en almacén" = al menos una barra (base/equiv) está en wh.stock con saldo <> 0.
  sku_stock_alm as (
    select sku_base from stock_alm_cod group by sku_base having sum(coalesce(cant,0)) <> 0
  ),
  -- ── DESPACHO del almacén (4 sem ISO CERRADAS) por skuBase — SOLO se usa en rama ALMACEN ───────────────────
  --    Universo Y serie de picos comparten la MISMA ventana 4-ISO-CERRADA (v_desde_obj..v_hasta_obj) → sin asimetría.
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
  -- universo despacho = cualquier sku con despacho en la ventana 4-ISO-CERRADA.
  desp_uni as (
    select distinct sku_base from desp_base
  ),
  -- serie semanal para el objetivo: SOLO días dentro de la ventana ISO CERRADA (4 sem).
  desp_dia as (
    select sku_base, dia, sum(u) as u_dia
    from desp_base
    where dia >= v_desde_obj and dia <= v_hasta_obj
    group by sku_base, dia
  ),
  -- pico diario por (sku, semana ISO) + volumen semanal.
  desp_sem as (
    select sku_base, to_char(dia,'IYYY"-W"IW') as sem, max(u_dia) as pico_sem, sum(u_dia) as vol_sem
    from desp_dia group by sku_base, to_char(dia,'IYYY"-W"IW')
  ),
  -- semanas de la ventana (4 ISO cerradas), densas (w=0 la más antigua .. 3 la más reciente).
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
  -- objetivo + tendencia + bcg del almacén (misma matemática que me._riz_picos).
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
  -- esperado materializado (VENTAS) — para ZONAS (IDÉNTICO a 173).
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.bcg, e.picos, e.volumen_4sem
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  accion as (
    select a.sku_base, a.accion from me.zona_accion_perro a where upper(btrim(a.zona_id)) = v_zona
  ),
  -- pedido persistido (ventana 7 días) — IDÉNTICO a 173.
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
  -- ── UNIVERSO ─────────────────────────────────────────────────────────────────────────────────────────────
  --   ALMACEN  = despacho 4 sem ∪ stock(wh.stock<>0).            (NO usa esp/cod_arr — son de ventas/zona)
  --   ZONAS    = esperado(ventas) ∪ stock de zona (me.stock_zonas).  (IDÉNTICO a 173)
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
      -- stockZona EFECTIVO: ALMACEN ⇒ stock de almacén (alm_arr) ; zonas ⇒ cod_arr (me.stock_zonas).
      (case when v_es_almacen then coalesce(aa.stock_almacen, 0) else coalesce(ca.stock_zona, 0) end) as stock_zona,
      -- esperada: ALMACEN ⇒ objetivo de despacho ; zonas ⇒ esperado materializado (ventas).
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
      -- codigos[] EFECTIVO: ALMACEN ⇒ desglose de almacén ; zonas ⇒ cod_arr.
      (case when v_es_almacen then coalesce(aa.codigos_almacen, '[]'::jsonb) else coalesce(ca.codigos, '[]'::jsonb) end) as codigos,
      ac.accion as accion_perro,
      pe.veces      as ped_veces,
      pe.ultimo_ts  as ped_ultimo_ts,
      pe.dias       as ped_dias,
      pe.etiqueta_dias as ped_etiqueta,
      -- ⭐ grupo: ROTADO si rotó en 4 sem (ALMACEN ⇒ despacho>0 ; ZONA ⇒ volumen ventas>0) ; PARADO si está
      --   por stock pero sin rotación. Mutuamente excluyentes (rotó → ROTADO aunque tenga stock).
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
revoke all on function me.zona_panel(jsonb) from public;
grant execute on function me.zona_panel(jsonb) to service_role, authenticated;
