-- ============================================================================
-- 302_mos_extension_100x_fixes3.sql — 3ª ronda 100x (identidad segura + cierre devices)
-- ----------------------------------------------------------------------------
-- HIGH: _identidad_persona concatenaba el nombre sin escapar '|' → un nombre con '|'
--   (o vacío) generaba identidad ambigua / merge. FIX: escapar '|'→'/' en el nombre +
--   guardar nombre vacío como 'ANON' (nunca segmento vacío).
-- HIGH: el cron 11pm no cerraba mos.accesos_dispositivos → filas ACTIVA acumulándose.
--   FIX: cerrarlas junto con las sesiones del día.
-- ============================================================================

create or replace function mos._identidad_persona(p_id text, p_nombre text, p_zona text, p_temporal boolean)
returns text language sql immutable set search_path = '' as $fn$
  select case
    when not coalesce(p_temporal, true) and coalesce(nullif(btrim(p_id),''),'') <> '' then btrim(p_id)
    else 'MEX:' ||
         coalesce(nullif(replace(upper(btrim(coalesce(nullif(p_nombre,''), p_id))), '|', '/'), ''), 'ANON') ||
         '|' || coalesce(nullif(upper(btrim(p_zona)),''), 'SINZONA')
  end;
$fn$;

-- cron 11pm: + cerrar los devices atados de las sesiones cerradas hoy
create or replace function mos.cerrar_sesiones_forzado_11pm()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
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

  return jsonb_build_object('ok',true,'sesiones_cerradas',v_ses,'devices_cerrados',v_acc,'dispositivos_forzados',v_dev,'fecha',v_dia);
end;
$fn$;
revoke all on function mos.cerrar_sesiones_forzado_11pm() from public;
grant execute on function mos.cerrar_sesiones_forzado_11pm() to authenticated, service_role;
