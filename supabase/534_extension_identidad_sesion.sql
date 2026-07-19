-- 534_extension_identidad_sesion.sql — Diseño FINAL del dueño para el permiso remoto:
-- "desbloquear 1h es desbloquear el UUID de esa app" → la solicitud DEBE funcionar con sesión
-- CERRADA (caso: quiere abrir caja fuera de horario). Lo que el admin necesita ver es QUIÉN fue
-- el ÚLTIMO logeado en ese equipo y el ESTADO de su sesión:
--   · sesión ABIERTA  → "👤 levo1 · sesión ABIERTA · últ. actividad 16:32"
--   · sesión CERRADA  → "👤 Mia · sesión CERRADA (cerró 18-jul 14:05)"
--   · sin sesión      → "👤 jorgenis (último logeo) · sin sesión" (mos.dispositivos.ultima_sesion)
-- Fuentes: me.cajas por dispositivo_id (ME, abierta-primero) → mos.dispositivos.ultima_sesion/
-- ultima_conexion (genérico: WH no liga sesión↔device). Reemplaza el guard 533.
create or replace function mos.solicitar_extension_horario(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id   text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_dev  text := nullif(btrim(coalesce(p->>'deviceId', p->>'device_id','')),'');
  v_app  text := nullif(btrim(coalesce(p->>'app','')),'');
  v_min  int  := 60;                         -- [511] 1 HORA fija (ignora el minutos del cliente)
  v_mot  text := left(btrim(coalesce(p->>'motivo','Sin motivo')), 200);
  v_alerta text;
  -- [534] identidad + estado de sesión del equipo
  v_quien   text := '';
  v_sestado text := 'SIN_SESION';
  v_sdetalle text := '';
  v_caja    record;
  v_disp    record;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null and v_dev is null then
    return jsonb_build_object('ok',false,'error','Requiere deviceId o idPersonal');
  end if;

  -- [534] contexto del equipo: última caja ME del device (ABIERTA primero) + registro del dispositivo
  if v_dev is not null then
    select c.vendedor, upper(coalesce(c.estado,'')) as estado, c.fecha_apertura, c.fecha_cierre
      into v_caja
      from me.cajas c
     where c.dispositivo_id = v_dev
     order by (upper(coalesce(c.estado,'')) = 'ABIERTA') desc, c.fecha_apertura desc
     limit 1;
    select nombre_equipo, nullif(btrim(coalesce(ultima_sesion,'')),'') as ultima_sesion, ultima_conexion
      into v_disp
      from mos.dispositivos where id_dispositivo = v_dev limit 1;

    if v_caja.vendedor is not null then
      v_quien := v_caja.vendedor;
      if v_caja.estado = 'ABIERTA' then
        v_sestado  := 'ABIERTA';
        v_sdetalle := 'sesión ABIERTA · últ. actividad '
          || coalesce(to_char(coalesce(v_disp.ultima_conexion, v_caja.fecha_apertura) at time zone 'America/Lima','HH24:MI'),'—');
      else
        v_sestado  := 'CERRADA';
        v_sdetalle := 'sesión CERRADA (cerró '
          || coalesce(to_char(v_caja.fecha_cierre at time zone 'America/Lima','DD-Mon HH24:MI'),'—') || ')';
      end if;
    elsif v_disp.ultima_sesion is not null then
      v_quien    := v_disp.ultima_sesion || ' (último logeo)';
      v_sdetalle := 'sin sesión · últ. conexión '
        || coalesce(to_char(v_disp.ultima_conexion at time zone 'America/Lima','DD-Mon HH24:MI'),'—');
    else
      v_quien    := coalesce(v_disp.nombre_equipo, 'equipo sin registro');
      v_sdetalle := 'sin sesión previa en este equipo';
    end if;
  end if;

  -- [534] id_personal: el que venga → o mapear el nombre resuelto → o DEV:<uuid> (trazable;
  -- el desbloqueo ES por UUID, la identidad es informativa para el admin)
  if v_id is null then
    select p2.id_personal into v_id from mos.personal p2
     where lower(btrim(p2.nombre || ' ' || coalesce(p2.apellido,''))) = lower(btrim(coalesce(v_caja.vendedor,'')))
        or lower(btrim(p2.nombre)) = lower(btrim(coalesce(v_caja.vendedor, v_disp.ultima_sesion, '')))
     limit 1;
    if v_id is null then v_id := 'DEV:' || v_dev; end if;
  end if;

  -- Dedup: si ya hay una solicitud PENDIENTE de esta persona (o de este UUID), no duplicar.
  if exists (select 1 from mos.seguridad_alertas
             where tipo='EXTENSION_HORARIO_PENDIENTE' and upper(coalesce(estado,''))='PENDIENTE'
               and (id_personal = v_id or (v_dev is not null and id_dispositivo = v_dev))) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true));
  end if;

  v_alerta := 'SEG' || (extract(epoch from clock_timestamp())*1000)::bigint::text || upper(substr(md5(random()::text),1,4));
  insert into mos.seguridad_alertas(id_alerta, tipo, id_dispositivo, id_personal, fecha, descripcion, prioridad, estado, datos_extra_json)
  values (v_alerta, 'EXTENSION_HORARIO_PENDIENTE', v_dev, v_id, now(),
          'Solicita extensión 1h · ' || v_mot
            || case when v_quien <> '' then ' · 👤 ' || v_quien || ' · ' || v_sdetalle else '' end,
          'MEDIA', 'PENDIENTE',
          jsonb_build_object('minutos', v_min, 'motivo', v_mot, 'deviceId', coalesce(v_dev,''),
                             'app', coalesce(v_app,''),
                             'solicitante', v_quien, 'sesionEstado', v_sestado, 'sesionDetalle', v_sdetalle,
                             'solicitadoEn', to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idAlerta', v_alerta, 'pendiente', true, 'minutos', v_min,
           'solicitante', v_quien, 'sesion', v_sdetalle));
end; $fn$;
