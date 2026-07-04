-- 340_mos_horario_custom_personal.sql
-- [CERO-GAS] setHorarioCustomPersonal → escribe mos.personal.horario_custom (reemplaza gas/Horarios.gs).
-- Day-keys lun/mar/mie/jue/vie/sab/dom (paridad SQL 330). El push segmentado del GAS queda para la
-- migración de push (best-effort, no bloquea). getPersonalConHorarioCustom read también (para el panel).
-- Gate por app-claim MOS (el panel de horarios es admin en MOS; llamado con token minteado authenticated).

-- WRITE: {idPersonal, horarioCustom}. Si horarioCustom falso/activo=false → limpia (null). Si no → guarda
-- {activo, dias:{7 días activo/apertura/cierre}, motivo, ts}. Devuelve {ok, data:{idPersonal, accion}}.
create or replace function mos.set_horario_custom_personal(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id   text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_hc   jsonb := p->'horarioCustom';
  v_dias text[] := array['lun','mar','mie','jue','vie','sab','dom'];
  v_d text; v_src jsonb; v_out jsonb := '{}'::jsonb; v_final jsonb; v_n int;
begin
  if v_claim not in ('MOS','mosExpress','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;

  -- Limpiar (sin custom o activo=false).
  if v_hc is null or jsonb_typeof(v_hc) <> 'object' or coalesce((v_hc->>'activo')::boolean, true) = false then
    update mos.personal set horario_custom = null where id_personal = v_id;
    get diagnostics v_n = row_count;
    if v_n = 0 then return jsonb_build_object('ok',false,'error','Personal no encontrado'); end if;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('idPersonal', v_id, 'accion', 'ELIMINADO'));
  end if;

  -- Construir los 7 días (dias.<d> o <d> directo; defaults 07:00/19:00; activo salvo false explícito).
  foreach v_d in array v_dias loop
    v_src := coalesce(v_hc->'dias'->v_d, v_hc->v_d, '{}'::jsonb);
    v_out := v_out || jsonb_build_object(v_d, jsonb_build_object(
      'activo',   coalesce((v_src->>'activo')::boolean, true),
      'apertura', coalesce(nullif(v_src->>'apertura',''), '07:00'),
      'cierre',   coalesce(nullif(v_src->>'cierre',''), '19:00')));
  end loop;
  v_final := jsonb_build_object('activo', true, 'dias', v_out,
    'motivo', coalesce(v_hc->>'motivo',''), 'ts', to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'));

  update mos.personal set horario_custom = v_final where id_personal = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Personal no encontrado'); end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('idPersonal', v_id, 'accion', 'GUARDADO'));
end;
$fn$;
revoke all on function mos.set_horario_custom_personal(jsonb) from public;
grant execute on function mos.set_horario_custom_personal(jsonb) to anon, authenticated, service_role;

-- READ: personal con horario_custom seteado. {ok, data:[{idPersonal, nombre, rol, horarioCustom}]}.
create or replace function mos.personal_horario_custom(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_data jsonb;
begin
  if v_claim not in ('MOS','mosExpress','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'idPersonal', id_personal, 'nombre', coalesce(nombre,''), 'rol', coalesce(rol,''),
    'horarioCustom', horario_custom) order by nombre), '[]'::jsonb)
    into v_data from mos.personal where horario_custom is not null;
  return jsonb_build_object('ok', true, 'data', v_data);
end;
$fn$;
revoke all on function mos.personal_horario_custom(jsonb) from public;
grant execute on function mos.personal_horario_custom(jsonb) to anon, authenticated, service_role;
