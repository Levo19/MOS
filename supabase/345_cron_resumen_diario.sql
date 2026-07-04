-- 345: cron NUEVO daily-summary (#32, cero-GAS). Agrega resumen_todos_dia + push a admins a las 22h Lima.
create or replace function mos.cron_resumen_diario()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_res jsonb; v_total numeric := 0; v_present int := 0;
begin
  perform set_config('request.jwt.claims', '{"app":"MOS"}', true);  -- claim local para resumen_todos_dia
  v_res := mos.resumen_todos_dia('{}'::jsonb);
  select coalesce(sum((e->>'totalDia')::numeric),0),
         count(*) filter (where coalesce((e->>'presente')::boolean,false))
    into v_total, v_present
    from jsonb_array_elements(coalesce(v_res->'data','[]'::jsonb)) e;
  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
      'titulo', '📊 Resumen del día',
      'cuerpo', 'S/ ' || round(coalesce(v_total,0))::text || ' en ventas · ' || coalesce(v_present,0) || ' persona(s) presente(s)',
      'data', jsonb_build_object('tipo','resumen_diario')));
  exception when others then null; end;
  insert into mos.cron_log(job, ok, resultado) values ('resumen_diario', true, jsonb_build_object('total',v_total,'presentes',v_present));
  return jsonb_build_object('ok', true, 'total', v_total, 'presentes', v_present);
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('resumen_diario', false, jsonb_build_object('excepcion',SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;
revoke all on function mos.cron_resumen_diario() from public, anon;
grant execute on function mos.cron_resumen_diario() to service_role;

-- agendar: 22h Lima = 03:00 UTC (Lima UTC-5). Idempotente (unschedule si ya existe).
select cron.unschedule('mos-resumen-diario') where exists (select 1 from cron.job where jobname='mos-resumen-diario');
select cron.schedule('mos-resumen-diario', '0 3 * * *', 'select mos.cron_resumen_diario();');
