-- 823a: el predicado que decide si un ticket entra en el overlay. Vive aparte para que la RPC
-- se lea de un vistazo y para no repetir la misma condición dos veces (conteo y listado).
--
-- Un ticket entra si tiene AL MENOS UNA línea que:
--   · pertenece al SKU (por su código propio, el del canónico o el de una presentación), y
--   · pasa el filtro pedido: ninguno, una presentación concreta, o un tramo concreto.
-- Para el tramo manda lo GRABADO en la venta (SQL 821); solo si la venta es anterior a ese
-- cambio se reconstruye con los tramos vigentes.

create or replace function mos._tk_linea_ok(
  p_id_venta text, p_sku text, p_clave text, p_seg text, p_tramos jsonb)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (
    select 1
      from me.ventas_detalle d
     where d.id_venta = p_id_venta
       and exists (
         select 1 from mos.productos pr
          where upper(btrim(coalesce(pr.sku_base,''))) = p_sku
            and (upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.cod_barras,'')))
              or upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.sku,'')))
              or upper(btrim(coalesce(pr.id_producto,'')))  = upper(btrim(coalesce(d.sku,'')))))
       and (p_clave is null
            or upper(btrim(coalesce(d.cod_barras,''))) = upper(p_clave)
            or upper(btrim(coalesce(d.sku,'')))        = upper(p_clave))
       and (p_seg is null
            or (case
                  when d.segmento_id is not null then
                       (case when p_seg = '__base__' then btrim(d.segmento_id) = ''
                             else btrim(d.segmento_id) = p_seg end)
                  else coalesce((
                         select s.value->>'id'
                           from jsonb_array_elements(coalesce(p_tramos,'[]'::jsonb)) s
                          where (case when coalesce((s.value->>'minIncl')::boolean,true)
                                      then d.cantidad*1000 >= coalesce((s.value->>'min')::numeric,0)
                                      else d.cantidad*1000 >  coalesce((s.value->>'min')::numeric,0) end)
                            and (case when coalesce((s.value->>'maxIncl')::boolean,true)
                                      then d.cantidad*1000 <= coalesce((s.value->>'max')::numeric,1e12)
                                      else d.cantidad*1000 <  coalesce((s.value->>'max')::numeric,1e12) end)
                          limit 1), '__base__') = p_seg
                end))
  );
$$;

grant execute on function mos._tk_linea_ok(text,text,text,text,jsonb) to anon, authenticated, service_role;
