-- [921] mos.zona_stock_cruzado — stock de cada código en las OTRAS zonas (para el "foquito": si a mi
-- zona le falta y almacén no cubre, avisar que en la otra zona hay). Excluye la zona actual. El front
-- filtra cuáles son retail (zona1/zona2) vs almacén. Barato: solo lee me.stock_zonas.
create or replace function mos.zona_stock_cruzado(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_zona text := upper(btrim(coalesce(p->>'zona','')));
  v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('cod', cod_barras, 'zona', zona_id, 'cant', round(cantidad,2))), '[]'::jsonb)
    into v
    from me.stock_zonas
   where upper(btrim(coalesce(zona_id,''))) <> v_zona
     and cantidad > 0;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v));
end $function$;
grant execute on function mos.zona_stock_cruzado(jsonb) to authenticated, anon, service_role;

select mos.zona_stock_cruzado('{"zona":"ZONA-01"}'::jsonb) -> 'data' -> 'items' -> 0 as muestra;
