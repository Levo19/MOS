-- 614 · Proveedores: stock, cobertura y FALTANTE por UBICACIÓN y por PRESENTACIÓN.
--
-- Modelo definido por Luis (03/08/2026):
--   · "En almacén decía 0 y en realidad hay 66.55 kg" → cada ubicación cuenta TODA la
--     familia (padre + equivalentes + derivados) convertida a unidad del padre.
--   · "Cada uno debe tener su propia cobertura semanal" → cobertura y faltante POR CÓDIGO,
--     no solo el agregado (el agregado esconde que el 250GR cubre 0.9 sem).
--   · "Compro para una semana" → demanda = promedio semanal de las 4 SEMANAS COMPLETAS
--     ANTERIORES (no cuenta la semana en curso, que está a medias).
--   · "La barra del card es la de ALMACÉN" → es el único que le compra al proveedor.
--   · Faltante de ALMACÉN = COMPRAR al proveedor · Faltante de ZONA = DESPACHAR desde
--     almacén. NUNCA se suman (sería pedir dos veces lo mismo).
--   · Los negativos RESTAN (no se ignoran) y el faltante los absorbe: stock −2 con demanda
--     2 → faltan 4 (2 tapan el hueco + 2 de la semana).
--
-- DEMANDA por ubicación:
--   🏬 ALMACÉN → Σ cant_recibida de guías tipo 'SALIDA_ZONA' ÷ 4.
--      EXCLUYE 'SALIDA_ENVASADO': convertir granel en bolsitas es movimiento interno,
--      contarlo duplicaría el mismo kilo (sale como granel y vuelve como derivado).
--   🏪 ZONA → Σ cantidad vendida al cliente en esa zona ÷ 4 (sin ventas anuladas).
--
-- Devuelve {ok, data:{productos:[{codigoBarra, ubicaciones:[...]}]}} — el front hace merge
-- por codigoBarra con la RPC v2 existente (que NO se toca).

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
  v_out   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_prov is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;

  with
  -- 1) padres = productos del catálogo de ESTE proveedor
  padres as (
    select distinct
           upper(btrim(pp.codigo_barra)) as padre_cb,
           coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) as padre_sku,
           pr.descripcion as padre_desc,
           coalesce(nullif(btrim(pr.unidad),''),'') as padre_unidad
      from mos.proveedores_productos pp
      join mos.productos pr on upper(btrim(pr.codigo_barra)) = upper(btrim(pp.codigo_barra))
     where pp.id_proveedor = v_prov
       and nullif(btrim(pp.codigo_barra),'') is not null
       and coalesce(pp.activa, true)
  ),
  -- 2) familia: el padre (factor 1) + sus equivalentes (factor 1) + sus derivados (factor real)
  familia as (
    select pa.padre_cb, pa.padre_sku, pa.padre_desc, pa.padre_unidad,
           pa.padre_cb as cod, pa.padre_desc as nombre, 1::numeric as factor,
           true as es_padre, 0 as orden
      from padres pa
    union all
    select pa.padre_cb, pa.padre_sku, pa.padre_desc, pa.padre_unidad,
           upper(btrim(e.codigo_barra)), coalesce(nullif(btrim(e.descripcion),''), pa.padre_desc),
           1::numeric, false, 1
      from padres pa
      join mos.equivalencias e on btrim(e.sku_base) = pa.padre_sku
     where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null
    union all
    select pa.padre_cb, pa.padre_sku, pa.padre_desc, pa.padre_unidad,
           upper(btrim(d.codigo_barra)), d.descripcion,
           coalesce(nullif(d.factor_conversion_base,0), 1)::numeric, false, 2
      from padres pa
      join mos.productos d on btrim(d.codigo_producto_base) = pa.padre_sku
     where nullif(btrim(d.codigo_barra),'') is not null
       and d.tipo_producto::text is distinct from 'PRESENTACION'
       and upper(btrim(d.codigo_barra)) <> pa.padre_cb
  ),
  -- dedupe: un código podría aparecer 2 veces (equivalente y derivado) → gana el de menor orden
  fam as (
    select distinct on (padre_cb, cod) * from familia order by padre_cb, cod, orden
  ),
  -- 3) DEMANDA semanal del ALMACÉN = salidas a zona ÷ 4 (sin envasado)
  dem_alm as (
    select upper(btrim(gd.cod_producto)) cod, sum(gd.cant_recibida)/4.0 as x_sem
      from wh.guia_detalle gd
      join wh.guias g on g.id_guia = gd.id_guia
     where g.tipo = 'SALIDA_ZONA'
       and (g.fecha at time zone 'America/Lima')::date between v_desde and v_hasta
     group by 1
  ),
  -- 4) DEMANDA semanal de cada ZONA = ventas al cliente ÷ 4
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
  -- 5) filas ALMACÉN (una por código de la familia con stock o demanda)
  filas_alm as (
    select f.padre_cb, 'ALMACEN'::text as ubi_id, 'ALMACEN'::text as ubi_tipo,
           f.cod, f.nombre, f.factor, f.es_padre, f.orden,
           coalesce(s.cantidad_disponible, 0)::numeric as stock,
           coalesce(d.x_sem, 0)::numeric as dem_sem
      from fam f
      left join wh.stock s on upper(btrim(s.cod_producto)) = f.cod
      left join dem_alm d on d.cod = f.cod
     where coalesce(s.cantidad_disponible,0) <> 0 or coalesce(d.x_sem,0) > 0 or f.es_padre
  ),
  -- 6) filas ZONA (una por código × zona con stock o venta)
  zonas_rel as (
    select distinct f.padre_cb, z.zona from fam f
      join (select upper(btrim(cod_barras)) cod, upper(btrim(zona_id)) zona from me.stock_zonas where cantidad <> 0
            union select cod, zona from dem_zona) z on z.cod = f.cod
  ),
  filas_zona as (
    select f.padre_cb, zr.zona as ubi_id, 'ZONA'::text as ubi_tipo,
           f.cod, f.nombre, f.factor, f.es_padre, f.orden,
           coalesce(sz.cantidad, 0)::numeric as stock,
           coalesce(dz.x_sem, 0)::numeric as dem_sem
      from fam f
      join zonas_rel zr on zr.padre_cb = f.padre_cb
      left join me.stock_zonas sz on upper(btrim(sz.cod_barras)) = f.cod and upper(btrim(sz.zona_id)) = zr.zona
      left join dem_zona dz on dz.cod = f.cod and dz.zona = zr.zona
     where coalesce(sz.cantidad,0) <> 0 or coalesce(dz.x_sem,0) > 0
  ),
  todas as (select * from filas_alm union all select * from filas_zona),
  -- 7) métricas POR LÍNEA: cobertura y faltante (el faltante absorbe el negativo)
  lineas as (
    select t.*,
           round(t.stock * t.factor, 3) as stock_eq,
           round(t.dem_sem * t.factor, 3) as dem_eq,
           case when t.dem_sem > 0 then round(t.stock / t.dem_sem, 1) else null end as cubre_sem,
           greatest(0, round(t.dem_sem - t.stock, 3)) as falta_und,
           round(greatest(0, t.dem_sem - t.stock) * t.factor, 3) as falta_eq
      from todas t
  ),
  -- 8) agregado por ubicación (negativos RESTAN, como pidió Luis)
  ubis as (
    select padre_cb, ubi_id, ubi_tipo,
           round(sum(stock_eq), 3) as total_eq,
           round(sum(dem_eq), 3)   as demanda_eq_sem,
           round(sum(falta_eq), 3) as falta_eq,
           count(*) filter (where stock <> 0) as n_pres,
           count(*) filter (where stock < 0)  as n_negativos,
           jsonb_agg(jsonb_build_object(
             'cod', cod, 'nombre', nombre, 'esPadre', es_padre, 'factor', factor,
             'stock', stock, 'stockEq', stock_eq,
             'demandaSem', round(dem_sem, 2), 'cubreSem', cubre_sem,
             'faltaUnd', falta_und, 'faltaEq', falta_eq
           ) order by orden, nombre) as lineas
      from lineas group by 1,2,3
  ),
  ubis2 as (
    select u.*,
           case when u.demanda_eq_sem > 0 then round(u.total_eq / u.demanda_eq_sem, 1) else null end as cubre_sem
      from ubis u
  ),
  por_producto as (
    select padre_cb,
           jsonb_agg(jsonb_build_object(
             'id', ubi_id, 'tipo', ubi_tipo,
             'totalEq', total_eq, 'demandaEqSem', demanda_eq_sem,
             'cubreSem', cubre_sem, 'faltaEq', falta_eq,
             'nPresentaciones', n_pres, 'nNegativos', n_negativos,
             'lineas', lineas
           ) order by (ubi_tipo <> 'ALMACEN'), ubi_id) as ubicaciones
      from ubis2 group by 1
  )
  select jsonb_build_object(
    'ok', true,
    'ventana', jsonb_build_object('desde', v_desde, 'hasta', v_hasta, 'semanas', 4),
    'data', jsonb_build_object('productos', coalesce(jsonb_agg(jsonb_build_object(
              'codigoBarra', padre_cb, 'ubicaciones', ubicaciones)), '[]'::jsonb))
  ) into v_out
  from por_producto;

  return coalesce(v_out, jsonb_build_object('ok',true,'data',jsonb_build_object('productos','[]'::jsonb)));
end;
$function$;

revoke all on function mos.prov_stock_ubicaciones(jsonb) from public;
grant execute on function mos.prov_stock_ubicaciones(jsonb) to service_role, authenticated;
