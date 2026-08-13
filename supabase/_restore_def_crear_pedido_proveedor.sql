create or replace function mos.crear_pedido_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idPedido','')), '');
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_items jsonb;
  v_monto numeric := mos._numn(p->>'montoEstimado');
  v_fest  timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PEDIDOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PEDIDOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_prov is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;

  if (p ? 'items') and jsonb_typeof(p->'items') = 'array' then
    v_items := p->'items';
  else
    v_items := '[]'::jsonb;
  end if;

  begin
    v_fest := nullif(btrim(coalesce(p->>'fechaEstimada','')),'')::timestamptz;
  exception when others then v_fest := null;
  end;

  if v_local is not null then
    select id_pedido into v_existe from mos.pedidos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_existe)); end if;
  end if;
  if v_id is not null and exists (select 1 from mos.pedidos_proveedor where id_pedido = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_id));
  end if;

  v_id := coalesce(v_id, 'PED'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.pedidos_proveedor (
    id_pedido, id_proveedor, items, monto_estimado, estado, fecha_creacion, fecha_estimada, usuario, notas, local_id
  ) values (
    v_id, v_prov, v_items, coalesce(v_monto,0), 'BORRADOR', now(), v_fest,
    nullif(btrim(coalesce(p->>'usuario','')),''),
    nullif(btrim(coalesce(p->>'notas','')),''),
    v_local
  )
  on conflict (id_pedido) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_pedido into v_existe from mos.pedidos_proveedor where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idPedido', v_id));
exception
  when unique_violation then
    if v_local is not null then
      select id_pedido into v_existe from mos.pedidos_proveedor where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPedido', v_id));
end;
$fn$;