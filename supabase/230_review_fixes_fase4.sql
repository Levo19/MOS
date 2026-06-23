-- 230_review_fixes_fase4.sql — Fixes del 40x retroactivo (MEDIO/BAJO).
-- (a) admin_crear_dispositivo: carrera de PK → devolver JSON {ok:false} en vez de excepción cruda (500).
-- (b) espia_push_batch: guard regex en el cast de `ts` del cliente (un ts no-numérico ya no revienta el push).

create or replace function mos.admin_crear_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := btrim(coalesce(p->>'ID_Dispositivo','')); v_nom text := btrim(coalesce(p->>'Nombre_Equipo',''));
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere ID_Dispositivo'); end if;
  if v_nom = '' then return jsonb_build_object('ok',false,'error','Requiere Nombre_Equipo'); end if;
  if exists (select 1 from mos.dispositivos where id_dispositivo = v_id) then
    return jsonb_build_object('ok',false,'error','Dispositivo ya registrado: '||v_id); end if;
  begin
    insert into mos.dispositivos (id_dispositivo, nombre_equipo, app, estado, ultima_conexion, ultima_zona, ultima_estacion)
    values (v_id, v_nom, coalesce(nullif(btrim(coalesce(p->>'App','')),''),'mosExpress'),
            coalesce(nullif(btrim(coalesce(p->>'Estado','')),''),'ACTIVO'), now(),
            coalesce(p->>'Ultima_Zona',''), coalesce(p->>'Ultima_Estacion',''));
  exception when unique_violation then
    return jsonb_build_object('ok',false,'error','Dispositivo ya registrado: '||v_id);   -- carrera TOCTOU → JSON, no 500
  end;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('ID_Dispositivo', v_id));
end;
$fn$;

create or replace function mos.espia_push_batch(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
  v_lado text := lower(coalesce(p->>'lado',''));
  v_ice_in jsonb := case when jsonb_typeof(p->'ice')='array' then p->'ice' else '[]'::jsonb end;
  v_r mos.espia_sesiones%rowtype; v_apl jsonb := '{}'::jsonb;
  v_base bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
  v_norm jsonb; v_e jsonb; v_i int := 0; v_col_arr jsonb; v_comb jsonb; v_len int;
  v_dur int; c text;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_lado not in ('master','device') then return jsonb_build_object('ok',false,'error','lado: master|device'); end if;
  foreach c in array array['sdpOferta','sdpRespuesta','sdpRenegOferta','sdpRenegRespuesta'] loop
    if p ? c and length(coalesce(p->>c,'')) > 45000 then return jsonb_build_object('ok',false,'error', c||' demasiado grande'); end if;
  end loop;

  select * into v_r from mos.espia_sesiones where sesion_id = v_sid for update;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_r.estado,'')) = 'CERRADA' and not (p ? 'cerrar') then
    return jsonb_build_object('ok',false,'error','Sesión cerrada'); end if;

  if jsonb_array_length(v_ice_in) > 0 then
    v_norm := '[]'::jsonb;
    for v_e in select * from jsonb_array_elements(v_ice_in) loop
      v_i := v_i + 1;
      -- [40x fix] guard regex: un `ts` no-numérico del cliente ya no revienta el cast (usa el server base+i).
      v_norm := v_norm || jsonb_build_object(
        'ts', case when (v_e->>'ts') ~ '^[0-9]+$' then (v_e->>'ts')::bigint else v_base + v_i end,
        'ice', coalesce(v_e->'ice', v_e));
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

  if p ? 'sdpOferta'         then update mos.espia_sesiones set sdp_oferta = coalesce(p->>'sdpOferta','') where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpOferta',true); end if;
  if p ? 'sdpRespuesta'      then update mos.espia_sesiones set sdp_respuesta = coalesce(p->>'sdpRespuesta','') where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpRespuesta',true); end if;
  if p ? 'sdpRenegOferta'    then update mos.espia_sesiones set sdp_reneg_oferta = coalesce(p->>'sdpRenegOferta',''), sdp_reneg_respuesta='' where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpRenegOferta',true); end if;
  if p ? 'sdpRenegRespuesta' then update mos.espia_sesiones set sdp_reneg_respuesta = coalesce(p->>'sdpRenegRespuesta',''), sdp_reneg_oferta='' where sesion_id=v_sid; v_apl:=v_apl||jsonb_build_object('sdpRenegRespuesta',true); end if;

  if (p ? 'streamsActivos') and not (p ? 'cerrar') then
    update mos.espia_sesiones set streams_activos = p->'streamsActivos',
      estado = case when upper(coalesce(estado,''))='CERRADA' then estado else 'EN_VIVO' end
     where sesion_id = v_sid;
    v_apl := v_apl || jsonb_build_object('streamsActivos', true);
  end if;

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
