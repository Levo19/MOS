-- 347: cron NUEVO salud-stock WH (#20, cero-GAS). Avisa a admins de productos críticos / vencimientos críticos.
-- Extracción defensiva (array→length o número). Push best-effort. Reemplaza el push GAS MOS_SALUD_STOCK_WH.
create or replace function mos.cron_salud_stock()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_o jsonb; v_d jsonb; v_crit int; v_venc int; v_merma int;
  _n int;
begin
  perform set_config('request.jwt.claims', '{"app":"MOS"}', true);
  v_o := mos.dashboard_almacen('{}'::jsonb);
  v_d := coalesce(v_o->'data', v_o);
  v_crit  := coalesce(case when jsonb_typeof(v_d->'productosCriticos')='array' then jsonb_array_length(v_d->'productosCriticos') else nullif(v_d->>'productosCriticos','')::int end, 0);
  v_venc  := coalesce(case when jsonb_typeof(v_d->'vencCriticos')='array' then jsonb_array_length(v_d->'vencCriticos') else nullif(v_d->>'vencCriticos','')::int end, 0);
  v_merma := coalesce(case when jsonb_typeof(v_d->'mermasPendientes')='array' then jsonb_array_length(v_d->'mermasPendientes') else nullif(v_d->>'mermasPendientes','')::int end, 0);
  begin
    if v_crit > 0 or v_venc > 0 then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '📦 Salud de stock',
        'cuerpo', v_crit || ' producto(s) en stock crítico · ' || v_venc || ' vencimiento(s) crítico(s)' || case when v_merma>0 then ' · '||v_merma||' merma(s) pendiente(s)' else '' end,
        'data', jsonb_build_object('tipo','salud_stock')));
    end if;
  exception when others then null; end;
  insert into mos.cron_log(job, ok, resultado) values ('salud_stock', true, jsonb_build_object('criticos',v_crit,'venc',v_venc,'mermas',v_merma));
  return jsonb_build_object('ok', true, 'criticos', v_crit, 'venc', v_venc, 'mermas', v_merma);
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('salud_stock', false, jsonb_build_object('excepcion',SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;
revoke all on function mos.cron_salud_stock() from public, anon;
grant execute on function mos.cron_salud_stock() to service_role;
-- 8am Lima = 13:00 UTC, diario.
select cron.unschedule('mos-salud-stock') where exists (select 1 from cron.job where jobname='mos-salud-stock');
select cron.schedule('mos-salud-stock', '0 13 * * *', 'select mos.cron_salud_stock();');
