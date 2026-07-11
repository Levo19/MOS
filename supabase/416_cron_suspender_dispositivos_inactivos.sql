-- ════════════════════════════════════════════════════════════════════════════
-- 416 · SUSPENSIÓN REAL de dispositivos con +2 días sin uso (antes: solo alerta)
-- ════════════════════════════════════════════════════════════════════════════
-- Pedido del dueño (2026-07-11): el cron 346 solo AVISABA ("alert-only"). Ahora
-- SUSPENDE de verdad: un UUID que no se conecta por 2 días enteros queda
-- estado='SUSPENDIDO' → device-auth.js lo trata fail-closed (pantalla de
-- bloqueo, sin ventas ni permisos). Protección anti robo/pérdida/ex-empleado.
--
-- · Un dispositivo SUSPENDIDO que hace ping NO se auto-reactiva (verificado en
--   SQL 100/103: el touch solo actualiza ultima_conexion; estado queda).
-- · Reactivar = el master en MOS → Infraestructura (mos.admin_aprobar_pendiente,
--   SQL 229: ACTIVO + limpia suspendido_desde). Flujo ya existente.
-- · EXENTOS los dispositivos app='MOS' (el panel admin): si el equipo del dueño
--   descansa 2 días y se suspendiera, el desbloqueo vive en ese mismo panel →
--   lockout total. Para MOS se mantiene la ALERTA push (sin suspender).
-- · ultima_conexion NULL se ignora (nunca conectó: lo gobierna el flujo de
--   aprobación PENDIENTE/CANCELADO_AUTO, no este cron).
-- Mismo cron/horario ('mos-dispositivos-inactivos', 9am Lima diario).
-- ════════════════════════════════════════════════════════════════════════════

create or replace function mos.cron_dispositivos_inactivos()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_susp jsonb;
  v_n int := 0;
  v_mos int := 0;
  v_nombres text;
begin
  -- 1) SUSPENDER operativos con +2 días sin conectar.
  -- Exención: app MOS *y también* app vacía/NULL — el auth (SQL 100, v_es_mos)
  -- trata app IN ('MOS','') como panel admin; suspender uno = lockout del dueño.
  with sus as (
    update mos.dispositivos set
        estado = 'SUSPENDIDO',
        suspendido_desde = now()
      where upper(coalesce(estado,'')) = 'ACTIVO'
        and upper(coalesce(app,'')) not in ('MOS','')
        and ultima_conexion is not null
        and ultima_conexion < now() - interval '2 days'
      returning id_dispositivo, coalesce(nullif(btrim(nombre_equipo),''), left(id_dispositivo,8)) nom, app
  )
  select count(*), jsonb_agg(jsonb_build_object('id',id_dispositivo,'nombre',nom,'app',app))
    into v_n, v_susp from sus;

  -- 2) los MOS (o sin app) inactivos solo se ALERTAN (nunca auto-suspender el panel)
  select count(*) into v_mos from mos.dispositivos
   where upper(coalesce(estado,''))='ACTIVO' and upper(coalesce(app,'')) in ('MOS','')
     and ultima_conexion is not null
     and ultima_conexion < now() - interval '2 days';

  -- 3) push al master (best-effort, nunca rompe el cron)
  begin
    if coalesce(v_n,0) > 0 or coalesce(v_mos,0) > 0 then
      select string_agg(e->>'nombre', ', ') into v_nombres
        from jsonb_array_elements(coalesce(v_susp,'[]'::jsonb)) e;
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', case when coalesce(v_n,0) > 0 then '🔒 Dispositivos suspendidos' else '😴 Dispositivos inactivos' end,
        'cuerpo', case when coalesce(v_n,0) > 0
                    then v_n || ' equipo(s) suspendidos por +2 días sin uso: ' || coalesce(v_nombres,'') ||
                         case when v_mos > 0 then ' · +' || v_mos || ' panel(es) MOS inactivos (no suspendidos)' else '' end ||
                         ' · Reactivar: MOS → Infraestructura'
                    else v_mos || ' panel(es) MOS ACTIVO(s) sin conectar +2 días · revísalos' end,
        'data', jsonb_build_object('tipo','device_inactivo')));
    end if;
  exception when others then null; end;

  insert into mos.cron_log(job, ok, resultado)
  values ('dispositivos_inactivos', true,
          jsonb_build_object('suspendidos', coalesce(v_n,0), 'mos_alertados', coalesce(v_mos,0),
                             'detalle', coalesce(v_susp,'[]'::jsonb)));
  return jsonb_build_object('ok', true, 'suspendidos', coalesce(v_n,0), 'mos_alertados', coalesce(v_mos,0));
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('dispositivos_inactivos', false, jsonb_build_object('excepcion',SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;

revoke all on function mos.cron_dispositivos_inactivos() from public, anon;
grant execute on function mos.cron_dispositivos_inactivos() to service_role;

-- ── Reactivar cuenta como "recién usado" (anti bucle de re-suspensión) ────────
-- Sin esto: el master reactiva un equipo el viernes en la noche, y el sábado
-- 9am el cron lo re-suspende porque ultima_conexion sigue vieja (el equipo aún
-- no se prendió). Reactivar = "este equipo vuelve al servicio AHORA" → touch.
-- (Idéntica a la versión viva de 229 + la línea de ultima_conexion.)
create or replace function mos.admin_aprobar_pendiente(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := btrim(coalesce(p->>'ID_Dispositivo','')); v_est text;
begin
  if coalesce(me.jwt_app(),'') <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere ID_Dispositivo'); end if;
  select upper(coalesce(estado,'')) into v_est from mos.dispositivos where id_dispositivo = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Dispositivo no encontrado: '||v_id); end if;
  if v_est = 'ACTIVO' then return jsonb_build_object('ok',true,'skipped',true,'motivo','ya_activo'); end if;
  update mos.dispositivos set
    estado = 'ACTIVO',
    ultima_conexion = now(),   -- [416] reactivación = en servicio ahora (anti re-suspensión inmediata)
    forzar_reverify = null,
    inactivo_alerta_ts = null,
    suspendido_desde = case when v_est = 'SUSPENDIDO' then null else suspendido_desde end,
    nombre_equipo = case when p ? 'Nombre_Equipo' and btrim(coalesce(p->>'Nombre_Equipo',''))<>'' then p->>'Nombre_Equipo' else nombre_equipo end,
    app = case when p ? 'App' and btrim(coalesce(p->>'App',''))<>'' then p->>'App' else app end
  where id_dispositivo = v_id;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('ID_Dispositivo', v_id, 'estado','ACTIVO'));
end;
$fn$;

revoke all on function mos.admin_aprobar_pendiente(jsonb) from public;
grant execute on function mos.admin_aprobar_pendiente(jsonb) to authenticated;

-- El cron ya existe con este mismo nombre/horario (346): no se re-agenda.
notify pgrst, 'reload schema';
