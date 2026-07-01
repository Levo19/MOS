-- ============================================================================
-- 311_mos_tickets_historial_calendario.sql — Navegación histórica + calendario
-- ----------------------------------------------------------------------------
-- ADITIVO (no toca mos.cierres_caja, que tiene ventana fija de 30 días):
--  · mos.tickets_dia(fecha)     → tickets de CUALQUIER día (mayo incluido), misma
--    forma que cierres_caja.todosTickets. Para viajar fuera de la ventana de 30d.
--  · mos.dias_con_tickets(mes)  → qué días del mes tienen ≥1 ticket (+ si hay
--    crédito pendiente) → para resaltar el calendario y saber a dónde viajar.
-- Solo lectura, gated mos._claim_ok (admin MOS).
-- ============================================================================

create or replace function mos.tickets_dia(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_tz text := 'America/Lima'; v_fecha date; v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  begin v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::date;
  exception when others then v_fecha := null; end;
  if v_fecha is null then return jsonb_build_object('ok',false,'error','fecha requerida (YYYY-MM-DD)'); end if;

  with vr as (
    select coalesce(v.id_caja,'') id_caja, coalesce(v.forma_pago,'EFECTIVO') forma_pago,
           coalesce(v.tipo_doc,'NOTA_DE_VENTA') tipo_doc, coalesce(v.total,0)::numeric total,
           v.fecha fecha_ts, coalesce(nullif(btrim(v.vendedor),''),'') vendedor,
           v.id_venta, v.correlativo, v.cliente_doc, v.cliente_nombre, v.obs
      from me.ventas v
     where (v.fecha at time zone v_tz)::date = v_fecha
  ),
  vt as (
    select vr.*,
      case when upper(forma_pago) like 'ANULADO%' then 'ANULADO'
           when upper(forma_pago) = 'CREDITO'     then 'CREDITO'
           when upper(forma_pago) = 'POR_COBRAR'  then 'POR_COBRAR'
           else 'COMPLETADO' end estado,
      case upper(tipo_doc) when 'BOLETA' then 'B' when 'FACTURA' then 'F' else 'NV' end tipo,
      to_char(fecha_ts at time zone v_tz,'YYYY-MM-DD') fecha,
      to_char(fecha_ts at time zone v_tz,'HH24:MI') hora
    from vr
  ),
  enr as (
    select vt.*, coalesce(cm.vendedor,'') cm_vendedor,
           coalesce(nullif(cm.zona_id,''), coalesce(cm.estacion,'')) cm_zona
      from vt left join me.cajas cm on cm.id_caja = vt.id_caja
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'idVenta', coalesce(id_venta,''), 'fecha', fecha, 'hora', hora,
           'correlativo', coalesce(correlativo,''), 'clienteDoc', coalesce(cliente_doc,''),
           'clienteNom', coalesce(cliente_nombre,''), 'total', total, 'tipoDoc', tipo_doc,
           'tipo', tipo, 'metodo', forma_pago, 'estado', estado, 'obs', coalesce(obs,''),
           'idCaja', id_caja, 'vendedor', coalesce(nullif(btrim(vendedor),''), cm_vendedor, ''), 'zona', cm_zona)
           order by (fecha||hora) desc, id_venta desc), '[]'::jsonb)
    into v_out from enr;
  return jsonb_build_object('ok', true, 'fecha', to_char(v_fecha,'YYYY-MM-DD'), 'todosTickets', coalesce(v_out,'[]'::jsonb));
end;
$fn$;
revoke all on function mos.tickets_dia(jsonb) from public;
grant execute on function mos.tickets_dia(jsonb) to authenticated, service_role;

create or replace function mos.dias_con_tickets(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_tz text := 'America/Lima'; v_desde date; v_hasta date; v_mes text := nullif(btrim(coalesce(p->>'mes','')),''); v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_mes is not null then
    begin v_desde := (v_mes||'-01')::date; v_hasta := (v_desde + interval '1 month - 1 day')::date;
    exception when others then return jsonb_build_object('ok',false,'error','mes inválido (YYYY-MM)'); end;
  else
    begin v_desde := nullif(btrim(coalesce(p->>'desde','')),'')::date; v_hasta := nullif(btrim(coalesce(p->>'hasta','')),'')::date;
    exception when others then v_desde := null; end;
    if v_desde is null or v_hasta is null then return jsonb_build_object('ok',false,'error','mes o desde/hasta requerido'); end if;
  end if;

  select coalesce(jsonb_object_agg(dia, info),'{}'::jsonb) into v_out from (
    select to_char((fecha at time zone v_tz)::date,'YYYY-MM-DD') dia,
           jsonb_build_object(
             'n', count(*),
             'credito', bool_or(upper(coalesce(forma_pago,'')) in ('CREDITO','POR_COBRAR')),
             'total', round(sum(coalesce(total,0))::numeric, 2)
           ) info
      from me.ventas
     where (fecha at time zone v_tz)::date between v_desde and v_hasta
       and upper(coalesce(forma_pago,'')) not like 'ANULADO%'
     group by (fecha at time zone v_tz)::date
  ) s;
  return jsonb_build_object('ok', true, 'dias', coalesce(v_out,'{}'::jsonb));
end;
$fn$;
revoke all on function mos.dias_con_tickets(jsonb) from public;
grant execute on function mos.dias_con_tickets(jsonb) to authenticated, service_role;
