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
      'estado',            t.estado
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
