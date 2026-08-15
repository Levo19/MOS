CREATE OR REPLACE FUNCTION wh.zona_pickup_detalle(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date := wh._bucket_dom((now() at time zone 'America/Lima')::date);
  v_acum   jsonb;
  v_hist   jsonb;
  v_items  jsonb;
  v_sinsku jsonb;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;

  select items into v_acum
    from wh.pickups
   where id_pickup = 'PCK-ACU-' || v_zona || '-' || to_char(v_bucket, 'YYYY-MM-DD')
   limit 1;
  v_acum := coalesce(v_acum, '[]'::jsonb);

  -- HISTORIAL por sku: PEDIDOS (cierres/RIZ/sombra, por pickup CON HORA) + DESPACHOS
  -- (líneas de guías SALIDA de la zona, hora real de cada línea = gd.created_at).
  with pedidos as (
    select it->>'skuBase' as sku,
           pk.fecha_creado as ts,
           pk.fuente,
           sum(wh._num(coalesce(it->>'solicitado','0'))) as ped
      from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where coalesce(pk.id_zona,'') = v_zona
       and coalesce(pk.fuente,'') <> 'ACUMULADO_SEMANAL'
       and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
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
       and wh._bucket_dom((g.fecha at time zone 'America/Lima')::date) = v_bucket
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', it->>'skuBase',
           'nombre', coalesce(it->>'nombre', it->>'skuBase'),
           'solicitado', wh._num(coalesce(it->>'solicitado','0')),
           'despachado', wh._num(coalesce(it->>'despachado','0')),
           'pendiente', greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))),
           'tsSolicitud', it->>'tsSolicitud',   -- [607] hora en que el producto entró al acumulado
           'tsDespacho',  it->>'tsDespacho',    -- [607] hora del último despacho marcado (WH)
           'sinSku', coalesce((it->>'sinSku')::boolean, false),
           'constancia', wh._num(coalesce(it->>'constancia','0')),
           'historial', coalesce(v_hist->(it->>'skuBase'), '[]'::jsonb)
         ) order by greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) desc), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(v_acum) it
   where coalesce((it->>'sinSku')::boolean, false) = false;   -- [606] constancias van en sinIdentificar

  -- [no-se-entiende] constancias: ahora también CON HORA del pickup que las trajo
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
         and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
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
$function$
