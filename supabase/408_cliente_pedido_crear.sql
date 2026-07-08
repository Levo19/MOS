-- 408 · RPC que inserta un pedido de cliente (PREVIEW) + items + adjuntos en 1 llamada. La usa la Edge
-- `recibir-pedido` (service role) tras correr la IA. Auto-alta del cliente si el token es desconocido.

create or replace function wh.cliente_pedido_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_token text := coalesce(nullif(btrim(upper(coalesce(p->>'token',''))),''),'ANON');
  v_id    text := 'PC' || (extract(epoch from clock_timestamp())*1000)::bigint::text || (floor(random()*1000))::int::text;
  v_nota  text := left(btrim(coalesce(p->>'nota','')), 300);
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_adj   jsonb := coalesce(p->'adjuntos','[]'::jsonb);
  v_nombre text; it jsonb; i int := 0; a jsonb; j int := 0;
begin
  -- Auto-alta silenciosa si el token no existe (espeja el GAS).
  if v_token <> 'ANON' and not exists (select 1 from wh.clientes_portal where token = v_token) then
    insert into wh.clientes_portal (token, nombre) values (v_token, v_token) on conflict do nothing;
  end if;
  select nombre into v_nombre from wh.clientes_portal where token = v_token;
  v_nombre := coalesce(v_nombre, 'Cliente anónimo');

  insert into wh.pedidos_cliente (id_pedido, token, ts, estado, notas)
  values (v_id, v_token, now(), 'PREVIEW', v_nota);

  for it in select * from jsonb_array_elements(v_items) loop
    insert into wh.pedidos_cliente_items (id_pedido, idx, nombre, cantidad, unidad, precio_est, duda)
    values (v_id, i,
            upper(btrim(coalesce(it->>'nombre',''))),
            round((coalesce((it->>'cantidad')::numeric,0))*10)/10,
            coalesce(nullif(btrim(it->>'unidad'),''),'unidad'),
            0, coalesce(it->>'duda',''));
    i := i + 1;
  end loop;

  for a in select * from jsonb_array_elements(v_adj) loop
    insert into wh.pedidos_cliente_adj (id_pedido, idx, tipo, nombre_archivo, url)
    values (v_id, j, coalesce(a->>'tipo',''), coalesce(a->>'nombre',''), coalesce(a->>'url',''));
    j := j + 1;
  end loop;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idPedido', v_id, 'nombreCliente', v_nombre,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'nombre', pi.nombre, 'cantidad', pi.cantidad, 'unidad', pi.unidad, 'duda', pi.duda) order by pi.idx)
      from wh.pedidos_cliente_items pi where pi.id_pedido = v_id), '[]'::jsonb)));
end; $fn$;

grant execute on function wh.cliente_pedido_crear(jsonb) to service_role;
