-- 358: [CPE demo cero-GAS] Sembrar las series BBB1(boleta)/FFF1(factura) en TODAS las zonas incl. MOS-VIP y
-- ALMACEN (pedido del dueño para la fase demo — cuando llegue el token de producción solo se cambian los
-- strings de serie + el token en fac.config, todo directo a Supabase, sin GAS ni intermediario).
-- 3 piezas: (1) contadores reales en fac.series; (2) filas por zona en mos.series_documentales; (3) defaults en fac.config.

-- (1) Contadores reales (fac.series) — tipo NubeFact: 1=FACTURA, 2=BOLETA. correlativo 0 (sin resetear si ya existen).
insert into fac.series(serie, tipo, correlativo, activa) values
  ('BBB1', 2, '0', true),
  ('FFF1', 1, '0', true)
on conflict (serie) do update set activa = true;

-- (2) Series por zona faltantes: MOS-VIP + ALMACEN (ZONA-01/02 ya tienen BBB1/FFF1).
insert into mos.series_documentales(id_serie, id_estacion, id_zona, tipo_documento, serie, correlativo, activo) values
  ('SER_VIP_BOL', 'MOS-VIP', 'MOS-VIP', 'BOLETA',  'BBB1', '1', true),
  ('SER_VIP_FAC', 'MOS-VIP', 'MOS-VIP', 'FACTURA', 'FFF1', '1', true),
  ('SER_ALM_BOL', 'ES004',   'ALMACEN', 'BOLETA',  'BBB1', '1', true),
  ('SER_ALM_FAC', 'ES004',   'ALMACEN', 'FACTURA', 'FFF1', '1', true)
on conflict (id_serie) do update set serie = excluded.serie, tipo_documento = excluded.tipo_documento,
  id_zona = excluded.id_zona, activo = true;

-- (3) Defaults del config → BBB1/FFF1 (para cualquier zona sin serie propia; hoy caía a B001/F001).
update fac.config set serie_boleta = 'BBB1', serie_factura = 'FFF1', actualizado_at = now() where id = 1;
