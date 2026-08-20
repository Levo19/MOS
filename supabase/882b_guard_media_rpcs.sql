-- [882] RPCs auxiliares de guard-media (resolver equipo por secreto · anotar media recibida)
create or replace function mos.yape_guard_por_secreto(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_nom text;
begin
  if v_sec = '' then return jsonb_build_object('ok',false); end if;
  select nombre into v_nom from mos.yape_dispositivos
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex') limit 1;
  if v_nom is null then return jsonb_build_object('ok',false); end if;
  return jsonb_build_object('ok',true,'nombre',v_nom);
end $function$;

create or replace function mos.yape_guard_media_recibida(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_path text := coalesce(p->>'path',''); v_n int;
begin
  if v_sec = '' or v_path = '' then return jsonb_build_object('ok',false); end if;
  update mos.yape_dispositivos
     set guard_media_path = v_path, guard_media_ts = now(), guard_foto_pedida = false
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex');
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0);
end $function$;

grant execute on function mos.yape_guard_por_secreto(jsonb)   to service_role;
grant execute on function mos.yape_guard_media_recibida(jsonb) to service_role;

-- equipo de prueba con secreto conocido (para el test E2E del upload; se borra al final)
insert into mos.yape_dispositivos (nombre, zona, secreto_hash, activo, creado_ts)
values ('__TEST_GUARD__', 'ZONA-01', encode(digest('SECRETO_TEST_GUARD_882','sha256'),'hex'), true, now())
on conflict do nothing;
select mos.yape_guard_por_secreto(jsonb_build_object('secreto','SECRETO_TEST_GUARD_882')) resolver;
