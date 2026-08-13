-- 760 · Horas reales en el REZAGADO (12-ago-2026) — paridad con el pickup (607).
-- La vista MOS → Zonas → Rezagado mostraba solo el día; el front (2.43.741) ya pinta
-- "🕐 pedido → salió" si la RPC manda tsSolicitud/tsDespacho, y los eventos del historial
-- con hora si la fecha viene 'YYYY-MM-DD"T"HH24:MI'. Fuentes de hora: pk.fecha_creado
-- (hora real del cierre/pedido) y gd.created_at (hora real del escaneo por línea, 607/608).
CREATE OR REPLACE FUNCTION wh.zona_rezagado_detalle(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date;
  v_items  jsonb;
  v_sinsku jsonb;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;

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

  -- [760] ped/desp conservan la HORA: ped = hora del pickup que trajo el pedido;
  -- desp = hora real del escaneo por línea (gd.created_at, backfill = fecha de guía).
  with ped as (
    select it->>'skuBase' sku, (pk.fecha_creado at time zone 'America/Lima')::date dia,
           sum(wh._num(coalesce(it->>'solicitado','0'))) cant, max(it->>'nombre') nombre,
           min(pk.fecha_creado) ts
    from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
    where coalesce(pk.id_zona,'')=v_zona and coalesce(pk.fuente,'')<>'ACUMULADO_SEMANAL'
      and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date)=v_bucket
      and coalesce(it->>'skuBase','')<>''
    group by 1,2
  ),
  desp as (
    select coalesce(pr.sku_base, gd.cod_producto) sku, (g.fecha at time zone 'America/Lima')::date dia,
           sum(coalesce(gd.cant_recibida, gd.cantidad_aplicada, 0)) cant,
           min(coalesce(gd.created_at, g.fecha)) ts_primero,
           max(coalesce(gd.created_at, g.fecha)) ts_ultimo
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
      coalesce((select sum(cant) from desp where desp.sku=s.sku),0) despacho,
      (select min(ts) from ped where ped.sku=s.sku) ts_ped,
      (select max(ts_ultimo) from desp where desp.sku=s.sku) ts_desp
    from skus s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'skuBase', a.sku, 'nombre', coalesce(a.nombre, a.sku),
    'solicitado', a.pedido, 'despachado', a.despacho,
    'pendiente', greatest(0, a.pedido - a.despacho),
    -- [760] horas por item — el front (2.43.741) las pinta como "🕐 pedido → salió"
    'tsSolicitud', case when a.ts_ped  is not null then to_char(a.ts_ped  at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI') end,
    'tsDespacho',  case when a.ts_desp is not null then to_char(a.ts_desp at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI') end,
    'historial', (
      select coalesce(jsonb_agg(h.obj order by (h.obj->>'fecha'), (h.obj->>'tipo') desc), '[]'::jsonb)
      from (
        select jsonb_build_object('fecha', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'), 'tipo','pedido','cant',cant) obj
          from ped where ped.sku=a.sku
        union all
        select jsonb_build_object('fecha', to_char(ts_primero at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'), 'tipo','despacho','cant',cant)
          from desp where desp.sku=a.sku
      ) h)
  ) order by greatest(0, a.pedido - a.despacho) desc), '[]'::jsonb)
  into v_items from agg a where greatest(0, a.pedido - a.despacho) > 0;

  -- [no-se-entiende] constancias del bucket rezagado — ahora también CON HORA.
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'solicitado', ped, 'despachado', 0,
           'fecha', to_char(ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')
         ) order by ts desc, nombre), '[]'::jsonb)
    into v_sinsku
    from (
      select upper(btrim(coalesce(it->>'nombre',''))) as nombre,
             min(pk.fecha_creado) as ts,
             sum(wh._num(coalesce(it->>'solicitado','0'))) as ped
        from wh.pickups pk
        cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
       where coalesce(pk.id_zona,'') = v_zona
         and coalesce(pk.fuente,'') = 'LISTA_IA'
         and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
         and coalesce(btrim(it->>'skuBase'),'') = ''
         and wh._num(coalesce(it->>'solicitado','0')) > 0
       group by 1, (pk.fecha_creado at time zone 'America/Lima')::date
      having sum(wh._num(coalesce(it->>'solicitado','0'))) > 0
    ) q;

  return jsonb_build_object('ok',true,'zona',v_zona,'rezagado',true,'bucket',to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items, 'sinIdentificar', coalesce(v_sinsku,'[]'::jsonb), 'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0,(x->>'solicitado')::numeric-(x->>'despachado')::numeric)),0) from jsonb_array_elements(v_items) x),
    'total_despachado', (select coalesce(sum((x->>'despachado')::numeric),0) from jsonb_array_elements(v_items) x));
end; $function$;
