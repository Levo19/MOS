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

  -- items vivos del acumulado de la zona (pendiente = solicitado - despachado)
  select items into v_acum
    from wh.pickups
   where id_pickup = 'PCK-ACU-' || v_zona || '-' || to_char(v_bucket, 'YYYY-MM-DD')
   limit 1;
  v_acum := coalesce(v_acum, '[]'::jsonb);

  -- HISTORIAL por sku: cada cierre/pedido del bucket (no acumulado), agrupado por día.
  with src as (
    select wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) as bkt,
           (pk.fecha_creado at time zone 'America/Lima')::date as dia,
           pk.fuente,
           it->>'skuBase' as sku,
           wh._num(coalesce(it->>'solicitado','0')) as pedido
      from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where coalesce(pk.id_zona,'') = v_zona
       and coalesce(pk.fuente,'') <> 'ACUMULADO_SEMANAL'
  ),
  perdia as (
    select sku, dia, fuente, sum(pedido) ped
      from src where bkt = v_bucket and coalesce(sku,'') <> '' and pedido > 0
     group by sku, dia, fuente
  )
  select coalesce(jsonb_object_agg(sku, h), '{}'::jsonb) into v_hist
    from (
      select sku, jsonb_agg(jsonb_build_object('fecha', dia, 'fuente', fuente, 'pedido', ped) order by dia) h
        from perdia group by sku
    ) z;
  v_hist := coalesce(v_hist, '{}'::jsonb);

  -- ensamblar: cada item del acumulado + su historial + pendiente
  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', it->>'skuBase',
           'nombre', coalesce(it->>'nombre', it->>'skuBase'),
           'solicitado', wh._num(coalesce(it->>'solicitado','0')),
           'despachado', wh._num(coalesce(it->>'despachado','0')),
           'pendiente', greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))),
           'historial', coalesce(v_hist->(it->>'skuBase'), '[]'::jsonb)
         ) order by greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) desc), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(v_acum) it;

  -- [no-se-entiende] renglones sin skuBase del bucket → SOLO constancia del pedido
  -- (jamás despachado). Sección aparte; NO entra a items ni a total_pendiente (deuda).
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'solicitado', ped, 'despachado', 0, 'fecha', to_char(dia,'YYYY-MM-DD')
         ) order by dia desc, nombre), '[]'::jsonb)
    into v_sinsku
    from (
      select upper(btrim(coalesce(it->>'nombre',''))) as nombre,
             (pk.fecha_creado at time zone 'America/Lima')::date as dia,
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
                          from jsonb_array_elements(v_acum) it));
end;
$function$
