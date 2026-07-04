-- 354: [CERO-GAS #26 acción] mos.desbloquear_temporal_dispositivo — reemplaza gas desbloquearTemporalDispositivo.
-- Sin gate de claim (barrera = bcrypt de la clave, igual que aprobar/revocar_dispositivo). Escribe la sombra
-- autoritativa (MOS_DISPOSITIVOS_DIRECTO=1). + revert cron que re-suspende al vencer (reemplaza el trigger GAS
-- revertirDesbloqueosVencidos; idempotente con él mientras coexistan). Shape de retorno EXACTO al GAS (autorizado/hasta).
create or replace function mos.desbloquear_temporal_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_dev  text := btrim(coalesce(p->>'deviceId', p->>'id_dispositivo', ''));
  v_clave text := btrim(coalesce(p->>'claveAdmin', p->>'clave_admin', ''));
  v_razon text := btrim(coalesce(p->>'razon',''));
  v_app  text := coalesce(p->>'app','');
  v_dur  numeric := coalesce(nullif(btrim(coalesce(p->>'duracionHoras','')),'')::numeric, 2);
  v_val  jsonb; v_por text; v_hasta timestamptz; v_alerta text; v_estado text;
begin
  if v_dev = '' then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  if v_razon = '' then return jsonb_build_object('ok',false,'error','razón requerida'); end if;
  if v_dur < 0.5 or v_dur > 12 then return jsonb_build_object('ok',false,'error','duracionHoras debe estar entre 0.5 y 12'); end if;
  -- clave admin (bcrypt + niveles + auditoría única) — misma CORE que aprobar/revocar
  v_val := mos._validar_clave_admin_core(v_clave, 'DESBLOQUEO_TEMPORAL', v_dev, v_app, v_dev,
             'Desbloqueo temp: ' || left(v_razon, 200));
  if coalesce(v_val->>'ok','') = 'false' then return v_val; end if;
  if coalesce((v_val->>'autorizado')::boolean, false) = false then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', coalesce(v_val->>'error','Clave incorrecta'));
  end if;
  select estado into v_estado from mos.dispositivos where id_dispositivo = v_dev;
  if v_estado is null then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado'); end if;
  v_por := coalesce(v_val->>'nombre', v_val->>'validado_por', '');
  v_hasta := now() + make_interval(mins => round(v_dur * 60)::int);
  update mos.dispositivos
     set estado = 'ACTIVO', desbloqueo_temporal_hasta = v_hasta,
         suspendido_desde = null
   where id_dispositivo = v_dev;
  -- alerta DESBLOQUEO_TEMPORAL (paridad _crearAlertaSeg)
  v_alerta := 'SEG' || (extract(epoch from clock_timestamp())*1000)::bigint::text || upper(substr(md5(random()::text),1,4));
  insert into mos.seguridad_alertas(id_alerta, tipo, id_dispositivo, fecha, descripcion, prioridad, estado, datos_extra_json)
  values (v_alerta, 'DESBLOQUEO_TEMPORAL', v_dev, now(),
          'Desbloqueo temp ' || v_dur || 'h · razón: ' || left(v_razon,150), 'ALTA', 'PENDIENTE',
          jsonb_build_object('hastaIso', to_char(v_hasta at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
                             'autorizadoPor', v_por, 'razon', v_razon));
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'autorizado', true,
    'hasta', to_char(v_hasta at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
    'duracionHoras', v_dur, 'autorizadoPor', v_por));
end; $fn$;
revoke all on function mos.desbloquear_temporal_dispositivo(jsonb) from public;
grant execute on function mos.desbloquear_temporal_dispositivo(jsonb) to anon, authenticated, service_role;

-- revert cron: al vencer desbloqueo_temporal_hasta → re-suspende (paridad gas revertirDesbloqueosVencidos:
-- estado SUSPENDIDO + limpia DT + suspendido_desde=now). Guard estado='ACTIVO' (no toca ya-suspendidos).
create or replace function mos.revertir_desbloqueos_vencidos()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
  update mos.dispositivos
     set estado = 'SUSPENDIDO', desbloqueo_temporal_hasta = null, suspendido_desde = now()
   where desbloqueo_temporal_hasta is not null
     and desbloqueo_temporal_hasta < now()
     and estado = 'ACTIVO';
  get diagnostics v_n = row_count;
  insert into mos.cron_log(job, ok, resultado) values ('revertir_desbloqueos', true, jsonb_build_object('revertidos', v_n));
  return jsonb_build_object('ok', true, 'revertidos', v_n);
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('revertir_desbloqueos', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;
revoke all on function mos.revertir_desbloqueos_vencidos() from public, anon;
grant execute on function mos.revertir_desbloqueos_vencidos() to service_role;

select cron.unschedule('mos-revertir-desbloqueos') where exists (select 1 from cron.job where jobname='mos-revertir-desbloqueos');
select cron.schedule('mos-revertir-desbloqueos', '7 * * * *', 'select mos.revertir_desbloqueos_vencidos();');
