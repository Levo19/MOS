-- [881] MosGuard · fase 1 — ubicación + estado del equipo (backend). Todo cuelga de la tabla que ya
-- existe (mos.yape_dispositivos) y de la RPC de latido que el APK ya llama cada 10 min. NADA de esto
-- afecta la captura de Yapes: son columnas y ramas nuevas, aditivas.
alter table mos.yape_dispositivos
  add column if not exists guard_estado text not null default 'NORMAL',   -- NORMAL | ROBADO
  add column if not exists guard_desde  timestamptz,
  add column if not exists lat          double precision,
  add column if not exists lon          double precision,
  add column if not exists ubic_prec_m  double precision,                 -- precisión en metros
  add column if not exists ubic_ts      timestamptz;

-- el latido acepta lat/lon si el equipo (flavor MosGuard) las manda; el YapeCaptor viejo nunca las
-- manda, así que para él esta rama no existe. Devuelve el estado guard para que el equipo sepa si el
-- dueño lo marcó ROBADO (y así suba ubicación más seguido / saque una foto).
create or replace function mos.yape_latido(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_id bigint; v_estado text; v_lat double precision; v_lon double precision;
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
         -- [881] MosGuard: solo si el equipo manda coordenadas válidas
         lat        = case when v_lat is not null then v_lat else lat end,
         lon        = case when v_lon is not null then v_lon else lon end,
         ubic_prec_m= case when v_lat is not null then nullif(p->>'precM','')::double precision else ubic_prec_m end,
         ubic_ts    = case when v_lat is not null then now() else ubic_ts end
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex')
   returning id, guard_estado into v_id, v_estado;
  if v_id is null then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;
  -- el estado le dice al equipo qué hacer sin tener que preguntarlo aparte
  return jsonb_build_object('ok',true,'guard', coalesce(v_estado,'NORMAL'));
end $function$;

-- el dueño marca un equipo ROBADO / NORMAL desde MOS (rol admin). ROBADO = el equipo, en su próximo
-- latido, se entera y empieza a subir ubicación seguido + una foto (fase 1) / video (fase 2).
create or replace function mos.yape_guard_marcar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nombre text := nullif(btrim(coalesce(p->>'nombre','')),''); v_estado text := upper(coalesce(p->>'estado','')); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','falta nombre del equipo'); end if;
  if v_estado not in ('NORMAL','ROBADO') then return jsonb_build_object('ok',false,'error','estado inválido (NORMAL|ROBADO)'); end if;
  update mos.yape_dispositivos
     set guard_estado = v_estado,
         guard_desde  = case when v_estado='ROBADO' then now() else null end
   where nombre = v_nombre;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','equipo no encontrado'); end if;
  return jsonb_build_object('ok',true,'estado',v_estado);
end $function$;

-- el panel de MosGuard: estado de cada equipo con su ubicación (reusa la forma de yape_dispositivos_estado
-- pero agrega guard + coordenadas). Se deja como RPC aparte para no tocar la que ya usa el panel de Yapes.
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
      'version', coalesce(d.version_name,'')
    ) order by d.guard_estado desc, d.activo desc, d.nombre), '[]'::jsonb) into v_out
    from mos.yape_dispositivos d;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('equipos', v_out));
end $function$;

grant execute on function mos.yape_guard_marcar(jsonb)  to authenticated, anon, service_role;
grant execute on function mos.yape_guard_estado(jsonb)  to authenticated, anon, service_role;

-- pruebas
select mos.yape_latido(jsonb_build_object('secreto','__no_existe__','lat','-13.71','lon','-76.20')) latido_desconocido;
select (mos.yape_guard_estado('{}'::jsonb)->'data'->'equipos') equipos;
