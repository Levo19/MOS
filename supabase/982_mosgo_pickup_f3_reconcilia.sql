-- [982] MosGo F3 — al DESPACHAR el pickup MOSGO, reconciliar el pedido. Cuando almacén cierra el pickup
--  (wh.cerrar_pickup_con_despacho → estado COMPLETADO/PARCIAL con item.despachado lleno), un trigger:
--   1) ajusta el TOTAL del pedido a lo REALMENTE despachado (precio proporcional del pack: despachado×precioCanon);
--   2) guarda el "split" (solicitado vs despachado por línea) en ruta.pedidos.despacho para el card dividido;
--   3) enlaza id_guia y pasa el pedido a DESPACHADO (= "listo para recoger");
--   4) avisa al VENDEDOR por push que su pedido ya está listo.
--  Todo money/ops-safe: si algo falla, el despacho de WH NO se rompe (la reconciliación es best-effort).

alter table ruta.pedidos add column if not exists total_original numeric(12,2);
alter table ruta.pedidos add column if not exists despacho       jsonb;
alter table ruta.pedidos add column if not exists origen         text default 'app';   -- 'app' | 'web'
alter table ruta.pedidos add column if not exists ts_despachado  timestamptz;

create or replace function mos._mosgo_pickup_reconciliar(p_id_pickup text) returns void
language plpgsql security definer set search_path to '' as $fn$
declare
  v_pk    wh.pickups%rowtype;
  v_ped   text;
  v_guia  text;
  v_split jsonb;
  v_totd  numeric := 0;
  v_ped_row ruta.pedidos%rowtype;
begin
  select * into v_pk from wh.pickups where id_pickup = p_id_pickup;
  if not found then return; end if;
  if upper(coalesce(v_pk.fuente,'')) <> 'MOSGO' and upper(coalesce(v_pk.id_zona,'')) <> 'MOSGO' then return; end if;

  -- id del pedido desde las notas: '[pedido:R-xxxx] ...'
  v_ped := substring(coalesce(v_pk.notas,'') from '\[pedido:([^\]]+)\]');
  if v_ped is null then return; end if;
  select * into v_ped_row from ruta.pedidos where id_pedido = v_ped;
  if not found then return; end if;
  if v_ped_row.estado in ('DESPACHADO','ENTREGADO','COBRADO','RENDIDO','VERIFICADO') then return; end if;  -- idempotente

  -- split por línea + total despachado (precio proporcional del pack).
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'skuBase', it->>'skuBase',
      'nombre',  it->>'nombre',
      'solicitado', wh._num(it->>'solicitado'),
      'despachado', wh._num(it->>'despachado'),
      'precioCanon', wh._num(it->>'precioCanon'),
      'valor', round(wh._num(it->>'despachado') * wh._num(it->>'precioCanon'), 2),
      'completo', wh._num(it->>'despachado') >= wh._num(it->>'solicitado')
    ) order by it->>'nombre'),'[]'::jsonb),
    coalesce(sum(round(wh._num(it->>'despachado') * wh._num(it->>'precioCanon'), 2)),0)
    into v_split, v_totd
    from jsonb_array_elements(coalesce(v_pk.items,'[]'::jsonb)) it;

  -- guía generada por el despacho (comentario '[pickup:<idPickup>]').
  select id_guia into v_guia from wh.guias
    where comentario like '%[pickup:'||p_id_pickup||']%' order by fecha desc limit 1;

  update ruta.pedidos set
    total_original = coalesce(total_original, total),
    total          = v_totd,
    despacho       = jsonb_build_object('items', v_split, 'total_despachado', v_totd,
                       'id_guia', v_guia, 'estado_pickup', v_pk.estado, 'ts', now()),
    id_guia        = coalesce(v_guia, id_guia),
    estado         = 'DESPACHADO',
    ts_despachado  = now(),
    updated_at     = now()
  where id_pedido = v_ped;

  -- push al vendedor: su pedido está listo para recoger.
  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('usuarios', jsonb_build_array(v_ped_row.vendedor)),
      'titulo', '🎁 ¡Pedido listo para recoger!',
      'cuerpo', coalesce(nullif(btrim(v_ped_row.nombre_cliente),''),'Tu cliente') || ' · ' || v_ped ||
                ' ya está despachado en almacén (' || to_char(v_totd,'FM999999990.00') || ').',
      'data', jsonb_build_object('tipo','mosgo_pedido_listo','idPedido',v_ped,'idPickup',p_id_pickup)));
  exception when others then null;
  end;
end; $fn$;

create or replace function mos._trg_mosgo_pickup_cerrado() returns trigger
language plpgsql security definer set search_path to '' as $tg$
begin
  begin
    if (upper(coalesce(NEW.fuente,'')) = 'MOSGO' or upper(coalesce(NEW.id_zona,'')) = 'MOSGO')
       and NEW.estado in ('COMPLETADO','PARCIAL')
       and NEW.estado is distinct from OLD.estado then
      perform mos._mosgo_pickup_reconciliar(NEW.id_pickup);
    end if;
  exception when others then null;   -- nunca romper el cierre del despacho en WH
  end;
  return null;
end; $tg$;

drop trigger if exists trg_mosgo_pickup_cerrado on wh.pickups;
create trigger trg_mosgo_pickup_cerrado after update on wh.pickups
  for each row execute function mos._trg_mosgo_pickup_cerrado();

select '982 mosgo pickup F3 reconcilia listo' as ok;
