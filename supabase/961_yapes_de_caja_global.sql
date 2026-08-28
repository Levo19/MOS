-- [961] yapes_de_caja con soporte de Yape global: candidatos y "tickets sin verificar" excluyen lo ya
-- cubierto por un enlace global; cada Yape sin cuadrar trae 'combinaciones' (sugerencia N-tickets);
-- un Yape global ya verificado muestra sus tickets ('ventasGlobal').
CREATE OR REPLACE FUNCTION mos.yapes_de_caja(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caja text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_zona text; v_desde timestamptz; v_hasta timestamptz;
  v_yapes jsonb; v_pend jsonb; v_res jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_caja is null then return jsonb_build_object('ok',false,'error','idCaja requerido'); end if;

  select k.zona_id into v_zona from me.cajas k where k.id_caja = v_caja;

  select min(v.fecha) - interval '30 minutes', max(v.fecha) + interval '30 minutes'
    into v_desde, v_hasta from me.ventas v where v.id_caja = v_caja;
  if v_desde is null then
    select k.fecha_apertura - interval '30 minutes', coalesce(k.fecha_cierre, now()) + interval '30 minutes'
      into v_desde, v_hasta from me.cajas k where k.id_caja = v_caja;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', y.id,
      'hora', to_char(y.ts_notificacion at time zone 'America/Lima','HH24:MI'),
      'monto', y.monto, 'pagador', coalesce(y.pagador,''), 'estado', y.estado,
      'idVenta', coalesce(y.id_venta,''), 'raw', y.raw,
      'manual', coalesce(y.match_por,'') <> 'AUTO' and y.estado = 'MATCHEADO',
      'correlativo', coalesce((select v.correlativo from me.ventas v where v.id_venta = y.id_venta),''),
      -- Yape GLOBAL ya verificado: sus tickets
      'esGlobal', coalesce((y.meta->>'global')::boolean, false),
      'ventasGlobal', case when coalesce((y.meta->>'global')::boolean,false) then coalesce((
          select jsonb_agg(jsonb_build_object(
                   'idVenta', yv.id_venta, 'correlativo', coalesce(v.correlativo,''),
                   'virtual', me._monto_virtual(v.forma_pago, v.total),
                   'hora', to_char(v.fecha at time zone 'America/Lima','HH24:MI')) order by v.fecha)
            from mos.yape_ventas yv join me.ventas v on v.id_venta = yv.id_venta
           where yv.id_yape = y.id), '[]'::jsonb) else '[]'::jsonb end,
      -- candidatos 1:1 (monto exacto de UN ticket, no cubierto por ningún Yape)
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
             and not mos._venta_cubierta(v.id_venta)), '[]'::jsonb)
        else '[]'::jsonb end,
      -- [959] combinaciones sugeridas (2-3 tickets que SUMAN el monto), solo si no cuadra 1:1
      'combinaciones', case when y.estado in ('AMBIGUO','NUEVO') and y.monto is not null
          then mos.yape_combos(v_caja, y.monto, y.ts_notificacion) else '[]'::jsonb end
    ) order by y.ts_notificacion), '[]'::jsonb) into v_yapes
    from mos.yapes_entrantes y
   where y.ts_notificacion between v_desde and v_hasta
     and (coalesce(v_zona,'') = '' or coalesce(y.zona,'') = '' or upper(btrim(y.zona)) = upper(btrim(v_zona)));

  -- tickets virtuales de la caja SIN verificar (excluye 1:1 y global)
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
     and not mos._venta_cubierta(v.id_venta);

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
end $function$;

select '961 yapes_de_caja global listo' as ok;
