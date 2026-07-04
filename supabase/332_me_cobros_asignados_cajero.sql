-- 332_me_cobros_asignados_cajero.sql
-- [CERO-GAS] Reemplaza gas/Creditos.gs::getCobrosAsignadosCajero. Lectura pura del cajero: cobros ASIGNADO
-- de SU caja destino, enriquecidos con items del ticket (me.ventas_detalle, máx 20) + vendedor original.
-- Forma EXACTA del GAS: {status:'success', cobros:[...]}. fechaVencimiento cae a fecha_asig+horas_ttl si null.
create or replace function me.cobros_asignados_cajero(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_caja text := btrim(coalesce(p->>'cajaId', p->>'idCaja', ''));
  v_data jsonb;
begin
  if coalesce((current_setting('request.jwt.claims', true))::jsonb->>'app','') not in ('mosExpress','MOS','') then
    return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA');
  end if;
  if v_caja = '' then return jsonb_build_object('status','error','error','cajaId requerido'); end if;

  select coalesce(jsonb_agg(row order by (row->>'fechaVencimiento')), '[]'::jsonb) into v_data
  from (
    select jsonb_build_object(
      'idCobro', coalesce(c.id_cobro,''), 'idVenta', coalesce(c.id_venta,''),
      'cajaDestino', coalesce(c.caja_destino,''), 'vendedorDest', coalesce(c.vendedor_dest,''),
      'metodoSug', coalesce(c.metodo_sug,''), 'adminAsig', coalesce(c.admin_asignador,''),
      'fechaAsig', case when c.fecha_asig is null then '' else to_char(c.fecha_asig at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'fechaVencimiento', case
        when c.fecha_vencimiento is not null then to_char(c.fecha_vencimiento at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
        when c.fecha_asig is not null then to_char((c.fecha_asig + (coalesce(nullif(c.horas_ttl,0),1)*interval '1 hour')) at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
        else '' end,
      'horasTTL', coalesce(nullif(c.horas_ttl,0),1), 'monto', coalesce(c.monto,0),
      'cliente', coalesce(c.cliente_nombre,''), 'correlativo', coalesce(c.correlativo,''),
      'mensajeAdmin', coalesce(c.mensaje_admin,''),
      'itemsOriginal', coalesce((
        select jsonb_agg(jsonb_build_object('nombre',coalesce(d.nombre,''),'cantidad',coalesce(d.cantidad,0),
          'precio',coalesce(d.precio,0),'subtotal',coalesce(d.subtotal, coalesce(d.cantidad,0)*coalesce(d.precio,0))) order by d.linea)
        from (select dd.nombre,dd.cantidad,dd.precio,dd.subtotal,dd.linea from me.ventas_detalle dd where dd.id_venta=c.id_venta order by dd.linea limit 20) d
      ), '[]'::jsonb),
      'vendedorOriginal', coalesce((select v.vendedor from me.ventas v where v.id_venta=c.id_venta limit 1),'')
    ) as row
    from me.creditos_cobro_asignado c
    where c.caja_destino = v_caja and upper(coalesce(c.estado,'')) = 'ASIGNADO'
  ) t;

  return jsonb_build_object('status','success','cobros', v_data);
end; $fn$;
revoke all on function me.cobros_asignados_cajero(jsonb) from public, anon;
grant execute on function me.cobros_asignados_cajero(jsonb) to authenticated, service_role;
