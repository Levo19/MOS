-- 514_fase1_ciclo_vida_cancelar.sql — FASE 1 del rediseño Config: completa el ciclo de vida.
-- El cron mos.cron_dispositivos_inactivos (416) ya hace ACTIVO→SUSPENDIDO a los 2 días.
-- Esto agrega el paso siguiente: SUSPENDIDO → CANCELADO_AUTO a los 7 días sin conectar
-- (se archiva: sale de la vista principal de Infraestructura). NO es baneo: verificar_dispositivo
-- (SQL 100) reabre un CANCELADO_AUTO a PENDIENTE_APROBACION cuando el equipo reconecta.
-- Exención: app MOS/'' (panel admin) NUNCA se auto-cancela (igual que la suspensión). Idempotente.
create or replace function mos.cron_dispositivos_inactivos()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_susp jsonb;
  v_n int := 0;
  v_mos int := 0;
  v_canc int := 0;
  v_nombres text;
begin
  -- 1) SUSPENDER operativos con +2 días sin conectar (excluye panel MOS/'').
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

  -- 1b) [FASE 1] CANCELAR (archivar) SUSPENDIDOS con +7 días sin conectar (excluye panel MOS/'').
  --     CANCELADO_AUTO = fuera de la vista; reversible (reabre a PENDIENTE al reconectar, SQL 100).
  update mos.dispositivos set
      estado = 'CANCELADO_AUTO',
      cancelado_auto_ts = now()
    where upper(coalesce(estado,'')) = 'SUSPENDIDO'
      and upper(coalesce(app,'')) not in ('MOS','')
      and ultima_conexion is not null
      and ultima_conexion < now() - interval '7 days';
  get diagnostics v_canc = row_count;

  -- 2) los MOS (o sin app) inactivos solo se ALERTAN (nunca auto-suspender/cancelar el panel)
  select count(*) into v_mos from mos.dispositivos
   where upper(coalesce(estado,''))='ACTIVO' and upper(coalesce(app,'')) in ('MOS','')
     and ultima_conexion is not null
     and ultima_conexion < now() - interval '2 days';

  -- 3) push al master (best-effort, nunca rompe el cron)
  begin
    if coalesce(v_n,0) > 0 or coalesce(v_mos,0) > 0 or coalesce(v_canc,0) > 0 then
      select string_agg(e->>'nombre', ', ') into v_nombres
        from jsonb_array_elements(coalesce(v_susp,'[]'::jsonb)) e;
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER')),
        'titulo', case when coalesce(v_n,0) > 0 then '🔒 Dispositivos suspendidos' else '😴 Dispositivos inactivos' end,
        'cuerpo', case when coalesce(v_n,0) > 0
                    then v_n || ' equipo(s) suspendidos por +2 días sin uso: ' || coalesce(v_nombres,'') ||
                         case when v_canc > 0 then ' · ' || v_canc || ' archivado(s) por +7 días' else '' end ||
                         case when v_mos > 0 then ' · +' || v_mos || ' panel(es) MOS inactivos (no suspendidos)' else '' end ||
                         ' · Reactivar: MOS → Infraestructura'
                    when coalesce(v_canc,0) > 0
                    then v_canc || ' equipo(s) archivados por +7 días sin uso · reversibles al reconectar'
                    else v_mos || ' panel(es) MOS ACTIVO(s) sin conectar +2 días · revísalos' end,
        'data', jsonb_build_object('tipo','device_inactivo')));
    end if;
  exception when others then null; end;

  insert into mos.cron_log(job, ok, resultado)
  values ('dispositivos_inactivos', true,
          jsonb_build_object('suspendidos', coalesce(v_n,0), 'cancelados', coalesce(v_canc,0),
                             'mos_alertados', coalesce(v_mos,0), 'detalle', coalesce(v_susp,'[]'::jsonb)));
  return jsonb_build_object('ok', true, 'suspendidos', coalesce(v_n,0), 'cancelados', coalesce(v_canc,0), 'mos_alertados', coalesce(v_mos,0));
exception when others then
  insert into mos.cron_log(job, ok, resultado) values ('dispositivos_inactivos', false, jsonb_build_object('excepcion',SQLERRM));
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end; $fn$;

revoke all on function mos.cron_dispositivos_inactivos() from public, anon;
grant execute on function mos.cron_dispositivos_inactivos() to service_role;
