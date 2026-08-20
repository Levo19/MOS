-- [888] MÓDULO ZONA EN TIEMPO REAL — cerrar los 3 flancos que no avisaban.
-- El panel de zona (me.zona_panel) se alimenta de varias tablas. El realtime (me.ops_meta) ya cubre
-- stock_zonas, wh.stock ('stock'), ventas y guías. Faltaban 3 tablas que NO bumpeaban → cambios en
-- ellas no refrescaban el panel abierto:
--   1) me.stock_movimientos  → el kardex/historial y los ajustes puros no refrescaban en vivo.
--   2) me.zona_esperado      → cuando el cron recalcula la rotación/objetivo, el panel no se enteraba.
--   3) me.zona_pedido_log    → y `me.zona_pedir_almacen` NO toca stock_zonas, así que pedir a almacén
--                              no refrescaba NADA (el chip "pedido hoy" salía recién al reabrir).
-- Todas bumpean el dominio 'stock_zonas', que es el que el front ya rutea → _zonaAutoRefrescar()
-- (re-pull de me.zona_panel = stock, esperado, pedidos, todo fresco). Triggers STATEMENT-LEVEL
-- (1 bump por operación, no por fila) y AFTER (no tocan la fila fuente) → cero impacto en la lógica
-- de dinero. Idempotentes.

-- 1) movimientos de stock (ventas, ajustes, traslados, auditorías) → refresca kardex + saldos
drop trigger if exists tg_bump_ops_stockmov on me.stock_movimientos;
create trigger tg_bump_ops_stockmov
  after insert or update or delete on me.stock_movimientos
  for each statement execute function me._tg_bump_ops('stock_zonas');

-- 2) snapshot de rotación/objetivo (lo recalcula el cron) → refresca esperado/tendencia/cuadrante
drop trigger if exists tg_bump_ops_zonaesperado on me.zona_esperado;
create trigger tg_bump_ops_zonaesperado
  after insert or update or delete on me.zona_esperado
  for each statement execute function me._tg_bump_ops('stock_zonas');

-- 3) log de pedidos a almacén → el estado "pedido hoy/ayer" aparece al instante
drop trigger if exists tg_bump_ops_pedidolog on me.zona_pedido_log;
create trigger tg_bump_ops_pedidolog
  after insert or update or delete on me.zona_pedido_log
  for each statement execute function me._tg_bump_ops('stock_zonas');

-- verificación
select tgrelid::regclass::text tabla, tgname
from pg_trigger
where tgname in ('tg_bump_ops_stockmov','tg_bump_ops_zonaesperado','tg_bump_ops_pedidolog')
order by 1;
