-- 352: [CERO-GAS #25] "Notificarme cuando abra mi horario". Reemplaza gas notificarmeCuandoAbra (request) +
-- procesarNotificacionesApertura (cron) + _enviarPushSegmentado. Diseño MEJORADO vs GAS: la request guarda el
-- deviceId → el cron pushea por deviceIds (exacto, sin la ambigüedad de nombre del GAS: login = nombre/apodo/completo).
-- Alertas viven en mos.seguridad_alertas (tipo NOTIFICAR_APERTURA/PENDIENTE). Horario resuelto con resolver_horario_personal.

-- (1) REQUEST — el operador pide ser notificado. Gate operador/admin. Dedup: 1 PENDIENTE por (persona,device).
create or replace function mos.notificar_apertura_pedir(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')),'');
  v_ap  text := coalesce(p->>'apertura','');
  v_alerta text;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  -- Dedup: si ya hay un PENDIENTE de esta persona (mismo device si se dio), no duplicar.
  if exists (
    select 1 from mos.seguridad_alertas
    where tipo='NOTIFICAR_APERTURA' and upper(coalesce(estado,''))='PENDIENTE' and id_personal = v_id
      and (v_dev is null or coalesce(datos_extra_json->>'deviceId','') = v_dev)
  ) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true));
  end if;
  v_alerta := 'SEG' || (extract(epoch from clock_timestamp())*1000)::bigint::text || upper(substr(md5(random()::text),1,4));
  insert into mos.seguridad_alertas(id_alerta, tipo, id_dispositivo, id_personal, fecha, descripcion, prioridad, estado, datos_extra_json)
  values (v_alerta, 'NOTIFICAR_APERTURA', v_dev, v_id, now(), 'Operador pidió notificación cuando abra horario', 'BAJA', 'PENDIENTE',
          jsonb_build_object('apertura', v_ap, 'deviceId', coalesce(v_dev,''), 'solicitadoEn', to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')));
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idAlerta', v_alerta));
end; $fn$;
revoke all on function mos.notificar_apertura_pedir(jsonb) from public;
grant execute on function mos.notificar_apertura_pedir(jsonb) to anon, authenticated, service_role;

-- (2) CRON — procesa PENDIENTES: si el horario ya abrió (cualquiera de las 2 apps), pushea al device del solicitante
-- (fallback usuarios por nombre) y marca REVISADA. Best-effort: el push nunca rompe el barrido.
create or replace function mos.procesar_notif_apertura()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  r record; v_perm boolean; v_hor jsonb; v_dev text; v_aud jsonb;
  v_nombre text; v_ape text; v_proc int := 0;
begin
  perform set_config('request.jwt.claims', '{"app":"MOS"}', true);  -- para resolver_horario_personal
  for r in
    select id_alerta, id_personal, coalesce(datos_extra_json->>'deviceId','') dev
    from mos.seguridad_alertas
    where tipo='NOTIFICAR_APERTURA' and upper(coalesce(estado,''))='PENDIENTE'
      and nullif(btrim(coalesce(id_personal,'')),'') is not null
    limit 200
  loop
    v_perm := false;
    v_hor := mos.resolver_horario_personal(jsonb_build_object('app','warehouseMos','idPersonal',r.id_personal));
    if coalesce((v_hor->'data'->>'permitido')::boolean,false) then v_perm := true; end if;
    if not v_perm then
      v_hor := mos.resolver_horario_personal(jsonb_build_object('app','mosExpress','idPersonal',r.id_personal));
      if coalesce((v_hor->'data'->>'permitido')::boolean,false) then v_perm := true; end if;
    end if;
    if not v_perm then continue; end if;
    -- audiencia: deviceId exacto si lo tenemos; sino por nombre (nombre + nombre+apellido).
    v_dev := nullif(btrim(r.dev),'');
    if v_dev is not null then
      v_aud := jsonb_build_object('deviceIds', jsonb_build_array(v_dev));
    else
      select nombre, apellido into v_nombre, v_ape from mos.personal where id_personal = r.id_personal;
      v_aud := jsonb_build_object('usuarios', jsonb_build_array(
        btrim(coalesce(v_nombre,'')), btrim(coalesce(v_nombre,'')||' '||coalesce(v_ape,''))));
    end if;
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', v_aud,
        'titulo', '🔔 Tu horario ya abrió',
        'cuerpo', 'Podés entrar a la app ahora.',
        'data', jsonb_build_object('tipo','horario_abrio')));
    exception when others then null; end;
    update mos.seguridad_alertas
      set estado='REVISADA', revisada_por='cron_apertura', revisada_en=now()
      where id_alerta = r.id_alerta;
    v_proc := v_proc + 1;
  end loop;
  insert into mos.cron_log(job, ok, resultado) values ('notif_apertura', true, jsonb_build_object('procesadas',v_proc));
  return jsonb_build_object('ok', true, 'procesadas', v_proc);
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('notif_apertura', false, jsonb_build_object('excepcion',SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;
revoke all on function mos.procesar_notif_apertura() from public, anon;
grant execute on function mos.procesar_notif_apertura() to service_role;

-- (3) agendar cada 10 min (granularidad aceptable para "tu turno abrió"). Idempotente.
select cron.unschedule('mos-notif-apertura') where exists (select 1 from cron.job where jobname='mos-notif-apertura');
select cron.schedule('mos-notif-apertura', '*/10 * * * *', 'select mos.procesar_notif_apertura();');
