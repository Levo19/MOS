create or replace function mos.actualizar_pedido_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idPedido','')), '');
  v_items jsonb;
  v_fest  timestamptz;
  v_fest_set boolean := false;
  v_n     int;
begin
  if coalesce((select valor from mos.config where clave='MOS_PEDIDOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PEDIDOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idPedido'); end if;

  if (p ? 'items') and jsonb_typeof(p->'items') = 'array' then v_items := p->'items'; end if;

  if p ? 'fechaEstimada' then
    v_fest_set := true;
    begin v_fest := nullif(btrim(coalesce(p->>'fechaEstimada','')),'')::timestamptz;
    exception when others then v_fest := null; end;
  end if;

  update mos.pedidos_proveedor t set
    estado         = case when p ? 'estado'        then nullif(btrim(coalesce(p->>'estado','')),'')   else t.estado end,
    items          = case when v_items is not null  then v_items                                       else t.items end,
    monto_estimado = case when p ? 'montoEstimado'  then coalesce(mos._numn(p->>'montoEstimado'),0)    else t.monto_estimado end,
    notas          = case when p ? 'notas'          then nullif(btrim(coalesce(p->>'notas','')),'')    else t.notas end,
    fecha_estimada = case when v_fest_set           then v_fest                                        else t.fecha_estimada end
  where id_pedido = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Pedido no encontrado'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true);
end;
$fn$;