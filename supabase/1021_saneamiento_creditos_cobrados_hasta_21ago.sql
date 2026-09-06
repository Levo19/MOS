-- 1021 · Saneamiento créditos COBRADOS del 21-ago HACIA ATRÁS (06-sep-2026).
--
-- CORRIGE 1020: aquel marcó desde el 21-ago hacia ADELANTE (interpretación errónea) y fue REVERTIDO
-- (source MOS_SANEAMIENTO_COBRADO_21AGO_REVERT). Luis aclaró: los del 21-ago hacia ATRÁS.
--
-- ORDEN (Luis, 06/09/2026, confirmado): TODAS las deudas de crédito con fecha <= 21/08/2026 fueron
-- cobradas en su momento pero nunca se registraron → darlas por cobradas. Incluye los sin cliente/VARIOS
-- (Luis confirmó marcar TODOS, supera la nota previa de "los limpiaremos de a pocos").
--
-- MÉTODO arqueo-safe (patrón 609/1020): forma_pago='PLANILLA' + marcador en historial. NO usa la vía CAJA
-- (me.creditos_cobro_asignado alimenta el cierre/arqueo → descuadraría el efectivo físico).
-- Reversible: forma_pago→'CREDITO' donde historial tenga source 'MOS_SANEAMIENTO_COBRADO_HASTA_21AGO'.
-- Idempotente: filtra por forma_pago='CREDITO'.

do $$
declare v_n int;
begin
  update me.ventas v
     set forma_pago = 'PLANILLA',
         historial_cambios = me._venta_hist_append(v.historial_cambios, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', 'Luis', 'rol', 'MASTER',
           'source', 'MOS_SANEAMIENTO_COBRADO_HASTA_21AGO', 'accion', 'descuento_planilla',
           'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','CREDITO','despues','PLANILLA')),
           'motivo', 'Saneamiento: creditos con fecha <= 21/08/2026 cobrados en su momento pero nunca registrados - orden de Luis 06/09/2026')),
         updated_at = now()
   where upper(coalesce(v.forma_pago,'')) = 'CREDITO'
     and (v.fecha at time zone 'America/Lima')::date <= date '2026-08-21'
     and not exists (select 1 from me.creditos_cobro_asignado a
                       where a.id_venta = v.id_venta and a.estado = 'COBRADO');
  get diagnostics v_n = row_count;
  raise notice '1021: creditos <= 21-ago saneados a PLANILLA (cobrados) = %', v_n;
end $$;
