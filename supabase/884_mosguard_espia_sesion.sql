-- [884] MosGuard · Spy2.0: la sesión de espía llega al equipo por el LATIDO (no hay FCM en MosGuard).
-- El master crea la sesión (espia_crear_sesion, reusado) y guarda el id acá; el equipo lo recoge en
-- su próximo latido/ronda y abre el WebView de streaming (guard-espia.html).
alter table mos.yape_dispositivos
  add column if not exists guard_espia_sesion text,
  add column if not exists guard_espia_ts     timestamptz;

-- el master (MOS) deja pedida la sesión para un equipo
create or replace function mos.yape_guard_espia_set(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nombre text := nullif(btrim(coalesce(p->>'nombre','')),''); v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos
     set guard_espia_sesion = v_sid,
         guard_espia_ts = case when v_sid is null then null else now() end
   where nombre = v_nombre;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','equipo no encontrado'); end if;
  return jsonb_build_object('ok',true);
end $function$;
grant execute on function mos.yape_guard_espia_set(jsonb) to authenticated, anon, service_role;

-- el latido devuelve la sesión SOLO si es fresca (pedida hace < 3 min): el equipo la abre una vez.
create or replace function mos.yape_latido(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_id bigint; v_estado text; v_foto boolean; v_live timestamptz; v_cap boolean; v_esp text; v_esp_ts timestamptz;
        v_lat double precision; v_lon double precision;
begin
  if v_sec = '' then return jsonb_build_object('ok',false,'error','sin secreto'); end if;
  begin v_lat := nullif(p->>'lat','')::double precision; v_lon := nullif(p->>'lon','')::double precision; exception when others then v_lat:=null; v_lon:=null; end;
  update mos.yape_dispositivos
     set ultimo_latido = now(),
         ultima_señal  = greatest(coalesce(ultima_señal, now()), now()),
         permiso_ok    = coalesce((p->>'permiso')::boolean, permiso_ok),
         pendientes    = coalesce(nullif(p->>'pendientes','')::int, pendientes),
         modelo        = coalesce(nullif(btrim(coalesce(p->>'equipo','')),''), modelo),
         version_code  = coalesce(nullif(p->>'versionCode','')::int, version_code),
         version_name  = coalesce(nullif(btrim(coalesce(p->>'versionName','')),''), version_name),
         aviso_caido_ts = case when coalesce((p->>'permiso')::boolean, true) then null else aviso_caido_ts end,
         lat        = case when v_lat is not null then v_lat else lat end,
         lon        = case when v_lon is not null then v_lon else lon end,
         ubic_prec_m= case when v_lat is not null then nullif(p->>'precM','')::double precision else ubic_prec_m end,
         ubic_ts    = case when v_lat is not null then now() else ubic_ts end
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex')
   returning id, guard_estado, guard_foto_pedida, guard_live_hasta, captura_yapes, guard_espia_sesion, guard_espia_ts
        into v_id, v_estado, v_foto, v_live, v_cap, v_esp, v_esp_ts;
  if v_id is null then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;
  return jsonb_build_object('ok',true,
    'capturaYapes', coalesce(v_cap,true),
    'guard', coalesce(v_estado,'NORMAL'),
    'foto',  coalesce(v_foto,false),
    'liveHasta', case when v_live is not null and v_live > now() then extract(epoch from v_live)::bigint else 0 end,
    'espiaSesion', case when v_esp is not null and v_esp_ts is not null and v_esp_ts > now() - interval '3 minutes' then v_esp else '' end);
end $function$;

select mos.yape_guard_espia_set(jsonb_build_object('nombre','__x__','sesionId','s1')) sin_equipo;
