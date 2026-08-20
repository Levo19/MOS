-- [883] MosGuard = agente universal. La app va en TODOS los equipos; el dueño decide desde MOS
-- cuáles capturan Yapes (los de caja) y cuáles solo se resguardan (personales). Un flag por equipo.
alter table mos.yape_dispositivos
  add column if not exists captura_yapes boolean not null default true;

-- el latido devuelve si este equipo debe capturar Yapes → un celular personal deja de leer las
-- notificaciones (privacidad) y solo hace resguardo.
create or replace function mos.yape_latido(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_id bigint; v_estado text; v_foto boolean; v_live timestamptz; v_cap boolean;
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
   returning id, guard_estado, guard_foto_pedida, guard_live_hasta, captura_yapes
        into v_id, v_estado, v_foto, v_live, v_cap;
  if v_id is null then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;
  return jsonb_build_object('ok',true,
    'capturaYapes', coalesce(v_cap,true),
    'guard', coalesce(v_estado,'NORMAL'),
    'foto',  coalesce(v_foto,false),
    'liveHasta', case when v_live is not null and v_live > now() then extract(epoch from v_live)::bigint else 0 end);
end $function$;

-- gate server-side: si el equipo tiene la captura APAGADA, la ingesta lo reconoce (para vaciar su
-- cola) pero NO guarda el Yape. Así, aunque un personal siga mandando, no entra plata ajena.
create or replace function mos.yape_ingesta(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text := coalesce(p->>'secreto',''); v_dev record; v_key text := nullif(btrim(coalesce(p->>'notifKey','')),'');
        v_raw text := coalesce(p->>'texto',''); v_ts timestamptz; v_par jsonb; v_id bigint; v_nuevo boolean := true;
begin
  if coalesce(me.jwt_app(),'') not in ('','MOS','mosExpress') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_sec = '' or v_key is null or btrim(v_raw) = '' then
    return jsonb_build_object('ok',false,'error','faltan secreto, notifKey o texto');
  end if;
  select * into v_dev from mos.yape_dispositivos
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex') limit 1;
  if not found then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;
  -- [883] captura apagada: se responde ok (el APK saca de su cola) y NO se guarda nada.
  if not coalesce(v_dev.captura_yapes, true) then
    update mos.yape_dispositivos set ultima_señal = now() where id = v_dev.id;
    return jsonb_build_object('ok', true, 'descartado', true, 'motivo', 'CAPTURA_APAGADA');
  end if;

  begin v_ts := (p->>'ts')::timestamptz; exception when others then v_ts := now(); end;
  v_ts := coalesce(v_ts, now());
  v_par := mos._yape_parse(v_raw);
  if coalesce((v_par->>'ok')::boolean, false) = false then
    update mos.yape_dispositivos set ultima_señal = now() where id = v_dev.id;
    return jsonb_build_object('ok', true, 'descartado', true, 'motivo', coalesce(v_par->>'motivo','NO_ES_COBRO'));
  end if;

  insert into mos.yapes_entrantes (notif_key, ts_notificacion, dia, monto, pagador, raw, paquete,
                                   dispositivo, zona, meta)
  values (v_key, v_ts, (v_ts at time zone 'America/Lima')::date,
          nullif(v_par->>'monto','')::numeric, nullif(v_par->>'pagador',''), v_raw,
          nullif(btrim(coalesce(p->>'paquete','')),''), v_dev.nombre, v_dev.zona,
          jsonb_build_object('titulo', coalesce(p->>'titulo',''), 'parseOk', (v_par->>'ok')::boolean))
  on conflict (notif_key) do nothing
  returning id into v_id;

  if v_id is null then
    v_nuevo := false;
    select id into v_id from mos.yapes_entrantes where notif_key = v_key;
  else
    update mos.yape_dispositivos set ultima_señal = now(), n_capturas = n_capturas + 1 where id = v_dev.id;
  end if;

  if v_nuevo then perform mos.yape_matchear(jsonb_build_object('id', v_id)); end if;

  return jsonb_build_object('ok',true,'id',v_id,'nuevo',v_nuevo,
    'monto', v_par->>'monto', 'pagador', v_par->>'pagador', 'parseOk', (v_par->>'ok')::boolean);
end $function$;

-- toggle desde MOS
create or replace function mos.yape_captura_set(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_nombre text := nullif(btrim(coalesce(p->>'nombre','')),''); v_on boolean := coalesce((p->>'on')::boolean, true); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre is null then return jsonb_build_object('ok',false,'error','falta nombre'); end if;
  update mos.yape_dispositivos set captura_yapes = v_on where nombre = v_nombre;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','equipo no encontrado'); end if;
  return jsonb_build_object('ok',true,'on',v_on);
end $function$;
grant execute on function mos.yape_captura_set(jsonb) to authenticated, anon, service_role;

-- el panel de equipos (yape_dispositivos_estado, el que usa la card de Yapes) suma `capturaYapes`
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('mos.yape_dispositivos_estado'::regproc);
  if position($q$'permisoOk', d.permiso_ok,$q$ in v_def) = 0 then raise notice 'ancla estado no encontrada'; return; end if;
  v_def := replace(v_def, $q$'permisoOk', d.permiso_ok,$q$,
                          $q$'permisoOk', d.permiso_ok, 'capturaYapes', coalesce(d.captura_yapes,true),$q$);
  execute v_def;
end $$;

select mos.yape_captura_set(jsonb_build_object('nombre','__x__','on','false')) sin_equipo;
select (mos.yape_dispositivos_estado('{}'::jsonb)->'data'->'equipos'->0->>'capturaYapes') primer_equipo;
