-- 348: cron NUEVO GPS-sin-señal (#22, cero-GAS). Avisa a master de dispositivos ACTIVOS que reportaban GPS
-- (última señal en las últimas 12h) pero PARARON hace +2h. Detección refinada (no la lista amplia de nunca-GPS).
create or replace function mos.cron_gps_sin_senal()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  select count(*) into v_n
  from (
    select u.device_id, max(u.ts) ult
      from mos.dispositivos_ubicaciones u
      join mos.dispositivos d on d.id_dispositivo = u.device_id and upper(coalesce(d.estado,''))='ACTIVO'
     group by u.device_id
  ) s
  where s.ult > now() - interval '12 hours' and s.ult < now() - interval '2 hours';
  begin
    if coalesce(v_n,0) > 0 then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', '📍 Dispositivos sin señal GPS',
        'cuerpo', v_n || ' dispositivo(s) dejaron de reportar ubicación hace +2h · revísalos',
        'data', jsonb_build_object('tipo','gps_sin_senal')));
    end if;
  exception when others then null; end;
  insert into mos.cron_log(job, ok, resultado) values ('gps_sin_senal', true, jsonb_build_object('sin_senal',v_n));
  return jsonb_build_object('ok', true, 'sin_senal', v_n);
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('gps_sin_senal', false, jsonb_build_object('excepcion',SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;
revoke all on function mos.cron_gps_sin_senal() from public, anon;
grant execute on function mos.cron_gps_sin_senal() to service_role;
-- 11am + 4pm Lima (16, 21 UTC) — mediodía/tarde laboral, conservador para no spamear.
select cron.unschedule('mos-gps-sin-senal') where exists (select 1 from cron.job where jobname='mos-gps-sin-senal');
select cron.schedule('mos-gps-sin-senal', '0 16,21 * * *', 'select mos.cron_gps_sin_senal();');
