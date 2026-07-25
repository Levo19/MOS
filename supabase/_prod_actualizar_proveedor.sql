CREATE OR REPLACE FUNCTION mos.actualizar_proveedor(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_n  int;
begin
  if coalesce((select valor from mos.config where clave='MOS_PROVEEDORES_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PROVEEDORES_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idProveedor'); end if;

  update mos.proveedores t set
    nombre             = case when p ? 'nombre'            then nullif(btrim(coalesce(p->>'nombre','')),'')             else t.nombre end,
    ruc                = case when p ? 'ruc'               then nullif(btrim(coalesce(p->>'ruc','')),'')                else t.ruc end,
    telefono           = case when p ? 'telefono'          then nullif(btrim(coalesce(p->>'telefono','')),'')           else t.telefono end,
    banco              = case when p ? 'banco'             then nullif(btrim(coalesce(p->>'banco','')),'')              else t.banco end,
    numero_cuenta      = case when p ? 'numeroCuenta'      then nullif(btrim(coalesce(p->>'numeroCuenta','')),'')       else t.numero_cuenta end,
    cci                = case when p ? 'cci'               then nullif(btrim(coalesce(p->>'cci','')),'')                else t.cci end,
    email              = case when p ? 'email'             then nullif(btrim(coalesce(p->>'email','')),'')              else t.email end,
    dia_pedido         = case when p ? 'diaPedido'         then nullif(btrim(coalesce(p->>'diaPedido','')),'')          else t.dia_pedido end,
    dia_pago           = case when p ? 'diaPago'           then nullif(btrim(coalesce(p->>'diaPago','')),'')            else t.dia_pago end,
    dia_entrega        = case when p ? 'diaEntrega'        then nullif(btrim(coalesce(p->>'diaEntrega','')),'')         else t.dia_entrega end,
    forma_pago         = case when p ? 'formaPago'         then nullif(btrim(coalesce(p->>'formaPago','')),'')          else t.forma_pago end,
    plazo_credito      = case when p ? 'plazoCredito'      then nullif(btrim(coalesce(p->>'plazoCredito','')),'')       else t.plazo_credito end,
    responsable        = case when p ? 'responsable'       then nullif(btrim(coalesce(p->>'responsable','')),'')        else t.responsable end,
    categoria_producto = case when p ? 'categoriaProducto' then nullif(btrim(coalesce(p->>'categoriaProducto','')),'')  else t.categoria_producto end,
    estado             = case when p ? 'estado'            then nullif(btrim(coalesce(p->>'estado','')),'')             else t.estado end
  where id_proveedor = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Proveedor no encontrado'); end if;
  perform mos._tocar_latido_sync();   -- HEARTBEAT-POR-ESCRITURA
  return jsonb_build_object('ok',true);
end;
$function$
