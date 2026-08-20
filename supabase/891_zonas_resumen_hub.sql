-- [891] mos.zonas_resumen — conteos BARATOS por zona para el HUB de puestos (selector Netflix).
-- Solo lee me.stock_zonas (sin las CTEs pesadas del panel): productos con stock + en negativo por zona.
-- Las vitales "finas" (pedir/muertos) viven dentro del puesto (el panel ya las calcula al entrar).
create or replace function mos.zonas_resumen(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'zonaId',    zona_id,
      'productos', productos,
      'negativos', negativos
    ) order by zona_id), '[]'::jsonb)
  into v
  from (
    select zona_id,
      count(*) filter (where cantidad <> 0) as productos,
      count(*) filter (where cantidad < 0)  as negativos
    from me.stock_zonas
    group by zona_id
  ) t;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('zonas', v));
end $function$;
grant execute on function mos.zonas_resumen(jsonb) to authenticated, anon, service_role;

-- prueba
select mos.zonas_resumen('{}'::jsonb);
