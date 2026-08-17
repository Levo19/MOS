-- 820_desglose_por_tramo.sql — [DUEÑO] "acá el ají panca tiene tramos, ¿en qué tramo es el
-- registro de venta?"
--
-- CORRECCIÓN DE ALGO QUE DIJE MAL: reporté "0 productos con tramos configurados" mirando
-- `mos.productos.segmentos_precio`, que efectivamente está en null. Los tramos NO viven ahí: viven
-- en **`mos.precio_tramos`** (sku_base → array de segmentos), y hay **24 SKU configurados**.
--
-- LA VENTA NO GUARDA EL TRAMO, pero se reconstruye exacto con la misma regla del POS: pasar la
-- cantidad a gramos y buscar el segmento que la contiene (respetando si los bordes son inclusivos).
-- Comprobado contra el AJI PANCA (LEV024, tramo 0–100 g con +5.5% sobre S/38.00/kg):
--     08:11 ·  50 g · S/ 2.00 → S/40.00/kg  ▲ tramo
--     11:43 · 100 g · S/ 4.00 → S/40.00/kg  ▲ tramo
--     11:45 · 500 g · S/19.00 → S/38.00/kg  ⬚ base
--     12:19 · 100 g · S/ 4.00 → S/40.00/kg  ▲ tramo
--     12:29 · 500 g · S/19.00 → S/38.00/kg  ⬚ base
--     12:46 · 100 g · S/ 4.00 → S/40.00/kg  ▲ tramo
-- Las seis líneas caen donde deben y suman los S/52.00 de la fila.
--
-- LÍMITE HONESTO: la reconstrucción usa los tramos de HOY. Si mañana se cambian, las ventas viejas
-- se re-atribuirían con los nuevos. Para historia fiel habría que grabar el segmento en la venta —
-- el POS ya lo sabe en el momento de calcular el precio.

create or replace function mos.finanzas_dia_sku_tramos(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_fecha text := nullif(btrim(coalesce(p->>'fecha','')),'');
  v_sku   text := upper(btrim(coalesce(p->>'skuBase','')));
  v_d     date;
  v_tramos jsonb;
  v_base  numeric := 0;
  v_costo numeric := 0;
  v_margen numeric;
  v_out   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku = '' then return jsonb_build_object('ok',false,'error','Requiere skuBase'); end if;
  v_d := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);

  select t.tramos into v_tramos from mos.precio_tramos t where upper(btrim(t.sku_base)) = v_sku;
  if v_tramos is null or jsonb_typeof(v_tramos) <> 'array' or jsonb_array_length(v_tramos) = 0 then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('skuBase', v_sku, 'tieneTramos', false, 'tramos', '[]'::jsonb));
  end if;

  v_margen := coalesce((select nullif(btrim(valor),'')::numeric from mos.config where clave='finMargenDefault' limit 1), 15);

  select coalesce(pr.precio_venta,0), coalesce(pr.precio_costo,0) into v_base, v_costo
    from mos.productos pr
   where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
   order by pr.codigo_barra limit 1;

  with vcobr as (
    select v.id_venta from me.ventas v
     where (v.fecha at time zone 'America/Lima')::date = v_d
       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
       and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
  ),
  lin as (
    select coalesce(d.cantidad,0)::numeric as cant,
           coalesce(d.subtotal, d.precio*d.cantidad, 0)::numeric as ingreso
      from me.ventas_detalle d
      join vcobr v on v.id_venta = d.id_venta
     where exists (
       select 1 from mos.productos pr
        where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
          and (upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.cod_barras,'')))
            or upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.sku,'')))
            or upper(btrim(coalesce(pr.id_producto,'')))  = upper(btrim(coalesce(d.sku,''))))
          and coalesce(nullif(pr.factor_conversion,0),1) = 1)   -- el tramo es del granel, no de los packs
  ),
  -- misma regla que aplica el POS: gramos = cantidad × 1000, bordes según minIncl/maxIncl
  clas as (
    select l.cant, l.ingreso,
           (select s.value from jsonb_array_elements(v_tramos) s
             where (case when coalesce((s.value->>'minIncl')::boolean,true)
                         then l.cant*1000 >= coalesce((s.value->>'min')::numeric,0)
                         else l.cant*1000 >  coalesce((s.value->>'min')::numeric,0) end)
               and (case when coalesce((s.value->>'maxIncl')::boolean,true)
                         then l.cant*1000 <= coalesce((s.value->>'max')::numeric,1e12)
                         else l.cant*1000 <  coalesce((s.value->>'max')::numeric,1e12) end)
             limit 1) as seg
      from lin l
  ),
  grp as (
    select coalesce(c.seg->>'id','__base__') as id,
           coalesce(nullif(btrim(c.seg->>'nombre'),''),
                    case when c.seg is null then 'Sin tramo · precio base'
                         else (coalesce(c.seg->>'min','0') || '–' || coalesce(c.seg->>'max','∞') || ' g') end) as etiqueta,
           coalesce((c.seg->>'ajustePct')::numeric, 0) as ajuste,
           (c.seg is null) as es_base,
           count(*)          as lineas,
           sum(c.cant)       as cantidad,
           mos._r2(sum(c.ingreso)) as ingreso
      from clas c group by 1,2,3,4
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id, 'etiqueta', g.etiqueta, 'ajustePct', g.ajuste, 'esBase', g.es_base,
           'lineas', g.lineas, 'cantidad', g.cantidad, 'ingreso', g.ingreso,
           'precioKg',  case when g.cantidad > 0 then mos._r2(g.ingreso / g.cantidad) else 0 end,
           'precioEsperado', mos._r2(v_base * (1 + g.ajuste/100)),
           'costo', case when v_costo > 0 then mos._r2(g.cantidad * v_costo)
                         else mos._r2(g.ingreso * (1 - v_margen/100)) end,
           'esEstimado', (v_costo <= 0),
           'margenPct', case when v_costo > 0 and g.ingreso > 0
                             then round(((g.ingreso - g.cantidad*v_costo)/g.ingreso)*1000)/10.0 else null end
         ) order by g.es_base, g.ajuste desc), '[]'::jsonb)
    into v_out from grp g;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'skuBase', v_sku, 'tieneTramos', true, 'precioBase', v_base, 'costoUnit', v_costo,
    'margenDefault', v_margen, 'tramos', coalesce(v_out,'[]'::jsonb)));
end;
$function$;

grant execute on function mos.finanzas_dia_sku_tramos(jsonb) to anon, authenticated, service_role;
