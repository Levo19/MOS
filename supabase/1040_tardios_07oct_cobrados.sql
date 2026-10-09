-- 1040 · Los 5 tickets tardíos del 07-oct (NVM1-017171..175, S/ 28) se cobraron (2026-10-09)
-- El dueño confirmó con el cajero (Josué) que los cobró el 07-oct. Pasan de POR_COBRAR a EFECTIVO en su caja
-- original CAJA-1791374504581, con historial (mismo formato que me.cobrar_venta_directo).
begin;
update me.ventas
   set forma_pago = 'EFECTIVO',
       historial_cambios = me._venta_hist_append(historial_cambios, jsonb_build_object(
         'ts', to_jsonb(now()), 'usuario', 'MASTER', 'rol', 'MASTER',
         'source','MOS_TARDIO_COBRADO','accion','cobrar_venta',
         'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','POR_COBRAR','despues','EFECTIVO')),
         'autorizadoPor', 'null'::jsonb,
         'motivo', 'Ticket tardío de la caída del 07-oct: el dueño confirmó que el cajero lo cobró ese día')),
       updated_at = now()
 where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175')
   and id_caja = 'CAJA-1791374504581' and forma_pago = 'POR_COBRAR';
update mos.ventas_tardias set forma_pago = 'EFECTIVO', nota = coalesce(nota,'') || ' · Cobrado (confirmado por el dueño el 09-oct).'
 where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175');
update mos.tickets_fantasma set mensaje = 'Devuelto a su caja original CAJA-1791374504581 (07-oct). Cobrado en efectivo (confirmado 09-oct).'
 where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175');
do $$ begin
  perform mos.recomputar_zona_dia(jsonb_build_object('zona','ZONA-01','fecha','2026-10-07'));
exception when others then raise warning '[1040] recomputar: %', sqlerrm; end $$;
select correlativo, forma_pago, total from me.ventas
 where correlativo in ('NVM1-017171','NVM1-017172','NVM1-017173','NVM1-017174','NVM1-017175') order by 1;
commit;
-- ROLLBACK: mismo update con forma_pago='POR_COBRAR'.
