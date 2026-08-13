create or replace function mos._liqdia_total(p_base numeric, p_env numeric, p_meta numeric, p_bon numeric, p_san numeric)
returns numeric language sql immutable set search_path = '' as $fn$
  -- max(0, round((base+env+meta+bon-san)*100)/100)  — idéntico a GAS, DINERO exacto.
  select greatest(0::numeric, round(
    coalesce(p_base,0) + coalesce(p_env,0) + coalesce(p_meta,0) + coalesce(p_bon,0) - coalesce(p_san,0)
  , 2));
$fn$;