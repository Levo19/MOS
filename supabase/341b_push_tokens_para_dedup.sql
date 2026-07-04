-- 341b_push_tokens_para_dedup.sql
-- [FIX 100x] push_tokens_para devolvía TODOS los tokens históricos (304 para 13 devices: el FCM rota y cada
-- registro inserta fila nueva sin desactivar la vieja → cientos de tokens muertos por device). Enviar a todos =
-- spam + costo FCM (aunque el Edge marque UNREGISTERED). FIX: deduplicar al ÚLTIMO token por device
-- (coalesce ultima_vez/fecha desc) → ~1 token vivo por device. Además match de rol/usuario excluye vacíos.
create or replace function mos.push_tokens_para(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
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
        (v_usuarios is not null and nullif(btrim(coalesce(t.usuario,'')),'') is not null and upper(btrim(t.usuario)) = any(v_usuarios))
        or (v_apps is not null and btrim(coalesce(t.app_origen,'')) = any(v_apps))
        or (v_devices is not null and nullif(btrim(coalesce(t.device_id,'')),'') is not null and btrim(t.device_id) = any(v_devices))
        or (v_roles is not null and nullif(btrim(coalesce(t.usuario,'')),'') is not null and exists (
              select 1 from mos.personal pe
              where pe.estado = true
                and upper(coalesce(pe.rol,'')) = any(v_roles)
                and nullif(btrim(coalesce(pe.nombre,'')),'') is not null
                and ( upper(btrim(coalesce(pe.nombre,'')||' '||coalesce(pe.apellido,''))) = upper(btrim(t.usuario))
                      or upper(btrim(pe.nombre)) = upper(btrim(t.usuario)) )
        ))
      )
    order by coalesce(nullif(btrim(t.device_id),''), nullif(upper(btrim(t.usuario)),''), t.id_token), coalesce(t.ultima_vez, t.fecha) desc nulls last
  ) s;

  return jsonb_build_object('ok', true, 'tokens', v_tokens, 'total', coalesce(jsonb_array_length(v_tokens),0));
end;
$fn$;
revoke all on function mos.push_tokens_para(jsonb) from public, anon;
grant execute on function mos.push_tokens_para(jsonb) to service_role;
