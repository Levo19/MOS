-- 142 · consolidar_pickups_todas: incluir también zonas con ACU de bucket ANTERIOR pendiente,
-- para que el rezago (week-death) se marque aunque la zona no tenga ventas nuevas esta semana.
create or replace function wh.consolidar_pickups_todas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_today  date := (now() at time zone 'America/Lima')::date;
  v_bucket date := wh._bucket_dom(v_today);
  v_zona   text;
  v_n      int := 0;
begin
  for v_zona in
    -- zonas con candidatos del bucket actual  ∪  zonas con ACU de bucket previo pendiente (rezago)
    select z from (
      select distinct coalesce(id_zona,'') z
      from wh.pickups
      where upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
        and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
        and wh._bucket_dom((fecha_creado at time zone 'America/Lima')::date) = v_bucket
      union
      select distinct coalesce(id_zona,'') z
      from wh.pickups
      where fuente = 'ACUMULADO_SEMANAL'
        and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
        and right(id_pickup,10) ~ '^\d{4}-\d{2}-\d{2}$'
        and to_date(right(id_pickup,10),'YYYY-MM-DD') < v_bucket
    ) zz
    where coalesce(z,'') <> ''
  loop
    perform wh.consolidar_pickup_zona(v_zona, v_bucket);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('bucket', v_bucket, 'zonas', v_n));
end;
$fn$;
