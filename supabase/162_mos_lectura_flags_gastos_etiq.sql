-- 162_mos_lectura_flags_gastos_etiq.sql — [CUTOVER DELETE-SAFE · flags de lectura faltantes]
-- Siembra los flags de LECTURA por-módulo de gastos y etiquetas (no existían). Espeja la convención de los
-- demás MOS_*_LECTURA (proveedores/pagos/pedidos/provprod/jornadas/eval/horario, todos '1' en prod).
-- Los read-backs de GAS (getGastos/_calcularGastos, getEtiquetasPendientes) ya leen vía el gate
-- (_mosFlagOn_ = MAESTRO 'MOS_LECTURA_NAVEGADOR' OR este flag). Como el maestro ya está ON, estas lecturas
-- YA estaban activas vía OR; este flag agrega un KILL-SWITCH explícito por-módulo:
--   apagar lectura de gastos:    update mos.config set valor='0' where clave='MOS_GASTOS_LECTURA';  (+ maestro OFF)
--   (⚠️ recordar: el MAESTRO ON pisa el flag de módulo; para apagar SOLO un módulo hay que apagar el maestro
--    y dejar ON los demás módulos, o viceversa — coherente con el front).
-- Idempotente: ON CONFLICT DO NOTHING (no pisa un valor ya seteado por el dueño).

insert into mos.config (clave, valor, descripcion) values
  ('MOS_GASTOS_LECTURA', '1', 'Lectura directa de gastos (GAS getGastos/_calcularGastos + sombra). Kill-switch por-módulo.'),
  ('MOS_ETIQ_LECTURA',   '1', 'Lectura directa de etiquetas_zona (GAS getEtiquetasPendientes + sombra). Kill-switch por-módulo.')
on conflict (clave) do nothing;
