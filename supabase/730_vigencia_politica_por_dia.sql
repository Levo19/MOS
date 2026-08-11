-- 730 · Cada día se paga con la política que regía ESE día (pedido del dueño).
-- (a) semilla del historial fiel a lo aplicado (nada viejo cambia)
-- (b) _meta_zona/_comision_pct con fecha pierden el fallback global
-- (c) recomputar_dia usa la version CON FECHA
create or replace function mos._meta_zona(p_zona text, p_dia date) returns numeric language sql stable set search_path to '' as $fn$
  -- [730] vigencia por día: primero el historial de ese día, luego la política actual de la zona.
  -- SIN fallback global (729) y SIN 0 (0 significaría "comisión sobre toda la venta").
  select coalesce(mos._politica_valor(p_zona, 'metaDiaria', p_dia),
                  mos._numn((select politica_json->>'metaDiaria' from mos.zonas where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1)));
$fn$;
create or replace function mos._comision_pct(p_zona text, p_dia date) returns numeric language sql stable set search_path to '' as $fn$
  select coalesce(mos._politica_valor(p_zona, 'comisionExcedentePct', p_dia),
                  mos._numn((select politica_json->>'comisionExcedentePct' from mos.zonas where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1)),
                  0::numeric);
$fn$;
-- + parche de recomputar_dia (ver def viva con [730]) y semilla en zona_politica_historial
