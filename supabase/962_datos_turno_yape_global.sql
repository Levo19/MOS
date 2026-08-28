-- [962] datos_turno (ticket Z / turno.html) reconoce el Yape GLOBAL: el sello por ticket y el resumen
-- del cierre cuentan como verificado un ticket cubierto por un enlace global (mos.yape_ventas), no solo
-- por el 1:1. Sin esto, un Yape global verificado seguía imprimiéndose "sin verificar" en el ticket Z.
do $mig$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('me.datos_turno(text)'::regprocedure);
  if position('yape_ventas' in v_def) > 0 then
    raise notice '962: ya aplicado'; return;
  end if;

  -- (a) sello por ticket: el Yape que verifica puede ser 1:1 (id_venta) o global (yape_ventas)
  v_new := replace(v_def,
    $a$                       where y.id_venta = tk.id_venta and y.estado = 'MATCHEADO' limit 1),$a$,
    $b$                       where y.estado = 'MATCHEADO' and (y.id_venta = tk.id_venta
                         or exists (select 1 from mos.yape_ventas yv where yv.id_yape = y.id and yv.id_venta = tk.id_venta)) limit 1),$b$);
  if v_new = v_def then raise exception '962: no encontré el sello por ticket'; end if;
  v_def := v_new;

  -- (b) resumen del cierre: verificado = cubierto (1:1 O global). Se quita el left join y se usa _venta_cubierta.
  v_new := replace(v_def,
    $a$          'verificados',      count(*) filter (where y.id is not null),
          'sinVerificar',     count(*) filter (where y.id is null),
          'montoVerificado',  coalesce(sum(v.total) filter (where y.id is not null),0),
          'montoSinVerificar',coalesce(sum(v.total) filter (where y.id is null),0),$a$,
    $b$          'verificados',      count(*) filter (where mos._venta_cubierta(v.id_venta)),
          'sinVerificar',     count(*) filter (where not mos._venta_cubierta(v.id_venta)),
          'montoVerificado',  coalesce(sum(v.total) filter (where mos._venta_cubierta(v.id_venta)),0),
          'montoSinVerificar',coalesce(sum(v.total) filter (where not mos._venta_cubierta(v.id_venta)),0),$b$);
  if v_new = v_def then raise exception '962: no encontré los filtros del resumen'; end if;
  v_def := v_new;

  v_new := replace(v_def,
    $a$          from me.ventas v
          left join mos.yapes_entrantes y on y.id_venta = v.id_venta and y.estado='MATCHEADO'
         where v.id_caja = p_id_caja
           and me._monto_virtual(v.forma_pago, v.total) is not null),$a$,
    $b$          from me.ventas v
         where v.id_caja = p_id_caja
           and me._monto_virtual(v.forma_pago, v.total) is not null),$b$);
  if v_new = v_def then raise exception '962: no encontré el left join del resumen'; end if;

  execute v_new;
  raise notice '962: datos_turno reconoce Yape global';
end $mig$;

select '962 datos_turno global listo' as ok;
