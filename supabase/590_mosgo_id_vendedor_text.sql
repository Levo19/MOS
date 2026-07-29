-- 590 · [MosGo · fix 400] ruta_pedido_crear EXPLOTABA con "invalid input syntax for type bigint":
-- el frontend manda id_vendedor = id_personal de MOS (TEXT, ej. 'PER26...') y la columna era
-- bigint → excepción → PostgREST 400 → NINGÚN pedido se creó jamás (la cola offline reintenta
-- el 400 para siempre). Columna a text (tabla vacía: 0 filas) + quitar el cast del RPC.
alter table ruta.pedidos alter column id_vendedor type text using id_vendedor::text;

create or replace function mos.ruta_pedido_crear(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_local text := btrim(coalesce(p->>'local_id',''));
  v_vend  text := btrim(coalesce(p->>'vendedor',''));
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_it jsonb; v_total numeric := 0; v_ahorro numeric := 0;
  v_cant numeric; v_pu numeric; v_sub numeric; v_unit numeric;
  v_clean jsonb := '[]'::jsonb; v_id text; v_ex ruta.pedidos%rowtype;
begin
  if v_local = '' or v_vend = '' then return jsonb_build_object('ok', false, 'error', 'local_id y vendedor requeridos'); end if;
  if jsonb_array_length(v_items) = 0 then return jsonb_build_object('ok', false, 'error', 'pedido vacío'); end if;

  select * into v_ex from ruta.pedidos where local_id = v_local;
  if found then
    return jsonb_build_object('ok', true, 'id_pedido', v_ex.id_pedido, 'estado', v_ex.estado,
      'total', v_ex.total, 'dedup', true);
  end if;

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_cant := coalesce((v_it->>'cant')::numeric, 0);
    v_pu   := coalesce((v_it->>'precio_unit')::numeric, 0);
    if v_cant <= 0 or v_pu <= 0 then return jsonb_build_object('ok', false, 'error', 'item inválido: ' || coalesce(v_it->>'codigo_barra','?')); end if;
    v_sub := round(v_cant * v_pu, 2);
    select precio_venta into v_unit from mos.productos where codigo_barra = v_it->>'codigo_barra';
    v_total  := round(v_total + v_sub, 2);
    v_ahorro := round(v_ahorro + greatest(0, round(v_cant * coalesce(v_unit, v_pu), 2) - v_sub), 2);
    v_clean := v_clean || jsonb_build_object(
      'codigo_barra', v_it->>'codigo_barra', 'descripcion', coalesce(v_it->>'descripcion',''),
      'cant', v_cant, 'precio_unit', v_pu, 'subtotal', v_sub,
      'tramo', coalesce(v_it->>'tramo',''));
  end loop;

  v_id := 'R-' || lpad(nextval('ruta.seq_pedido')::text, 4, '0');
  insert into ruta.pedidos (id_pedido, local_id, documento_cliente, nombre_cliente, vendedor, id_vendedor,
    items, total, ahorro_total, fecha_entrega, nota)
  values (v_id, v_local, coalesce(p->>'documento_cliente',''), coalesce(p->>'nombre_cliente',''),
    v_vend, nullif(p->>'id_vendedor',''), v_clean, v_total, v_ahorro,
    nullif(p->>'fecha_entrega','')::date, coalesce(p->>'nota',''))
  on conflict (local_id) do nothing;
  return jsonb_build_object('ok', true, 'id_pedido', v_id, 'estado', 'CONFIRMADO', 'total', v_total, 'ahorro', v_ahorro);
end; $function$;

notify pgrst, 'reload schema';
