-- ============================================================================
-- 312_mos_tickets_rango.sql — Tickets por RANGO de fechas (buscador "ver todos")
-- ----------------------------------------------------------------------------
-- Para buscar un ticket (ej. NV 0045) SIN ir día por día: trae todos los tickets
-- de [desde, hasta] (cap 93 días), misma forma que mos.tickets_dia. Read-only.
-- ============================================================================

create or replace function mos.tickets_rango(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_tz text := 'America/Lima'; v_desde date; v_hasta date; v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  begin
    v_desde := nullif(btrim(coalesce(p->>'desde','')),'')::date;
    v_hasta := nullif(btrim(coalesce(p->>'hasta','')),'')::date;
  exception when others then v_desde := null; end;
  if v_desde is null or v_hasta is null then return jsonb_build_object('ok',false,'error','desde y hasta requeridos (YYYY-MM-DD)'); end if;
  if v_hasta < v_desde then return jsonb_build_object('ok',false,'error','hasta < desde'); end if;
  if (v_hasta - v_desde) > 92 then v_desde := v_hasta - 92; end if;   -- cap 93 días (protege de cargas enormes)

  with vr as (
    select coalesce(v.id_caja,'') id_caja, coalesce(v.forma_pago,'EFECTIVO') forma_pago,
           coalesce(v.tipo_doc,'NOTA_DE_VENTA') tipo_doc, coalesce(v.total,0)::numeric total,
           v.fecha fecha_ts, coalesce(nullif(btrim(v.vendedor),''),'') vendedor,
           v.id_venta, v.correlativo, v.cliente_doc, v.cliente_nombre, v.obs
      from me.ventas v
     where (v.fecha at time zone v_tz)::date between v_desde and v_hasta
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
  return jsonb_build_object('ok', true, 'desde', to_char(v_desde,'YYYY-MM-DD'), 'hasta', to_char(v_hasta,'YYYY-MM-DD'), 'todosTickets', coalesce(v_out,'[]'::jsonb));
end;
$fn$;
revoke all on function mos.tickets_rango(jsonb) from public;
grant execute on function mos.tickets_rango(jsonb) to authenticated, service_role;
