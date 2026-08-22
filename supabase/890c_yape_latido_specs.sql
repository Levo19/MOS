-- [890c] El latido ahora persiste marca + versión de Android (el APK las manda en cada heartbeat).
-- Así los equipos que YA existían antes del auto-registro (ej el device de prueba con secreto viejo)
-- backfillean sus specs solos en su próximo latido — sin re-registrar. Solo agrega 2 líneas al UPDATE.
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
         marca         = coalesce(nullif(btrim(coalesce(p->>'marca','')),''), marca),
         so_ver        = coalesce(nullif(btrim(coalesce(p->>'so','')),''), so_ver),
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

select 'yape_latido +marca/so_ver listo' as ok;
