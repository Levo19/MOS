-- 819_desglose_sku_del_dia.sql — [DUEÑO] "el desglose debe ser al clickear cada SKU de esta
-- lista, para que me muestre el costo y margen y demás datos… así puedo ver cuál es más rentable
-- para mí, cómo vendo mejor, y así puedo crear nuevas presentaciones o tramos".
--
-- La fila del modal es el SKU COLAPSADO: el granel y todas sus presentaciones sumados. Sirve para
-- el total del día, pero esconde justo lo que el dueño quiere decidir — si conviene vender suelto
-- o empacado. Esta RPC abre esa fila.
--
-- MISMO UNIVERSO que `mos.finanzas_dia`, a propósito: ventas del día, sin anuladas y **sin
-- crédito** (decisión del dueño: "el crédito no entra al margen"). Si los números de acá no
-- sumaran los de la fila, el desglose no serviría para nada.
--
-- CÓMO SE PARTE: por el producto REAL que pasó por caja. Cada línea de venta guarda su
-- `cod_barras`, y cada presentación tiene el suyo, así que la separación es exacta — no estimada.
-- El costo sigue la misma regla de la casa: costo del canónico × unidades base (cantidad ×
-- factor). Por eso un pack de 8 cuesta 8 veces la unidad, y el margen de cada presentación sale
-- del mismo costo con distinto precio — que es exactamente la comparación que el dueño busca.
--
-- SOBRE LOS TRAMOS (segmentos_precio): el POS ya los aplica al granel, calculando por gramos. Hoy
-- hay 0 productos configurados, así que no hay nada que desglosar todavía. Cuando se configuren,
-- el tramo se puede reconstruir con la misma fórmula del POS — pero conviene que la venta guarde
-- qué segmento aplicó, o un cambio futuro de tramos re-escribiría la historia.

create or replace function mos.finanzas_dia_sku(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_fecha text := nullif(btrim(coalesce(p->>'fecha','')),'');
  v_sku   text := upper(btrim(coalesce(p->>'skuBase','')));
  v_d     date;
  v_margen numeric;
  v_costo_canon numeric := 0;
  v_out   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku = '' then return jsonb_build_object('ok',false,'error','Requiere skuBase'); end if;
  v_d := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);

  -- margen de respaldo (el mismo que usa el resumen del día para los SKU sin costo)
  v_margen := coalesce((select nullif(btrim(valor),'')::numeric from mos.config
                         where clave = 'finMargenDefault' limit 1), 15);

  -- costo por unidad BASE del canónico del grupo
  select coalesce(pr.precio_costo,0) into v_costo_canon
    from mos.productos pr
   where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
   order by pr.codigo_barra limit 1;

  with vcobr as (
    -- mismo universo que finanzas_dia: cobrado, sin anular, sin crédito
    select v.id_venta
      from me.ventas v
     where (v.fecha at time zone 'America/Lima')::date = v_d
       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
       and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
  ),
  lin as (
    select upper(btrim(coalesce(d.cod_barras,''))) as cb,
           upper(btrim(coalesce(d.sku,'')))       as sk,
           coalesce(d.cantidad,0)::numeric         as cantidad,
           coalesce(d.subtotal, d.precio * d.cantidad, 0)::numeric as ingreso,
           coalesce(d.nombre,'')                   as nombre_venta,
           coalesce(d.unidad_medida,'')            as um
      from me.ventas_detalle d
      join vcobr v on v.id_venta = d.id_venta
  ),
  -- se resuelve el PRODUCTO REAL de cada línea (la presentación exacta que pasó por caja)
  res as (
    select l.*,
           pr.id_producto, pr.descripcion, pr.codigo_barra,
           coalesce(nullif(pr.factor_conversion,0),1)::numeric as factor,
           coalesce(pr.precio_venta,0)::numeric as precio_lista
      from lin l
      left join lateral (
        select * from mos.productos q
         where upper(btrim(coalesce(q.codigo_barra,''))) = l.cb
            or upper(btrim(coalesce(q.codigo_barra,''))) = l.sk
            or upper(btrim(coalesce(q.id_producto,'')))  = l.sk
         order by q.id_producto limit 1
      ) pr on true
     where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
  ),
  grp as (
    select coalesce(nullif(r.codigo_barra,''), r.cb, r.sk) as clave,
           max(coalesce(nullif(r.descripcion,''), r.nombre_venta)) as nombre,
           max(r.factor)        as factor,
           max(r.precio_lista)  as precio_lista,
           max(r.um)            as um,
           sum(r.cantidad)      as cantidad,
           sum(r.cantidad * r.factor) as unidades_base,
           mos._r2(sum(r.ingreso))    as ingreso,
           count(*)             as lineas
      from res r
     group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'clave',        g.clave,
           'nombre',       g.nombre,
           'factor',       g.factor,
           'esBase',       (g.factor = 1),
           'unidad',       g.um,
           'cantidad',     g.cantidad,
           'unidadesBase', g.unidades_base,
           'lineas',       g.lineas,
           'ingreso',      g.ingreso,
           'precioProm',   case when g.cantidad > 0 then mos._r2(g.ingreso / g.cantidad) else 0 end,
           'precioLista',  g.precio_lista,
           -- costo: SIEMPRE el del canónico × unidades base. Es lo que hace comparable a una
           -- presentación con su granel: mismo costo por unidad, distinto precio.
           'costo',        case when v_costo_canon > 0
                                then mos._r2(g.unidades_base * v_costo_canon)
                                else mos._r2(g.ingreso * (1 - v_margen/100)) end,
           'esEstimado',   (v_costo_canon <= 0),
           'margenPct',    case when v_costo_canon > 0 and g.ingreso > 0
                                then round(((g.ingreso - (g.unidades_base * v_costo_canon)) / g.ingreso) * 1000) / 10.0
                                else null end
         ) order by g.ingreso desc), '[]'::jsonb)
    into v_out
    from grp g;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'skuBase',        v_sku,
    'fecha',          to_char(v_d,'YYYY-MM-DD'),
    'costoUnitBase',  v_costo_canon,
    'margenDefault',  v_margen,
    'items',          coalesce(v_out,'[]'::jsonb)
  ));
end;
$function$;

grant execute on function mos.finanzas_dia_sku(jsonb) to anon, authenticated, service_role;
