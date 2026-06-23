-- ============================================================
-- 164_me_venta_reposicion_lectura.sql
-- LECTURA (delete-safe) para reponer stock al anular UNA venta cuya caja YA cerró.
-- ------------------------------------------------------------
-- Residual del cutover 160: `_reponerStockVentaAnulada` (Guias.gs) y su helper
-- `_meCajaVentaYaCerrada` aún leían VENTAS_CABECERA / VENTAS_DETALLE / GUIAS_CABECERA
-- del Sheet. Si el Sheet se borra, una anulación TARDÍA (post-cierre) NO podía
-- determinar (a) la caja de la venta, (b) si esa caja ya cerró, (c) la zona del
-- descuento, ni (d) las cantidades a reponer → stock FANTASMA (money bug).
--
-- Esta RPC devuelve, para UNA venta, TODO lo que la reposición necesita, leído de
-- me.ventas / me.ventas_detalle / me.guias_cabecera — idéntico al criterio del Sheet:
--   · id_caja            = me.ventas.id_caja de la venta.
--   · caja_cerrada       = existe guía Tipo='SALIDA_VENTAS' cuya observacion contiene
--                          el id_caja (mismo anti-dup que generarGuiaSalidaVentas).
--   · zona               = zona_id de ESA guía SALIDA_VENTAS (zona EXACTA del descuento,
--                          NO inferida) — igual que _meCajaVentaYaCerrada leía col Zona_ID.
--   · totales_por_cod    = suma de cantidad por cod_barras de la venta (fallback al sku
--                          si la línea no trae cod_barras = detalle[6] || detalle[1] del Sheet).
--
-- Money-safety: 100% LECTURA (STABLE, sin efectos). NO repone — la reposición la
-- aplica me.zona_registrar_guia (tipo ENTRADA, idGuia 'ANUL:<idVenta>') que ya es
-- idempotente por refId 'GUIA:ANUL:<idVenta>:<cod>'. Esta RPC solo informa.
-- NOTA: la zona del descuento se toma de la guía, no de la venta — porque el
-- descuento del cierre se imputó a la zona de la caja (guia.zona_id), que es la
-- misma unidad de stock que hay que reponer.
-- ============================================================

create or replace function me.venta_reposicion_datos(p_id_venta text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_app    text := me.jwt_app();
  v_id     text := nullif(btrim(coalesce(p_id_venta,'')),'');
  v_caja   text;
  v_forma  text;
  v_zona   text;
  v_cerr   boolean := false;
  v_tot    jsonb;
begin
  -- Gate de app (igual que cierre_datos_caja). service_role (GAS) → jwt_app()='' → permitido.
  if v_app <> '' and v_app <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'ID_VENTA_REQUERIDO');
  end if;

  select id_caja, forma_pago into v_caja, v_forma
  from me.ventas where id_venta = v_id limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'VENTA_NO_ENCONTRADA', 'id_venta', v_id);
  end if;

  v_caja := nullif(btrim(coalesce(v_caja,'')),'');
  if v_caja is null then
    return jsonb_build_object('ok', true, 'id_venta', v_id, 'id_caja', '',
      'caja_cerrada', false, 'zona', '', 'totales_por_cod', '{}'::jsonb,
      'forma_pago', coalesce(v_forma,''));
  end if;

  -- ¿Caja ya cerrada? = existe su guía SALIDA_VENTAS. Tomamos zona_id de esa guía
  -- (zona exacta del descuento). Si hay varias (no debería), la más reciente por fecha.
  select gc.zona_id into v_zona
  from me.guias_cabecera gc
  where gc.tipo = 'SALIDA_VENTAS'
    and coalesce(gc.observacion,'') ilike '%'||v_caja||'%'
  order by gc.fecha desc nulls last
  limit 1;
  v_cerr := found;

  -- Totales por cod_barras de ESTA venta (fallback al sku). Sin filtro de forma_pago:
  -- es la venta puntual que se anuló; sus cantidades físicas son las que hay que reponer.
  select coalesce(jsonb_object_agg(cb, cant), '{}'::jsonb)
  into v_tot
  from (
    select upper(btrim(coalesce(nullif(d.cod_barras,''), d.sku))) as cb,
           sum(coalesce(d.cantidad,0)) as cant
    from me.ventas_detalle d
    where d.id_venta = v_id
      and coalesce(nullif(d.cod_barras,''), d.sku) is not null
      and btrim(coalesce(nullif(d.cod_barras,''), d.sku)) <> ''
    group by 1
    having sum(coalesce(d.cantidad,0)) > 0
  ) t;

  return jsonb_build_object(
    'ok', true,
    'id_venta', v_id,
    'id_caja', v_caja,
    'caja_cerrada', v_cerr,
    'zona', coalesce(v_zona,''),
    'totales_por_cod', v_tot,
    'forma_pago', coalesce(v_forma,'')
  );
end;
$function$;

revoke all on function me.venta_reposicion_datos(text) from public, anon;
grant execute on function me.venta_reposicion_datos(text) to authenticated, service_role;
