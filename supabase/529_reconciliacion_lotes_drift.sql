-- 529_reconciliacion_lotes_drift.sql — ONE-TIME: reconcilia el drift creado por el hueco
-- del cutover (cierres cero-GAS sin consumo de lotes, ~2026-06-16 → 2026-07-19).
-- Estado antes: 161 productos donde Σ lotes ACTIVOS > stock disponible (~52k uds de exceso:
-- salidas reales que nunca descontaron su lote). Regla de reconciliación = la MISMA política
-- FEFO del sistema: el exceso se consume de los lotes que vencen primero (los que salieron
-- primero según la política de picking). Auditable: cada consumo queda en wh.lotes_historial
-- con accion='RECONCILIACION'.
do $$
declare
  r record;
  v_exceso numeric;
begin
  for r in
    select l.cod_producto,
           sum(l.cantidad_actual) - coalesce(max(s.cantidad_disponible), 0) as exceso
      from wh.lotes_vencimiento l
      left join wh.stock s on upper(s.cod_producto) = upper(l.cod_producto)
     where l.estado = 'ACTIVO' and coalesce(l.cantidad_actual,0) > 0
     group by l.cod_producto
    having sum(l.cantidad_actual) > coalesce(max(s.cantidad_disponible), 0)
  loop
    v_exceso := r.exceso;
    perform wh._consumir_lotes_fefo(r.cod_producto, v_exceso,
      'RECON20260719', 'reconciliación drift cutover (lotes > stock)', 'sistema-reconciliacion');
  end loop;
end $$;

-- verificación: no debe quedar producto con lotes > stock
select count(*)::int as productos_con_drift_restante
  from (
    select l.cod_producto
      from wh.lotes_vencimiento l
      left join wh.stock s on upper(s.cod_producto) = upper(l.cod_producto)
     where l.estado = 'ACTIVO' and coalesce(l.cantidad_actual,0) > 0
     group by l.cod_producto
    having sum(l.cantidad_actual) > coalesce(max(s.cantidad_disponible), 0) + 0.001
  ) x;
