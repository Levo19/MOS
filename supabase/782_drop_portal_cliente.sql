-- 782 · PURGA TOTAL del Portal Cliente WH (14-ago-2026, orden del dueño).
-- El portal de pedidos (pedido.html/clientes.html) NUNCA se usó en producción:
-- wh.clientes tenía solo 2 clientes de PRUEBA (TESTSMOK126/JUANDIEG279) y 4
-- pedidos smoke. Se corta de raíz: 7 RPCs + 5 tablas. El frontend (2 HTML +
-- clienteInbox.js + SW) se borra en el repo WH; la Edge recibir-pedido se
-- des-despliega aparte. reporte.html NO es del portal (reportes de guía, ME).
begin;

drop function if exists wh.cliente_pedido_crear(jsonb);
drop function if exists wh.cliente_confirmar_pedido(jsonb);
drop function if exists wh.cliente_estado_pedido(jsonb);
drop function if exists wh.cliente_inbox_polling(jsonb);
drop function if exists wh.cliente_listar(jsonb);
drop function if exists wh.cliente_registrar(jsonb);
drop function if exists wh.cliente_info(jsonb);

drop table if exists wh.pedidos_cliente_adj;
drop table if exists wh.pedidos_cliente_items;
drop table if exists wh.pedidos_cliente;
drop table if exists wh.clientes_portal;
drop table if exists wh.clientes;

commit;
