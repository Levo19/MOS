-- 1020 · Saneamiento créditos COBRADOS desde el 21-ago (06-sep-2026).
--
-- CONTEXTO: Luis confirma (06/09/2026) que TODAS las deudas de crédito desde el 21/08/2026
-- fueron COBRADAS en su momento, pero nunca se registró el cobro en el sistema. Quedaron
-- como CREDITO vivo en la mesa. Orden: darlas por cobradas/saldadas.
--
-- MÉTODO (arqueo-safe, mismo patrón que 609): NO se usa la vía CAJA (me.creditos_cobro_asignado),
-- porque esa fila alimenta el cierre/arqueo de caja (27/315/327/595) y descuadraría el arqueo
-- físico. Se marca forma_pago='PLANILLA' (el "sello cobrado por liquidación" de la mesa 610) +
-- marcador de saneamiento en historial. Efecto: salen de VIVOS, muestran ✓ COBRADO, sin tocar caja.
--
-- Reversible: revertir = forma_pago→'CREDITO' donde el historial tenga source
-- 'MOS_SANEAMIENTO_COBRADO_21AGO'. Idempotente: filtra por forma_pago='CREDITO'.

do $$
declare v_n int;
begin
  update me.ventas v
     set forma_pago = 'PLANILLA',
         historial_cambios = me._venta_hist_append(v.historial_cambios, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', 'Luis', 'rol', 'MASTER',
           'source', 'MOS_SANEAMIENTO_COBRADO_21AGO', 'accion', 'descuento_planilla',
           'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','CREDITO','despues','PLANILLA')),
           'motivo', 'Saneamiento: creditos desde 21/08/2026 cobrados en su momento pero nunca registrados - orden de Luis 06/09/2026')),
         updated_at = now()
   where upper(coalesce(v.forma_pago,'')) = 'CREDITO'
     and (v.fecha at time zone 'America/Lima')::date >= date '2026-08-21'
     and not exists (select 1 from me.creditos_cobro_asignado a
                       where a.id_venta = v.id_venta and a.estado = 'COBRADO');
  get diagnostics v_n = row_count;
  raise notice '1020: creditos desde 21-ago saneados a PLANILLA (cobrados) = %', v_n;
end $$;
