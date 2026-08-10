-- 726 · Techo propio de 30s en las lecturas pesadas del panel (mismo remedio que catalogo_pos_rls).
-- CAUSA: el rol authenticated corta a 8s; productos_master_rls tarda ~7s en frio (5.8MB) → bajo
-- concurrencia cruza el limite y PostgREST devuelve HTTP 500. Cero cambios de logica.
-- NOTA: esto es un PARCHE. El fondo es la dieta del payload (5.8MB por boot del panel).
alter function mos.productos_master_rls() set statement_timeout='30s';
alter function mos.rotacion_productos() set statement_timeout='30s';
alter function mos.cierres_caja() set statement_timeout='30s';
alter function mos.finanzas_dia() set statement_timeout='30s';
alter function mos.finanzas_rango() set statement_timeout='30s';
alter function mos.resumen_todos_dia() set statement_timeout='30s';
