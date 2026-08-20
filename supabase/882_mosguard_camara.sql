-- [882] MosGuard fase 2 — cámara: foto a pedido + "en vivo" por cuadros. Sin audio, nunca.
-- El equipo (edición MosGuard) se entera de qué hacer por la respuesta del latido/guardia; no hay
-- canal aparte. Los cuadros van a Storage (bucket privado 'guard') vía la Edge guard-media.
alter table mos.yape_dispositivos
  add column if not exists guard_foto_pedida boolean not null default false,
  add column if not exists guard_live_hasta  timestamptz,
  add column if not exists guard_media_ts    timestamptz,
  add column if not exists guard_media_path  text;

insert into storage.buckets (id, name, public) values ('guard','guard',false)
on conflict (id) do nothing;

create or replace function mos.yape_latido(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_id bigint; v_estado text; v_foto boolean; v_live timestamptz;
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
   returning id, guard_estado, guard_foto_pedida, guard_live_hasta into v_id, v_estado, v_foto, v_live;
  if v_id is null then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;
  return jsonb_build_object('ok',true,
    'guard', coalesce(v_estado,'NORMAL'),
    'foto',  coalesce(v_foto,false),
    'liveHasta', case when v_live is not null and v_live > now() then extract(epoch from v_live)::bigint else 0 end);
end $function$;

create or replace function mos.yape_guard_foto(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nombre text := nullif(btrim(coalesce(p->>'nombre','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos set guard_foto_pedida = true where nombre = v_nombre;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','equipo no encontrado'); end if;
  return jsonb_build_object('ok',true);
end $function$;

create or replace function mos.yape_guard_live(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nombre text := nullif(btrim(coalesce(p->>'nombre','')),''); v_seg int := coalesce(nullif(p->>'seg','')::int, 120); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos
     set guard_live_hasta = case when v_seg <= 0 then null else now() + make_interval(secs => least(v_seg, 600)) end
   where nombre = v_nombre;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','equipo no encontrado'); end if;
  return jsonb_build_object('ok',true,'hasta', case when v_seg<=0 then 0 else v_seg end);
end $function$;

grant execute on function mos.yape_guard_foto(jsonb) to authenticated, anon, service_role;
grant execute on function mos.yape_guard_live(jsonb) to authenticated, anon, service_role;

create or replace function mos.yape_guard_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'nombre', d.nombre, 'zona', coalesce(d.zona,''), 'modelo', coalesce(d.modelo,''),
      'guardEstado', coalesce(d.guard_estado,'NORMAL'),
      'guardDesde', to_char(d.guard_desde at time zone 'America/Lima','YYYY-MM-DD HH24:MI'),
      'lat', d.lat, 'lon', d.lon, 'precM', d.ubic_prec_m,
      'ubicHace', case when d.ubic_ts is null then null else round(extract(epoch from (now()-d.ubic_ts))/60)::int end,
      'ultimoLatidoHace', case when d.ultimo_latido is null then null else round(extract(epoch from (now()-d.ultimo_latido))/60)::int end,
      'latidoEstado', case when not d.activo then 'REVOCADO' when d.ultimo_latido is null then 'NUNCA'
                          when d.ultimo_latido > now() - interval '30 minutes' then 'VIVO' else 'CAIDO' end,
      'fotoPedida', coalesce(d.guard_foto_pedida,false),
      'liveSeg', case when d.guard_live_hasta is not null and d.guard_live_hasta > now() then round(extract(epoch from (d.guard_live_hasta-now())))::int else 0 end,
      'mediaPath', d.guard_media_path,
      'mediaHaceSeg', case when d.guard_media_ts is null then null else round(extract(epoch from (now()-d.guard_media_ts)))::int end,
      'version', coalesce(d.version_name,'')
    ) order by d.guard_estado desc, d.activo desc, d.nombre), '[]'::jsonb) into v_out
    from mos.yape_dispositivos d;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('equipos', v_out));
end $function$;

select mos.yape_guard_foto(jsonb_build_object('nombre','__x__')) sin_equipo;
select mos.yape_guard_live(jsonb_build_object('nombre','Celular Yape ZONA-02','seg','0')) apagar;
select (mos.yape_guard_estado('{}'::jsonb)->'data'->'equipos'->0->>'fotoPedida') f0;
