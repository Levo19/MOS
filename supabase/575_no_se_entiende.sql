-- 575 · "NO SE ENTIENDE" — renglones de lista sombra que el IA nunca identifica
-- (skuBase=''). Se guardan en el pickup al cerrar (SOLO pedido; despachado SIEMPRE 0,
-- sin código de barra no hay escaneo) y las vistas de zona los devuelven en una
-- sección aparte 'sinIdentificar' (constancia: qué se pidió mal, cuándo, cuánto).
-- consolidar_pickup_zona los saltea (skuBase='') → NUNCA suman deuda de reposición.
-- Base exacta: 540 (cerrar) + 219 (pickup actual) + 295 (rezagado), patch quirúrgico.

create or replace function wh.cerrar_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_items jsonb := p->'items';
  v_row  record;
  v_final jsonb;
  v_pick jsonb;
  v_sinsku jsonb;
  v_now  timestamptz := now();
begin
  if v_items is not null and jsonb_typeof(v_items) = 'string' then
    begin v_items := (p->>'items')::jsonb; exception when others then v_items := null; end;
  end if;
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;

  select * into v_row from wh.listas_sombra where id_lista = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  -- Idempotencia: un retry sobre una lista ya cerrada NO re-contabiliza.
  if upper(coalesce(v_row.estado,'')) in ('COMPLETADA','ANULADA') then
    return jsonb_build_object('ok',true,'idempotente',true); end if;

  v_final := case when v_items is not null and jsonb_typeof(v_items)='array' then v_items else v_row.items end;
  update wh.listas_sombra
     set items = coalesce(v_final, items), estado='COMPLETADA', fecha_completada=v_now
   where id_lista = v_id;

  -- [540] deuda_nueva = max(0, deuda + pedido − despachado): se materializa vía
  -- pickup PCK-LSC (sol=pedido, desp=escaneado) que el consolidador mergea.
  if coalesce(btrim(v_row.zona),'') <> '' and v_final is not null and jsonb_typeof(v_final)='array' then
    begin
      select coalesce(jsonb_agg(jsonb_build_object(
               'skuBase',    it->>'skuBase',
               'nombre',     coalesce(nullif(btrim(coalesce(it->>'nombreMaster','')),''), it->>'nombre', it->>'skuBase'),
               'solicitado', wh._num(coalesce(it->>'cantidad','0')),
               'despachado', wh._num(coalesce(it->>'cantidadEscaneada','0'))
             )), '[]'::jsonb)
        into v_pick
        from jsonb_array_elements(v_final) it
       where coalesce(btrim(it->>'skuBase'),'') <> ''
         and (wh._num(coalesce(it->>'cantidad','0')) > 0 or wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0);
      -- [no-se-entiende] renglones que el IA nunca identificó (skuBase=''): SOLO
      -- constancia del pedido. despachado SIEMPRE 0 (sin código de barra no hay
      -- escaneo). consolidar_pickup_zona los saltea (skuBase='') → jamás suman deuda.
      select coalesce(jsonb_agg(jsonb_build_object(
               'skuBase',    '',
               'sinSku',     true,
               'nombre',     coalesce(nullif(btrim(coalesce(it->>'nombre','')),''), 'SIN NOMBRE'),
               'solicitado', wh._num(coalesce(it->>'cantidad','0')),
               'despachado', 0
             )), '[]'::jsonb)
        into v_sinsku
        from jsonb_array_elements(v_final) it
       where coalesce(btrim(it->>'skuBase'),'') = ''
         and wh._num(coalesce(it->>'cantidad','0')) > 0;
      v_pick := coalesce(v_pick,'[]'::jsonb) || coalesce(v_sinsku,'[]'::jsonb);
      if v_pick is not null and jsonb_array_length(v_pick) > 0 then
        insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
        values ('PCK-LSC-'||v_id, 'LISTA_IA', 'PENDIENTE', v_pick, btrim(v_row.zona),
                'Cierre lista IA '||v_id||' · pedido−despachado → acumulado', coalesce(v_row.usuario_tomada, v_row.usuario_creador, 'sistema'), v_now, v_now)
        on conflict (id_pickup) do nothing;
      end if;
    exception when others then null;  -- la contabilidad jamás rompe el cierre (cron repara)
    end;
  end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function wh.zona_pickup_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
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
$fn$;

create or replace function wh.zona_rezagado_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date;
  v_items  jsonb;
  v_sinsku jsonb;
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

  -- [no-se-entiende] renglones sin skuBase del bucket rezagado → SOLO constancia.
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

  return jsonb_build_object('ok',true,'zona',v_zona,'rezagado',true,'bucket',to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items, 'sinIdentificar', coalesce(v_sinsku,'[]'::jsonb), 'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0,(x->>'solicitado')::numeric-(x->>'despachado')::numeric)),0) from jsonb_array_elements(v_items) x),
    'total_despachado', (select coalesce(sum((x->>'despachado')::numeric),0) from jsonb_array_elements(v_items) x));
end; $fn$;

notify pgrst, 'reload schema';
