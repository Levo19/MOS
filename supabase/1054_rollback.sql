-- [1054] ROLLBACK: 1054 solo CREA objetos nuevos (no reemplaza ninguna función viva), así que la reversa
-- es quitarlos. Idempotente: aplicarla dos veces = NO-OP.
-- ⚠ Borra las marcas de revisión y su bitácora: si ya hay marcas reales, respaldarlas antes
--   (select * from mos.control_caja_revision; select * from mos.control_caja_revision_log).

begin;
drop function if exists mos.control_caja_marcar(jsonb);
drop function if exists mos.reporte_cajas_semana(jsonb);
drop function if exists mos._control_caja_nivel(text);
drop function if exists mos._control_caja_ts(text);
drop function if exists mos._control_caja_rol_ok(text);
drop table if exists mos.control_caja_revision_log;
drop table if exists mos.control_caja_revision;
commit;
