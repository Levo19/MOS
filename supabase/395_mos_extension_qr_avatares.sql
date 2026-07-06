-- 395 · Extensión de dispositivo v2 (rediseño intuitivo): avatares por zona en el wizard + QR rotativo estilo
-- WhatsApp + canje por escaneo + cascada de logout. 100% Supabase, cero-GAS. Reusa 297/300.
-- Flujo: Dispo2 ve avatares de su zona → toca uno → pedir_extension → Dispo1 acepta → emite QR (rota 90s) →
-- Dispo2 escanea → canjear_qr (ata + jala rol/zona) → al cerrar sesión el principal, cascada a las extensiones.

alter table mos.extension_requests add column if not exists qr_token text;
alter table mos.extension_requests add column if not exists qr_expira timestamptz;

-- ── 1) avatares: sesiones ACTIVAS de una zona hoy (para el wizard del Dispo 2) ──
create or replace function mos.extension_activos_zona(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_zona text := upper(btrim(coalesce(p->>'zona','')));
  v_dia  date;
  v_data jsonb;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  begin v_dia := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::date, (now() at time zone 'America/Lima')::date);
  exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
  select coalesce(jsonb_agg(jsonb_build_object(
      'idDia', l.id_dia, 'nombre', l.nombre, 'rol', upper(coalesce(l.rol,'')), 'zona', upper(coalesce(l.zona,'')),
      'foto', (select foto from mos.personal pp where pp.id_personal = l.id_personal limit 1),
      'principalDeviceId', coalesce(
          (select device_id from mos.accesos_dispositivos a where a.id_dia = l.id_dia and a.es_principal
             order by a.hora_ingreso limit 1),
          (select device_id from mos.accesos_dispositivos a where a.id_dia = l.id_dia order by a.hora_ingreso limit 1)),
      'ultimaConexion', l.ultima_conexion
    ) order by l.ultima_conexion desc nulls last), '[]'::jsonb)
  into v_data
  from mos.liquidaciones_dia l
  where (l.fecha at time zone 'America/Lima')::date = v_dia
    and upper(coalesce(l.estado_sesion,'')) = 'ACTIVA'
    and upper(coalesce(l.zona,'')) = v_zona
    and btrim(coalesce(l.nombre,'')) <> '';
  return jsonb_build_object('ok',true,'data', v_data);
end; $fn$;

-- ── 2) el PRINCIPAL acepta → emite/rota el QR (token de un solo uso, 90s). Rellamar = rotar. ──
create or replace function mos.extension_qr_emitir(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_idreq text := btrim(coalesce(p->>'idReq',''));
  v_cod   text := btrim(coalesce(p->>'codigo',''));
  r mos.extension_requests%rowtype; v_tok text;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF'); end if;
  select * into r from mos.extension_requests where id_req = v_idreq for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(r.estado,'')) not in ('PENDIENTE','QR') then return jsonb_build_object('ok',false,'error','YA_'||upper(r.estado)); end if;
  if now() > r.expira then update mos.extension_requests set estado='EXPIRADA' where id_req=v_idreq;
    return jsonb_build_object('ok',false,'error','EXPIRADA'); end if;
  if v_cod <> '' and v_cod <> r.codigo then return jsonb_build_object('ok',false,'error','CODIGO_NO_COINCIDE'); end if;
  v_tok := substr(md5(random()::text || clock_timestamp()::text || v_idreq), 1, 12);
  update mos.extension_requests
     set estado='QR', qr_token=v_tok, qr_expira=now() + interval '90 seconds',
         expira = greatest(expira, now() + interval '5 minutes')   -- extiende la vida global mientras se escanea
   where id_req = v_idreq;
  -- payload compacto para el QR: EXTQR:idReq:token
  return jsonb_build_object('ok',true,'qrPayload','EXTQR:'||v_idreq||':'||v_tok,'qrToken',v_tok,'expiraSeg',90);
end; $fn$;

-- ── 3) el Dispo 2 escanea → canjea el QR → ATA el equipo + jala rol/zona ──
create or replace function mos.extension_canjear_qr(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_idreq text := btrim(coalesce(p->>'idReq',''));
  v_tok   text := btrim(coalesce(p->>'qrToken',''));
  v_dev   text := btrim(coalesce(p->>'deviceId',''));
  v_push  text := btrim(coalesce(p->>'pushToken',''));
  r mos.extension_requests%rowtype; v_ses record;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF'); end if;
  if v_dev = '' then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  select * into r from mos.extension_requests where id_req = v_idreq for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  -- idempotente: si ya se ató este equipo, devolver OK con los datos de la sesión
  if upper(coalesce(r.estado,'')) = 'APROBADA' and r.device_sol = v_dev then
    -- pasa a devolver la sesión abajo
    null;
  elsif upper(coalesce(r.estado,'')) <> 'QR' then
    return jsonb_build_object('ok',false,'error','ESTADO_'||upper(coalesce(r.estado,'')));
  elsif r.device_sol <> v_dev then
    return jsonb_build_object('ok',false,'error','OTRO_EQUIPO');
  elsif coalesce(r.qr_token,'') = '' or r.qr_token <> v_tok then
    return jsonb_build_object('ok',false,'error','QR_INVALIDO');    -- token viejo/rotado → apuntá al nuevo
  elsif r.qr_expira is null or now() > r.qr_expira then
    return jsonb_build_object('ok',false,'error','QR_VENCIDO');     -- expiró → el principal ya rotó, reintenta
  else
    -- ATAR (idempotente por PK) + marcar la solicitud aprobada
    insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado, push_token)
    values (r.id_dia, v_dev, r.rol_sol, false, 'ACTIVA', v_push)
    on conflict (id_dia, device_id) do update set estado='ACTIVA', ultima_conexion=now(), push_token=excluded.push_token;
    update mos.extension_requests set estado='APROBADA' where id_req = v_idreq;
  end if;
  -- datos de la sesión (rol/zona/nombre) — la extensión JALA estos (no editables)
  select nombre, upper(coalesce(rol,'')) rol, upper(coalesce(zona,'')) zona, id_personal
    into v_ses from mos.liquidaciones_dia where id_dia = r.id_dia limit 1;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idDia', r.id_dia, 'nombre', coalesce(v_ses.nombre,''), 'rol', coalesce(v_ses.rol,''),
    'zona', coalesce(v_ses.zona,''),
    'principalDeviceId', (select device_id from mos.accesos_dispositivos a where a.id_dia=r.id_dia and a.es_principal order by hora_ingreso limit 1)));
end; $fn$;

-- ── 4) registrar el PRINCIPAL en accesos (al abrir sesión) — para saber quién autoriza y la cascada ──
create or replace function mos.extension_registrar_principal(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
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
  insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado, push_token)
  values (v_iddia, v_dev, v_rol, true, 'ACTIVA', btrim(coalesce(p->>'pushToken','')))
  on conflict (id_dia, device_id) do update set es_principal=true, estado='ACTIVA', ultima_conexion=now();
  return jsonb_build_object('ok',true,'idDia',v_iddia);
end; $fn$;

-- ── 5) cascada de logout: el principal cierra sesión → fuerza logout de TODAS sus extensiones ──
create or replace function mos.extension_cerrar_cascada(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_iddia text := nullif(btrim(coalesce(p->>'idDia','')),'');
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dia date; v_n int := 0; rec record;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_iddia is null and v_nombre <> '' then
    begin v_dia := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::date, (now() at time zone 'America/Lima')::date);
    exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;
    v_iddia := mos._liqdia_key(mos._identidad_persona(null, v_nombre, v_zona, true), to_char(v_dia,'YYYY-MM-DD'));
  end if;
  if v_iddia is null then return jsonb_build_object('ok',false,'error','idDia o nombre requerido'); end if;
  -- fuerza logout de cada equipo-extensión (no principal) + marca su acceso CERRADO
  for rec in select device_id from mos.accesos_dispositivos
             where id_dia = v_iddia and coalesce(es_principal,false) = false and upper(coalesce(estado,'')) = 'ACTIVA'
  loop
    update mos.dispositivos set forzar_logout = true where id_dispositivo = rec.device_id;
    v_n := v_n + 1;
  end loop;
  update mos.accesos_dispositivos set estado='CERRADA' where id_dia = v_iddia and upper(coalesce(estado,''))='ACTIVA';
  return jsonb_build_object('ok',true,'extensionesCerradas', v_n);
end; $fn$;

revoke all on function mos.extension_activos_zona(jsonb), mos.extension_qr_emitir(jsonb), mos.extension_canjear_qr(jsonb),
  mos.extension_registrar_principal(jsonb), mos.extension_cerrar_cascada(jsonb) from public, anon;
grant execute on function mos.extension_activos_zona(jsonb), mos.extension_qr_emitir(jsonb), mos.extension_canjear_qr(jsonb),
  mos.extension_registrar_principal(jsonb), mos.extension_cerrar_cascada(jsonb) to authenticated, service_role;
