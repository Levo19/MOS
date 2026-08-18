-- 854d: pgcrypto no vive en el search_path (y la función corre con search_path vacío por
-- seguridad), así que digest() hay que llamarlo calificado. Sin esto la ingesta fallaba con
-- "function digest(text, unknown) does not exist" — el APK nunca habría podido entregar nada.
create or replace function mos.yape_ingesta(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_sec  text := coalesce(p->>'secreto','');
  v_dev  record;
  v_key  text := nullif(btrim(coalesce(p->>'notifKey','')),'');
  v_raw  text := coalesce(p->>'texto','');
  v_ts   timestamptz;
  v_par  jsonb; v_id bigint; v_nuevo boolean := true;
begin
  if v_sec = '' or v_key is null or btrim(v_raw) = '' then
    return jsonb_build_object('ok',false,'error','faltan secreto, notifKey o texto');
  end if;
  select * into v_dev from mos.yape_dispositivos
   where activo and secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex') limit 1;
  if not found then return jsonb_build_object('ok',false,'error','DISPOSITIVO_NO_AUTORIZADO'); end if;

  begin v_ts := (p->>'ts')::timestamptz; exception when others then v_ts := now(); end;
  v_ts := coalesce(v_ts, now());
  v_par := mos._yape_parse(v_raw);

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
end $fn$;

-- helper para dar de alta un celular sin escribir el hash a mano
create or replace function mos.yape_dispositivo_alta(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
        v_zona text := nullif(btrim(coalesce(p->>'zona','')),'');
        v_sec text := nullif(btrim(coalesce(p->>'secreto','')),''); v_id bigint;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null or v_sec is null then return jsonb_build_object('ok',false,'error','nombre y secreto requeridos'); end if;
  insert into mos.yape_dispositivos (nombre, zona, secreto_hash)
  values (v_nom, v_zona, encode(extensions.digest(v_sec,'sha256'),'hex'))
  returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id,'nombre',v_nom,'zona',coalesce(v_zona,'(todas)'));
end $fn$;
grant execute on function mos.yape_dispositivo_alta(jsonb) to anon, authenticated, service_role;
