-- 228_espia_aggregators.sql — RPCs agregadoras del espía (matchean las acciones del cliente WebRTC: espiaSync,
-- espiaPushBatch, espiaIniciarDispositivo, espiaConfig) para que el wiring frontend sea repoint casi-1:1.
-- Componen sobre mos.espia_sesiones (SQL 225). Auth: app JWT del ecosistema + sesionId como capacidad.

-- espia_iniciar_dispositivo: handshake del device. Valida sesión+device, devuelve marker token (compat) + meta.
create or replace function mos.espia_iniciar_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_dev text := nullif(btrim(coalesce(p->>'deviceId','')),''); v_r mos.espia_sesiones%rowtype; v_exp int;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sid is null then return jsonb_build_object('ok',false,'error','sesionId requerido'); end if;
  if v_dev is null then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if btrim(coalesce(v_r.device_id,'')) <> v_dev then return jsonb_build_object('ok',false,'error','deviceId no coincide con la sesión'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;
  v_exp := greatest(0, 600 - floor(extract(epoch from (now() - v_r.fecha)))::int) * 1000;
  -- token: marker (la auth real es el JWT de app + sesionId; el front lo guarda por compat con el flujo GAS).
  return jsonb_build_object('ok',true,'data', jsonb_build_object('token', 'sb:'||v_sid, 'masterId', v_r.master_id, 'estado', v_r.estado, 'expiraEn', v_exp));
end;
$fn$;

-- espia_config: ICE servers (STUN gratis de Google; TURN opcional vía mos.config ESPIA_TURN_*). Sin DB de sesión.
create or replace function mos.espia_config(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_turn_url text; v_turn_user text; v_turn_cred text; v_ice jsonb; v_tiene boolean := false;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_ice := jsonb_build_array(jsonb_build_object('urls', jsonb_build_array('stun:stun.l.google.com:19302','stun:stun1.l.google.com:19302')));
  select valor into v_turn_url  from mos.config where clave='ESPIA_TURN_URL'  limit 1;
  select valor into v_turn_user from mos.config where clave='ESPIA_TURN_USER' limit 1;
  select valor into v_turn_cred from mos.config where clave='ESPIA_TURN_CRED' limit 1;
  if coalesce(v_turn_url,'')<>'' and coalesce(v_turn_user,'')<>'' and coalesce(v_turn_cred,'')<>'' then
    v_ice := v_ice || jsonb_build_object('urls', (select jsonb_agg(btrim(u)) from regexp_split_to_table(v_turn_url,',') u where btrim(u)<>''),
                                         'username', v_turn_user, 'credential', v_turn_cred);
    v_tiene := true;
  end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'iceServers', v_ice, 'tieneTurn', v_tiene, 'ttlSesionMs', 600000,
    'ahora', (extract(epoch from now())*1000)::bigint));
end;
$fn$;

-- espia_sync: poll agregado. Devuelve estado/expiraEn/ahora/streams + SDPs selectivos (necesito{}) + ICE del OTRO
-- lado filtrado por iceDesde. Réplica fiel de _espiaSyncImpl.
create or replace function mos.espia_sync(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
  v_lado text := lower(coalesce(p->>'lado',''));
  v_desde bigint := case when coalesce(p->>'iceDesde','') ~ '^[0-9]+$' then (p->>'iceDesde')::bigint else 0 end;
  v_nec jsonb := case when jsonb_typeof(p->'necesito')='object' then p->'necesito' else '{}'::jsonb end;
  v_r mos.espia_sesiones%rowtype; v_snap jsonb; v_det jsonb; v_arr jsonb; v_ice jsonb; v_tsmax bigint;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_lado not in ('master','device') then return jsonb_build_object('ok',false,'error','lado: master|device'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada','codigo','NO_EXISTE'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;

  v_snap := jsonb_build_object('estado', v_r.estado,
    'expiraEn', greatest(0, 600 - floor(extract(epoch from (now() - v_r.fecha)))::int) * 1000,
    'ahora', (extract(epoch from now())*1000)::bigint);
  if v_r.streams_activos is not null then v_snap := v_snap || jsonb_build_object('streamsActivos', v_r.streams_activos); end if;
  if upper(coalesce(v_r.estado,'')) = 'CERRADA' and v_r.detalle_fin is not null then
    v_det := v_r.detalle_fin;
    v_snap := v_snap || jsonb_build_object('motivoFin', coalesce(v_det->>'motivo',''), 'ladoCierre', coalesce(v_det->>'lado',''), 'duracionSeg', coalesce((v_det->>'duracionSeg')::int,0));
  end if;
  -- SDPs selectivos
  if coalesce((v_nec->>'sdpOferta')::boolean,false)         then v_snap := v_snap || jsonb_build_object('sdpOferta', coalesce(v_r.sdp_oferta,'')); end if;
  if coalesce((v_nec->>'sdpRespuesta')::boolean,false)      then v_snap := v_snap || jsonb_build_object('sdpRespuesta', coalesce(v_r.sdp_respuesta,'')); end if;
  if coalesce((v_nec->>'sdpRenegOferta')::boolean,false)    then v_snap := v_snap || jsonb_build_object('sdpRenegOferta', coalesce(v_r.sdp_reneg_oferta,'')); end if;
  if coalesce((v_nec->>'sdpRenegRespuesta')::boolean,false) then v_snap := v_snap || jsonb_build_object('sdpRenegRespuesta', coalesce(v_r.sdp_reneg_respuesta,'')); end if;
  -- ICE del OTRO lado
  if coalesce((v_nec->>'ice')::boolean,false) then
    v_arr := case when v_lado='master' then coalesce(v_r.ice_device,'[]'::jsonb) else coalesce(v_r.ice_master,'[]'::jsonb) end;
    select coalesce(jsonb_agg(e order by (e->>'ts')::bigint), '[]'::jsonb) into v_ice
      from jsonb_array_elements(v_arr) e where (e->>'ts')::bigint > v_desde;
    select coalesce(max((e->>'ts')::bigint), v_desde) into v_tsmax from jsonb_array_elements(v_arr) e;
    v_snap := v_snap || jsonb_build_object('ice', v_ice, 'tsMax', v_tsmax);
  end if;
  return jsonb_build_object('ok',true,'data', v_snap);
end;
$fn$;

-- espia_push_batch: escritura batched (1 UPDATE). ICE del lado actual (cap 300) + SDPs + streams(→EN_VIVO) +
-- cerrar opcional (atómico). Réplica fiel de _espiaPushBatchImpl.
create or replace function mos.espia_push_batch(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
  v_lado text := lower(coalesce(p->>'lado',''));
  v_ice_in jsonb := case when jsonb_typeof(p->'ice')='array' then p->'ice' else '[]'::jsonb end;
  v_r mos.espia_sesiones%rowtype; v_apl jsonb := '{}'::jsonb;
  v_base bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
  v_norm jsonb; v_e jsonb; v_i int := 0; v_col_arr jsonb; v_comb jsonb; v_len int;
  v_estado_new text; v_dur int;
  c text;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_lado not in ('master','device') then return jsonb_build_object('ok',false,'error','lado: master|device'); end if;
  -- validar tamaños SDP (cheap, fuera de lock)
  foreach c in array array['sdpOferta','sdpRespuesta','sdpRenegOferta','sdpRenegRespuesta'] loop
    if p ? c and length(coalesce(p->>c,'')) > 45000 then return jsonb_build_object('ok',false,'error', c||' demasiado grande'); end if;
  end loop;

  select * into v_r from mos.espia_sesiones where sesion_id = v_sid for update;   -- lock de fila (serializa batches)
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_r.estado,'')) = 'CERRADA' and not (p ? 'cerrar') then
    return jsonb_build_object('ok',false,'error','Sesión cerrada'); end if;

  -- ── ICE batch (lado actual) → normalizar {ice}|{ts,ice} y concatenar, cap 300 ──
  if jsonb_array_length(v_ice_in) > 0 then
    v_norm := '[]'::jsonb;
    for v_e in select * from jsonb_array_elements(v_ice_in) loop
      v_i := v_i + 1;
      v_norm := v_norm || jsonb_build_object('ts', coalesce((v_e->>'ts')::bigint, v_base + v_i), 'ice', coalesce(v_e->'ice', v_e));
    end loop;
    v_col_arr := case when v_lado='master' then coalesce(v_r.ice_master,'[]'::jsonb) else coalesce(v_r.ice_device,'[]'::jsonb) end;
    v_comb := v_col_arr || v_norm;
    v_len := jsonb_array_length(v_comb);
    if v_len > 300 then
      select coalesce(jsonb_agg(e), '[]'::jsonb) into v_comb
        from (select e from jsonb_array_elements(v_comb) with ordinality t(e,ord) order by ord offset (v_len-300)) s;
    end if;
    if v_lado='master' then update mos.espia_sesiones set ice_master = v_comb where sesion_id = v_sid;
    else update mos.espia_sesiones set ice_device = v_comb where sesion_id = v_sid; end if;
    v_apl := v_apl || jsonb_build_object('ice', v_i);
  end if;

  -- ── SDPs ──
  if p ? 'sdpOferta'         then update mos.espia_sesiones set sdp_oferta = coalesce(p->>'sdpOferta','') where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpOferta',true); end if;
  if p ? 'sdpRespuesta'      then update mos.espia_sesiones set sdp_respuesta = coalesce(p->>'sdpRespuesta','') where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpRespuesta',true); end if;
  if p ? 'sdpRenegOferta'    then update mos.espia_sesiones set sdp_reneg_oferta = coalesce(p->>'sdpRenegOferta',''), sdp_reneg_respuesta='' where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpRenegOferta',true); end if;
  if p ? 'sdpRenegRespuesta' then update mos.espia_sesiones set sdp_reneg_respuesta = coalesce(p->>'sdpRenegRespuesta',''), sdp_reneg_oferta='' where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpRenegRespuesta',true); end if;

  -- ── streams → EN_VIVO (si no se está cerrando) ──
  if (p ? 'streamsActivos') and not (p ? 'cerrar') then
    update mos.espia_sesiones set streams_activos = p->'streamsActivos',
      estado = case when upper(coalesce(estado,''))='CERRADA' then estado else 'EN_VIVO' end
     where sesion_id = v_sid;
    v_apl := v_apl || jsonb_build_object('streamsActivos', true);
  end if;

  -- ── cerrar (atómico) ──
  if p ? 'cerrar' then
    if upper(coalesce(v_r.estado,'')) <> 'CERRADA' then
      v_dur := round(extract(epoch from (now() - v_r.fecha)))::int;
      update mos.espia_sesiones set estado='CERRADA',
        detalle_fin = jsonb_build_object('motivo', coalesce((p->'cerrar')->>'motivo','push_batch'), 'lado', v_lado, 'duracionSeg', v_dur)
       where sesion_id = v_sid;
      v_apl := v_apl || jsonb_build_object('cerrada', true, 'duracionSeg', v_dur);
    else
      v_apl := v_apl || jsonb_build_object('cerrada', true, 'yaCerrada', true);
    end if;
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('aplicado', v_apl));
end;
$fn$;

do $$ declare f text; begin
  foreach f in array array['espia_iniciar_dispositivo(jsonb)','espia_config(jsonb)','espia_sync(jsonb)','espia_push_batch(jsonb)'] loop
    execute 'revoke all on function mos.'||f||' from public';
    execute 'grant execute on function mos.'||f||' to authenticated';
  end loop;
end $$;
