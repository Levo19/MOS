create or replace function mos.crear_proveedor(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local  text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_nombre text := nullif(btrim(coalesce(p->>'nombre','')), '');
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PROVEEDORES_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PROVEEDORES_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_nombre is null then return jsonb_build_object('ok',false,'error','El nombre es requerido'); end if;

  if v_local is not null then
    select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe));
    end if;
  end if;

  if v_id is not null and exists (select 1 from mos.proveedores where id_proveedor = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_id));
  end if;

  v_id := coalesce(v_id, 'PROV'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.proveedores (
    id_proveedor, nombre, ruc, imagen, telefono, banco, numero_cuenta, cci, email,
    dia_pedido, dia_pago, dia_entrega, forma_pago, plazo_credito, responsable, categoria_producto,
    estado, local_id
  ) values (
    v_id, v_nombre,
    nullif(btrim(coalesce(p->>'ruc','')),''),
    nullif(btrim(coalesce(p->>'imagen','')),''),
    nullif(btrim(coalesce(p->>'telefono','')),''),
    nullif(btrim(coalesce(p->>'banco','')),''),
    nullif(btrim(coalesce(p->>'numeroCuenta','')),''),
    nullif(btrim(coalesce(p->>'cci','')),''),
    nullif(btrim(coalesce(p->>'email','')),''),
    nullif(btrim(coalesce(p->>'diaPedido','')),''),
    nullif(btrim(coalesce(p->>'diaPago','')),''),
    nullif(btrim(coalesce(p->>'diaEntrega','')),''),
    coalesce(nullif(btrim(coalesce(p->>'formaPago','')),''),'CONTADO'),
    coalesce(nullif(btrim(coalesce(p->>'plazoCredito','')),''),'0'),
    nullif(btrim(coalesce(p->>'responsable','')),''),
    nullif(btrim(coalesce(p->>'categoriaProducto','')),''),
    '1',
    v_local
  )
  on conflict (id_proveedor) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    if v_local is not null then
      select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_id));
  end if;

  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA (best-effort, no rompe la tx)
  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idProveedor', v_id));
exception
  when unique_violation then
    if v_local is not null then
      select id_proveedor into v_existe from mos.proveedores where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idProveedor', v_id));
end;
$fn$;