-- 404 · extension_registrar_principal: takeover del slot de principal (sin 409).
-- Bug: ux_accdisp_principal = UNIQUE(id_dia) WHERE es_principal AND estado='ACTIVA' → solo UN principal activo por
-- día. El insert de la RPC usaba `on conflict (id_dia, device_id)`, que NO cubre esa constraint parcial → si otro
-- device (o una fila stale del MISMO device en otro id_dia key) ya tenía el slot, saltaba unique_violation → PostgREST
-- devolvía 409 (Conflict) ruidoso en cada login. Como el login que llama a esto ES el equipo PRINCIPAL (el 2º equipo
-- entra por el flujo de extensión explícito, es_principal=false), lo correcto es TOMAR el slot: degradar cualquier
-- principal-activo previo de OTRO device en el mismo id_dia y quedarnos nosotros. Idempotente y sin excepción.

create or replace function mos.extension_registrar_principal(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dev    text := btrim(coalesce(p->>'deviceId',''));
  v_rol    text := btrim(coalesce(p->>'rol',''));
  v_dia date; v_idp text; v_iddia text;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre='' or v_dev='' then return jsonb_build_object('ok',false,'error','faltan datos'); end if;
  begin v_dia := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  v_idp := mos._identidad_persona(null, v_nombre, v_zona, true);
  v_iddia := mos._liqdia_key(v_idp, to_char(v_dia,'YYYY-MM-DD'));

  -- [404] Liberar el slot de principal: degradar a cualquier OTRO device que lo tenga hoy para esta persona.
  --   El equipo que registra ahora es el principal (el 2º equipo entra por extensión, no por acá). Esto evita la
  --   unique_violation contra ux_accdisp_principal y deja un único principal activo (el más reciente).
  update mos.accesos_dispositivos
     set es_principal = false
   where id_dia = v_iddia and device_id <> v_dev
     and es_principal = true and estado = 'ACTIVA';

  insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado, push_token)
  values (v_iddia, v_dev, v_rol, true, 'ACTIVA', btrim(coalesce(p->>'pushToken','')))
  on conflict (id_dia, device_id) do update set es_principal=true, estado='ACTIVA', ultima_conexion=now();

  return jsonb_build_object('ok',true,'idDia',v_iddia);
end; $function$;

grant execute on function mos.extension_registrar_principal(jsonb) to authenticated, service_role, anon;
