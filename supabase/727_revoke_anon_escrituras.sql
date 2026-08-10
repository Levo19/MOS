-- 727 · Auditoría 500x C2: cierre del hueco de ESCRITURA anónima (probado por la auditoría:
-- se sobrescribió un ticket de pago con la anon key pública, en tx revertida).
-- OJO: guardar_ticket_pago NO tenía grant propio — heredaba de PUBLIC. Revocar sin dar el grant
-- explícito a authenticated habría roto la impresión de tickets. Por eso van los dos pasos.
revoke execute on function mos.guardar_ticket_pago(jsonb) from public;
revoke execute on function mos.guardar_ticket_pago(jsonb) from anon;
grant execute on function mos.guardar_ticket_pago(jsonb) to authenticated;
grant execute on function mos.guardar_ticket_pago(jsonb) to service_role;
revoke execute on function mos.pn_descartar(jsonb) from public;
revoke execute on function mos.pn_descartar(jsonb) from anon;
grant execute on function mos.pn_descartar(jsonb) to authenticated;
grant execute on function mos.pn_descartar(jsonb) to service_role;
revoke execute on function mos.rechazar_dispositivo_pendiente(jsonb) from public;
revoke execute on function mos.rechazar_dispositivo_pendiente(jsonb) from anon;
grant execute on function mos.rechazar_dispositivo_pendiente(jsonb) to authenticated;
grant execute on function mos.rechazar_dispositivo_pendiente(jsonb) to service_role;
revoke execute on function wh.cargador_dia_upsert(jsonb) from public;
revoke execute on function wh.cargador_dia_upsert(jsonb) from anon;
grant execute on function wh.cargador_dia_upsert(jsonb) to authenticated;
grant execute on function wh.cargador_dia_upsert(jsonb) to service_role;
revoke execute on function wh.marcar_producto_nuevo_aprobado(jsonb) from public;
revoke execute on function wh.marcar_producto_nuevo_aprobado(jsonb) from anon;
grant execute on function wh.marcar_producto_nuevo_aprobado(jsonb) to authenticated;
grant execute on function wh.marcar_producto_nuevo_aprobado(jsonb) to service_role;
