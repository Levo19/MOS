-- 615 · Correcciones de la revisión adversarial sobre 614 (todas verificadas en prod).
--
-- H1 · 195 de 746 productos-proveedor (26%) NO entraban: el join era SOLO por codigo_barra
--      y muchos catálogos guardan el código con ceros a la izquierda distintos o el
--      id_producto. Se agrega match por sku_base (193 de los 195 se rescatan así).
--      Un proveedor entero (PROV005, celofanes) quedaba en cero.
-- H2 · El faltante decía "cómprale al proveedor" cuando lo que faltaba era ENVASAR:
--      si el granel padre tiene stock y la bolsita está en cero, la card se contradecía
--      (barra verde "cubre 8 sem" + botón rojo "compra 3.6 kg"). Caso real WHCOLFNO.
--      Ahora se separa: faltaEnvasarEq (lo cubre el granel propio) y faltaComprarEq
--      (lo que de verdad hay que pedirle al proveedor).
-- H3 · Se emite `unidad` del padre: 267 de 341 productos son NIU (unidades), no kg —
--      el front escribía "falta 1,003.13 kg" de margarina en barras.
-- H4 · Faltantes absurdos por stock corrupto (−5178 → "necesita 5179 kg"). Se topa a
--      8 semanas de demanda y se marca `stockCorrupto` para que el front lo muestre
--      como "stock a corregir" y no como un pedido real.
-- H5 · Las ventas de PRESENTACIONES (packs/fracciones) no contaban en la demanda de la
--      zona (se ligan por sku_base, no por codigo_producto_base) → cobertura inflada.
--      Ahora suman demanda (no stock: no son inventario propio).
-- M1 · Las devoluciones de zona ahora NETEAN la demanda del almacén (826 unidades
--      devueltas en la ventana inflaban la compra hasta 2.8×).
-- M3 · Se excluyen guías ANULADAS (hoy 0, pero la próxima anulación inflaría la compra).
-- M4 · Se excluyen zonas MOCK/FALLBACK (aparecían como una tienda más con "falta 1 kg").

create or replace function mos.prov_stock_ubicaciones(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
declare
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_desde date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) - 28;
  v_hasta date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) - 1;
  v_tope  numeric := 8;    -- [H4] tope del faltante = 8 semanas de demanda
  v_out   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_prov is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;

  with
  -- [H1] padre = por codigo_barra O por sku_base (26% se perdía por el match estricto)
  padres as (
    select distinct on (pp.id_pp)
           upper(btrim(pr.codigo_barra)) as padre_cb,
           coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) as padre_sku,
           pr.descripcion as padre_desc,
           upper(coalesce(nullif(btrim(pr.unidad),''),'NIU')) as padre_unidad
      from mos.proveedores_productos pp
      join mos.productos pr
        on upper(btrim(pr.codigo_barra)) = upper(btrim(pp.codigo_barra))
        or coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = btrim(pp.sku_base)
     where pp.id_proveedor = v_prov
       and coalesce(pp.activa, true)
       and nullif(btrim(pr.codigo_barra),'') is not null
     order by pp.id_pp,
              -- prioriza el match exacto por código y el CANONICO
              (upper(btrim(pr.codigo_barra)) = upper(btrim(pp.codigo_barra))) desc,
              (pr.tipo_producto::text = 'CANONICO') desc,
              pr.codigo_barra
  ),
  -- familia: padre (factor 1) + equivalentes (factor 1) + derivados (factor real).
  -- [H5] + presentaciones: NO son inventario (no suman stock) pero SÍ demanda.
  familia as (
    select pa.padre_cb, pa.padre_sku, pa.padre_desc, pa.padre_unidad,
           pa.padre_cb as cod, pa.padre_desc as nombre, 1::numeric as factor,
           true as es_padre, false as solo_demanda, 0 as orden
      from padres pa
    union all
    select pa.padre_cb, pa.padre_sku, pa.padre_desc, pa.padre_unidad,
           upper(btrim(e.codigo_barra)), coalesce(nullif(btrim(e.descripcion),''), pa.padre_desc),
           1::numeric, false, false, 1
      from padres pa
      join mos.equivalencias e on btrim(e.sku_base) = pa.padre_sku
     where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null
    union all
    select pa.padre_cb, pa.padre_sku, pa.padre_desc, pa.padre_unidad,
           upper(btrim(d.codigo_barra)), d.descripcion,
           coalesce(nullif(d.factor_conversion_base,0), 1)::numeric, false, false, 2
      from padres pa
      join mos.productos d on btrim(d.codigo_producto_base) = pa.padre_sku
     where nullif(btrim(d.codigo_barra),'') is not null
       and d.tipo_producto::text is distinct from 'PRESENTACION'
       and upper(btrim(d.codigo_barra)) <> pa.padre_cb
    union all
    select pa.padre_cb, pa.padre_sku, pa.padre_desc, pa.padre_unidad,
           upper(btrim(pz.codigo_barra)), pz.descripcion,
           coalesce(nullif(pz.factor_conversion,0), 1)::numeric, false, true, 3
      from padres pa
      join mos.productos pz on coalesce(nullif(btrim(pz.sku_base),''), pz.id_producto) = pa.padre_sku
     where pz.tipo_producto::text = 'PRESENTACION'
       and nullif(btrim(pz.codigo_barra),'') is not null
       and upper(btrim(pz.codigo_barra)) <> pa.padre_cb
  ),
  fam as (select distinct on (padre_cb, cod) * from familia order by padre_cb, cod, orden),
  -- [M1+M3] demanda ALMACÉN = salidas a zona − devoluciones, sin anuladas, sin envasado
  dem_alm as (
    select cod, greatest(0, sum(x))/4.0 as x_sem from (
      select upper(btrim(gd.cod_producto)) cod,
             case when g.tipo = 'SALIDA_ZONA' then gd.cant_recibida else -gd.cant_recibida end as x
        from wh.guia_detalle gd
        join wh.guias g on g.id_guia = gd.id_guia
       where g.tipo in ('SALIDA_ZONA','INGRESO_DEVOLUCION_ZONA')
         and upper(coalesce(g.estado,'')) <> 'ANULADA'
         and (g.fecha at time zone 'America/Lima')::date between v_desde and v_hasta
    ) t group by cod
  ),
  dem_zona as (
    select upper(btrim(vd.cod_barras)) cod, upper(btrim(v.zona_id)) zona,
           sum(vd.cantidad)/4.0 as x_sem
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where nullif(btrim(v.zona_id),'') is not null
       and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hasta
       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
     group by 1,2
  ),
  filas_alm as (
    select f.padre_cb, f.padre_unidad, 'ALMACEN'::text as ubi_id, 'ALMACEN'::text as ubi_tipo,
           f.cod, f.nombre, f.factor, f.es_padre, f.solo_demanda, f.orden,
           case when f.solo_demanda then 0 else coalesce(s.cantidad_disponible, 0) end::numeric as stock,
           coalesce(d.x_sem, 0)::numeric as dem_sem
      from fam f
      left join wh.stock s on upper(btrim(s.cod_producto)) = f.cod
      left join dem_alm d on d.cod = f.cod
     where coalesce(s.cantidad_disponible,0) <> 0 or coalesce(d.x_sem,0) > 0 or f.es_padre
  ),
  -- [M4] fuera zonas MOCK/FALLBACK (no son tiendas reales)
  zonas_rel as (
    select distinct f.padre_cb, z.zona from fam f
      join (select upper(btrim(cod_barras)) cod, upper(btrim(zona_id)) zona from me.stock_zonas where cantidad <> 0
            union select cod, zona from dem_zona) z on z.cod = f.cod
     where z.zona not like '%MOCK%' and z.zona not like '%FALLBACK%' and z.zona not like '%TEST%'
  ),
  filas_zona as (
    select f.padre_cb, f.padre_unidad, zr.zona as ubi_id, 'ZONA'::text as ubi_tipo,
           f.cod, f.nombre, f.factor, f.es_padre, f.solo_demanda, f.orden,
           case when f.solo_demanda then 0 else coalesce(sz.cantidad, 0) end::numeric as stock,
           coalesce(dz.x_sem, 0)::numeric as dem_sem
      from fam f
      join zonas_rel zr on zr.padre_cb = f.padre_cb
      left join me.stock_zonas sz on upper(btrim(sz.cod_barras)) = f.cod and upper(btrim(sz.zona_id)) = zr.zona
      left join dem_zona dz on dz.cod = f.cod and dz.zona = zr.zona
     where coalesce(sz.cantidad,0) <> 0 or coalesce(dz.x_sem,0) > 0
  ),
  todas as (select * from filas_alm union all select * from filas_zona),
  lineas as (
    select t.*,
           round(t.stock * t.factor, 3) as stock_eq,
           round(t.dem_sem * t.factor, 3) as dem_eq,
           case when t.dem_sem > 0 then round(t.stock / t.dem_sem, 1) else null end as cubre_sem,
           greatest(0, round(t.dem_sem - t.stock, 3)) as falta_und,
           round(greatest(0, t.dem_sem - t.stock) * t.factor, 3) as falta_eq,
           -- [H4] la línea es "stock a corregir", no una necesidad real
           (t.stock < 0 and t.dem_sem > 0 and abs(t.stock) > t.dem_sem * v_tope) as stock_corrupto
      from todas t
  ),
  ubis as (
    select padre_cb, max(padre_unidad) as unidad, ubi_id, ubi_tipo,
           round(sum(stock_eq), 3) as total_eq,
           round(sum(dem_eq), 3)   as demanda_eq_sem,
           round(sum(falta_eq), 3) as falta_bruta_eq,
           -- [H2] lo que el granel PADRE ya tiene disponible para envasar
           round(greatest(0, max(case when es_padre then stock_eq else 0 end)), 3) as padre_disp_eq,
           count(*) filter (where stock <> 0 and not solo_demanda) as n_pres,
           count(*) filter (where stock < 0) as n_negativos,
           bool_or(stock_corrupto) as hay_corrupto,
           jsonb_agg(jsonb_build_object(
             'cod', cod, 'nombre', nombre, 'esPadre', es_padre, 'factor', factor,
             'soloDemanda', solo_demanda,
             'stock', stock, 'stockEq', stock_eq,
             'demandaSem', round(dem_sem, 2), 'cubreSem', cubre_sem,
             'faltaUnd', falta_und, 'faltaEq', falta_eq, 'stockCorrupto', stock_corrupto
           ) order by orden, nombre) as lineas
      from lineas group by 1,3,4
  ),
  ubis2 as (
    select u.*,
           case when u.demanda_eq_sem > 0 then round(u.total_eq / u.demanda_eq_sem, 1) else null end as cubre_sem,
           -- [H4] tope: nunca pedir más de 8 semanas de demanda (protege de stock corrupto)
           least(u.falta_bruta_eq, case when u.demanda_eq_sem > 0 then round(u.demanda_eq_sem * v_tope, 3)
                                        else u.falta_bruta_eq end) as falta_eq
      from ubis u
  ),
  ubis3 as (
    select u.*,
           -- [H2] del faltante, lo que sale del granel propio = ENVASAR; el resto = COMPRAR
           least(u.falta_eq, u.padre_disp_eq) as falta_envasar_eq,
           greatest(0, round(u.falta_eq - u.padre_disp_eq, 3)) as falta_comprar_eq
      from ubis2 u
  ),
  por_producto as (
    select padre_cb, max(unidad) as unidad,
           jsonb_agg(jsonb_build_object(
             'id', ubi_id, 'tipo', ubi_tipo,
             'totalEq', total_eq, 'demandaEqSem', demanda_eq_sem,
             'cubreSem', cubre_sem,
             'faltaEq', falta_eq, 'faltaBrutaEq', falta_bruta_eq,
             'faltaComprarEq', falta_comprar_eq, 'faltaEnvasarEq', falta_envasar_eq,
             'padreDispEq', padre_disp_eq,
             'nPresentaciones', n_pres, 'nNegativos', n_negativos,
             'hayCorrupto', hay_corrupto,
             'lineas', lineas
           ) order by (ubi_tipo <> 'ALMACEN'), ubi_id) as ubicaciones
      from ubis3 group by 1
  )
  select jsonb_build_object(
    'ok', true,
    'ventana', jsonb_build_object('desde', v_desde, 'hasta', v_hasta, 'semanas', 4),
    'data', jsonb_build_object('productos', coalesce(jsonb_agg(jsonb_build_object(
              'codigoBarra', padre_cb, 'unidad', unidad, 'ubicaciones', ubicaciones)), '[]'::jsonb))
  ) into v_out
  from por_producto;

  return coalesce(v_out, jsonb_build_object('ok',true,'data',jsonb_build_object('productos','[]'::jsonb)));
end;
$function$;
