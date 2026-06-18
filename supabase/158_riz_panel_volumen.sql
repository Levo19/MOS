-- 155_riz_panel_volumen.sql — [RIZ · BCG VOLUMEN] — me.zona_panel ahora devuelve `volumen` por item.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBLEMA: me.zona_panel NO emitía `volumen` (el eje X de la BCG = unidades base vendidas en la ventana).
--   El frontend (app.js _zonaNormItem) ya intenta leer p.volumen ("El panel no trae volumen; rotacion = volumen
--   si vino, si no 0"), y las burbujas de la Matriz BCG dimensionan por `rotacion`. Sin volumen, TODAS las
--   burbujas salen del mismo tamaño (planas) y _zonaBCGClase no puede derivar _volAlto.
-- FIX: agregar `volumen` al item, leído de me.zona_esperado.volumen_4sem (ya materializado por el recompute /
--   cron — la MISMA fuente del eje X de la BCG en me._riz_picos). Es ADITIVO: no cambia ningún campo existente.
--   El backend ya calcula bcg server-side (me._riz_picos vs mediana de la zona), así que el cuadrante NO depende
--   de este campo; volumen es para el TAMAÑO de la burbuja + sort. Backward-compatible 100%.
--
-- REDEFINE me.zona_panel = la versión de 135 (CAMBIOS 1/2/3 intactos) + 'volumen'. El wrapper mos.zona_panel
--   (132/135) es pass-through puro → NO se toca (sigue devolviendo lo que me.zona_panel emita).
-- PATRÓN intacto: security definer · search_path='' · gate mos._claim_ok() · || mos._frescura_sombra().
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function me.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_filtro text := upper(btrim(coalesce(p->>'filtro','')));
  v_hoy    date := (now() at time zone 'America/Lima')::date;
  v_data   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  with
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
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
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) as cant
    from wh.stock s
    join cb_sku cs on cs.cb = upper(btrim(s.cod_producto))
    group by cs.sku
  ),
  lotes as (
    select l.sku_base, min(l.fecha_vencimiento) as venc_prox, count(*) as n
    from me.zona_lotes l
    where upper(btrim(l.zona_id)) = v_zona and coalesce(l.cant_restante,0) > 0
    group by l.sku_base
  ),
  -- esperado materializado (AHORA también volumen_4sem → eje X de la BCG / tamaño de burbuja).
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.bcg, e.picos, e.volumen_4sem
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  -- decisión BCG-perro vigente del admin (SQL 157): PROMOCIONAR|GONDOLA|REMATAR. Informativo, no muta nada.
  accion as (
    select a.sku_base, a.accion from me.zona_accion_perro a where upper(btrim(a.zona_id)) = v_zona
  ),
  universo as (
    select sku_base from esp union select sku_base from cod_arr
  ),
  filas as (
    select
      u.sku_base,
      coalesce(sm.descripcion, u.sku_base) as descripcion,
      coalesce(ca.stock_zona, 0) as stock_zona,
      coalesce(es.esperado, 0) as esperada,
      greatest(0, coalesce(es.esperado, 0) - greatest(coalesce(ca.stock_zona, 0), 0)) as brecha,
      (coalesce(ca.stock_zona, 0) < 0) as stock_negativo,
      coalesce(sa.cant, 0) as stock_almacen,
      coalesce(es.tendencia, 'NULA') as tendencia,
      coalesce(es.bcg, 'PERRO') as bcg,
      coalesce(es.picos, '[]'::jsonb) as picos,
      coalesce(es.volumen_4sem, 0) as volumen,                                  -- BCG VOLUMEN (eje X)
      lo.venc_prox,
      coalesce(lo.n, 0) as count_lotes,
      coalesce(sm.unidad, '') as unidad,
      me._riz_es_granel(sm.unidad, sm.factor) as es_granel,
      coalesce(ca.codigos, '[]'::jsonb) as codigos,
      ac.accion as accion_perro
    from universo u
    left join sku_meta   sm on sm.sku = u.sku_base
    left join cod_arr    ca on ca.sku_base = u.sku_base
    left join esp        es on es.sku_base = u.sku_base
    left join stock_alm  sa on sa.sku_base = u.sku_base
    left join lotes      lo on lo.sku_base = u.sku_base
    left join accion     ac on ac.sku_base = u.sku_base
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
      'volumen', f.volumen,                                                     -- BCG VOLUMEN
      'unidad', f.unidad,
      'esGranel', f.es_granel,
      'codigos', f.codigos,
      'accionPerro', f.accion_perro,                                            -- decisión BCG-perro vigente (157)
      'vencimientoProximo', case when f.venc_prox is null then null else jsonb_build_object(
        'fecha', to_char((f.venc_prox at time zone 'America/Lima')::date, 'YYYY-MM-DD'),
        'dias', ((f.venc_prox at time zone 'America/Lima')::date - v_hoy)) end,
      'countLotes', f.count_lotes
    ) order by f.brecha desc, f.volumen desc, f.stock_zona desc), '[]'::jsonb)  -- sort secundario por volumen
  ) into v_data
  from filas f
  where v_filtro = '' or v_filtro is null
     or (v_filtro = 'BRECHA' and f.brecha > 0)
     or (v_filtro = 'SIN_ROTACION' and f.tendencia = 'NULA')
     or (v_filtro in ('CRECIENTE','DECRECIENTE','ESTABLE') and f.tendencia = v_filtro)
     or (v_filtro in ('ESTRELLA','VACA','INTERROGANTE','PERRO') and f.bcg = v_filtro);

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_panel(jsonb) from public;
grant execute on function me.zona_panel(jsonb) to service_role, authenticated;
