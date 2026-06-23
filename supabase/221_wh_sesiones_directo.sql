-- 221_wh_sesiones_directo.sql — Ciclo de sesión de WH 100% Supabase (parte SEGURA de F1: NO toca login/
-- PIN/horario, que tienen lockout-risk + dato de horario custom solo en la Hoja). Migra getSesionActiva
-- (lectura) y cerrarTurno (cierre) a wh.sesiones. Gate _claim_ok + flag WH_SESION_DIRECTO. La sesión ya
-- se dual-escribe a wh.sesiones desde GAS, así que leer/cerrar desde Supabase es coherente.

create or replace function wh.get_sesion_activa(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idSesion','')), ''); v_row wh.sesiones%rowtype;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idSesion requerido'); end if;
  select * into v_row from wh.sesiones where id_sesion = v_id and upper(coalesce(estado,'')) = 'ACTIVA' limit 1;
  if not found then return jsonb_build_object('ok',false,'error','Sesión inválida o expirada'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idSesion', v_row.id_sesion, 'idPersonal', v_row.id_personal,
    'fechaInicio', v_row.fecha_inicio, 'horaInicio', v_row.hora_inicio,
    'minutosActivos', v_row.minutos_activos, 'estado', v_row.estado));
end;
$fn$;

create or replace function wh.cerrar_sesion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idSesion','')), '');
  v_forz   boolean := coalesce((p->>'forzado')::boolean, false);
  v_row    wh.sesiones%rowtype;
  v_inicio timestamp; v_now_lima timestamp; v_min int;
begin
  if coalesce((select valor from mos.config where clave='WH_SESION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_SESION_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idSesion requerido'); end if;
  select * into v_row from wh.sesiones where id_sesion = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','Sesión no encontrada'); end if;
  if upper(coalesce(v_row.estado,'')) <> 'ACTIVA' then
    -- ya cerrada → idempotente
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idSesion', v_id, 'minutosActivos', v_row.minutos_activos, 'yaCerrada', true));
  end if;
  -- minutos = ahora(Lima) − (fecha_inicio::date Lima + hora_inicio) — réplica del GAS
  v_now_lima := (now() at time zone 'America/Lima');
  v_inicio   := ((v_row.fecha_inicio at time zone 'America/Lima')::date)::timestamp
                + coalesce(nullif(btrim(coalesce(v_row.hora_inicio,'')),'')::time, '00:00:00'::time);
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

insert into mos.config (clave, valor, descripcion) values
  ('WH_SESION_DIRECTO','0','WH: cerrar_sesion directo a wh.sesiones (getSesionActiva siempre directa). Login/horario sigue GAS.')
on conflict (clave) do nothing;

revoke all on function wh.get_sesion_activa(jsonb) from public;
revoke all on function wh.cerrar_sesion(jsonb) from public;
grant execute on function wh.get_sesion_activa(jsonb) to authenticated;
grant execute on function wh.cerrar_sesion(jsonb) to authenticated;
