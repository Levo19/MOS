-- 822_tickets_de_un_sku.sql — [DUEÑO] "quiero un botón que me muestre por overlay todos los
-- tickets que se cuentan; si de ajinomoto 1kg vendí 10 unidades, que me muestre todos los tickets
-- que tienen ajinomoto en su detalle, como una mesa, resaltando dónde están los ajinomotos. Ese
-- botón debe estar en el líder agrupado pero también en cada tramo o presentación."
--
-- Es la trazabilidad que faltaba: del número agregado a los tickets que lo formaron. Sin esto,
-- cuando un margen se ve raro no hay forma de ir a mirar las ventas concretas.
--
-- FILTRA EN TRES NIVELES, el mismo que se toque:
--   · sin filtro           → todos los tickets del día con ese SKU (líder: incluye packs y tramos)
--   · `clave`              → solo los de esa presentación (por su código de barras)
--   · `segmentoId`         → solo los de ese tramo de precio ('__base__' = los cobrados sin tramo)
--
-- Devuelve el ticket COMPLETO —todas sus líneas, no solo la del producto— porque el dueño quiere
-- ver el contexto: qué más se llevó esa persona. Las líneas del producto en cuestión vienen con
-- `esEste`, para resaltarlas.
--
-- Mismo universo que el resto de Finanzas: del día, sin anuladas y sin crédito.

create or replace function mos.finanzas_dia_sku_tickets(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_fecha text := nullif(btrim(coalesce(p->>'fecha','')),'');
  v_sku   text := upper(btrim(coalesce(p->>'skuBase','')));
  v_clave text := nullif(btrim(coalesce(p->>'clave','')),'');
  v_seg   text := nullif(btrim(coalesce(p->>'segmentoId','')),'');
  v_lim   int  := greatest(1, least(200, coalesce((p->>'limite')::int, 80)));
  v_d     date;
  v_tramos jsonb;
  v_tot   int := 0;
  v_out   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku = '' then return jsonb_build_object('ok',false,'error','Requiere skuBase'); end if;
  v_d := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);
  select t.tramos into v_tramos from mos.precio_tramos t where upper(btrim(t.sku_base)) = v_sku;

  create temp table if not exists _tk_sel(id_venta text primary key) on commit drop;
  delete from _tk_sel;

  insert into _tk_sel(id_venta)
  select distinct v.id_venta
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
   where (v.fecha at time zone 'America/Lima')::date = v_d
     and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
     and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
     -- la línea pertenece al SKU (por su código propio, su id, o el del canónico/presentación)
     and exists (
       select 1 from mos.productos pr
        where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
          and (upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.cod_barras,'')))
            or upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.sku,'')))
            or upper(btrim(coalesce(pr.id_producto,'')))  = upper(btrim(coalesce(d.sku,'')))))
     -- filtro por PRESENTACIÓN
     and (v_clave is null
          or upper(btrim(coalesce(d.cod_barras,''))) = upper(v_clave)
          or upper(btrim(coalesce(d.sku,'')))        = upper(v_clave))
     -- filtro por TRAMO: primero lo grabado; si la venta es vieja, se reconstruye
     and (v_seg is null
          or (case
                when d.segmento_id is not null then
                     (case when v_seg = '__base__' then btrim(d.segmento_id) = ''
                           else btrim(d.segmento_id) = v_seg end)
                else coalesce((
                       select s.value->>'id' from jsonb_array_elements(coalesce(v_tramos,'[]'::jsonb)) s
                        where (case when coalesce((s.value->>'minIncl')::boolean,true)
                                    then d.cantidad*1000 >= coalesce((s.value->>'min')::numeric,0)
                                    else d.cantidad*1000 >  coalesce((s.value->>'min')::numeric,0) end)
                          and (case when coalesce((s.value->>'maxIncl')::boolean,true)
                                    then d.cantidad*1000 <= coalesce((s.value->>'max')::numeric,1e12)
                                    else d.cantidad*1000 <  coalesce((s.value->>'max')::numeric,1e12) end)
                        limit 1), '__base__') = v_seg
              end));

  select count(*)::int into v_tot from _tk_sel;

  select coalesce(jsonb_agg(x.obj order by x.orden desc), '[]'::jsonb) into v_out
    from (
      select v.fecha as orden, jsonb_build_object(
        'idVenta',    v.id_venta,
        'hora',       to_char(v.fecha at time zone 'America/Lima','HH24:MI'),
        'correlativo',coalesce(v.correlativo,''),
        'tipoDoc',    coalesce(v.tipo_doc,''),
        'formaPago',  coalesce(v.forma_pago,''),
        'vendedor',   coalesce(v.vendedor,''),
        'cliente',    coalesce(nullif(btrim(v.cliente_nombre),''),''),
        'total',      coalesce(v.total,0),
        'lineas',     coalesce((
          select jsonb_agg(jsonb_build_object(
                   'nombre',   coalesce(d.nombre,''),
                   'cantidad', coalesce(d.cantidad,0),
                   'precio',   coalesce(d.precio,0),
                   'subtotal', coalesce(d.subtotal, d.precio*d.cantidad, 0),
                   'unidad',   coalesce(d.unidad_medida,''),
                   'segmento', coalesce(nullif(btrim(d.segmento_nombre),''), ''),
                   'esEste',   exists (
                     select 1 from mos.productos pr
                      where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
                        and (upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.cod_barras,'')))
                          or upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.sku,'')))
                          or upper(btrim(coalesce(pr.id_producto,'')))  = upper(btrim(coalesce(d.sku,'')))))
                 ) order by d.linea)
            from me.ventas_detalle d where d.id_venta = v.id_venta), '[]'::jsonb)
      ) obj
      from me.ventas v
      join _tk_sel t on t.id_venta = v.id_venta
      order by v.fecha desc
      limit v_lim
    ) x;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'skuBase', v_sku, 'fecha', to_char(v_d,'YYYY-MM-DD'),
    'filtroClave', coalesce(v_clave,''), 'filtroSegmento', coalesce(v_seg,''),
    'total', v_tot, 'mostrados', jsonb_array_length(coalesce(v_out,'[]'::jsonb)),
    'tickets', coalesce(v_out,'[]'::jsonb)));
end;
$function$;

grant execute on function mos.finanzas_dia_sku_tickets(jsonb) to anon, authenticated, service_role;
