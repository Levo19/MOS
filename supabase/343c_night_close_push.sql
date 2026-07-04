-- 343c: push best-effort night-close (#19 -> admin). Cero-GAS.
CREATE OR REPLACE FUNCTION mos.cerrar_sesiones_forzado_11pm()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dia   date := (now() at time zone 'America/Lima')::date;
  v_fecha timestamptz := ((to_char(v_dia,'YYYY-MM-DD') || ' 00:00:00')::timestamp at time zone 'America/Lima');
  v_now   timestamptz := now();
  v_ses int := 0; v_dev int := 0; v_acc int := 0;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',true,'skipped','MOS_ACCESOS_DIRECTO_OFF');
  end if;

  with cerradas as (
    update mos.liquidaciones_dia set
        estado_sesion   = 'FORZADA_11PM',
        hora_salida     = v_now,
        minutos_activos = least(1440, greatest(coalesce(minutos_activos,0),
                            round(extract(epoch from (v_now - coalesce(hora_ingreso, v_fecha)))/60.0))),
        ts_actualizado  = v_now
      where fecha = v_fecha and upper(coalesce(estado_sesion,'')) = 'ACTIVA'
      returning device_id
  )
  select count(*) into v_ses from cerradas;

  -- [100x] cerrar los devices atados de las sesiones de hoy (evita fuga de ACTIVA)
  update mos.accesos_dispositivos a set estado='CERRADA'
   where a.id_dia in (select id_dia from mos.liquidaciones_dia where fecha = v_fecha)
     and upper(coalesce(a.estado,'')) = 'ACTIVA';
  get diagnostics v_acc = row_count;

  update mos.dispositivos d set
      forzar_logout  = true,
      logout_auto_ts = v_now
    where coalesce(d.id_dispositivo,'') in (
      select distinct device_id from mos.liquidaciones_dia
      where fecha = v_fecha and device_id is not null and btrim(device_id) <> ''
    );
  get diagnostics v_dev = row_count;

  begin
    if coalesce(v_ses,0) > 0 or coalesce(v_dev,0) > 0 then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '🌙 Cierre nocturno automático',
        'cuerpo', coalesce(v_ses,0) || ' sesión(es) y ' || coalesce(v_dev,0) || ' dispositivo(s) cerrados a las 11pm',
        'data', jsonb_build_object('tipo','cierre_nocturno')));
    end if;
  exception when others then null;
  end;
  return jsonb_build_object('ok',true,'sesiones_cerradas',v_ses,'devices_cerrados',v_acc,'dispositivos_forzados',v_dev,'fecha',v_dia);
end;
$function$
;
