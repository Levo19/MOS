-- ════════════════════════════════════════════════════════════════════
-- 555 — Push SOLO a dispositivos AUTORIZADOS (aprobados = estado ACTIVO).
--
-- Problema (detectado por el dueño): mos.push_tokens_para resolvía la
-- audiencia mirando solo push_tokens.activo, sin cruzar con mos.dispositivos.
-- Resultado: equipos SUSPENDIDO / CANCELADO_AUTO / INACTIVO / PENDIENTE
-- seguían recibiendo push broadcast (ej. 17 de 183 tokens WH, 5 mosExpress).
-- La idea del permiso por UUID es que SOLO los aprobados reciban.
--
-- Regla canónica (igual que mos.verificar_dispositivo): autorizado = estado='ACTIVO'.
--
-- DOS cuidados:
--  (a) FAIL-OPEN para tokens SIN device_id (p.ej. los 357 de MOS admin) o con
--      device_id no registrado en mos.dispositivos → se dejan pasar (no romper
--      notificaciones legítimas que no usan device-auth).
--  (b) El targeting EXPLÍCITO por `deviceIds` NO se filtra por estado: seguridad/
--      espía debe poder alcanzar un equipo suspendido/robado (localizar, alarma).
--      El gate ACTIVO aplica solo a audiencias BROADCAST (usuarios/apps/roles).
-- ════════════════════════════════════════════════════════════════════

create or replace function mos.push_tokens_para(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_usuarios text[]; v_apps text[]; v_devices text[]; v_roles text[];
  v_tokens jsonb;
begin
  select array_agg(upper(btrim(x))) into v_usuarios from jsonb_array_elements_text(coalesce(p->'usuarios','[]'::jsonb)) x where btrim(x) <> '';
  select array_agg(btrim(x))        into v_apps     from jsonb_array_elements_text(coalesce(p->'apps','[]'::jsonb)) x where btrim(x) <> '';
  select array_agg(btrim(x))        into v_devices  from jsonb_array_elements_text(coalesce(p->'deviceIds','[]'::jsonb)) x where btrim(x) <> '';
  select array_agg(upper(btrim(x))) into v_roles    from jsonb_array_elements_text(coalesce(p->'roles','[]'::jsonb)) x where btrim(x) <> '';

  select coalesce(jsonb_agg(token), '[]'::jsonb) into v_tokens
  from (
    -- último token vivo por device (o por id_token si el device viene vacío).
    select distinct on (coalesce(nullif(btrim(t.device_id),''), nullif(upper(btrim(t.usuario)),''), t.id_token)) t.token
    from mos.push_tokens t
    where coalesce(t.activo, true)
      and nullif(btrim(coalesce(t.token,'')),'') is not null
      and (
        -- (b) targeting EXPLÍCITO por deviceId → sin gate de estado (seguridad/espía).
        (v_devices is not null and nullif(btrim(coalesce(t.device_id,'')),'') is not null and btrim(t.device_id) = any(v_devices))
        or (
          -- audiencias BROADCAST (usuarios/apps/roles) → solo dispositivos AUTORIZADOS.
          (
            (v_usuarios is not null and nullif(btrim(coalesce(t.usuario,'')),'') is not null and upper(btrim(t.usuario)) = any(v_usuarios))
            or (v_apps is not null and btrim(coalesce(t.app_origen,'')) = any(v_apps))
            or (v_roles is not null and nullif(btrim(coalesce(t.usuario,'')),'') is not null and exists (
                  select 1 from mos.personal pe
                  where pe.estado = true
                    and upper(coalesce(pe.rol,'')) = any(v_roles)
                    and nullif(btrim(coalesce(pe.nombre,'')),'') is not null
                    and ( upper(btrim(coalesce(pe.nombre,'')||' '||coalesce(pe.apellido,''))) = upper(btrim(t.usuario))
                          or upper(btrim(pe.nombre)) = upper(btrim(t.usuario)) )
            ))
          )
          -- (a) gate ACTIVO con fail-open para tokens sin device_id o device no registrado.
          and (
            nullif(btrim(coalesce(t.device_id,'')),'') is null
            or not exists (select 1 from mos.dispositivos dd where dd.id_dispositivo = t.device_id)
            or exists (select 1 from mos.dispositivos dd where dd.id_dispositivo = t.device_id and dd.estado = 'ACTIVO')
          )
        )
      )
    order by coalesce(nullif(btrim(t.device_id),''), nullif(upper(btrim(t.usuario)),''), t.id_token), coalesce(t.ultima_vez, t.fecha) desc nulls last
  ) s;

  return jsonb_build_object('ok', true, 'tokens', v_tokens, 'total', coalesce(jsonb_array_length(v_tokens),0));
end;
$function$;

grant execute on function mos.push_tokens_para(jsonb) to anon, authenticated, service_role;
