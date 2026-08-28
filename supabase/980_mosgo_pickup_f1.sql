-- [980] MosGo F1 — Pedido → PICKUP MOSGO (directo a WH). Al confirmar un pedido (o al llegar uno de la web),
--  nace un pickup ÚNICO en wh.pickups (fuente='MOSGO', zona='MOSGO', estado PENDIENTE) con las líneas ya
--  canonizadas (skuBase + codigosOriginales para aceptar canónico+equivalentes). El pedido pasa a
--  EN_PREPARACION y se enlaza id_pickup. Almacén recibe un push "nuevo pedido a despachar". NO mueve stock
--  (eso ocurre recién al despachar). Los items guardan precioCanon (precio por unidad canónica) para que,
--  si el despacho es parcial, MosGo reajuste el total a la proporción del pack (F3).

create or replace function mos.ruta_pedido_a_pickup(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'id_pedido','')),'');
  v_ped    ruta.pedidos%rowtype;
  v_pk     text;
  v_built  jsonb;
  v_n      int;
  v_cli    text;
begin
  if v_id is null then return jsonb_build_object('ok',false,'error','id_pedido requerido'); end if;
  select * into v_ped from ruta.pedidos where id_pedido = v_id;
  if not found then return jsonb_build_object('ok',false,'error','pedido no existe'); end if;

  v_pk := 'PCK-MOSGO-' || v_id;
  -- idempotente: si ya tiene pickup, no duplicar.
  if coalesce(nullif(btrim(v_ped.id_pickup),''),'') <> '' or exists (select 1 from wh.pickups where id_pickup = v_pk) then
    return jsonb_build_object('ok',true,'dedup',true,'idPickup', coalesce(nullif(v_ped.id_pickup,''), v_pk));
  end if;

  v_cli := coalesce(nullif(btrim(v_ped.nombre_cliente),''),'cliente');

  -- items canónicos desde ruta.pedidos.items. p_um='' → cant SIEMPRE × factor (la cant de MosGo está en
  -- packs/tramos, factor la lleva a la unidad canónica del almacén). Se agrupa por sku_base.
  with src as (
    select it->>'codigo_barra' cb,
           wh._num((it->>'cant')::text) cant,
           wh._num(coalesce(it->>'subtotal', it->>'precio_unit','0')) sub,
           coalesce(it->>'descripcion','') dsc
      from jsonb_array_elements(coalesce(v_ped.items,'[]'::jsonb)) it
  ),
  det as (
    select s.sub, s.dsc, cv.sku_base sku, cv.cant ccant
      from src s cross join lateral mos._venta_canonico(s.cb, s.cant, '') cv
     where s.cant > 0
  ),
  agg as (
    select sku, sum(ccant) sol, sum(sub) sub, min(dsc) nom
      from det where coalesce(sku,'') <> '' group by sku having sum(ccant) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'skuBase', a.sku,
    'nombre', coalesce(nullif(a.nom,''),
      (select pp.descripcion from mos.productos pp where pp.sku_base=a.sku order by (pp.codigo_producto_base is null) desc limit 1),
      a.sku),
    'solicitado', a.sol,
    'despachado', 0,
    'precioCanon', round(a.sub / nullif(a.sol,0), 4),   -- [980] precio por unidad canónica → reajuste parcial
    'codigosOriginales', coalesce((select jsonb_agg(distinct cod) from (
        select pp.codigo_barra cod from mos.productos pp
          where pp.sku_base=a.sku and coalesce(pp.codigo_barra,'')<>'' and coalesce(nullif(pp.factor_conversion,0),1)=1
        union select e.codigo_barra from mos.equivalencias e where e.sku_base=a.sku and e.activo and coalesce(e.codigo_barra,'')<>''
      ) q),'[]'::jsonb)
  ) order by a.sku),'[]'::jsonb) into v_built from agg a;

  v_n := jsonb_array_length(coalesce(v_built,'[]'::jsonb));
  if v_n = 0 then
    return jsonb_build_object('ok',false,'error','pedido sin líneas canonizables');
  end if;

  insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
  values (v_pk, 'MOSGO', 'PENDIENTE', v_built, 'MOSGO',
          '[pedido:'||v_id||'] MosGo · '||coalesce(nullif(btrim(v_ped.vendedor),''),'?')||' → '||v_cli,
          coalesce(nullif(btrim(v_ped.vendedor),''),'MOSGO'), now(), now())
  on conflict (id_pickup) do nothing;

  update ruta.pedidos set id_pickup = v_pk,
         estado = case when estado in ('CONFIRMADO') then 'EN_PREPARACION' else estado end,
         updated_at = now()
   where id_pedido = v_id;

  -- aviso a TODO el almacén: nuevo pedido MosGo por despachar (jamás rompe la creación del pedido).
  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
      'titulo', '🛒 Nuevo pedido MosGo',
      'cuerpo', v_cli || ' · ' || v_n || ' producto' || case when v_n=1 then '' else 's' end || ' · listo para despachar',
      'data', jsonb_build_object('tipo','mosgo_pickup_nuevo','idPickup',v_pk,'idPedido',v_id)));
  exception when others then null;
  end;

  return jsonb_build_object('ok',true,'idPickup',v_pk,'items',v_n);
end; $fn$;

revoke all on function mos.ruta_pedido_a_pickup(jsonb) from public;
grant execute on function mos.ruta_pedido_a_pickup(jsonb) to authenticated, anon;

-- Enganche: cada pedido CONFIRMADO nuevo → su pickup MOSGO. El try/catch garantiza que si algo del pickup
-- falla, el PEDIDO igual queda creado (nunca se pierde una venta por un problema de almacén).
create or replace function mos._trg_ruta_pedido_a_pickup() returns trigger
language plpgsql security definer set search_path to '' as $tg$
begin
  begin
    if new.estado = 'CONFIRMADO' and coalesce(nullif(btrim(new.id_pickup),''),'') = '' then
      perform mos.ruta_pedido_a_pickup(jsonb_build_object('id_pedido', new.id_pedido));
    end if;
  exception when others then null;   -- jamás bloquear la creación del pedido
  end;
  return null;
end; $tg$;

drop trigger if exists trg_ruta_pedido_a_pickup on ruta.pedidos;
create trigger trg_ruta_pedido_a_pickup after insert on ruta.pedidos
  for each row execute function mos._trg_ruta_pedido_a_pickup();

select '980 mosgo pickup F1 listo' as ok;
