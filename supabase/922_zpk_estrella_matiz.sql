-- [922] wh.zona_pickup_detalle + BCG por sku de la zona → matiz "⭐ estrella que falta despachar = urgente"
-- en el botón PICKUP del módulo Zona (MOS). El pickup mostraba urgencia por deuda/veces/días/stock,
-- pero no sabía si el producto es ESTRELLA. Ahora expone `bcg` por ítem (join me.zona_esperado de ESA
-- zona — clave para que las pestañas Zona1/Zona2 del Almacén traigan el BCG correcto). El front suma el
-- matiz al score. Cambio ADITIVO: mismo shape + un campo `bcg` nuevo. Base = definición viva 2026-08-20.
create or replace function wh.zona_pickup_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date := wh._bucket_despacho((now() at time zone 'America/Lima')::date);
  v_acum   jsonb;
  v_hist   jsonb;
  v_stock  jsonb;   -- [789] sku → stock de almacén
  v_bcg    jsonb;   -- [922] sku → BCG (ESTRELLA/VACA/INTERROGANTE/PERRO) de ESTA zona
  v_items  jsonb;
  v_sinsku jsonb;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;

  select items into v_acum
    from wh.pickups
   where id_pickup = 'PCK-ACU-' || v_zona || '-' || to_char(v_bucket, 'YYYY-MM-DD')
   limit 1;
  v_acum := coalesce(v_acum, '[]'::jsonb);

  with pedidos as (
    select it->>'skuBase' as sku,
           pk.fecha_creado as ts,
           pk.fuente,
           sum(wh._num(coalesce(it->>'solicitado','0'))) as ped
      from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where coalesce(pk.id_zona,'') = v_zona
       and coalesce(pk.fuente,'') <> 'ACUMULADO_SEMANAL'
       and wh._bucket_venta((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
       and coalesce(it->>'skuBase','') <> ''
       and wh._num(coalesce(it->>'solicitado','0')) > 0
     group by 1, 2, 3
  ),
  despachos as (
    select coalesce(pr.sku_base, eq.sku_base) as sku,
           coalesce(gd.created_at, g.fecha) as ts,
           sum(coalesce(gd.cant_recibida, 0)) as cant
      from wh.guias g
      join wh.guia_detalle gd on gd.id_guia = g.id_guia
      left join mos.productos    pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
     where coalesce(g.id_zona,'') = v_zona
       and g.tipo like 'SALIDA%'
       and wh._bucket_despacho((g.fecha at time zone 'America/Lima')::date) = v_bucket
       and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
       and coalesce(pr.sku_base, eq.sku_base) is not null
     group by 1, 2
  ),
  eventos as (
    select sku, ts, 'pedido'::text as tipo, fuente, ped as cant from pedidos
    union all
    select sku, ts, 'despacho'::text as tipo, 'GUIA_SALIDA' as fuente, cant from despachos
  )
  select coalesce(jsonb_object_agg(sku, h), '{}'::jsonb) into v_hist
    from (
      select sku, jsonb_agg(jsonb_build_object(
               'fecha',  to_char(ts at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI'),
               'tipo',   tipo,
               'fuente', fuente,
               'pedido', case when tipo = 'pedido'  then cant end,
               'cant',   cant
             ) order by ts) h
        from eventos where coalesce(sku,'') <> ''
       group by sku
    ) z;
  v_hist := coalesce(v_hist, '{}'::jsonb);

  select coalesce(jsonb_object_agg(sku, st), '{}'::jsonb) into v_stock
    from (
      select coalesce(pr.sku_base, eq.sku_base) as sku,
             sum(coalesce(s.cantidad_disponible, 0)) as st
        from wh.stock s
        left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
        left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
       where coalesce(pr.sku_base, eq.sku_base) is not null
       group by 1
    ) q;
  v_stock := coalesce(v_stock, '{}'::jsonb);

  -- [922] BCG por sku de ESTA zona (PK zona_id+sku_base → claves únicas). Sube el matiz de estrella
  -- en el front. Se ignoran filas sin bcg. Clave = sku_base tal cual (mismo canónico que el acumulado).
  select coalesce(jsonb_object_agg(sku_base, upper(btrim(bcg))), '{}'::jsonb) into v_bcg
    from me.zona_esperado
   where btrim(coalesce(zona_id,'')) = btrim(v_zona)
     and coalesce(btrim(bcg),'') <> ''
     and coalesce(btrim(sku_base),'') <> '';
  v_bcg := coalesce(v_bcg, '{}'::jsonb);

  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', it->>'skuBase',
           'nombre', coalesce(it->>'nombre', it->>'skuBase'),
           'solicitado', wh._num(coalesce(it->>'solicitado','0')),
           'despachado', wh._num(coalesce(it->>'despachado','0')),
           'pendiente', greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))),
           'tsSolicitud', it->>'tsSolicitud',
           'tsDespacho',  it->>'tsDespacho',
           'stockWh', coalesce((v_stock->>(it->>'skuBase'))::numeric, 0),
           'bcg', coalesce(v_bcg->>(it->>'skuBase'), ''),   -- [922] matiz estrella
           'sinSku', coalesce((it->>'sinSku')::boolean, false),
           'constancia', wh._num(coalesce(it->>'constancia','0')),
           'historial', coalesce(v_hist->(it->>'skuBase'), '[]'::jsonb)
         ) order by greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) desc), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(v_acum) it
   where coalesce((it->>'sinSku')::boolean, false) = false;

  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'solicitado', ped, 'despachado', 0,
           'fecha', to_char(ts at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI')
         ) order by ts desc, nombre), '[]'::jsonb)
    into v_sinsku
    from (
      select upper(btrim(coalesce(it->>'nombre',''))) as nombre,
             pk.fecha_creado as ts,
             sum(wh._num(coalesce(it->>'solicitado','0'))) as ped
        from wh.pickups pk
        cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
       where coalesce(pk.id_zona,'') = v_zona
         and coalesce(pk.fuente,'') = 'LISTA_IA'
         and wh._bucket_venta((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
         and coalesce(btrim(it->>'skuBase'),'') = ''
         and wh._num(coalesce(it->>'solicitado','0')) > 0
       group by 1, 2
      having sum(wh._num(coalesce(it->>'solicitado','0'))) > 0
    ) q;

  return jsonb_build_object(
    'ok', true, 'zona', v_zona, 'bucket', to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items,
    'sinIdentificar', coalesce(v_sinsku,'[]'::jsonb),
    'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')))),0)
                          from jsonb_array_elements(v_acum) it
                         where coalesce((it->>'sinSku')::boolean, false) = false));
end;
$function$;
grant execute on function wh.zona_pickup_detalle(jsonb) to authenticated, anon, service_role;
