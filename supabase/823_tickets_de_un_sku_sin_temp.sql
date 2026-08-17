-- 823_tickets_de_un_sku_sin_temp.sql — arregla el 822.
--
-- La versión anterior usaba una tabla temporal para juntar los id_venta seleccionados y PostgREST
-- rechazaba la llamada con HTTP 400 (el overlay abría vacío). Se rehace con una sola consulta:
-- el filtro vive en un `exists` y no hay estado intermedio — más simple y sin nada compartido
-- entre peticiones.
--
-- Lo demás es igual al 822: filtra en tres niveles (todo el SKU / una presentación / un tramo),
-- devuelve el ticket COMPLETO con `esEste` en las líneas del producto, y usa el mismo universo de
-- Finanzas (del día, sin anuladas, sin crédito).

create or replace function mos.finanzas_dia_sku_tickets(p jsonb)
 returns jsonb language plpgsql stable security definer set search_path to ''
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

  -- ¿Cuántos tickets del día tienen una línea de este SKU que además pase el filtro pedido?
  select count(*)::int into v_tot
    from me.ventas v
   where (v.fecha at time zone 'America/Lima')::date = v_d
     and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
     and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
     and mos._tk_linea_ok(v.id_venta, v_sku, v_clave, v_seg, v_tramos);

  select coalesce(jsonb_agg(x.obj order by x.orden desc), '[]'::jsonb) into v_out
    from (
      select v.fecha as orden, jsonb_build_object(
        'idVenta',     v.id_venta,
        'hora',        to_char(v.fecha at time zone 'America/Lima','HH24:MI'),
        'correlativo', coalesce(v.correlativo,''),
        'tipoDoc',     coalesce(v.tipo_doc,''),
        'formaPago',   coalesce(v.forma_pago,''),
        'vendedor',    coalesce(v.vendedor,''),
        'cliente',     coalesce(nullif(btrim(v.cliente_nombre),''),''),
        'total',       coalesce(v.total,0),
        'lineas',      coalesce((
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
     where (v.fecha at time zone 'America/Lima')::date = v_d
       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
       and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
       and mos._tk_linea_ok(v.id_venta, v_sku, v_clave, v_seg, v_tramos)
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
