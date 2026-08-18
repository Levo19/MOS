-- 860_yapes_por_caja.sql
--
-- [DUEÑO] "en MOS cada caja debe tener su propio panel de Yapes capturados: ver los libres y
--  matchearlos manualmente, o DESVERIFICARLOS si hubo algún error, así el admin va avanzando en
--  su control de cierre de caja."
--
-- El panel se arma por CAJA porque así se cierra: el admin toma una caja, ve sus tickets virtuales
-- y los Yapes que entraron en su zona y horario, y va cerrando el círculo. Un panel global de
-- "todos los Yapes del día" no le sirve para eso.
--
-- Devuelve las DOS mitades del problema, porque cerrar es cuadrar ambas:
--   · los Yapes que llegaron (verificados, libres, ambiguos, ilegibles)
--   · los tickets virtuales de la caja que TODAVÍA no tienen su Yape
-- Sin la segunda mitad el admin ve plata que entró pero no sabe qué le falta por verificar.

begin;

create or replace function mos.yapes_de_caja(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_caja text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_zona text; v_desde timestamptz; v_hasta timestamptz;
  v_yapes jsonb; v_pend jsonb; v_res jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_caja is null then return jsonb_build_object('ok',false,'error','idCaja requerido'); end if;

  select k.zona_id into v_zona from me.cajas k where k.id_caja = v_caja;

  -- ventana de la caja: desde su primera venta hasta la última, con media hora de margen a cada
  -- lado (el Yape puede entrar antes de que se emita el ticket, o después de cerrar el turno)
  select min(v.fecha) - interval '30 minutes', max(v.fecha) + interval '30 minutes'
    into v_desde, v_hasta from me.ventas v where v.id_caja = v_caja;
  if v_desde is null then
    select k.fecha_apertura - interval '30 minutes', coalesce(k.fecha_cierre, now()) + interval '30 minutes'
      into v_desde, v_hasta from me.cajas k where k.id_caja = v_caja;
  end if;

  -- los Yapes de esa zona y esa ventana
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', y.id,
      'hora', to_char(y.ts_notificacion at time zone 'America/Lima','HH24:MI'),
      'monto', y.monto, 'pagador', coalesce(y.pagador,''), 'estado', y.estado,
      'idVenta', coalesce(y.id_venta,''), 'raw', y.raw,
      'manual', coalesce(y.match_por,'') <> 'AUTO' and y.estado = 'MATCHEADO',
      'correlativo', coalesce((select v.correlativo from me.ventas v where v.id_venta = y.id_venta),''),
      'candidatos', case when y.estado in ('AMBIGUO','NUEVO') then coalesce((
          select jsonb_agg(jsonb_build_object(
                   'idVenta', v.id_venta, 'correlativo', coalesce(v.correlativo,''),
                   'hora', to_char(v.fecha at time zone 'America/Lima','HH24:MI'),
                   'total', v.total, 'virtual', me._monto_virtual(v.forma_pago, v.total),
                   'formaPago', coalesce(v.forma_pago,''),
                   'cliente', coalesce(nullif(btrim(v.cliente_nombre),''),'')) order by v.fecha)
            from me.ventas v
           where v.id_caja = v_caja
             and me._monto_virtual(v.forma_pago, v.total) is not null
             and round(me._monto_virtual(v.forma_pago, v.total),1) = round(y.monto,1)
             and not exists (select 1 from mos.yapes_entrantes y2
                              where y2.id_venta = v.id_venta and y2.id <> y.id)), '[]'::jsonb)
        else '[]'::jsonb end
    ) order by y.ts_notificacion), '[]'::jsonb) into v_yapes
    from mos.yapes_entrantes y
   where y.ts_notificacion between v_desde and v_hasta
     and (coalesce(v_zona,'') = '' or coalesce(y.zona,'') = '' or upper(btrim(y.zona)) = upper(btrim(v_zona)));

  -- la otra mitad: tickets virtuales de la caja que siguen SIN verificar
  select coalesce(jsonb_agg(jsonb_build_object(
      'idVenta', v.id_venta, 'correlativo', coalesce(v.correlativo,''),
      'hora', to_char(v.fecha at time zone 'America/Lima','HH24:MI'),
      'total', v.total, 'virtual', me._monto_virtual(v.forma_pago, v.total),
      'formaPago', coalesce(v.forma_pago,''), 'vendedor', coalesce(v.vendedor,''),
      'cliente', coalesce(nullif(btrim(v.cliente_nombre),''),'')) order by v.fecha), '[]'::jsonb)
    into v_pend
    from me.ventas v
   where v.id_caja = v_caja
     and me._monto_virtual(v.forma_pago, v.total) is not null
     and not exists (select 1 from mos.yapes_entrantes y where y.id_venta = v.id_venta);

  select jsonb_build_object(
      'yapes', jsonb_array_length(v_yapes),
      'verificados', (select count(*) from jsonb_array_elements(v_yapes) e where e->>'estado' = 'MATCHEADO'),
      'libres',      (select count(*) from jsonb_array_elements(v_yapes) e where e->>'estado' = 'NUEVO'),
      'ambiguos',    (select count(*) from jsonb_array_elements(v_yapes) e where e->>'estado' = 'AMBIGUO'),
      'ilegibles',   (select count(*) from jsonb_array_elements(v_yapes) e where (e->>'monto') is null),
      'ticketsSinVerificar', jsonb_array_length(v_pend),
      'montoYapes',  (select coalesce(sum((e->>'monto')::numeric),0) from jsonb_array_elements(v_yapes) e where (e->>'monto') is not null),
      'montoSinVerificar', (select coalesce(sum((e->>'virtual')::numeric),0) from jsonb_array_elements(v_pend) e))
    into v_res;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idCaja', v_caja, 'zona', coalesce(v_zona,''),
    'desde', to_char(v_desde at time zone 'America/Lima','HH24:MI'),
    'hasta', to_char(v_hasta at time zone 'America/Lima','HH24:MI'),
    'resumen', v_res, 'yapes', v_yapes, 'sinVerificar', v_pend));
end $fn$;

grant execute on function mos.yapes_de_caja(jsonb) to anon, authenticated, service_role;

commit;
