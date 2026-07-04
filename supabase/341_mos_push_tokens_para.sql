-- 341_mos_push_tokens_para.sql
-- [CERO-GAS push] Resuelve AUDIENCIA → lista de tokens FCM activos (para el Edge push-audience).
-- La usa el Edge `push` (service role) cuando el caller manda {audiencia} en vez de {tokens}.
-- Audiencia (unión de criterios, OR): usuarios[], apps[], deviceIds[], roles[] (join a mos.personal por nombre).
-- Reemplaza la selección de audiencia que hoy hace el GAS leyendo el Sheet DISPOSITIVOS.
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

  select coalesce(jsonb_agg(distinct t.token), '[]'::jsonb) into v_tokens
  from mos.push_tokens t
  where coalesce(t.activo, true)
    and nullif(btrim(coalesce(t.token,'')),'') is not null
    and (
      (v_usuarios is not null and upper(btrim(coalesce(t.usuario,''))) = any(v_usuarios))
      or (v_apps is not null and btrim(coalesce(t.app_origen,'')) = any(v_apps))
      or (v_devices is not null and btrim(coalesce(t.device_id,'')) = any(v_devices))
      or (v_roles is not null and exists (
            select 1 from mos.personal pe
            where pe.estado = true
              and upper(coalesce(pe.rol,'')) = any(v_roles)
              and ( upper(btrim(coalesce(pe.nombre,'')||' '||coalesce(pe.apellido,''))) = upper(btrim(coalesce(t.usuario,'')))
                    or upper(coalesce(pe.nombre,'')) = upper(btrim(coalesce(t.usuario,''))) )
      ))
    );

  return jsonb_build_object('ok', true, 'tokens', v_tokens,
    'total', coalesce(jsonb_array_length(v_tokens),0));
end;
$fn$;
revoke all on function mos.push_tokens_para(jsonb) from public, anon;
grant execute on function mos.push_tokens_para(jsonb) to service_role;
