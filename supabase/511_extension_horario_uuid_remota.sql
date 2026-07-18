-- ============================================================================
-- 511_extension_horario_uuid_remota.sql — Extensión de horario REMOTA por UUID (1h)
-- ----------------------------------------------------------------------------
-- Cierra el flujo remoto de extensión de horario para que aparezca en el buzón/alerta
-- flotante de MOS y cualquier admin (incl. master) lo apruebe sin errores, concediendo
-- 1 HORA fija al DISPOSITIVO (UUID) que la pidió — mismo mecanismo que el in-situ
-- (mos.dispositivos.desbloqueo_temporal_hasta), que DeviceAuth ya sincroniza al cliente
-- vía ExtensorHorario en cada boot/polling → el operador desbloquea sin re-login.
--
--   (A) solicitar_extension_horario v2: guarda TAMBIÉN el UUID (id_dispositivo) + app en
--       la alerta → el aprobador sabe a qué equipo conceder. Duración: 1h FIJA (60 min).
--   (B) aprobar_extension_horario: cualquier admin MOS (gate claim MOS) concede 1h al UUID
--       (desbloqueo_temporal_hasta = max(now+1h, actual)), marca la alerta APROBADA y
--       manda push al equipo. Idempotente por estado de la alerta.
--   (C) rechazar_extension_horario: marca RECHAZADA + push best-effort.
-- 100% Supabase, cero-GAS.
-- ============================================================================

-- ── (A) solicitar_extension_horario v2 (guarda UUID + app; 1h fija) ──────────
create or replace function mos.solicitar_extension_horario(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id   text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_dev  text := nullif(btrim(coalesce(p->>'deviceId', p->>'device_id','')),'');
  v_app  text := nullif(btrim(coalesce(p->>'app','')),'');
  v_min  int  := 60;                         -- [511] 1 HORA fija (ignora el minutos del cliente)
  v_mot  text := left(btrim(coalesce(p->>'motivo','Sin motivo')), 200);
  v_alerta text;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  -- Dedup: si ya hay una solicitud PENDIENTE de esta persona (o de este UUID), no duplicar.
  if exists (select 1 from mos.seguridad_alertas
             where tipo='EXTENSION_HORARIO_PENDIENTE' and upper(coalesce(estado,''))='PENDIENTE'
               and (id_personal = v_id or (v_dev is not null and id_dispositivo = v_dev))) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true));
  end if;
  v_alerta := 'SEG' || (extract(epoch from clock_timestamp())*1000)::bigint::text || upper(substr(md5(random()::text),1,4));
  insert into mos.seguridad_alertas(id_alerta, tipo, id_dispositivo, id_personal, fecha, descripcion, prioridad, estado, datos_extra_json)
  values (v_alerta, 'EXTENSION_HORARIO_PENDIENTE', v_dev, v_id, now(),
          'Solicita extensión 1h · ' || v_mot, 'MEDIA', 'PENDIENTE',
          jsonb_build_object('minutos', v_min, 'motivo', v_mot, 'deviceId', coalesce(v_dev,''),
                             'app', coalesce(v_app,''), 'solicitadoEn', to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idAlerta', v_alerta, 'pendiente', true, 'minutos', v_min));
end; $fn$;
revoke all on function mos.solicitar_extension_horario(jsonb) from public;
grant execute on function mos.solicitar_extension_horario(jsonb) to anon, authenticated, service_role;

-- ── (B) aprobar_extension_horario: concede 1h al UUID + resuelve + push ──────
create or replace function mos.aprobar_extension_horario(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_alerta text := nullif(btrim(coalesce(p->>'idAlerta','')),'');
  v_por    text := left(btrim(coalesce(p->>'aprobadoPor','admin')), 80);
  r        mos.seguridad_alertas%rowtype;
  v_dev    text; v_actual timestamptz; v_hasta timestamptz;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_alerta is null then return jsonb_build_object('ok',false,'error','idAlerta requerido'); end if;
  select * into r from mos.seguridad_alertas where id_alerta = v_alerta for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(r.tipo,'')) <> 'EXTENSION_HORARIO_PENDIENTE' then
    return jsonb_build_object('ok',false,'error','TIPO_INVALIDO'); end if;
  if upper(coalesce(r.estado,'')) <> 'PENDIENTE' then
    return jsonb_build_object('ok',false,'error','YA_'||upper(coalesce(r.estado,'RESUELTA'))); end if;

  v_dev := nullif(btrim(coalesce(r.id_dispositivo, r.datos_extra_json->>'deviceId','')),'');
  if v_dev is null then
    -- solicitud vieja sin UUID: marcamos aprobada igual (no hay a quién desbloquear por device)
    update mos.seguridad_alertas set estado='APROBADA', revisada_por=v_por, revisada_en=now() where id_alerta=v_alerta;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('sinDispositivo',true));
  end if;

  -- 1h al UUID (preserva la mayor vigente, igual que el in-situ)
  select desbloqueo_temporal_hasta into v_actual from mos.dispositivos where id_dispositivo = v_dev;
  v_hasta := greatest(now() + interval '1 hour', coalesce(v_actual, now()));
  update mos.dispositivos set desbloqueo_temporal_hasta = v_hasta where id_dispositivo = v_dev;
  update mos.seguridad_alertas set estado='APROBADA', revisada_por=v_por, revisada_en=now() where id_alerta=v_alerta;

  begin
    perform mos.emitir_push(jsonb_build_object(
      'audiencia', jsonb_build_object('deviceIds', jsonb_build_array(v_dev)),
      'titulo', '✅ Extensión aprobada · +1h',
      'cuerpo', 'Un admin te concedió 1 hora más · ya puedes seguir operando',
      'data', jsonb_build_object('tipo','extension_horario_aprobada')));
  exception when others then null; end;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'deviceId', v_dev, 'aprobadoPor', v_por,
    'hastaTs', to_char(v_hasta at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'), 'minutos', 60));
end; $fn$;
revoke all on function mos.aprobar_extension_horario(jsonb) from public;
grant execute on function mos.aprobar_extension_horario(jsonb) to anon, authenticated, service_role;

-- ── (C) rechazar_extension_horario ──────────────────────────────────────────
create or replace function mos.rechazar_extension_horario(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_alerta text := nullif(btrim(coalesce(p->>'idAlerta','')),'');
  v_por    text := left(btrim(coalesce(p->>'aprobadoPor','admin')), 80);
  r        mos.seguridad_alertas%rowtype;
  v_dev    text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_alerta is null then return jsonb_build_object('ok',false,'error','idAlerta requerido'); end if;
  select * into r from mos.seguridad_alertas where id_alerta = v_alerta for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(r.estado,'')) <> 'PENDIENTE' then
    return jsonb_build_object('ok',false,'error','YA_'||upper(coalesce(r.estado,'RESUELTA'))); end if;
  update mos.seguridad_alertas set estado='RECHAZADA', revisada_por=v_por, revisada_en=now() where id_alerta=v_alerta;
  v_dev := nullif(btrim(coalesce(r.id_dispositivo, r.datos_extra_json->>'deviceId','')),'');
  begin
    if v_dev is not null then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('deviceIds', jsonb_build_array(v_dev)),
        'titulo', 'Solicitud de extensión no aprobada',
        'cuerpo', 'El admin no aprobó tu extensión de horario',
        'data', jsonb_build_object('tipo','extension_horario_rechazada')));
    end if;
  exception when others then null; end;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('rechazada',true));
end; $fn$;
revoke all on function mos.rechazar_extension_horario(jsonb) from public;
grant execute on function mos.rechazar_extension_horario(jsonb) to anon, authenticated, service_role;
