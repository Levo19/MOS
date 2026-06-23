-- 233_me_cerrar_caja_efectos.sql — Efectos cross-app del cierre de caja ME, 100% Supabase (erradica el mirror GAS
-- CIERRE_CAJA→generarGuiaSalidaVentas). Orquesta los 3 efectos, TODOS idempotentes (safe aunque corra junto al
-- mirror GAS durante la transición):
--   1. Descuento de stock SALIDA_VENTAS → me.zona_descontar_venta (idempotente por id_caja + kardex).
--   2. Guía meta (cabecera+detalle) → me.zona_guia_registrar_meta (idempotente por idGuia).
--   3. Pickup de reposición a WH → wh.crear_pickup_desde_ventas (canónico×factor, idempotente por id_caja).
-- totales_por_cod se computan de me.ventas_detalle (ventas VIVAS: forma_pago NOT ILIKE 'ANULADO%').
create or replace function me.cerrar_caja_efectos(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'id_caja','')), '');
  v_caja  me.cajas%rowtype;
  v_items jsonb; v_idguia text;
  v_rdesc jsonb; v_rmeta jsonb; v_rpick jsonb;
begin
  if coalesce(me.jwt_app(),'') <> 'mosExpress' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','id_caja requerido'); end if;
  select * into v_caja from me.cajas where id_caja = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','CAJA_NO_ENCONTRADA'); end if;

  -- totales_por_cod de ventas VIVAS de la caja (excluye ANULADO%) → items [{codBarra,cantidad}]
  select coalesce(jsonb_agg(jsonb_build_object('codBarra', cod, 'cantidad', q)), '[]'::jsonb) into v_items
  from (
    select coalesce(nullif(btrim(d.cod_barras),''), d.sku) as cod, sum(coalesce(d.cantidad,0)) as q
    from me.ventas_detalle d
    join me.ventas v on v.id_venta = d.id_venta
    where v.id_caja = v_id and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
    group by 1 having sum(coalesce(d.cantidad,0)) > 0
  ) t;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',true,'vacio',true,'data',jsonb_build_object('idCaja',v_id,'items',0));
  end if;

  v_idguia := 'G-VENTAS-' || v_id;   -- determinístico → meta idempotente

  -- 1. Descuento (idempotente por id_caja)
  v_rdesc := me.zona_descontar_venta(jsonb_build_object(
    'idCaja', v_id, 'zona', coalesce(v_caja.zona_id,''), 'usuario', coalesce(v_caja.vendedor,''),
    'origen', 'CIERRE', 'items', v_items));
  -- 2. Guía meta (idempotente por idGuia)
  v_rmeta := me.zona_guia_registrar_meta(jsonb_build_object(
    'idGuia', v_idguia, 'zona', coalesce(v_caja.zona_id,''), 'tipo', 'SALIDA_VENTAS',
    'vendedor', coalesce(v_caja.vendedor,''), 'observacion', 'Auto cierre de caja · '||v_id,
    'estado', 'CONFIRMADO', 'items', v_items));
  -- 3. Pickup a WH (canónico×factor, idempotente por id_caja)
  v_rpick := wh.crear_pickup_desde_ventas(jsonb_build_object(
    'idCaja', v_id, 'idZona', coalesce(v_caja.zona_id,''), 'cajero', coalesce(v_caja.vendedor,''),
    'idGuiaME', v_idguia, 'items', v_items));

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idCaja', v_id, 'idGuia', v_idguia, 'items', jsonb_array_length(v_items),
    'descuento', coalesce(v_rdesc->'ok', v_rdesc->'data', to_jsonb(false)),
    'descuentoOk', coalesce((v_rdesc->>'ok')::boolean, false),
    'metaOk', coalesce((v_rmeta->>'ok')::boolean, false),
    'pickupOk', coalesce((v_rpick->>'ok')::boolean, false),
    'pickup', v_rpick->'data'));
end;
$fn$;

revoke all on function me.cerrar_caja_efectos(jsonb) from public;
grant execute on function me.cerrar_caja_efectos(jsonb) to authenticated;
