-- 346: cron NUEVO device-inactividad (#15 alert-only, cero-GAS). Avisa a master de devices ACTIVOS sin
-- conectar +2 días. Solo ALERTA (no suspende = no toca auth-state, safe). Push best-effort.
create or replace function mos.cron_dispositivos_inactivos()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  select count(*) into v_n from mos.dispositivos
   where upper(coalesce(estado,''))='ACTIVO'
     and ultima_conexion is not null
     and ultima_conexion < now() - interval '2 days';
  begin
    if coalesce(v_n,0) > 0 then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', '😴 Dispositivos inactivos',
        'cuerpo', v_n || ' dispositivo(s) ACTIVO(s) sin conectar +2 días · revísalos',
        'data', jsonb_build_object('tipo','device_inactivo')));
    end if;
  exception when others then null; end;
  insert into mos.cron_log(job, ok, resultado) values ('dispositivos_inactivos', true, jsonb_build_object('inactivos',v_n));
  return jsonb_build_object('ok', true, 'inactivos', v_n);
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('dispositivos_inactivos', false, jsonb_build_object('excepcion',SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;
revoke all on function mos.cron_dispositivos_inactivos() from public, anon;
grant execute on function mos.cron_dispositivos_inactivos() to service_role;
-- 9am Lima = 14:00 UTC, diario.
select cron.unschedule('mos-dispositivos-inactivos') where exists (select 1 from cron.job where jobname='mos-dispositivos-inactivos');
select cron.schedule('mos-dispositivos-inactivos', '0 14 * * *', 'select mos.cron_dispositivos_inactivos();');
