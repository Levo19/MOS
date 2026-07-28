-- 584 · [Ruteo de push por rol] Un push que apunta a roles admin/master (audiencia
-- {roles:['MASTER','ADMINISTRADOR','ADMIN']}) hoy alcanza TODOS los tokens de esa persona
-- sin importar la app (MOS, warehouseMos, mosExpress). Como el admin usa WH instalado + MOS,
-- la misma notificación le llega DUPLICADA (WH y MOS). El admin opera desde MOS → sus
-- notificaciones deben ir SOLO a la app MOS.
--
-- Fix quirúrgico y centralizado (1 función cubre a los ~18 emisores, presentes y futuros):
-- en la rama de `roles` de push_tokens_para, cuando el rol emparejado es admin/master,
-- exigir que el token sea de la app admin. Config-driven: mos.config.MOS_PUSH_APP_ADMIN
-- (default 'MOS'; '*' = sin restricción). Operadores/vendedores (roles no-admin) INTACTOS,
-- targeting por deviceId (espía) INTACTO, audiencias por `apps` (p.ej. PN → warehouseMos) INTACTAS.
--
-- Verificado antes de aplicar: los 3 admin/master (LUIS, JAVIER) tienen tokens app='MOS'
-- activos → restringir a MOS no deja a nadie sin push.

-- config editable (si no existe, la crea; no pisa un valor ya puesto)
insert into mos.config (clave, valor) values ('MOS_PUSH_APP_ADMIN', 'MOS')
on conflict (clave) do nothing;

create or replace function mos.push_tokens_para(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_usuarios text[]; v_apps text[]; v_devices text[]; v_roles text[];
  v_admin_app text;
  v_tokens jsonb;
begin
  select array_agg(upper(btrim(x))) into v_usuarios from jsonb_array_elements_text(coalesce(p->'usuarios','[]'::jsonb)) x where btrim(x) <> '';
  select array_agg(btrim(x))        into v_apps     from jsonb_array_elements_text(coalesce(p->'apps','[]'::jsonb)) x where btrim(x) <> '';
  select array_agg(btrim(x))        into v_devices  from jsonb_array_elements_text(coalesce(p->'deviceIds','[]'::jsonb)) x where btrim(x) <> '';
  select array_agg(upper(btrim(x))) into v_roles    from jsonb_array_elements_text(coalesce(p->'roles','[]'::jsonb)) x where btrim(x) <> '';

  -- [584] app a la que se rutean los push de rol admin/master. default 'MOS'; '*' = sin restricción.
  v_admin_app := coalesce(nullif(btrim((select valor from mos.config where clave='MOS_PUSH_APP_ADMIN' limit 1)),''), 'MOS');

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
                    -- [584] ruteo por rol: admin/master solo por la app admin (MOS por defecto).
                    --   Roles NO-admin (operador/vendedor) sin restricción → siguen recibiendo por su app.
                    and ( v_admin_app = '*'
                          or upper(coalesce(pe.rol,'')) <> all(array['MASTER','ADMINISTRADOR','ADMIN'])
                          or btrim(coalesce(t.app_origen,'')) = v_admin_app )
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

notify pgrst, 'reload schema';
