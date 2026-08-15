-- 789_zpk_stock_almacen.sql — [SEMÁFORO DE URGENCIA · chip de stock de almacén]
-- Pedido del dueño (2026-08-15): en MOS→Zonas→Pickup acumulado quiere ver, por producto,
-- el STOCK DE ALMACÉN (chip) — y el front sube la alerta cuando la zona reclama deuda Y
-- el almacén SÍ tiene stock para despachar. El resto del semáforo (veces pedido, deuda,
-- antigüedad, origen cierre/sombra/RIZ) ya viaja en `historial` desde el 607/760.
--
-- Cambio ÚNICO: ambas RPCs de detalle (pickup vivo + rezagado) agregan `stockWh` por item.
-- stockWh = Σ wh.stock.cantidad_disponible de TODOS los códigos que resuelven al sku
-- (productos + equivalencias, mismo join que ya usa el CTE `despachos` — consistencia).
-- Nada más se toca: historial, constancias [606], horas [607]/[760] y orden quedan igual
-- (el ORDEN por urgencia lo decide el FRONT 2.43.801, que re-ordena client-side).

-- ── (1) pickup acumulado en vivo ──
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
  v_stock  jsonb;   -- [789] sku → stock de almacén
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

  -- [789] stock de almacén por sku (mismo join productos+equivalencias que `despachos`).
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', it->>'skuBase',
           'nombre', coalesce(it->>'nombre', it->>'skuBase'),
           'solicitado', wh._num(coalesce(it->>'solicitado','0')),
           'despachado', wh._num(coalesce(it->>'despachado','0')),
           'pendiente', greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))),
           'tsSolicitud', it->>'tsSolicitud',   -- [607] hora en que el producto entró al acumulado
           'tsDespacho',  it->>'tsDespacho',    -- [607] hora del último despacho marcado (WH)
           'stockWh', coalesce((v_stock->>(it->>'skuBase'))::numeric, 0),   -- [789] stock de almacén
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
$function$;

-- ── (2) rezagado semana pasada: mismo chip `stockWh` (el modal comparte render) ──
CREATE OR REPLACE FUNCTION wh.zona_rezagado_detalle(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date;
  v_stock  jsonb;   -- [789] sku → stock de almacén
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

  -- [789] stock de almacén por sku (idéntico al de zona_pickup_detalle).
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
    'stockWh', coalesce((v_stock->>(a.sku))::numeric, 0),   -- [789] stock de almacén
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
