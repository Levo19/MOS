-- 330_mos_resolver_horario.sql
-- [CERO-GAS] Resolución de horario de personal 100% Supabase (reemplaza el GAS verificarHorarioME →
-- resolverHorarioPersonal). Read-only, fail-open (ante cualquier duda → permitido=true, igual que el GAS).
-- Lee mos.config_horarios_apps (sombra fresca) + mos.personal (lookup por nombre para rol/horario_custom).
-- Day-keys REALES: lun/mar/mie/jue/vie/sab/dom (isodow 1..7). Soporta cruce de medianoche.
-- horario_custom: nueva columna sombra (nullable). Mientras no tenga dual-write queda NULL → degrada a la
-- config de la app (comportamiento "sin custom", fail-open). Si se usan horarios custom, alimentar la columna.

alter table mos.personal add column if not exists horario_custom jsonb;

-- helper: 'HH' | 'HH:MM' → hora decimal (espeja _parseHora del GAS). NULL si inválido.
create or replace function mos._parse_hora(s text)
returns numeric language sql immutable set search_path = '' as $$
  select case
    when s ~ '^\d{1,2}:\d{2}$' then split_part(s,':',1)::numeric + split_part(s,':',2)::numeric/60.0
    when s ~ '^\d{1,2}$'       then s::numeric
    else null end;
$$;

create or replace function mos.resolver_horario_personal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
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
  v_hor    jsonb;          -- horario efectivo (custom u app)
  v_fuente text := 'app';
  v_dias   text[] := array['lun','mar','mie','jue','vie','sab','dom'];
  v_diakey text;
  v_cfgdia jsonb;
  v_now    timestamptz := now();
  v_hdec   numeric;
  v_ap     numeric; v_ci numeric;
  v_perm   boolean;
begin
  -- Gate: ME (mosExpress), MOS o service('') — la config de horario no es PII sensible.
  if v_claim not in ('mosExpress','MOS','') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_app is null then return jsonb_build_object('ok',false,'error','app requerida'); end if;

  -- Lookup personal (rol + horario_custom) por idPersonal o nombre. Si no se encuentra, se PRESERVA el rol
  -- pasado por el caller (no se pisa con NULL) — importa para el atajo admin-libre.
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

  -- Config de la app.
  select coalesce(horario_json,'{}'::jsonb),
         coalesce(lower(coalesce(admins_libres::text,'true')) in ('true','t','1'), true)
    into v_horario_json, v_admins_libres
  from mos.config_horarios_apps where app = v_app limit 1;

  -- horarioCustom activo GANA (paridad v2.43.31).
  if v_custom is not null and coalesce((v_custom->>'activo')::boolean,false) and v_custom ? 'dias' then
    v_hor := v_custom->'dias'; v_fuente := 'custom';
  end if;

  -- Admin con admins_libres y SIN custom → permitido siempre.
  if v_hor is null and v_rol in ('MASTER','ADMINISTRADOR') and v_admins_libres then
    return jsonb_build_object('ok',true,'data', jsonb_build_object('permitido',true,'motivo','rol_admin_libre','fuente','app'));
  end if;
  if v_hor is null then v_hor := v_horario_json; end if;

  -- Día TZ Lima (isodow 1=lun..7=dom).
  v_diakey := v_dias[ extract(isodow from (v_now at time zone 'America/Lima'))::int ];
  v_cfgdia := coalesce(v_hor->v_diakey,'{}'::jsonb);

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
$fn$;
revoke all on function mos.resolver_horario_personal(jsonb) from public, anon;
grant execute on function mos.resolver_horario_personal(jsonb) to authenticated, service_role;
