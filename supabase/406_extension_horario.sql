-- 406 · Extensión de horario 100% Supabase (cero-GAS). Reemplaza SeguridadAlerts.gs solicitarExtensionHorario +
-- extenderHorarioHoy (+ el trigger 00:01 revertirExtensionesDiarias, que YA NO hace falta: el marcador
-- `extension_hoy` lleva la FECHA y resolver_horario_personal solo lo aplica si es HOY → auto-expira sin cron).

-- ── A) Solicitar extensión (operador) → alerta PENDIENTE para el admin. Espeja el _crearAlertaSeg del GAS. ──
create or replace function mos.solicitar_extension_horario(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_min int  := greatest(1, least(240, coalesce((p->>'minutos')::int, 60)));
  v_mot text := left(btrim(coalesce(p->>'motivo','Sin motivo')), 200);
  v_alerta text;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  -- Dedup: si ya hay una solicitud PENDIENTE de esta persona, no duplicar.
  if exists (select 1 from mos.seguridad_alertas
             where tipo='EXTENSION_HORARIO_PENDIENTE' and upper(coalesce(estado,''))='PENDIENTE' and id_personal = v_id) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('yaExistia',true));
  end if;
  v_alerta := 'SEG' || (extract(epoch from clock_timestamp())*1000)::bigint::text || upper(substr(md5(random()::text),1,4));
  insert into mos.seguridad_alertas(id_alerta, tipo, id_personal, fecha, descripcion, prioridad, estado, datos_extra_json)
  values (v_alerta, 'EXTENSION_HORARIO_PENDIENTE', v_id, now(),
          'Solicita extensión ' || v_min || 'min · ' || v_mot, 'MEDIA', 'PENDIENTE',
          jsonb_build_object('minutos', v_min, 'motivo', v_mot, 'solicitadoEn', to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idAlerta', v_alerta, 'pendiente', true));
end; $fn$;

-- ── B) Extender horario HOY. Dos modos (igual que el GAS):
--    App  : {app, cierre(HH:MM), razon}          → marca extension_hoy en config_horarios_apps.horario_json
--    User : {idPersonal, minutos, app?}          → marca extension_hoy en personal.horario_custom (suma minutos al cierre)
-- El marcador lleva {fecha, dia, cierre}; resolver_horario_personal lo aplica SOLO si fecha==hoy Lima → auto-expira. ──
create or replace function mos.extender_horario_hoy(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_dias  text[] := array['lun','mar','mie','jue','vie','sab','dom'];
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_dia   text := v_dias[ extract(isodow from (now() at time zone 'America/Lima'))::int ];
  v_app   text := nullif(btrim(coalesce(p->>'app','')),'');
  v_id    text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_cierre text := btrim(coalesce(p->>'cierre',''));
  v_min   int; v_hj jsonb; v_hc jsonb; v_res jsonb; v_ci text; v_tot int; v_hh int; v_mm int; v_n int;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- Modo APP: cierre explícito HH:MM
  if v_app is not null and v_id is null then
    if v_cierre !~ '^\d{2}:\d{2}$' then return jsonb_build_object('ok',false,'error','cierre inválido (HH:MM)'); end if;
    select horario_json into v_hj from mos.config_horarios_apps where app = v_app limit 1;
    if v_hj is null then return jsonb_build_object('ok',false,'error','app no encontrada'); end if;
    v_hj := jsonb_set(v_hj, '{extension_hoy}', jsonb_build_object(
      'fecha', to_char(v_hoy,'YYYY-MM-DD'), 'dia', v_dia, 'cierre', v_cierre,
      'razon', left(btrim(coalesce(p->>'razon','')),120)), true);
    update mos.config_horarios_apps set horario_json = v_hj, fecha_actualizacion = now() where app = v_app;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('app',v_app,'cierreNuevo',v_cierre,'dia',v_dia));
  end if;

  -- Modo USUARIO: suma minutos al cierre vigente
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal o app+cierre requeridos'); end if;
  v_min := greatest(1, least(240, coalesce((p->>'minutos')::int, 60)));
  v_res := mos.resolver_horario_personal(jsonb_build_object('idPersonal', v_id, 'app', coalesce(v_app,'warehouseMos')));
  v_ci  := coalesce(v_res->'data'->>'cierre','');
  if v_ci !~ '^\d{1,2}:\d{2}$' then return jsonb_build_object('ok',false,'error','No se pudo determinar el cierre actual'); end if;
  v_hh := split_part(v_ci,':',1)::int; v_mm := split_part(v_ci,':',2)::int;
  v_tot := v_hh*60 + v_mm + v_min;
  v_hh := least(23, v_tot/60); v_mm := case when v_tot/60 >= 24 then 59 else v_tot % 60 end;
  v_cierre := lpad(v_hh::text,2,'0') || ':' || lpad(v_mm::text,2,'0');
  select coalesce(horario_custom,'{}'::jsonb) into v_hc from mos.personal where id_personal = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Personal no encontrado'); end if;
  v_hc := jsonb_set(coalesce(v_hc,'{}'::jsonb), '{extension_hoy}', jsonb_build_object(
    'fecha', to_char(v_hoy,'YYYY-MM-DD'), 'dia', v_dia, 'cierre', v_cierre), true);
  update mos.personal set horario_custom = v_hc where id_personal = v_id;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPersonal',v_id,'nuevoCierre',v_cierre,'dia',v_dia));
end; $fn$;

grant execute on function mos.solicitar_extension_horario(jsonb) to authenticated, service_role, anon;
grant execute on function mos.extender_horario_hoy(jsonb)        to authenticated, service_role, anon;

-- ── C) resolver_horario_personal: honrar extension_hoy (auto-expira: solo si fecha==hoy Lima y dia coincide). ──
create or replace function mos.resolver_horario_personal(p jsonb DEFAULT '{}'::jsonb)
 returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_app  text := nullif(btrim(coalesce(p->>'app','mosExpress')),'');
  v_id   text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_rol  text := upper(btrim(coalesce(p->>'rol','')));
  v_rol_db text;
  v_vend text := upper(btrim(coalesce(p->>'vendedor','')));
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_horario_json jsonb := '{}'::jsonb;
  v_admins_libres boolean := true;
  v_custom jsonb;
  v_hor    jsonb;
  v_fuente text := 'app';
  v_dias   text[] := array['lun','mar','mie','jue','vie','sab','dom'];
  v_diakey text;
  v_cfgdia jsonb;
  v_ext    jsonb;          -- [406] marcador extension_hoy {fecha,dia,cierre}
  v_now    timestamptz := now();
  v_hdec   numeric;
  v_ap     numeric; v_ci numeric;
  v_perm   boolean;
begin
  if v_claim not in ('mosExpress','MOS','') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_app is null then return jsonb_build_object('ok',false,'error','app requerida'); end if;

  if v_id is not null then
    select upper(coalesce(rol,'')), horario_custom into v_rol_db, v_custom
    from mos.personal where id_personal = v_id limit 1;
  elsif v_vend is not null then
    select upper(coalesce(rol,'')), horario_custom into v_rol_db, v_custom
    from mos.personal
    where app_origen = 'mosExpress'
      and ( upper(btrim(coalesce(nombre,'')||' '||coalesce(apellido,''))) = v_vend
            or upper(coalesce(nombre,'')) = v_vend )
    limit 1;
  end if;
  v_rol := coalesce(nullif(v_rol_db,''), v_rol);

  select coalesce(horario_json,'{}'::jsonb),
         coalesce(lower(coalesce(admins_libres::text,'true')) in ('true','t','1'), true)
    into v_horario_json, v_admins_libres
  from mos.config_horarios_apps where app = v_app limit 1;

  if v_custom is not null and coalesce((v_custom->>'activo')::boolean,false) and v_custom ? 'dias' then
    v_hor := v_custom->'dias'; v_fuente := 'custom';
  end if;

  if v_hor is null and v_rol in ('MASTER','ADMINISTRADOR') and v_admins_libres then
    return jsonb_build_object('ok',true,'data', jsonb_build_object('permitido',true,'motivo','rol_admin_libre','fuente','app'));
  end if;
  if v_hor is null then v_hor := v_horario_json; end if;

  v_diakey := v_dias[ extract(isodow from (v_now at time zone 'America/Lima'))::int ];
  v_cfgdia := coalesce(v_hor->v_diakey,'{}'::jsonb);

  -- [406] Override de cierre por EXTENSIÓN de HOY (auto-expira: solo si fecha==hoy y dia coincide, y el día está
  --   activo). Fuente: custom.extension_hoy (modo usuario) o config_horarios_apps.horario_json.extension_hoy (app).
  v_ext := coalesce(v_custom->'extension_hoy', v_horario_json->'extension_hoy');
  if v_ext is not null
     and (v_ext->>'fecha') = to_char(v_now at time zone 'America/Lima','YYYY-MM-DD')
     and coalesce(v_ext->>'dia','') = v_diakey
     and coalesce((v_cfgdia->>'activo')::boolean,false)
     and nullif(v_ext->>'cierre','') is not null then
    v_cfgdia := jsonb_set(v_cfgdia, '{cierre}', to_jsonb(v_ext->>'cierre'));
  end if;

  if not coalesce((v_cfgdia->>'activo')::boolean,false) then
    return jsonb_build_object('ok',true,'data', jsonb_build_object(
      'permitido',false,'motivo','dia_cerrado','fuente',v_fuente,'dia',v_diakey,
      'apertura',v_cfgdia->>'apertura','cierre',v_cfgdia->>'cierre'));
  end if;

  v_hdec := extract(hour from (v_now at time zone 'America/Lima'))
            + extract(minute from (v_now at time zone 'America/Lima'))/60.0;
  v_ap := mos._parse_hora(v_cfgdia->>'apertura');
  v_ci := mos._parse_hora(v_cfgdia->>'cierre');
  if v_ap is null or v_ci is null then
    return jsonb_build_object('ok',true,'data', jsonb_build_object('permitido',true,'motivo','hora_invalida_permitir','fuente',v_fuente,'dia',v_diakey));
  end if;

  if    v_ci > v_ap then v_perm := (v_hdec >= v_ap and v_hdec < v_ci);
  elsif v_ci < v_ap then v_perm := (v_hdec >= v_ap or  v_hdec < v_ci);
  else  v_perm := false; end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'permitido',v_perm,
    'motivo', case when v_perm then 'en_horario' when v_hdec < v_ap then 'antes_apertura' else 'despues_cierre' end,
    'fuente',v_fuente,'dia',v_diakey,
    'apertura',v_cfgdia->>'apertura','cierre',v_cfgdia->>'cierre'));
end;
$function$;
