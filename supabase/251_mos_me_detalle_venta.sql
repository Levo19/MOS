-- ════════════════════════════════════════════════════════════════════════════
-- 251 · REPARACIÓN #4 (Etapa 1) — mos.me_detalle_venta: detalle de un ticket 100% Supabase
-- ════════════════════════════════════════════════════════════════════════════
-- El modal de acciones de ticket (MOS Cajas) NO tenía de dónde leer las LÍNEAS de la venta
-- (getCierresCaja.todosTickets no trae items). Esta RPC devuelve cabecera + líneas desde la sombra
-- me.ventas / me.ventas_detalle → alimenta (a) la sección "detalle del ticket" del modal y (b) la
-- impresión del ticket. Lectura pura, secdef, gate _claim_ok + _frescura_sombra (mismo patrón que 118).
-- ════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_detalle_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idVenta','')), '');
  v_v     me.ventas%rowtype;
  v_items jsonb;
  v_fr    jsonb := mos._frescura_sombra();
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido') || v_fr; end if;

  select * into v_v from me.ventas where id_venta = v_id limit 1;
  if not found then
    -- venta muy reciente aún no sincronizada → no es error duro; _fresh lo señala y el front cae a GAS.
    return jsonb_build_object('ok', true, 'encontrado', false, 'items', '[]'::jsonb) || v_fr;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
            'linea',        d.linea,
            'sku',          d.sku,
            'nombre',       d.nombre,
            'cantidad',     d.cantidad,
            'precio',       d.precio,
            'subtotal',     d.subtotal,
            'codBarras',    d.cod_barras,
            'unidadMedida', d.unidad_medida
          ) order by d.linea), '[]'::jsonb)
    into v_items
    from me.ventas_detalle d
   where d.id_venta = v_id;

  return jsonb_build_object('ok', true, 'encontrado', true, 'data', jsonb_build_object(
      'idVenta',        v_v.id_venta,
      'correlativo',    v_v.correlativo,
      'tipoDoc',        v_v.tipo_doc,
      'formaPago',      v_v.forma_pago,
      'total',          v_v.total,
      'clienteDoc',     v_v.cliente_doc,
      'clienteNombre',  v_v.cliente_nombre,
      'vendedor',       v_v.vendedor,
      'fecha',          v_v.fecha,
      'idCaja',         v_v.id_caja,
      'obs',            v_v.obs,
      'nfEstado',       v_v.nf_estado,
      'items',          v_items
  )) || v_fr;
end;
$fn$;
revoke all on function mos.me_detalle_venta(jsonb) from public, anon;
grant execute on function mos.me_detalle_venta(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
