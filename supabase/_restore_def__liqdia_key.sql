create or replace function mos._liqdia_key(p_id_personal text, p_fecha text)
returns text language sql immutable set search_path = '' as $fn$
  -- [100x C1] se preserva '|' además de ':' → MEX:SERGIO|ZONA-01 no colapsa su separador
  -- (antes '|'→'_' podía fundir identidades distintas en la misma fila = merge de dinero).
  select 'LDIA-' || replace(coalesce(p_fecha,''),'-','') || '-'
         || regexp_replace(coalesce(p_id_personal,''), '[^a-zA-Z0-9:|]', '_', 'g');
$fn$;