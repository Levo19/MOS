-- 524_normalizar_estados_mermas.sql — CAUSA RAÍZ del "Pendientes (0)" en WH:
-- filas legacy (era Hoja) traían estado PENDIENTE / PROCESADA; el ciclo v2 usa
-- EN_PROCESO / RESUELTA / DESECHADA y la vista WH filtra por ese canon → las 3
-- pendientes reales quedaban invisibles (MOS sí las veía: filtra por cantidad).
-- Normalización aplicada 2026-07-19 NOMINAL (las 3 únicas filas legacy, todas con
-- pendiente > 0 → EN_PROCESO). El front además quedó blindado: deriva el estado
-- de las CANTIDADES (_estadoCanon en WH app.js), nunca más del string legacy.
update wh.mermas set estado = 'EN_PROCESO'
 where id_merma in ('M001','M002','M003')
   and coalesce(cantidad_pendiente,0) > 0;
