-- 50_mos_permisos_accion.sql — [Autorización · F0.2] Catálogo de acciones protegidas en TABLA (reemplaza _AUTH_CATALOGO de GAS).
-- nivel_minimo: 2=admin (master también por CASCADA, rol_nivel>=2), 3=master-only. tier = cache (1 rutina/2 sensible/3 crítico).
-- Niveles confirmados con el usuario (2026-06-13): 5 master-only; resto admin. Las 3 dudosas (cierre caja forzado,
-- bloquear/liberar dispositivo, NV→CPE) = admin. INERTE (la RPC F1 lo consultará; nadie lo usa aún).

create table if not exists mos.permisos_accion (
  accion        text primary key,
  tier          int  not null default 2,
  nivel_minimo  int  not null default 2,   -- 2=admin (+master por cascada), 3=master-only
  label         text,
  app           text
);

insert into mos.permisos_accion (accion, tier, nivel_minimo, label, app) values
  -- === MOS ===
  ('ANULAR_PAGO',                   2, 2, 'Anular pago liquidación',            'MOS'),
  ('VETAR_LIQUIDACION',             2, 2, 'Vetar liquidación día',              'MOS'),
  ('DESVETAR_LIQUIDACION',          1, 2, 'Desvetar liquidación',               'MOS'),
  ('BLOQUEAR_DISPOSITIVO',          2, 2, 'Bloquear dispositivo(s)',            'MOS'),
  ('LIBERAR_DISPOSITIVO_BLOQUEADO', 2, 2, 'Liberar dispositivo',                'MOS'),
  ('REVOCAR_DISPOSITIVO',           3, 3, 'Revocar dispositivo',                'MOS'),
  ('APROBAR_DISPOSITIVO_REMOTO',    2, 2, 'Aprobar dispositivo (panel)',        'MOS'),
  ('APROBAR_DISPOSITIVO_INSITU_MOS',3, 3, 'Aprobar MOS in-situ (master)',       'MOS'),
  ('REACTIVAR_DISPOSITIVO_SUSPENDIDO',2,2,'Reactivar dispositivo suspendido',   'MOS'),
  ('FORZAR_REVERIFY_DISPOSITIVO',   2, 2, 'Forzar re-verificación dispositivo', 'MOS'),
  ('CANCELACION_AUTO_PENDIENTE',    1, 2, 'Auto-cancelar solicitud >20h',       'MOS'),
  ('FORZAR_WIZARD',                 2, 2, 'Forzar wizard remoto',               'MOS'),
  ('CIERRE_CAJA_FORZADO',           3, 2, 'Cierre forzado de caja',             'MOS'),
  ('PURGAR_CATALOGO',               3, 3, 'Eliminar items del catálogo',        'MOS'),
  ('ROTAR_PIN_GLOBAL',              3, 3, 'Rotar PIN admin global',             'MOS'),
  -- === MosExpress ===
  ('ANULACION',                     1, 2, 'Anular venta',                       'MosExpress'),
  ('CREDITO_DIRECTO',               1, 2, 'Crédito directo',                    'MosExpress'),
  ('CREDITAR_VENTA',                1, 2, 'Marcar como crédito',                'MosExpress'),
  ('COBRAR_VENTA',                  1, 2, 'Cambiar método de pago',             'MosExpress'),
  ('COBRAR_CREDITO_CON_EXTRA',      1, 2, 'Cobrar crédito (caja receptora)',    'MosExpress'),
  ('CONVERTIR_NV_A_CPE',            2, 2, 'Convertir NV → CPE',                 'MosExpress'),
  ('BAJA_CPE',                      3, 3, 'Baja CPE a SUNAT',                   'MosExpress'),
  ('EDITAR_CLIENTE_VENTA',          2, 2, 'Editar cliente venta',              'MosExpress'),
  ('ACTIVAR_POS_60',                2, 2, 'Activar POS 60 min',                 'MosExpress'),
  ('DESBLOQUEO_TEMPORAL',           2, 2, 'Desbloqueo temporal',                'MosExpress'),
  ('EXTENDER_HORARIO_DISPOSITIVO',  2, 2, 'Extender horario in-situ por UUID',  'MosExpress'),
  -- === Warehouse ===
  ('REABRIR_GUIA',                  1, 2, 'Reabrir guía cerrada',               'warehouseMos'),
  ('ANULAR_ENVASADO',               2, 2, 'Anular envasado',                    'warehouseMos'),
  ('EDITAR_ENVASADO',               1, 2, 'Editar envasado',                    'warehouseMos'),
  ('APROBAR_DISPOSITIVO_INSITU',    2, 2, 'Aprobar dispositivo',                'warehouseMos'),
  ('PROCESAR_MERMAS',               2, 2, 'Procesar mermas',                    'warehouseMos'),
  -- === Centro Tributario ===
  ('TRIBUTARIO_LIMPIAR_HUERFANAS',  2, 2, 'Limpiar ventas huérfanas',           'MOS'),
  ('TRIBUTARIO_RECONCILIAR_TODOS',  2, 2, 'Reconciliar CPE con SUNAT',          'MOS'),
  ('TRIBUTARIO_REINTENTAR_CPE',     2, 2, 'Reintentar CPE individual',          'MOS'),
  ('TRIBUTARIO_REPROCESAR_OCR',     1, 2, 'Reprocesar OCR factura',             'MOS'),
  ('TRIBUTARIO_OCR_MASIVO',         2, 2, 'OCR masivo del mes',                 'MOS')
on conflict (accion) do update set tier=excluded.tier, nivel_minimo=excluded.nivel_minimo, label=excluded.label, app=excluded.app;

revoke all on mos.permisos_accion from public;
grant select on mos.permisos_accion to service_role, authenticated;
