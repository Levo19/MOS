-- 612 · Adhesivo Papito v2 — versión por producto: "Dulce Níspero".
--
-- Feedback de Luis tras imprimir la v1 (03/08/2026):
--   · Va por VERSIONES (no genérico): título = producto "Dulce Níspero" (con tilde
--     → transliteración CP437 nueva en tspl.mjs: í → 0xA1), debajo "Postres Papito".
--   · El teléfono se DESBORDABA por la derecha (font 2 negrita medía más que el
--     cálculo teórico). Fix: columna de texto en x15 y número en font 3 normal
--     (termina en ~40 mm de 50 — margen ancho). Ningún texto pasa de 44 mm.
--   · Icono ☎ (nuevo 'telefono', hex 32+48 sembrados) al costado del número.
--
-- Mismo id ADH-PAPITO-01 (reemplaza a la v1 genérica). Idempotente.

update mos.adhesivo_plantillas set
  nombre = 'Papito · Dulce Níspero',
  descripcion = 'Mini-tarjeta para postres · versión Dulce Níspero · sin membrete',
  json = '{
    "capas": [
      { "id": "ic", "tipo": "icono", "x_mm": 2,    "y_mm": 5,    "idIcono": "postre", "tamano_dots": 96 },
      { "id": "t1", "tipo": "texto", "x_mm": 15,   "y_mm": 2.2,  "texto": "Dulce",   "font": 4, "negrita": false, "rotacion": 0, "alineacion": "left" },
      { "id": "t2", "tipo": "texto", "x_mm": 15,   "y_mm": 7.2,  "texto": "Níspero", "font": 4, "negrita": false, "rotacion": 0, "alineacion": "left" },
      { "id": "t3", "tipo": "texto", "x_mm": 15,   "y_mm": 13.2, "texto": "Postres Papito", "font": 2, "negrita": false, "rotacion": 0, "alineacion": "left" },
      { "id": "ln", "tipo": "linea", "x_mm": 15,   "y_mm": 16.8, "ancho_mm": 26, "alto_mm": 0.4 },
      { "id": "tf", "tipo": "icono", "x_mm": 14.5, "y_mm": 18.6, "idIcono": "telefono", "tamano_dots": 32 },
      { "id": "t4", "tipo": "texto", "x_mm": 18.8, "y_mm": 19.2, "texto": "976 222 528", "font": 3, "negrita": false, "rotacion": 0, "alineacion": "left" }
    ],
    "tamano": { "tipo": "adhesivo", "alto_mm": 25, "ancho_mm": 50 },
    "version": 2,
    "metadata": { "nombre": "Papito · Dulce Níspero", "membrete": false, "protegida": true }
  }'::jsonb,
  fecha_ult_mod = now(),
  activo = true
where id_plantilla = 'ADH-PAPITO-01';
