-- ============================================================
-- 430 · [fix PGRST 400] REESCRITURA SIN TEMP TABLE de mos.analitica_grupo — analítica FUSIONADA almacén(WH) + zonas(ME) por grupo canónico
-- ============================================================
-- Dibujo v4 §07. Fusiona las dos rotaciones que hoy no se hablan:
--   · ALMACÉN: salidas por guías WH (desde wh.rotacion_cache, SQL 424) — con corte por zona destino.
--   · ZONAS:   ventas ME por zona (me.ventas.zona_id + me.ventas_detalle).
-- GRUPO EXTENDIDO (a diferencia de analitica_producto/119 que no suma satélites):
--   canónico + presentaciones (sku_base) + equivalencias activas
--   + DERIVADOS (codigo_producto_base → skuBase|idProducto del granel, patrón SQL 113/117)
--   + presentaciones y equivalencias de los derivados.
-- Todo normalizado a UNIDADES DEL CANÓNICO (kg si granel) — regla mos._venta_canonico (138):
--   venta por peso → cantidad directa · por unidad → × factor del miembro.
-- Zonas SIN ventas ME (ej. zona01 hoy): bloque estimada=true con DOS vías que se validan:
--   ① despachado a esa zona por guías (dato WH real) · ② diferencia (almacén − zonas con data).
-- Directriz: CERO GAS, CERO FALLBACK — RPC directa pura.
-- ============================================================

create or replace function mos.analitica_grupo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_cb   text := nullif(btrim(coalesce(p->>'codigoBarra','')),'');
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  -- [rev M2] fijo a 8: la cache de almacén (SQL 424) materializa exactamente 8 semanas;
  -- aceptar otra ventana haría que la doble vía almacén-vs-zonas compare periodos distintos.
  v_sem  int  := 8;
  v_alcance text[] := case when jsonb_typeof(p->'codigos')='array'
                       then array(select upper(btrim(x)) from jsonb_array_elements_text(p->'codigos') x where btrim(x)<>'')
                       else null end;
  v_id_canon text; v_cb_canon text; v_desc text; v_unidad text; v_es_peso boolean;
  v_ini timestamptz;
  v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- ── resolver el canónico del grupo ──────────────────────────────
  if v_sku is null and v_id is not null then
    select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) into v_sku
    from mos.productos pr where pr.id_producto = v_id limit 1;
  end if;
  if v_sku is null and v_cb is not null then
    -- [rev B6] normalizado upper(btrim()) como el resto del sistema
    select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) into v_sku
    from mos.productos pr where upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(v_cb)) limit 1;
    if v_sku is null then
      select e.sku_base into v_sku from mos.equivalencias e
      where upper(btrim(coalesce(e.codigo_barra,''))) = upper(btrim(v_cb)) and e.activo limit 1;
    end if;
  end if;
  if v_sku is null then return jsonb_build_object('ok',false,'error','PRODUCTO_NO_ENCONTRADO'); end if;

  -- [rev M3] si consultan por un DERIVADO (él es el único factor=1 de su propio grupo,
  -- pero tiene codigo_producto_base), SUBIR al granel padre: su analítica es la del grupo.
  declare v_padre text;
  begin
    select upper(btrim(coalesce(d.codigo_producto_base,''))) into v_padre
    from mos.productos d
    where (d.sku_base = v_sku or d.id_producto = v_sku)
      and coalesce(nullif(btrim(d.codigo_producto_base),''),'') <> ''
    limit 1;
    if coalesce(v_padre,'') <> '' then
      select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) into v_sku
      from mos.productos pr
      where upper(coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto)) = v_padre
         or upper(pr.id_producto) = v_padre
      limit 1;
    end if;
  end;

  select pr.id_producto, pr.codigo_barra, pr.descripcion, upper(coalesce(pr.unidad_medida,''))
    into v_id_canon, v_cb_canon, v_desc, v_unidad
  from mos.productos pr
  where (pr.sku_base = v_sku or pr.id_producto = v_sku)
    and coalesce(nullif(pr.factor_conversion,0),1) = 1
    and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
  order by pr.codigo_barra limit 1;
  if v_id_canon is null then return jsonb_build_object('ok',false,'error','CANONICO_NO_ENCONTRADO'); end if;

  v_es_peso := v_unidad in ('KGM','KG','LTR','L','MTR','M','GR','GMS','G','GRAMO','GRAMOS','KILO','KILOS','LITRO','LITROS');
  v_ini := ((date_trunc('week', now() at time zone 'America/Lima') at time zone 'America/Lima')
            - ((v_sem-1)::text||' weeks')::interval);

  -- ── ALMACÉN (cache SQL 424: por semana, por zona destino) ──────
  with _g_raw as (
    -- [430] grupo extendido como CTE (antes temp table: el plan cacheado + pool PostgREST
    -- reventaba con 'could not open relation' → HTTP 400 en el panel del dueño)
    select upper(btrim(pr.codigo_barra)) as cb,
           case when coalesce(nullif(pr.factor_conversion,0),1) = 1 then 'granel' else 'presentacion' end as tipo,
           pr.descripcion as nombre, coalesce(nullif(pr.factor_conversion,0),1) as f_canon, 0 as prio
    from mos.productos pr
    where (pr.sku_base = v_sku or pr.id_producto = v_sku)
      and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
      and coalesce(btrim(pr.codigo_barra),'') <> ''
    union all
    select upper(btrim(e.codigo_barra)), 'equivalente', coalesce(e.descripcion,'equivalente'), 1, 1
    from mos.equivalencias e
    where e.sku_base = v_sku and e.activo and coalesce(btrim(e.codigo_barra),'') <> ''
    union all
    select upper(btrim(d.codigo_barra)), 'derivado', d.descripcion, coalesce(nullif(d.factor_conversion_base,0),0), 2
    from mos.productos d
    where upper(btrim(coalesce(d.codigo_producto_base,''))) in (upper(v_sku), upper(v_id_canon))
      and coalesce(btrim(d.codigo_barra),'') <> ''
      and coalesce(nullif(d.factor_conversion_base,0),0) > 0
    union all
    select upper(btrim(pp.codigo_barra)), 'pres_derivado', pp.descripcion,
           coalesce(nullif(pp.factor_conversion,0),1) * coalesce(nullif(d.factor_conversion_base,0),0), 3
    from mos.productos d
    join mos.productos pp
      on (pp.sku_base = coalesce(nullif(btrim(d.sku_base),''), d.id_producto) or pp.sku_base = d.id_producto)
     and coalesce(nullif(pp.factor_conversion,0),1) > 1
    where upper(btrim(coalesce(d.codigo_producto_base,''))) in (upper(v_sku), upper(v_id_canon))
      and coalesce(nullif(d.factor_conversion_base,0),0) > 0
      and coalesce(btrim(pp.codigo_barra),'') <> ''
    union all
    select upper(btrim(e.codigo_barra)), 'equiv_derivado', coalesce(e.descripcion,'equiv derivado'),
           coalesce(nullif(d.factor_conversion_base,0),0), 4
    from mos.productos d
    join mos.equivalencias e
      on e.sku_base = coalesce(nullif(btrim(d.sku_base),''), d.id_producto) and e.activo
    where upper(btrim(coalesce(d.codigo_producto_base,''))) in (upper(v_sku), upper(v_id_canon))
      and coalesce(nullif(d.factor_conversion_base,0),0) > 0
      and coalesce(btrim(e.codigo_barra),'') <> ''
  ),
  _ag_grupo as (
    select distinct on (cb) cb, tipo, nombre, f_canon
    from _g_raw
    where (v_alcance is null or cb = any(v_alcance))
    order by cb, prio
  ),
  sem_lbl as (
    select w, to_char((v_ini + (w||' weeks')::interval) at time zone 'America/Lima','IYYY"-W"IW') as lbl
    from generate_series(0, v_sem-1) as w
  ),
  -- [rev M5] semanas COMPLETAS (la en-curso queda fuera de todo promedio/total)
  sem_cerradas as ( select lbl from sem_lbl where w < v_sem-1 ),
  alm as (  -- total (id_zona='') normalizado a canónico
    select rc.semana, sum(rc.unidades * g.f_canon) as cant
    from wh.rotacion_cache rc join _ag_grupo g on g.cb = rc.cod_producto
    where rc.id_zona = '' group by rc.semana
  ),
  alm_serie as (
    select sl.w, sl.lbl, coalesce(a.cant,0) as cant from sem_lbl sl left join alm a on a.semana = sl.lbl
  ),
  alm_forma as (
    select g.tipo, g.nombre, g.cb, sum(rc.unidades) as unidades, sum(rc.unidades * g.f_canon) as cant
    from wh.rotacion_cache rc join _ag_grupo g on g.cb = rc.cod_producto
    where rc.id_zona = '' group by g.tipo, g.nombre, g.cb
  ),
  alm_zona as (  -- despachos por zona destino (para la estimación doble vía)
    -- [rev M2b+M5] solo semanas COMPLETAS de la ventana — misma base que cantSem
    -- para que la doble vía (despachado vs diferencia) compare periodos idénticos
    select rc.id_zona, sum(rc.unidades * g.f_canon) as cant
    from wh.rotacion_cache rc join _ag_grupo g on g.cb = rc.cod_producto
    where rc.id_zona <> ''
      and rc.semana in (select lbl from sem_lbl where w < v_sem-1)
    group by rc.id_zona
  ),
  -- ── ZONAS (ventas ME reales, por zona_id) ────────────────────────
  vta as (
    select coalesce(nullif(btrim(v.zona_id),''),'SIN_ZONA') as zona,
           to_char(v.fecha at time zone 'America/Lima','IYYY"-W"IW') as sem,
           g.tipo, g.nombre, g.cb,
           sum(coalesce(d.cantidad,0)) as unidades,
           sum(case when upper(coalesce(d.unidad_medida,'')) in
                    ('KGM','KG','LTR','L','MTR','M','GR','GMS','G','GRAMO','GRAMOS','KILO','KILOS','LITRO','LITROS')
                    then coalesce(d.cantidad,0)
                    else coalesce(d.cantidad,0) * g.f_canon end) as cant,
           sum(coalesce(d.subtotal, d.cantidad * d.precio, 0)) as soles
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    -- [rev C2] cod_barras-o-sku con COALESCE (precedente SQL 126): el IN doblaba la línea
    -- cuando cod_barras=equivalente y sku=canónico matcheaban miembros distintos → 2x soles.
    join _ag_grupo g on g.cb = upper(btrim(coalesce(nullif(btrim(d.cod_barras),''), d.sku)))
    where v.fecha >= v_ini and v.fecha <= now()
      -- [rev M1] not like 'ANULADO%': ANULADO_CONVERSION (NV→CPE) contaba doble
      -- (mismo bug ya corregido 2 veces en el repo: SQL 111 y 264).
      and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
    group by 1, 2, 3, 4, 5
  ),
  vta_zona_sem as ( select zona, sem, sum(cant) as cant, sum(soles) as soles from vta group by zona, sem ),
  -- [rev M5] totales de zona solo con semanas completas (porSemana sí muestra la actual)
  vta_zona_tot as ( select zona, sum(cant) as cant, sum(soles) as soles from vta
                    where sem in (select lbl from sem_cerradas) group by zona ),
  vta_zona_forma as ( select zona, tipo, nombre, cb, sum(unidades) as unidades, sum(cant) as cant from vta group by 1,2,3,4 ),
  -- [rev M5] tendencia almacén: últimas 4 semanas COMPLETAS vs las 3 anteriores
  -- (la semana en curso está parcial — un lunes desplomaba prom4 ~25% y sub-pedía)
  tend as (
    select avg(cant) filter (where w between v_sem-5 and v_sem-2) as prom4,
           avg(cant) filter (where w between v_sem-8 and v_sem-6) as prom4ant
    from alm_serie
  ),
  stockg as (
    select coalesce(sum(coalesce(s.cantidad_disponible,0) * g.f_canon),0) as stock_canon
    from wh.stock s join _ag_grupo g on g.cb = upper(btrim(s.cod_producto))
  )
  select jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'skuBase', v_sku, 'idCanonico', v_id_canon, 'descripcion', v_desc,
      'unidadCanon', case when v_es_peso then 'kg' else 'u' end,
      'semanas', v_sem,
      'etiquetas', (select jsonb_agg(lbl order by w) from sem_lbl),
      'grupo', (select jsonb_agg(jsonb_build_object('cb',cb,'tipo',tipo,'nombre',nombre,'factor',f_canon)) from _ag_grupo),
      'almacen', jsonb_build_object(
        'cantSem', round(coalesce((select sum(cant) filter (where w < v_sem-1) from alm_serie),0) / (v_sem-1), 2),
        'porSemana', (select jsonb_agg(jsonb_build_object('semana',lbl,'cant',round(cant,2)) order by w) from alm_serie),
        'porForma', coalesce((select jsonb_agg(jsonb_build_object('tipo',tipo,'nombre',nombre,'cb',cb,
                              'unidades',round(unidades,2),'cant',round(cant,2)) order by cant desc) from alm_forma),'[]'::jsonb),
        'porZonaDespacho', coalesce((select jsonb_object_agg(id_zona, round(cant / (v_sem-1), 2)) from alm_zona),'{}'::jsonb),
        'tendenciaPct', (select case when coalesce(prom4ant,0) > 0
                                     then round((prom4/prom4ant - 1) * 100)
                                     else null end from tend)
      ),
      'zonasReales', coalesce((select jsonb_object_agg(z.zona, jsonb_build_object(
          'cantSem', round(z.cant / (v_sem-1), 2),
          'solesSem', round(z.soles / (v_sem-1), 2),
          'porSemana', (select jsonb_agg(jsonb_build_object('semana',sl.lbl,'cant',round(coalesce(vz.cant,0),2)) order by sl.w)
                        from sem_lbl sl left join vta_zona_sem vz on vz.zona = z.zona and vz.sem = sl.lbl),
          'porForma', coalesce((select jsonb_agg(jsonb_build_object('tipo',f.tipo,'nombre',f.nombre,'cb',f.cb,
                                'unidades',round(f.unidades,2),'cant',round(f.cant,2)) order by f.cant desc)
                                from vta_zona_forma f where f.zona = z.zona),'[]'::jsonb)
        )) from vta_zona_tot z),'{}'::jsonb),
      'insight', jsonb_build_object(
        'stockCanon', round((select stock_canon from stockg), 2),
        'coberturaSem', case when coalesce((select sum(cant) from alm_serie),0) > 0
                             then round((select stock_canon from stockg) /
                                        ((select sum(cant) from alm_serie) / v_sem), 1)
                             else null end,
        'sugerenciaPedido', greatest(0, round(
          coalesce((select prom4 from tend),0) * 1.2 - (select stock_canon from stockg), 1))
      )
    )
  ) into v_out;

  return v_out;
end; $fn$;

revoke all on function mos.analitica_grupo(jsonb) from public, anon;
grant execute on function mos.analitica_grupo(jsonb) to authenticated, service_role;
