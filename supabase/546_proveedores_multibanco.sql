-- ════════════════════════════════════════════════════════════════════════════
-- 546 · Proveedores: MULTI-BANCO jsonb (tarjeta de presentación v2)
-- ════════════════════════════════════════════════════════════════════════════
-- Regla del dueño: banco/cuenta/cci sueltos era un error de modelo — un proveedor
-- puede tener VARIOS bancos. bancos jsonb = [{banco, cuenta, cci}]. Se migran los
-- existentes; banco/numero_cuenta/cci quedan como legacy de solo lectura.

alter table mos.proveedores add column if not exists bancos jsonb;

-- migración one-shot de los campos sueltos
update mos.proveedores set bancos = jsonb_build_array(jsonb_build_object('banco', banco, 'cuenta', coalesce(numero_cuenta,''), 'cci', coalesce(cci,'')))
 where bancos is null and nullif(btrim(coalesce(banco,'')),'') is not null;

CREATE OR REPLACE FUNCTION mos.proveedores_lista(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_estado text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_q      text := lower(nullif(btrim(coalesce(p->>'q','')), ''));
  v_data   jsonb;
  v_count  int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(row order by row->>'idProveedor'), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idProveedor',       t.id_proveedor,
      'nombre',            t.nombre,
      'ruc',               t.ruc,
      'imagen',            t.imagen,
      'telefono',          t.telefono,
      'banco',             t.banco,
      'numeroCuenta',      t.numero_cuenta,
      'cci',               t.cci,
      'email',             t.email,
      'diaPedido',         t.dia_pedido,
      'diaPago',           t.dia_pago,
      'diaEntrega',        t.dia_entrega,
      'formaPago',         t.forma_pago,
      'plazoCredito',      t.plazo_credito,
      'responsable',       t.responsable,
      'categoriaProducto', t.categoria_producto,
      'estado',            t.estado,
      'bancos',            coalesce(t.bancos, '[]'::jsonb)
    ) as row
    from mos.proveedores t
    where (v_estado is null or t.estado = v_estado)
      and (v_q is null
           or position(v_q in lower(coalesce(t.nombre,''))) > 0
           or position(v_q in lower(coalesce(t.ruc,'')))    > 0)
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$function$
;

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
    bancos             = case when p ? 'bancos' and jsonb_typeof(p->'bancos')='array' then p->'bancos' else t.bancos end,
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
;
