-- 333_me_detalle_venta_gate_me.sql
-- [CERO-GAS fix] mos.me_detalle_venta usaba SOLO mos._claim_ok() (rechaza mosExpress) → el frontend ME
-- (token app=mosExpress) recibía APP_NO_AUTORIZADA siempre. Se relaja el gate para ACEPTAR mosExpress:
-- es una lectura read-only del detalle de una venta (para reimpresión de ticket). Cuerpo idéntico.
create or replace function mos.me_detalle_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')), '');
  v_v     me.ventas%rowtype;
  v_items jsonb;
  v_fr    jsonb := mos._frescura_sombra();
begin
  -- gate: MOS (via _claim_ok) O mosExpress (token ME). Lectura no sensible.
  if not mos._claim_ok()
     and coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','') <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido') || v_fr; end if;

  select * into v_v from me.ventas where id_venta = v_id limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'encontrado', false, 'items', '[]'::jsonb) || v_fr;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
            'linea', d.linea, 'sku', d.sku, 'nombre', d.nombre, 'cantidad', d.cantidad,
            'precio', d.precio, 'subtotal', d.subtotal, 'codBarras', d.cod_barras, 'unidadMedida', d.unidad_medida
          ) order by d.linea), '[]'::jsonb)
    into v_items from me.ventas_detalle d where d.id_venta = v_id;

  return jsonb_build_object('ok', true, 'encontrado', true, 'data', jsonb_build_object(
      'idVenta', v_v.id_venta, 'correlativo', v_v.correlativo, 'tipoDoc', v_v.tipo_doc,
      'formaPago', v_v.forma_pago, 'total', v_v.total, 'clienteDoc', v_v.cliente_doc,
      'clienteNombre', v_v.cliente_nombre, 'vendedor', v_v.vendedor, 'fecha', v_v.fecha,
      'idCaja', v_v.id_caja, 'obs', v_v.obs, 'nfEstado', v_v.nf_estado, 'items', v_items
  )) || v_fr;
end;
$function$;
