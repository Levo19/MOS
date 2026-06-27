-- 276_me_historial_modal.sql — #4 Etapa 2: los 2 historiales del modal de ticket → Supabase (cero-GAS).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- El modal de acciones de ticket (MOS Cajas) abría historial-ticket e historial-cliente vía GAS
-- (meHistorialVenta / meHistorialCliente). Ahora salen directo de me.ventas.historial_cambios (jsonb
-- que ya escriben me.editar_cliente / me.editar_forma_pago / me.anular_venta / convertir_nv_cpe).
--   · historial_venta(idVenta): eventos de ESE ticket.
--   · historial_cliente(doc):   eventos de TODOS los tickets de ese cliente_doc, c/u etiquetado con su correlativo.
-- Shape compatible con _tkHistRender (mapea ts→timestamp). Read-only, fail-closed, app MOS/mosExpress.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function me.historial_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_app text := me.jwt_app();
  v_id  text := nullif(btrim(coalesce(p->>'idVenta','')),'');
  v_h   jsonb;
begin
  if v_app not in ('MOS','mosExpress') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  select coalesce(jsonb_agg(ev || jsonb_build_object('timestamp', ev->>'ts') order by (ev->>'ts')), '[]'::jsonb)
    into v_h
    from me.ventas v, jsonb_array_elements(coalesce(v.historial_cambios,'[]'::jsonb)) ev
   where v.id_venta = v_id;
  return jsonb_build_object('ok',true,'historial', coalesce(v_h,'[]'::jsonb));
end;
$fn$;

create or replace function me.historial_cliente(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_app text := me.jwt_app();
  v_doc text := nullif(btrim(coalesce(p->>'doc','')),'');
  v_h   jsonb;
begin
  if v_app not in ('MOS','mosExpress') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_doc is null then return jsonb_build_object('ok',false,'error','doc requerido'); end if;
  -- aplana los eventos de TODOS los tickets del cliente; cada evento etiquetado con su correlativo en 'accion'.
  select coalesce(jsonb_agg(
           ev || jsonb_build_object(
             'timestamp', ev->>'ts',
             'accion', coalesce(ev->>'accion', ev->>'source', 'cambio') || ' · ' || coalesce(v.correlativo, v.id_venta)
           ) order by (ev->>'ts')
         ), '[]'::jsonb)
    into v_h
    from me.ventas v, jsonb_array_elements(coalesce(v.historial_cambios,'[]'::jsonb)) ev
   where v.cliente_doc = v_doc;
  return jsonb_build_object('ok',true,'historial', coalesce(v_h,'[]'::jsonb));
end;
$fn$;

revoke all on function me.historial_venta(jsonb)   from public;
revoke all on function me.historial_cliente(jsonb) from public;
grant execute on function me.historial_venta(jsonb)   to authenticated;
grant execute on function me.historial_cliente(jsonb) to authenticated;
notify pgrst, 'reload schema';
