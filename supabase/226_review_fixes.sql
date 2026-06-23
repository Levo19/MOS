-- 226_review_fixes.sql — Correcciones de la revisión adversarial 100x (sesión 2026-06-23).
-- Todos MEDIO/BAJO (no había crítico). create-or-replace sobre 221/224/225.

-- (2) seleccionar_tokens_push: parse defensivo de booleanos (un valor no-bool reventaba toda la RPC → no
--     notificaba a nadie). Acepta true/t/1 como verdadero; cualquier otra cosa = false. Sin cast frágil.
create or replace function mos.seleccionar_tokens_push(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_excl  text := lower(nullif(btrim(coalesce(p->>'excluirUsuario','')),''));
  v_app   text := upper(nullif(btrim(coalesce(p->>'soloAppOrigen','')),''));
  v_master boolean := lower(coalesce(p->>'soloRolesMaster','')) in ('true','t','1');
  v_admin  boolean := lower(coalesce(p->>'soloRolesAdmin','')) in ('true','t','1');
  v_solo  jsonb := case when jsonb_typeof(p->'soloUsuarios')='array' then p->'soloUsuarios' else null end;
  v_extra jsonb := case when jsonb_typeof(p->'usuariosExtra')='array' then p->'usuariosExtra' else null end;
  v_tokens jsonb;
begin
  if coalesce(me.jwt_app(),'') = '' and coalesce((current_setting('request.jwt.claims', true)::jsonb)->>'role','') <> 'service_role' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with roles as (
    select lower(btrim(nombre)) n from mos.personal
      where coalesce(estado,true) = true
        and ( (v_master and upper(coalesce(rol,''))='MASTER')
           or (v_admin  and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')) )
    union
    select lower(btrim(nombre||' '||coalesce(apellido,''))) from mos.personal
      where coalesce(estado,true) = true
        and ( (v_master and upper(coalesce(rol,''))='MASTER')
           or (v_admin  and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')) )
  ),
  app_match as (
    select t.*, case
        when upper(coalesce(app_origen,'')) in ('WH','WAREHOUSEMOS','WAREHOUSE','WHM') then 'WH'
        when upper(coalesce(app_origen,'')) in ('ME','MOSEXPRESS') then 'ME'
        when upper(coalesce(app_origen,'')) in ('MOS','PROYECTOMOS') then 'MOS'
        else upper(coalesce(app_origen,'')) end as app_norm
      from mos.push_tokens t
     where activo = true and coalesce(token,'') <> ''
  ),
  filtrados as (
    select * from app_match am
     where (v_excl is null or lower(btrim(coalesce(usuario,''))) <> v_excl)
       and (v_app is null or app_norm = v_app)
       and (
         (v_solo is not null and lower(btrim(coalesce(usuario,''))) in (select lower(btrim(x)) from jsonb_array_elements_text(v_solo) x))
         or
         (v_solo is null and (
            (not (v_master or v_admin))
            or lower(btrim(coalesce(usuario,''))) in (select n from roles)
            or (v_extra is not null and lower(btrim(coalesce(usuario,''))) in (select lower(btrim(x)) from jsonb_array_elements_text(v_extra) x))
         ))
       )
  ),
  ranked as (
    select token, usuario, app_norm,
      row_number() over (
        partition by coalesce(nullif(lower(btrim(usuario)),''), 'tok:'||token) || case when v_app is not null then '@'||app_norm else '' end
        order by ultima_vez desc nulls last
      ) rn
    from filtrados
  )
  select coalesce(jsonb_agg(jsonb_build_object('token',token,'usuario',usuario) order by usuario), '[]'::jsonb)
    into v_tokens from ranked where rn = 1;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('tokens', v_tokens));
end;
$fn$;

-- (3) registrar_push_token: id_token con md5 COMPLETO (32 chars) → colisión despreciable (antes 12 chars podían
--     chocar en PK sin caer en on-conflict(token)). Resto idéntico.
create or replace function mos.registrar_push_token(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_token text := nullif(btrim(coalesce(p->>'token','')), '');
  v_app   text := coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''), 'MOS');
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_token is null then return jsonb_build_object('ok',false,'error','token requerido'); end if;
  insert into mos.push_tokens (id_token, token, usuario, dispositivo, app_origen, device_id, fecha, ultima_vez, activo)
  values ('PTK-'||md5(v_token), v_token, coalesce(p->>'usuario',''), coalesce(p->>'dispositivo',''),
          v_app, coalesce(p->>'deviceId',''), now(), now(), true)
  on conflict (token) do update set
    usuario = coalesce(nullif(excluded.usuario,''), mos.push_tokens.usuario),
    dispositivo = coalesce(nullif(excluded.dispositivo,''), mos.push_tokens.dispositivo),
    app_origen = excluded.app_origen,
    device_id = coalesce(nullif(excluded.device_id,''), mos.push_tokens.device_id),
    ultima_vez = now(),
    activo = true;
  return jsonb_build_object('ok', true);
end;
$fn$;

-- (1) espia_subir_oferta: bloquear sesión CERRADA/expirada (consistencia con reneg; antes escribía SDP sobre
--     sesión muerta). (2) espia_leer_ice: parse defensivo de `desde`.
create or replace function mos.espia_subir_oferta(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),''); v_sdp text := coalesce(p->>'sdp',''); v_r mos.espia_sesiones%rowtype;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sid is null or v_sdp='' then return jsonb_build_object('ok',false,'error','Requiere sesionId y sdp'); end if;
  if length(v_sdp) > 45000 then return jsonb_build_object('ok',false,'error','SDP demasiado grande'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_r.estado,'')) = 'CERRADA' then return jsonb_build_object('ok',false,'error','Sesión cerrada'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;
  update mos.espia_sesiones set sdp_oferta = v_sdp where sesion_id = v_sid;
  return jsonb_build_object('ok',true);
end;
$fn$;

create or replace function mos.espia_leer_ice(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sid text := nullif(btrim(coalesce(p->>'sesionId','')),'');
  v_lado text := lower(coalesce(p->>'lado',''));
  v_desde bigint := case when coalesce(p->>'desde','') ~ '^[0-9]+$' then (p->>'desde')::bigint else 0 end;
  v_r mos.espia_sesiones%rowtype; v_arr jsonb; v_nuevos jsonb; v_tsmax bigint;
begin
  if not mos._espia_app_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_r from mos.espia_sesiones where sesion_id = v_sid;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if mos._espia_expiro(v_r.fecha) then return jsonb_build_object('ok',false,'error','Sesión expirada','codigo','EXPIRADO'); end if;
  v_arr := case when v_lado='master' then coalesce(v_r.ice_master,'[]'::jsonb) else coalesce(v_r.ice_device,'[]'::jsonb) end;
  select coalesce(jsonb_agg(e order by (e->>'ts')::bigint), '[]'::jsonb) into v_nuevos
    from jsonb_array_elements(v_arr) e where (e->>'ts')::bigint > v_desde;
  select coalesce(max((e->>'ts')::bigint), v_desde) into v_tsmax from jsonb_array_elements(v_arr) e;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('ice', v_nuevos, 'tsMax', v_tsmax));
end;
$fn$;

-- (4) wh.cerrar_sesion: guard regex en hora_inicio (un valor no-time pero no-vacío reventaba el cierre).
create or replace function wh.cerrar_sesion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idSesion','')), '');
  v_forz   boolean := coalesce((p->>'forzado')::boolean, false);
  v_row    wh.sesiones%rowtype;
  v_inicio timestamp; v_now_lima timestamp; v_min int; v_hora time;
begin
  if coalesce((select valor from mos.config where clave='WH_SESION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_SESION_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idSesion requerido'); end if;
  select * into v_row from wh.sesiones where id_sesion = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_row.estado,'')) <> 'ACTIVA' then
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idSesion', v_id, 'minutosActivos', v_row.minutos_activos, 'yaCerrada', true));
  end if;
  v_now_lima := (now() at time zone 'America/Lima');
  -- hora_inicio: HH:mm[:ss] Lima; guard regex → si viene basura, 00:00:00 (no revienta el cierre)
  v_hora := case when coalesce(btrim(v_row.hora_inicio),'') ~ '^\d{1,2}:\d{2}(:\d{2})?$'
                 then v_row.hora_inicio::time else '00:00:00'::time end;
  v_inicio := ((v_row.fecha_inicio at time zone 'America/Lima')::date)::timestamp + v_hora;
  v_min := greatest(0, round(extract(epoch from (v_now_lima - v_inicio)) / 60)::int);
  update wh.sesiones set
    fecha_fin = now(),
    hora_fin = to_char(v_now_lima, 'HH24:MI:SS'),
    minutos_activos = v_min,
    estado = case when v_forz then 'FORZADA' else 'CERRADA' end
  where id_sesion = v_id;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idSesion', v_id, 'minutosActivos', v_min, 'horas', round(v_min/60.0, 2)));
end;
$fn$;
