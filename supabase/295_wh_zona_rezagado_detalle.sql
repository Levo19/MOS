-- ============================================================================
-- 295_wh_zona_rezagado_detalle.sql — Detalle del REZAGADO de la semana pasada (por zona)
-- ----------------------------------------------------------------------------
-- Igual que wh.zona_pickup_detalle (137) pero para el bucket REZAGADO más reciente de la
-- zona (la semana que murió sin despacharse). Devuelve, por producto: solicitado /
-- despachado / pendiente + historial por día (cuándo se pidió y cuándo se despachó),
-- para reclamos. 100% Supabase, read-only. MOS lo consume (Content-Profile wh).
-- ============================================================================
create or replace function wh.zona_rezagado_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date;
  v_items  jsonb;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;

  -- Bucket REZAGADO más reciente de la zona (la semana pasada, no despachada).
  select to_date(right(id_pickup,10),'YYYY-MM-DD') into v_bucket
    from wh.pickups
   where coalesce(id_zona,'')=v_zona and fuente='ACUMULADO_SEMANAL'
     and upper(coalesce(estado,''))='REZAGADO'
     and id_pickup like 'PCK-ACU-'||v_zona||'-%'
     and right(id_pickup,10) ~ '^\d{4}-\d{2}-\d{2}$'
   order by to_date(right(id_pickup,10),'YYYY-MM-DD') desc
   limit 1;

  if v_bucket is null then
    return jsonb_build_object('ok',true,'zona',v_zona,'rezagado',true,'sin_rezagado',true,
      'items','[]'::jsonb,'total_items',0,'total_pendiente',0,'total_despachado',0);
  end if;

  -- Mismo cómputo que zona_pickup_detalle, pero para el bucket REZAGADO (v_bucket).
  with ped as (
    select it->>'skuBase' sku, (pk.fecha_creado at time zone 'America/Lima')::date dia,
           sum(wh._num(coalesce(it->>'solicitado','0'))) cant, max(it->>'nombre') nombre
    from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
    where coalesce(pk.id_zona,'')=v_zona and coalesce(pk.fuente,'')<>'ACUMULADO_SEMANAL'
      and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date)=v_bucket
      and coalesce(it->>'skuBase','')<>''
    group by 1,2
  ),
  desp as (
    select coalesce(pr.sku_base, gd.cod_producto) sku, (g.fecha at time zone 'America/Lima')::date dia,
           sum(coalesce(gd.cant_recibida, gd.cantidad_aplicada, 0)) cant
    from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
    left join mos.productos pr on pr.codigo_barra=gd.cod_producto
    where g.tipo='SALIDA_ZONA' and coalesce(g.id_zona,'')=v_zona
      and wh._bucket_dom((g.fecha at time zone 'America/Lima')::date)=v_bucket
    group by 1,2
  ),
  skus as (select sku from ped union select sku from desp),
  agg as (
    select s.sku,
      (select max(nombre) from ped where ped.sku=s.sku) nombre,
      coalesce((select sum(cant) from ped where ped.sku=s.sku),0) pedido,
      coalesce((select sum(cant) from desp where desp.sku=s.sku),0) despacho
    from skus s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'skuBase', a.sku, 'nombre', coalesce(a.nombre, a.sku),
    'solicitado', a.pedido, 'despachado', a.despacho,
    'pendiente', greatest(0, a.pedido - a.despacho),
    'historial', (
      select coalesce(jsonb_agg(h.obj order by (h.obj->>'fecha'), (h.obj->>'tipo') desc), '[]'::jsonb)
      from (
        select jsonb_build_object('fecha',dia,'tipo','pedido','cant',cant) obj from ped where ped.sku=a.sku
        union all
        select jsonb_build_object('fecha',dia,'tipo','despacho','cant',cant) from desp where desp.sku=a.sku
      ) h)
  ) order by greatest(0, a.pedido - a.despacho) desc), '[]'::jsonb)
  into v_items from agg a where greatest(0, a.pedido - a.despacho) > 0;   -- solo lo que QUEDÓ pendiente

  return jsonb_build_object('ok',true,'zona',v_zona,'rezagado',true,'bucket',to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items, 'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0,(x->>'solicitado')::numeric-(x->>'despachado')::numeric)),0) from jsonb_array_elements(v_items) x),
    'total_despachado', (select coalesce(sum((x->>'despachado')::numeric),0) from jsonb_array_elements(v_items) x));
end; $fn$;
revoke all on function wh.zona_rezagado_detalle(jsonb) from public;
grant execute on function wh.zona_rezagado_detalle(jsonb) to anon, authenticated, service_role;
