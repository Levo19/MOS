-- ════════════════════════════════════════════════════════════════════════════
-- 219 · wh.zona_pickup_detalle(p) — detalle del pickup acumulado de una zona + HISTORIAL
-- ════════════════════════════════════════════════════════════════════════════
-- Para la vista "Pickup" en MOS/zonas. Devuelve, por producto, lo pendiente (del
-- acumulado vivo) + el HISTORIAL por día (cuánto se pidió cada cierre del bucket).
-- Deriva el historial de los pickups del bucket (incluye ABSORBIDO) → NO toca la
-- consolidación money-crítica. anon-callable (solo lectura). 100% Supabase.
--   p = { "zona": "ZONA-02" }  (o "id_zona")
-- ════════════════════════════════════════════════════════════════════════════

create or replace function wh.zona_pickup_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date := wh._bucket_dom((now() at time zone 'America/Lima')::date);
  v_acum   jsonb;
  v_hist   jsonb;
  v_items  jsonb;
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

  return jsonb_build_object(
    'ok', true, 'zona', v_zona, 'bucket', to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items,
    'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')))),0)
                          from jsonb_array_elements(v_acum) it));
end;
$fn$;

revoke all on function wh.zona_pickup_detalle(jsonb) from public;
grant execute on function wh.zona_pickup_detalle(jsonb) to anon, authenticated, service_role;
