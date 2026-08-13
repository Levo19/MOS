create or replace function mos.registrar_pago_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idPago','')), '');
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_monto numeric := mos._numn(p->>'monto');
  v_fecha timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PAGOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PAGOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_prov is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok',false,'error','Requiere monto válido (> 0)'); end if;

  if v_local is null then return jsonb_build_object('ok',false,'error','Requiere localId (idempotencia de pago)'); end if;

  select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
  if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;

  if v_id is not null and exists (select 1 from mos.pagos_proveedor where id_pago = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
  end if;

  begin
    v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());

  v_id := coalesce(v_id, 'PAG'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.pagos_proveedor (
    id_pago, id_proveedor, monto, fecha, numero_factura, estado, observacion, registrado_por, local_id
  ) values (
    v_id, v_prov, v_monto, v_fecha,
    nullif(btrim(coalesce(p->>'numeroFactura','')),''),
    coalesce(nullif(btrim(coalesce(p->>'estado','')),''),'PAGADO'),
    nullif(btrim(coalesce(p->>'observacion','')),''),
    nullif(btrim(coalesce(p->>'registradoPor','')),''),
    v_local
  )
  on conflict (local_id) where local_id is not null do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA (best-effort; el pago ya está commiteado)
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idPago', v_id));
exception
  when unique_violation then
    select id_pago into v_existe from mos.pagos_proveedor where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_existe)); end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idPago', v_id));
end;
$fn$;