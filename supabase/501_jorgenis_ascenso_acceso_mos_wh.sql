-- ============================================================================
-- 501_jorgenis_ascenso_acceso_mos_wh.sql
-- ----------------------------------------------------------------------------
-- Cierra dos huecos del ASCENSO DUAL (acceso_mos) para que un operador ascendido
-- (ej. Jorgenis OP001, ALMACENERO + acceso_mos=true) tenga TODOS los permisos de
-- admin de forma unificada con su ÚNICA clave personal de 4 dígitos:
--
--   (1) mos.get_clave_admin_global — "Ver clave admin global" rechazaba al
--       ascendido porque filtraba rol IN (MASTER/ADMIN/ADMINISTRADOR) SIN honrar
--       acceso_mos. Ahora acepta también a los ascendidos (mismo patrón que
--       _validar_clave_admin_core y verificar_pin_personal). Con esto su PIN
--       personal (parte de la clave de 8) revela la clave global de 4.
--
--   (2) mos.login_pin_wh — devolvía el rol CRUDO (ALMACENERO) → en WH las
--       compuertas de UI admin (multi-impresora, chat, auditoría, avanzado) lo
--       dejaban afuera. Ahora devuelve el rol EFECTIVO 'ADMIN' para ascendidos
--       (rol_nivel<2 AND acceso_mos), igual que verificar_pin_personal hace en
--       MOS. NO afecta el PAGO: la liquidación se calcula en MOS desde la columna
--       mos.personal.rol (queda ALMACENERO); el registro de ingreso/asistencia
--       también sigue con el rol REAL. Solo cambia el rol de la RESPUESTA de login
--       (que el frontend usa para gatear la UI).
-- 100% Supabase, sin deploy de backend. El frontend WH normaliza sus gates aparte.
-- ============================================================================

-- ── (1) get_clave_admin_global: honrar acceso_mos ──────────────────────────
create or replace function mos.get_clave_admin_global(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_pin text := nullif(btrim(coalesce(p->>'pinAdmin','')),'');
  v_por text; v_global text; v_fecha text;
  v_ult timestamptz; v_dias_desde int; v_dias_para int; v_vencida boolean;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_pin is null then return jsonb_build_object('ok',false,'error','Requiere pinAdmin (PIN del solicitante)'); end if;
  -- [FIX 501] admin por rol (nivel>=2) O ascendido (acceso_mos): un ALMACENERO ascendido
  -- puede revelar la clave global con su PIN personal, igual que un admin/master.
  select nombre into v_por from mos.personal
   where estado = true
     and ( upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR') or coalesce(acceso_mos,false) = true )
     and ( (pin_hash is not null and pin_hash = extensions.crypt(v_pin, pin_hash)) or (coalesce(pin,'') = v_pin) )
   limit 1;
  if v_por is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error','PIN no reconocido')); end if;

  select lpad(coalesce(valor,''),4,'0') into v_global from mos.config where clave='ADMIN_GLOBAL_PIN' limit 1;
  select valor into v_fecha from mos.config where clave='ADMIN_GLOBAL_PIN_FECHA' limit 1;

  begin v_ult := nullif(btrim(v_fecha),'')::timestamptz; exception when others then v_ult := null; end;
  if v_ult is null then
    v_dias_desde := 0; v_dias_para := 30; v_vencida := false;
  else
    v_dias_desde := greatest(0, floor(extract(epoch from (now() - v_ult)) / 86400)::int);
    v_dias_para  := greatest(0, 30 - v_dias_desde);
    v_vencida    := v_dias_desde >= 30;
  end if;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'pin', coalesce(v_global,''), 'validadoPor', v_por,
    'diasDesdeRotacion', v_dias_desde, 'diasParaProximaRotacion', v_dias_para, 'vencida', v_vencida,
    'fechaUltimaRotacion', coalesce(v_fecha,''),
    'fechaProximaRotacion', case when v_ult is null then ''
      else to_char((v_ult + interval '30 days') at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') end));
end; $function$;

-- ── (2) login_pin_wh: rol EFECTIVO 'ADMIN' para ascendidos (pago intacto) ───
create or replace function mos.login_pin_wh(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_pin text := nullif(btrim(coalesce(p->>'pin','')), '');
  v_op  mos.personal%rowtype;
  v_rol_ef text;
  v_dia date := (now() at time zone 'America/Lima')::date;
  v_hora text := to_char(now() at time zone 'America/Lima', 'HH24:MI:SS');
  v_fini timestamptz := ((v_dia::text || ' 00:00:00')::timestamp at time zone 'America/Lima');
  v_ses wh.sesiones%rowtype; v_sid text;
  v_hor jsonb; v_hd jsonb;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_pin is null then return jsonb_build_object('ok',false,'error','PIN requerido'); end if;
  select * into v_op from mos.personal
    where btrim(coalesce(pin,'')) = v_pin and coalesce(estado,false) = true
    order by (lower(coalesce(app_origen,'')) like '%warehouse%') desc
    limit 1;
  if not found then return jsonb_build_object('ok',false,'error','PIN incorrecto'); end if;

  -- [FIX 501] rol EFECTIVO: el ascendido (acceso_mos, rol_nivel<2) se presenta como
  -- 'ADMIN' en WH → habilita la UI admin (multi-impresora, etc.). El rol REAL (v_op.rol)
  -- queda intacto para asistencia y para la liquidación en MOS (que lee la columna BD).
  v_rol_ef := case when mos.rol_nivel(v_op.rol) < 2 and coalesce(v_op.acceso_mos, false)
                   then 'ADMIN' else v_op.rol end;

  begin
    v_hor := mos.resolver_horario_personal(jsonb_build_object('app','warehouseMos','idPersonal',v_op.id_personal::text,'rol',v_op.rol));
    v_hd  := v_hor->'data';
    if coalesce((v_hor->>'ok')::boolean,false) and v_hd is not null and coalesce((v_hd->>'permitido')::boolean, true) = false then
      return jsonb_build_object('ok',false,'error','FUERA_DE_HORARIO','data', jsonb_build_object(
        'rol',v_op.rol,'nombre',v_op.nombre,
        'apertura',v_hd->>'apertura','cierre',v_hd->>'cierre','dia',v_hd->>'dia','motivo',v_hd->>'motivo'));
    end if;
  exception when others then null;
  end;

  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    begin
      perform mos.registrar_ingreso_personal(jsonb_build_object(
        'idPersonal',  v_op.id_personal::text,
        'nombre',      v_op.nombre,
        'rol',         v_op.rol,                       -- asistencia con el rol REAL
        'appOrigen',   'warehouseMos',
        'deviceId',    btrim(coalesce(p->>'deviceId', p->>'device_id', '')),
        'esTemporal',  false));
    exception when others then null;
    end;
  end if;

  select * into v_ses from wh.sesiones
    where id_personal = v_op.id_personal::text and upper(coalesce(estado,'')) = 'ACTIVA'
      and (fecha_inicio at time zone 'America/Lima')::date = v_dia
    order by fecha_inicio desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'idSesion', v_ses.id_sesion, 'idPersonal', v_op.id_personal, 'nombre', v_op.nombre,
      'apellido', v_op.apellido, 'rol', v_rol_ef, 'color', v_op.color, 'foto', v_op.foto,
      'horaInicio', v_ses.hora_inicio, 'yaEnSesionHoy', true, 'bienvenidaImpresa', true));
  end if;

  v_sid := 'SES-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_op.id_personal), 1, 6);
  insert into wh.sesiones (id_sesion, id_personal, fecha_inicio, hora_inicio, minutos_activos, estado)
  values (v_sid, v_op.id_personal::text, v_fini, v_hora, 0, 'ACTIVA');
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idSesion', v_sid, 'idPersonal', v_op.id_personal, 'nombre', v_op.nombre, 'apellido', v_op.apellido,
    'rol', v_rol_ef, 'color', v_op.color, 'foto', v_op.foto,
    'horaInicio', v_hora, 'yaEnSesionHoy', false, 'bienvenidaImpresa', false));
end; $function$;
