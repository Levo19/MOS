-- 725 · Propagación rápida del estado/config de IMPRESORAS y SERIES (pedido dueño 2026-08-10):
--   "cambié el ID de impresora en MOS pero a muchos dispositivos de ME no les llega".
--   CAUSA: mos.impresoras y mos.series NO tenían trigger de bump (estaciones y zonas sí),
--   y ZONAS_CONFIG del payload del POS (que lleva PrintNode_ID a cada ME) sale de ahí.
--   Sin bump, los ME conservaban la config vieja hasta la re-descarga natural (3AM/1PM o manual).
--   Mismo patrón que 661: CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED → el lock del bump
--   dura microsegundos y una edición masiva deja 1 solo bump por transacción.
drop trigger if exists tg_bump_catversion_impresoras on mos.impresoras;
create constraint trigger tg_bump_catversion_impresoras
  after insert or delete or update on mos.impresoras
  deferrable initially deferred
  for each row execute function mos._bump_catalogo_version();

-- NOTA: mos.series_documentales YA tenía tg_bump_catversion_series (verificado al aplicar) → no se duplica.
