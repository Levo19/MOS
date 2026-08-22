alter table mos.yape_dispositivos add column if not exists espia_diag text;
create or replace function mos.espia_diag(p jsonb) returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_dev text := nullif(btrim(coalesce(p->>'device','')),'');
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update mos.yape_dispositivos set espia_diag = left(coalesce(p->>'diag',''),300) || ' @' || to_char(now() at time zone 'America/Lima','HH24:MI:SS')
   where nombre = v_dev or device_uuid = v_dev;
  return jsonb_build_object('ok', true);
end $function$;
grant execute on function mos.espia_diag(jsonb) to authenticated, anon, service_role;
select 'espia_diag listo' ok;
