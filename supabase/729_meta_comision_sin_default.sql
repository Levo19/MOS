-- 729 · Dinero (pedido del dueño): meta y comision SOLO de la politica de la zona, sin global.
-- meta NULL cuando no hay config (NUNCA 0: con 0 el pool seria la venta completa por el % = sobrepago).
-- comision 0 cuando no hay config (nunca inventar una tasa).
create or replace function mos._meta_zona(p_zona text) returns numeric language sql stable set search_path to '' as $fn$
  -- [729] SIN fallback global (pedido del dueño: fiel a la config de la zona).
  -- NULL = zona sin meta configurada → el bono sale 0. Jamás 0, que significaría "comisión sobre todo".
  select mos._numn((select politica_json->>'metaDiaria' from mos.zonas
                     where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1));
$fn$;
create or replace function mos._comision_pct(p_zona text) returns numeric language sql stable set search_path to '' as $fn$
  -- [729] SIN fallback global. Sin % configurado = 0% (nunca inventar una tasa de pago).
  select coalesce(mos._numn((select politica_json->>'comisionExcedentePct' from mos.zonas
                              where upper(btrim(id_zona)) = upper(btrim(p_zona)) limit 1)), 0::numeric);
$fn$;
