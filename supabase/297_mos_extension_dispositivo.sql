-- ============================================================================
-- 297_mos_extension_dispositivo.sql — FASE 1: fundación backend (INERTE, cero-GAS)
-- ----------------------------------------------------------------------------
-- Doc: ProyectoMOS/DISENO_extension_dispositivo_sesion.md
-- Objetivo: que un 2º equipo de la MISMA persona se ATE a su sesión del día (no cree
-- otra persona ni otra base), aprobado por el equipo PRINCIPAL (estilo vincular WhatsApp
-- Web) con un código de 3 dígitos.
--
-- ⚠️ TODO INERTE:
--   · Flag nuevo MOS_EXTENSION_DIRECTO default '0'. Los RPC de escritura chequean el flag.
--   · Tablas nuevas (no tocan liquidaciones_dia ni el flujo vivo).
--   · Nadie lo llama todavía (el frontend es de una fase posterior) → sin efecto en prod.
--   · La identidad `MEX:<NOMBRE>|<ZONA>` se PREPARA como helper pero NO se cablea al hook
--     vivo aquí (ese flip es una fase gateada aparte, para no re-key las filas en vivo).
-- ============================================================================

-- ── flag maestro (INERTE) ───────────────────────────────────────────────────
insert into mos.config(clave, valor) values ('MOS_EXTENSION_DIRECTO','0')
  on conflict (clave) do nothing;

-- ── 1) dispositivos ATADOS a una sesión (id_dia) — 1 fila por equipo ─────────
create table if not exists mos.accesos_dispositivos (
  id_dia          text        not null,              -- = mos._liqdia_key(idPersonal, fecha)
  device_id       text        not null,
  rol             text        default '',            -- rol con el que opera ESTE equipo
  es_principal    boolean     default false,         -- el que abrió la sesión / autoriza
  estado          text        default 'ACTIVA',      -- ACTIVA | CERRADA
  push_token      text        default '',            -- para fan-out de notificaciones
  hora_ingreso    timestamptz default now(),
  ultima_conexion timestamptz default now(),
  primary key (id_dia, device_id)
);
create index if not exists ix_accdisp_dia on mos.accesos_dispositivos (id_dia);

-- ── 2) solicitudes de extensión (pendientes de aprobar) ──────────────────────
create table if not exists mos.extension_requests (
  id_req        text        primary key,
  id_dia        text        not null,               -- sesión a la que quiere atarse
  device_sol    text        not null,               -- equipo solicitante (el celular)
  rol_sol       text        default '',
  codigo        text        not null,               -- 3 dígitos, se muestra en ambos
  estado        text        default 'PENDIENTE',    -- PENDIENTE | APROBADA | RECHAZADA | EXPIRADA
  creado        timestamptz default now(),
  expira        timestamptz default now() + interval '2 minutes',
  push_token    text        default ''
);
create index if not exists ix_extreq_dia on mos.extension_requests (id_dia) where estado = 'PENDIENTE';

-- ── 3) helper de identidad unificada (uniformiza MAYÚSCULA + trim) ───────────
-- Temporal ME → MEX:<NOMBRE>|<ZONA>. Persona registrada (id real) → su id, sin tocar.
-- ⚠️ Solo helper: el hook vivo se cablea en una fase posterior (evita re-key en caliente).
create or replace function mos._identidad_persona(p_id text, p_nombre text, p_zona text, p_temporal boolean)
returns text language sql immutable set search_path = '' as $fn$
  select case
    when not coalesce(p_temporal, true) and coalesce(nullif(btrim(p_id),''),'') <> '' then btrim(p_id)
    else 'MEX:' || upper(btrim(coalesce(nullif(p_nombre,''), p_id))) ||
         case when coalesce(nullif(btrim(p_zona),''),'') <> '' then '|' || upper(btrim(p_zona)) else '' end
  end;
$fn$;

-- ── 4) RPC: pedir_extension — el 2º equipo pide atarse ───────────────────────
-- Devuelve: {ok, needsApproval, idReq?, codigo?, idDia?, principalDeviceId?} o
--           {ok, needsApproval:false} si NO hay sesión activa (→ login normal).
create or replace function mos.pedir_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nombre text := upper(btrim(coalesce(p->>'nombre','')));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_dev    text := btrim(coalesce(p->>'deviceId',''));
  v_rol    text := btrim(coalesce(p->>'rol',''));
  v_fecha  text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_dia    date;
  v_idp    text;
  v_iddia  text;
  v_ppal   text;
  v_cod    text;
  v_idreq  text;
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

  -- ¿existe sesión ACTIVA de esa identidad hoy? (la fila del día debe existir + estar activa)
  perform 1 from mos.liquidaciones_dia
    where id_dia = v_iddia and upper(coalesce(estado_sesion,'')) = 'ACTIVA';
  if not found then
    return jsonb_build_object('ok', true, 'needsApproval', false);  -- no hay a quién atarse → login normal
  end if;

  -- device principal a notificar (el que abrió, o el device_id de la fila)
  v_ppal := coalesce(
    (select device_id from mos.accesos_dispositivos where id_dia = v_iddia and es_principal order by hora_ingreso limit 1),
    (select device_id from mos.liquidaciones_dia where id_dia = v_iddia));

  -- si el MISMO equipo ya está atado → no repetir
  perform 1 from mos.accesos_dispositivos where id_dia = v_iddia and device_id = v_dev and upper(coalesce(estado,'')) = 'ACTIVA';
  if found then return jsonb_build_object('ok', true, 'needsApproval', false, 'alreadyLinked', true); end if;

  v_cod  := lpad((floor(random()*1000))::int::text, 3, '0');   -- 3 dígitos
  v_idreq := 'EXT-' || to_char(now(),'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text || v_dev), 1, 6);
  insert into mos.extension_requests (id_req, id_dia, device_sol, rol_sol, codigo, push_token)
  values (v_idreq, v_iddia, v_dev, v_rol, v_cod, btrim(coalesce(p->>'pushToken','')));

  return jsonb_build_object('ok', true, 'needsApproval', true,
    'idReq', v_idreq, 'codigo', v_cod, 'idDia', v_iddia, 'principalDeviceId', v_ppal);
end;
$fn$;

-- ── 5) RPC: aprobar_extension — el PRINCIPAL (o admin) acepta ────────────────
-- El código se muestra en ambos equipos (verificación humana); aquí se valida por si acaso.
create or replace function mos.aprobar_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idreq text := btrim(coalesce(p->>'idReq',''));
  v_cod   text := btrim(coalesce(p->>'codigo',''));
  r       mos.extension_requests%rowtype;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='MOS_EXTENSION_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','EXTENSION_OFF');
  end if;

  select * into r from mos.extension_requests where id_req = v_idreq for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(r.estado,'')) <> 'PENDIENTE' then return jsonb_build_object('ok',false,'error','YA_'||upper(r.estado)); end if;
  if now() > r.expira then
    update mos.extension_requests set estado='EXPIRADA' where id_req = v_idreq;
    return jsonb_build_object('ok',false,'error','EXPIRADA');
  end if;
  -- el código debe coincidir (el humano confirma que ve el mismo en ambas pantallas)
  if v_cod <> '' and v_cod <> r.codigo then return jsonb_build_object('ok',false,'error','CODIGO_NO_COINCIDE'); end if;

  -- ATAR el equipo a la sesión (idempotente por PK)
  insert into mos.accesos_dispositivos (id_dia, device_id, rol, es_principal, estado, push_token)
  values (r.id_dia, r.device_sol, r.rol_sol, false, 'ACTIVA', r.push_token)
  on conflict (id_dia, device_id) do update set estado='ACTIVA', ultima_conexion=now(), rol=excluded.rol;

  update mos.extension_requests set estado='APROBADA' where id_req = v_idreq;
  return jsonb_build_object('ok',true,'idDia',r.id_dia,'deviceId',r.device_sol);
end;
$fn$;

-- ── 6) RPC: rechazar_extension ───────────────────────────────────────────────
create or replace function mos.rechazar_extension(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update mos.extension_requests set estado='RECHAZADA'
   where id_req = btrim(coalesce(p->>'idReq','')) and upper(coalesce(estado,''))='PENDIENTE';
  return jsonb_build_object('ok', found);
end;
$fn$;

-- ── 7) RPC: accesos_duplicados_dia — data del CHIP de alerta ─────────────────
-- Nombres (normalizados) que aparecen en >1 fila el día, con su venta cobrada por fila,
-- para que el admin decida (fantasma / mismo movido / otra persona). Solo lectura.
create or replace function mos.accesos_duplicados_dia(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with dia as (
    select mos._norm_nom(nombre) nrm, id_personal, coalesce(zona,'') zona,
           coalesce(venta_cobrada,0) venta, coalesce(total_dia,0) total
    from mos.liquidaciones_dia
    where (fecha at time zone 'America/Lima')::date
        = coalesce(nullif(btrim(p->>'fecha',''),'')::date, (now() at time zone 'America/Lima')::date)
      and btrim(coalesce(nombre,'')) <> ''
  ), dup as (
    select nrm from dia group by nrm having count(*) > 1
  )
  select coalesce(jsonb_object_agg(nrm, filas), '{}'::jsonb)
  from (
    select d.nrm, jsonb_agg(jsonb_build_object(
             'idPersonal', d.id_personal, 'zona', d.zona, 'venta', d.venta, 'total', d.total)
             order by d.venta desc) filas
    from dia d join dup u on u.nrm = d.nrm
    group by d.nrm
  ) s;
$fn$;

-- ── grants ──────────────────────────────────────────────────────────────────
revoke all on function mos.pedir_extension(jsonb)          from public;
revoke all on function mos.aprobar_extension(jsonb)        from public;
revoke all on function mos.rechazar_extension(jsonb)       from public;
revoke all on function mos.accesos_duplicados_dia(jsonb)   from public;
revoke all on function mos._identidad_persona(text,text,text,boolean) from public;
grant execute on function mos.pedir_extension(jsonb)        to authenticated, service_role;
grant execute on function mos.aprobar_extension(jsonb)      to authenticated, service_role;
grant execute on function mos.rechazar_extension(jsonb)     to authenticated, service_role;
grant execute on function mos.accesos_duplicados_dia(jsonb) to authenticated, service_role;
grant execute on function mos._identidad_persona(text,text,text,boolean) to authenticated, service_role;
grant select, insert, update on mos.accesos_dispositivos to authenticated, service_role;
grant select, insert, update on mos.extension_requests   to authenticated, service_role;
