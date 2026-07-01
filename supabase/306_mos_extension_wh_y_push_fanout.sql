-- ============================================================================
-- 306_mos_extension_wh_y_push_fanout.sql
--   (c) COMPANION EN WH: identidad por idPersonal (la sesión WH se llavea por
--       id_personal, no por MEX temporal) + habilitar warehouseMos en _ext_app_ok.
--   (b) PUSH FAN-OUT: RPC que devuelve los tokens de TODOS los equipos vivos de
--       una sesión (principal + companions ACTIVOS de hoy) para avisar a ambos.
-- 100% Supabase (cero-GAS). Aditivo: ME (sin idPersonal) mantiene el path temporal.
-- ============================================================================

-- (c.1) warehouseMos entra al gate del companion (rechazar_extension + nota).
--   pedir/aprobar/estado/pendientes ya aceptan cualquier app (jwt_app<>''); solo
--   rechazar y las 2 RPC de nota usaban el gate estricto → ahora incluye WH.
create or replace function mos._ext_app_ok()
returns boolean language sql stable set search_path = '' as $fn$
  select coalesce(me.jwt_app(),'') in ('mosExpress','MOS','warehouseMos');
$fn$;
revoke all on function mos._ext_app_ok() from public;
grant execute on function mos._ext_app_ok() to authenticated, service_role;

-- (c.2) pedir_extension: acepta idPersonal → llave por id (igual que la sesión WH).
--   Sin idPersonal (ME) = path temporal MEX:NOMBRE|ZONA idéntico al anterior.
create or replace function mos.pedir_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dev    text := btrim(coalesce(p->>'deviceId',''));
  v_rol    text := btrim(coalesce(p->>'rol',''));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_idpers text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_dia    date; v_idp text; v_iddia text; v_ppal text; v_cod text; v_idreq text;
  v_prev   mos.extension_requests%rowtype;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;
  if v_nombre = '' or v_dev = '' then return jsonb_build_object('ok',false,'error','nombre y deviceId requeridos'); end if;
  begin v_dia := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  -- [306] WH manda idPersonal → identidad NO temporal (llave = id_personal, igual que
  --   su sesión en liquidaciones_dia). ME no manda idPersonal → temporal MEX (igual que antes).
  v_idp   := mos._identidad_persona(v_idpers, v_nombre, v_zona, v_idpers is null);
  v_iddia := mos._liqdia_key(v_idp, to_char(v_dia,'YYYY-MM-DD'));

  perform 1 from mos.liquidaciones_dia where id_dia = v_iddia and upper(coalesce(estado_sesion,''))='ACTIVA';
  if not found then return jsonb_build_object('ok', true, 'needsApproval', false); end if;

  perform 1 from mos.accesos_dispositivos where id_dia=v_iddia and device_id=v_dev and upper(coalesce(estado,''))='ACTIVA';
  if found then return jsonb_build_object('ok', true, 'needsApproval', false, 'alreadyLinked', true); end if;

  v_ppal := coalesce(
    (select device_id from mos.accesos_dispositivos where id_dia=v_iddia and es_principal order by hora_ingreso limit 1),
    (select device_id from mos.liquidaciones_dia where id_dia=v_iddia));

  -- [100x H2] si ya hay un PENDIENTE vivo de ESTE device para ESTA sesión → reusarlo (no spam)
  select * into v_prev from mos.extension_requests
   where id_dia=v_iddia and device_sol=v_dev and upper(coalesce(estado,''))='PENDIENTE' and now() <= expira
   order by creado desc limit 1;
  if found then
    return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_prev.id_req,'codigo',v_prev.codigo,'idDia',v_iddia,'principalDeviceId',v_ppal);
  end if;

  v_cod  := lpad((floor(random()*1000))::int::text, 3, '0');
  v_idreq := 'EXT-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_dev), 1, 6);
  insert into mos.extension_requests (id_req, id_dia, device_sol, rol_sol, codigo, push_token)
  values (v_idreq, v_iddia, v_dev, v_rol, v_cod, btrim(coalesce(p->>'pushToken','')));
  return jsonb_build_object('ok',true,'needsApproval',true,'idReq',v_idreq,'codigo',v_cod,'idDia',v_iddia,'principalDeviceId',v_ppal);
end;
$fn$;
revoke all on function mos.pedir_extension(jsonb) from public;
grant execute on function mos.pedir_extension(jsonb) to authenticated, service_role;

-- (c.3) _nota_iddia: mismo path idPersonal para que WH comparta la nota de su sesión.
create or replace function mos._nota_iddia(p jsonb)
returns text language plpgsql stable set search_path = '' as $fn$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_idpers text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_dia    date; v_idp text;
begin
  begin v_dia := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  v_idp := mos._identidad_persona(v_idpers, v_nombre, v_zona, v_idpers is null);
  return mos._liqdia_key(v_idp, to_char(v_dia,'YYYY-MM-DD'));
end;
$fn$;
revoke all on function mos._nota_iddia(jsonb) from public;
grant execute on function mos._nota_iddia(jsonb) to authenticated, service_role;

-- (b) PUSH FAN-OUT: tokens de TODOS los equipos vivos de la sesión de un usuario hoy.
--   Devuelve principal (liquidaciones_dia.device_id) + companions ACTIVOS, resueltos
--   por device_id contra mos.push_tokens (solo equipos vivos de HOY → sin spam a
--   celulares viejos). Gate = admin MOS (_claim_ok), el contexto que envía push.
create or replace function mos.tokens_sesion_usuario(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_nombre text := btrim(coalesce(p->>'nombre',''));
  v_zona   text := btrim(coalesce(p->>'zona',''));
  v_dia    date := (now() at time zone 'America/Lima')::date;
  v_iddia  text; v_dev text; v_tokens jsonb; v_cnt int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nombre = '' then return jsonb_build_object('ok',true,'tokens','[]'::jsonb); end if;
  -- matchea por el PREFIJO de fecha embebido en id_dia (autoritativo, business-date;
  -- evita el shift TZ de la columna fecha) + nombre normalizado (+ zona si se dio).
  -- [100x MED] si el nombre es AMBIGUO (≥2 sesiones ACTIVA hoy, p.ej. 2 homónimos en
  --   zonas distintas), NO adivinar → devolver [] (el push cae al envío normal de 1
  --   token, nunca al equipo equivocado). El caller puede desambiguar pasando zona.
  select count(*) into v_cnt
    from mos.liquidaciones_dia
   where id_dia like 'LDIA-' || to_char(v_dia,'YYYYMMDD') || '-%'
     and upper(coalesce(estado_sesion,''))='ACTIVA'
     and mos._norm_nom(nombre) = mos._norm_nom(v_nombre)
     and (v_zona = '' or upper(btrim(coalesce(zona,''))) = upper(v_zona));
  if coalesce(v_cnt,0) <> 1 then return jsonb_build_object('ok',true,'tokens','[]'::jsonb,'ambiguo', coalesce(v_cnt,0) > 1); end if;
  select id_dia, device_id into v_iddia, v_dev
    from mos.liquidaciones_dia
   where id_dia like 'LDIA-' || to_char(v_dia,'YYYYMMDD') || '-%'
     and upper(coalesce(estado_sesion,''))='ACTIVA'
     and mos._norm_nom(nombre) = mos._norm_nom(v_nombre)
     and (v_zona = '' or upper(btrim(coalesce(zona,''))) = upper(v_zona))
   order by hora_ingreso desc limit 1;
  if v_iddia is null then return jsonb_build_object('ok',true,'tokens','[]'::jsonb); end if;
  with devs as (
    select v_dev as device_id where coalesce(v_dev,'') <> ''
    union
    select device_id from mos.accesos_dispositivos where id_dia = v_iddia and upper(coalesce(estado,''))='ACTIVA'
  )
  select coalesce(jsonb_agg(distinct t.token), '[]'::jsonb) into v_tokens
    from mos.push_tokens t
   where t.activo = true and coalesce(t.token,'') <> ''
     and t.device_id in (select device_id from devs where coalesce(device_id,'') <> '');
  return jsonb_build_object('ok', true, 'idDia', v_iddia, 'tokens', coalesce(v_tokens,'[]'::jsonb));
end;
$fn$;
revoke all on function mos.tokens_sesion_usuario(jsonb) from public;
grant execute on function mos.tokens_sesion_usuario(jsonb) to authenticated, service_role;
