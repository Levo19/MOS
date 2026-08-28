-- [984] MosGo F1b — el pedido del CLIENTE por la web va DIRECTO. Cuando llega una solicitud del lookbook
--  ETIQUETADA a un vendedor (catv_solicitudes.id_vendedor no nulo), un trigger la convierte en un
--  ruta.pedidos real (origen='web', a nombre del cliente web, con los precios que ya calculó el servidor),
--  lo que a su vez dispara el pickup MOSGO (trigger 980). La solicitud se marca ATENDIDO para que NO
--  aparezca duplicada como "pendiente". Solicitudes SIN vendedor siguen en el pozo como antes.
--  Todo exception-safe: si algo falla, la solicitud igual queda guardada (nunca se pierde el lead).
create or replace function mos._trg_catv_a_pedido() returns trigger
language plpgsql security definer set search_path to '' as $tg$
declare
  v_vend_nom text;
  v_items jsonb;
  v_id text;
begin
  begin
    if coalesce(nullif(btrim(NEW.id_vendedor),''),'') = '' then return null; end if;   -- sin dueño → pozo (como antes)

    select btrim(coalesce(nombre,'')||' '||coalesce(apellido,'')) into v_vend_nom
      from mos.personal where id_personal = NEW.id_vendedor and estado is true;
    if coalesce(v_vend_nom,'') = '' then return null; end if;

    -- mapear las líneas del catálogo → formato de ruta.pedidos.items
    select jsonb_agg(jsonb_build_object(
             'codigo_barra', l->>'cod_barras',
             'descripcion',  l->>'producto',
             'cant',         wh._num(l->>'cantidad'),
             'precio_unit',  wh._num(l->>'precio_unit'),
             'subtotal',     wh._num(l->>'subtotal'),
             'tramo',        coalesce(l->>'escalon','')
           )) into v_items
      from jsonb_array_elements(coalesce(NEW.lineas,'[]'::jsonb)) l
     where coalesce(l->>'cod_barras','') <> '';
    if v_items is null or jsonb_array_length(v_items) = 0 then return null; end if;

    v_id := 'R-' || lpad(nextval('ruta.seq_pedido')::text, 4, '0');
    insert into ruta.pedidos (id_pedido, local_id, documento_cliente, nombre_cliente, vendedor, id_vendedor,
      items, total, ahorro_total, nota, origen, estado)
    values (v_id, 'catv-'||NEW.codigo, '',
      coalesce(nullif(btrim(NEW.nombre),''),'Cliente web'), v_vend_nom, NEW.id_vendedor,
      v_items, coalesce(NEW.total,0), 0,
      'Pedido web'||case when coalesce(NEW.telefono,'')<>'' then ' · 📱 '||NEW.telefono else '' end,
      'web', 'CONFIRMADO')
    on conflict (local_id) do nothing;

    -- marcar la solicitud como atendida (ya nació el pedido) para no verla duplicada en "pendientes".
    update mos.catv_solicitudes set estado = 'ATENDIDO', atendido_por = v_vend_nom where codigo = NEW.codigo;
  exception when others then null;   -- jamás perder el lead por un fallo de conversión
  end;
  return null;
end; $tg$;

drop trigger if exists trg_catv_a_pedido on mos.catv_solicitudes;
create trigger trg_catv_a_pedido after insert on mos.catv_solicitudes
  for each row execute function mos._trg_catv_a_pedido();

select '984 mosgo web directo listo' as ok;
