-- 101_mos_dispositivos_columnas_fase4.sql — [FASE 4.1 · Etapa A] Completar el esquema de la sombra
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- La sombra mos.dispositivos NO tiene varias columnas que SÍ están en la hoja DISPOSITIVOS y que los
-- lectores GAS necesitan. Sin ellas, al migrar los lectores a la sombra se romperían push/audio/espía
-- (FCM_Token), las alertas de seguridad, los horarios y el detalle de bloqueo.
-- INERTE: agregar columnas no cambia ningún comportamiento (nadie las escribe/lee todavía; el dual-write
-- ampliado de la Etapa B las empezará a poblar). Idempotente (add column if not exists).
--
-- NO se agrega "Aprobado": en la sombra el estado vive en `estado` (ACTIVO/PENDIENTE/...). El flag
-- Aprobado de la hoja es redundante con estado='ACTIVO' → se deriva, no se duplica (verificar en vivo
-- que ningún lector lo lea separado antes de migrar ese lector; documentado en DISENO_FASE4_auth_puro.md).
--
-- Bloqueo: el estado se modela en `estado='BLOQUEADO'` (la sombra ya soporta varios estados) + estas dos
-- columnas de detalle para el panel/auditoría. suspendido_desde ya existe (para SUSPENDIDO).

alter table mos.dispositivos add column if not exists fcm_token                 text;        -- push/audio/espía
alter table mos.dispositivos add column if not exists alerta_seguridad          text;        -- alertarDispositivosInactivos2a7d
alter table mos.dispositivos add column if not exists alerta_seguridad_revisada boolean default false; -- _marcarAlertaSegRevisada
alter table mos.dispositivos add column if not exists forzar_horario_hasta      timestamptz; -- Horarios.gs verificarHorario
alter table mos.dispositivos add column if not exists razon_bloqueo             text;        -- Bloqueos.gs panel/auditoría
alter table mos.dispositivos add column if not exists bloqueado_desde           timestamptz; -- Bloqueos.gs

-- (índice por fcm_token NO se crea: se consulta por id_dispositivo, no por token.)
