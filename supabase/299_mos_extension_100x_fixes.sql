-- ============================================================================
-- 299_mos_extension_100x_fixes.sql — correcciones de la revisión 100x (CRÍTICO/dinero+seguridad)
-- ----------------------------------------------------------------------------
-- C1: _liqdia_key colapsaba '|' → '_' → identidades distintas podían colisionar a la MISMA
--     fila (merge de jornales). FIX: preservar '|' en la clave. + re-key de las filas de hoy.
-- C2: identidad con zona vacía = MEX:<NOMBRE> (sin '|') → colisión con formato viejo + doble
--     fijo. FIX: zona vacía → MEX:<NOMBRE>|SINZONA (nunca pipe-less).
-- H3: _venta_cobrada_persona/zona hacían match EXACTO de zona → un 'ZONA-02 '/'zona-02'
--     zeraba la comisión. FIX: normalizar upper(btrim()).
-- H1: aprobar_extension aceptaba código vacío (bypass) y cualquier token aprobaba. FIX:
--     código NO vacío + el que aprueba debe ser el device PRINCIPAL (o admin).
-- H2: pedir_extension spammeable. FIX: dedup por (id_dia, device_sol) PENDIENTE.
-- H4: registrar_printer_device lo escribía cualquiera. FIX: el device debe estar ATADO.
-- M1: dos devices podían quedar es_principal. FIX: dedup + índice único parcial.
-- ============================================================================

-- ── C1: clave preserva '|' (separador de identidad) ──────────────────────────
create or replace function mos._liqdia_key(p_id_personal text, p_fecha text)
returns text language sql immutable set search_path = '' as $fn$
  -- [100x C1] se preserva '|' además de ':' → MEX:SERGIO|ZONA-01 no colapsa su separador
  -- (antes '|'→'_' podía fundir identidades distintas en la misma fila = merge de dinero).
  select 'LDIA-' || replace(coalesce(p_fecha,''),'-','') || '-'
         || regexp_replace(coalesce(p_id_personal,''), '[^a-zA-Z0-9:|]', '_', 'g');
$fn$;

-- ── C2: identidad con zona vacía nunca es pipe-less ──────────────────────────
create or replace function mos._identidad_persona(p_id text, p_nombre text, p_zona text, p_temporal boolean)
returns text language sql immutable set search_path = '' as $fn$
  select case
    when not coalesce(p_temporal, true) and coalesce(nullif(btrim(p_id),''),'') <> '' then btrim(p_id)
    else 'MEX:' || upper(btrim(coalesce(nullif(p_nombre,''), p_id))) || '|' ||
         coalesce(nullif(upper(btrim(p_zona)),''), 'SINZONA')
  end;
$fn$;

-- ── H3: match de zona normalizado (case/espacios) ────────────────────────────
create or replace function mos._venta_cobrada_persona(p_nombre text, p_zona text, p_dia date)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(sum(v.total),0)::numeric
    from me.ventas v
   where (v.fecha at time zone 'America/Lima')::date = p_dia
     and upper(btrim(coalesce(v.zona_id,''))) = upper(btrim(coalesce(p_zona,'')))
     and mos._norm_nom(v.vendedor) = mos._norm_nom(p_nombre)
     and v.forma_pago ~* '^(efectivo|virtual|mixto)';
$fn$;
create or replace function mos._venta_cobrada_zona(p_zona text, p_dia date)
returns numeric language sql stable set search_path = '' as $fn$
  select coalesce(sum(v.total),0)::numeric
    from me.ventas v
   where (v.fecha at time zone 'America/Lima')::date = p_dia
     and upper(btrim(coalesce(v.zona_id,''))) = upper(btrim(coalesce(p_zona,'')))
     and v.forma_pago ~* '^(efectivo|virtual|mixto)';
$fn$;

-- ── H1: aprobar_extension seguro (código obligatorio + solo el PRINCIPAL/admin) ──
create or replace function mos.aprobar_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idreq text := btrim(coalesce(p->>'idReq',''));
  v_cod   text := btrim(coalesce(p->>'codigo',''));
  v_dev   text := btrim(coalesce(p->>'deviceId',''));   -- device que APRUEBA (debe ser el principal)
  v_admin boolean := coalesce((p->>'admin')::boolean, false) and mos._claim_ok();
  r       mos.extension_requests%rowtype;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;
  select * into r from mos.extension_requests where id_req = v_idreq for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(r.estado,'')) <> 'PENDIENTE' then return jsonb_build_object('ok',false,'error','YA_'||upper(r.estado)); end if;
  if now() > r.expira then update mos.extension_requests set estado='EXPIRADA' where id_req=v_idreq;
    return jsonb_build_object('ok',false,'error','EXPIRADA'); end if;
  -- [100x H1] el código es OBLIGATORIO y debe coincidir (antes vacío = bypass).
  if v_cod = '' or v_cod <> r.codigo then return jsonb_build_object('ok',false,'error','CODIGO_INVALIDO'); end if;
  -- [100x H1] quien aprueba debe ser el device PRINCIPAL ACTIVO de esa sesión (o un admin).
  if not v_admin and not exists(
       select 1 from mos.accesos_dispositivos
        where id_dia = r.id_dia and device_id = v_dev and es_principal and upper(coalesce(estado,''))='ACTIVA') then
    return jsonb_build_object('ok',false,'error','SOLO_EL_PRINCIPAL_APRUEBA');
  end if;

  insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado, push_token)
  values (r.id_dia, r.device_sol, r.rol_sol, false, 'ACTIVA', r.push_token)
  on conflict (id_dia, device_id) do update set estado='ACTIVA', ultima_conexion=now(), rol=excluded.rol;
  update mos.extension_requests set estado='APROBADA' where id_req = v_idreq;
  return jsonb_build_object('ok',true,'idDia',r.id_dia,'deviceId',r.device_sol);
end;
$fn$;

-- ── H2: pedir_extension dedup (no spam de PENDIENTE por mismo device/sesión) ──
create or replace function mos.pedir_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dev    text := btrim(coalesce(p->>'deviceId',''));
  v_rol    text := btrim(coalesce(p->>'rol',''));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
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
  v_idp   := mos._identidad_persona(null, v_nombre, v_zona, true);
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

-- ── H4: registrar_printer_device solo si el device está ATADO a esa sesión ────
create or replace function mos.registrar_printer_device(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_dia text := btrim(coalesce(p->>'idDia','')); v_dev text := btrim(coalesce(p->>'deviceId','')); v_pr text := btrim(coalesce(p->>'printerId',''));
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dia = '' or v_dev = '' then return jsonb_build_object('ok',false,'error','idDia y deviceId requeridos'); end if;
  update mos.accesos_dispositivos set printer_id = v_pr, ultima_conexion = now()
   where id_dia = v_dia and device_id = v_dev and upper(coalesce(estado,''))='ACTIVA';   -- [100x H4] debe estar atado
  return jsonb_build_object('ok', found);
end;
$fn$;

-- ── M1: un solo principal por sesión (dedup + índice único parcial) ──────────
with ranked as (
  select id_dia, device_id, row_number() over (partition by id_dia order by hora_ingreso, device_id) rn
  from mos.accesos_dispositivos where es_principal)
update mos.accesos_dispositivos a set es_principal = false
  from ranked r where a.id_dia=r.id_dia and a.device_id=r.device_id and r.rn > 1;
create unique index if not exists ux_accdisp_principal on mos.accesos_dispositivos (id_dia) where es_principal;

-- ── C1 corrección de datos: re-key de las filas de HOY con la nueva clave ─────
do $rk$
declare r record; v_new text;
begin
  for r in
    select id_dia, id_personal, to_char((fecha at time zone 'America/Lima')::date,'YYYY-MM-DD') f
      from mos.liquidaciones_dia
     where id_personal like 'MEX:%|%'
       and (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
  loop
    v_new := mos._liqdia_key(r.id_personal, r.f);
    if v_new <> r.id_dia and not exists(select 1 from mos.liquidaciones_dia where id_dia = v_new) then
      update mos.accesos_dispositivos set id_dia = v_new where id_dia = r.id_dia;
      update mos.extension_requests   set id_dia = v_new where id_dia = r.id_dia;
      update mos.liquidaciones_dia     set id_dia = v_new where id_dia = r.id_dia;
    end if;
  end loop;
end $rk$;
