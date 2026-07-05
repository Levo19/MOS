-- 383 · kill-GAS OCR/Jefa (backend). El OCR-IA en sí lo hace el cliente vía Edge `ia`; estos son los
-- RPCs de datos: contexto del ticket-jefa (join guía⋈catálogo) + edición de precio_unitario del detalle.

-- ── contexto del ticket jefa: por cada línea de la guía, costo(línea) + venta/margen actuales del catálogo ──
create or replace function mos.contexto_ticket_jefa(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_g text := nullif(btrim(coalesce(p->>'idGuia','')),''); v_items jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_g is null then return jsonb_build_object('ok',false,'error','idGuia requerido'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'skuBase', coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto, d.cod_producto),
      'descripcion', coalesce(pr.descripcion, d.cod_producto),
      'costo', coalesce(d.precio_unitario, 0),
      'ventaActual', coalesce(pr.precio_venta, 0),
      'margenActualPct', coalesce(pr.margen_pct, 0)
    ) order by d.linea), '[]'::jsonb)
  into v_items
  from wh.guia_detalle d
  left join lateral (
    select * from mos.productos pp
     where pp.codigo_barra = d.cod_producto or pp.id_producto = d.cod_producto
     order by (pp.id_producto = d.cod_producto) desc limit 1
  ) pr on true
  where d.id_guia = v_g
    and upper(coalesce(d.observacion,'')) <> 'ANULADO';
  return jsonb_build_object('ok',true,'data',jsonb_build_object('items', v_items));
end; $fn$;

-- ── actualizar precio_unitario de líneas del detalle (llenarCostosGuia). NO mueve stock. ──
-- Dual-gate (mos._claim_ok con token MOS, o wh._claim_ok). Idempotente (update por id_detalle).
create or replace function wh.actualizar_precios_detalle(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_g text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_it jsonb; v_id text; v_pu numeric; v_n int := 0; v_tot numeric := 0;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_items) <> 'array' then return jsonb_build_object('ok',false,'error','items debe ser array'); end if;
  for v_it in select * from jsonb_array_elements(v_items) loop
    v_id := nullif(btrim(coalesce(v_it->>'idDetalle','')),'');
    v_pu := mos._numn(v_it->>'precioUnitario');
    if v_id is null or v_pu is null or v_pu < 0 then continue; end if;
    update wh.guia_detalle set precio_unitario = v_pu where id_detalle = v_id;
    if found then v_n := v_n + 1; end if;
  end loop;
  -- monto total nuevo de la guía (Σ precio_unitario × cant_recibida de líneas no anuladas)
  if v_g is not null then
    select coalesce(sum(coalesce(precio_unitario,0) * abs(coalesce(nullif(cant_recibida,0), cant_esperada, 0))),0)
      into v_tot from wh.guia_detalle
     where id_guia = v_g and upper(coalesce(observacion,'')) <> 'ANULADO';
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('actualizados', v_n, 'montoTotalNuevo', round(v_tot,2)));
end; $fn$;

revoke all on function mos.contexto_ticket_jefa(jsonb), wh.actualizar_precios_detalle(jsonb) from public, anon;
grant execute on function mos.contexto_ticket_jefa(jsonb), wh.actualizar_precios_detalle(jsonb) to authenticated, service_role;
