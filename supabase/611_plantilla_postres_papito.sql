-- 611 · Plantilla de adhesivo "Postres Papito" (mini-tarjeta de presentación).
--
-- Pedido de Luis (03/08/2026): adhesivo 50×25 para pegar en postres — SIN membrete
-- de Inversiones MOS. Marca propia: icono cupcake (nuevo icono 'postre' del catálogo,
-- sembrado en mos.adhesivo_iconos 48+96 por _seed_icono_postre.mjs) + "POSTRES
-- PAPITO" + eslogan "Dulzura hecha en casa" + teléfono 972 225 28.
-- Boceto aprobado: layout A (icono izq., tarjeta clásica), cupcake, eslogan recomendado.
--
-- Idempotente (on conflict update). protegida:true → catálogo fijo, solo-imprimir.

insert into mos.adhesivo_plantillas (id_plantilla, nombre, descripcion, tamano_canvas, json, creado_por, fecha_creado, fecha_ult_mod, activo)
values (
  'ADH-PAPITO-01',
  'Postres Papito · tarjeta',
  'Mini-tarjeta para postres · sin membrete · cupcake + eslogan + teléfono',
  '50x25',
  '{
    "capas": [
      { "id": "ic", "tipo": "icono", "x_mm": 2,  "y_mm": 6,    "idIcono": "postre", "tamano_dots": 96 },
      { "id": "t1", "tipo": "texto", "x_mm": 16, "y_mm": 2.5,  "texto": "POSTRES", "font": 3, "negrita": true,  "rotacion": 0, "alineacion": "left" },
      { "id": "t2", "tipo": "texto", "x_mm": 16, "y_mm": 9,    "texto": "PAPITO",  "font": 3, "negrita": true,  "rotacion": 0, "alineacion": "left" },
      { "id": "t3", "tipo": "texto", "x_mm": 16, "y_mm": 15.6, "texto": "Dulzura hecha en casa", "font": 1, "negrita": false, "rotacion": 0, "alineacion": "left" },
      { "id": "ln", "tipo": "linea", "x_mm": 16, "y_mm": 18.6, "ancho_mm": 30, "alto_mm": 0.4 },
      { "id": "t4", "tipo": "texto", "x_mm": 16, "y_mm": 19.8, "texto": "972 225 28", "font": 2, "negrita": true, "rotacion": 0, "alineacion": "left" }
    ],
    "tamano": { "tipo": "adhesivo", "alto_mm": 25, "ancho_mm": 50 },
    "version": 2,
    "metadata": { "nombre": "Postres Papito · tarjeta", "membrete": false, "protegida": true }
  }'::jsonb,
  'Luis',
  now(), now(), true
)
on conflict (id_plantilla) do update
  set nombre = excluded.nombre,
      descripcion = excluded.descripcion,
      json = excluded.json,
      fecha_ult_mod = now(),
      activo = true;
