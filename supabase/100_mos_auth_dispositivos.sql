-- 100_mos_auth_dispositivos.sql — [AUTH DISPOSITIVOS · FASE 1 · CIMIENTOS · 100% INERTE]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- OBJETIVO (solo cimientos del cutover de auth de dispositivos a Supabase directo — DISENO_auth_dispositivos_cutover_supabase.md §5 Fase A):
--   (1) Paridad de schema: agregar a mos.dispositivos las 2 columnas que la HOJA tiene y la sombra no.
--   (2) Factorizar la validación bcrypt de la clave admin en una FUNCIÓN CORE sin gate de claim (mos._validar_clave_admin_core),
--       reusable por RPCs anon (bootstrap del primer device sin token). verificar_clave_admin pasa a ser wrapper que la llama
--       tras el gate _claim_ok() → CERO cambio de comportamiento para los llamadores actuales con token.
--   (3) Mecanismo de rate-limit / lockout exponencial (tabla mos.auth_intentos) contra fuerza bruta del PIN expuesto a anon.
--   (4) 4 RPCs: registrar_dispositivo (anon, anti-spam) · verificar_dispositivo (anon, read+heartbeat) ·
--       aprobar_dispositivo (anon PERO gateada por clave admin + lockout) · revocar_dispositivo (anon + clave admin + lockout).
--   (5) Denylist en mos.get_flags(): dispositivos_revocados[] + device_verify_version (sin romper el 99: superconjunto).
--
-- ⚠️⚠️ 100% INERTE — NADA cambia el comportamiento de producción ⚠️⚠️
--   · device-auth.js NO se toca; el frontend de las 3 apps sigue autenticando 100% por GAS (Config.gs).
--   · NADIE llama estas RPCs nuevas. Existen, validan, pero el front no las consume (eso es Fase C, detrás de flag).
--   · mos.get_flags() sigue devolviendo TODO lo que devolvía (el 99) + 2 campos nuevos que el front aún no lee.
--   · El sync HOJA→sombra actual sigue siendo el maestro de auth (Fase 2 = invertirlo). Estas RPCs escriben la MISMA
--     tabla mos.dispositivos que ese sync; al no ser llamadas, no compiten con él.
--   · NO toca verificar_clave_admin para los llamadores con token (mismo veredicto bcrypt — wrapper transparente).
--
-- CONVENCIÓN (obligatoria, ver memoria de roles): security definer + set search_path='' + revoke public + grants
--   explícitos + fail-closed. extensions.crypt/gen_salt calificadas. Tablas nuevas → enable row level security + revoke anon.
--   anon SOLO recibe execute en las RPCs que DEBEN ser pre-auth (registrar/verificar/aprobar/revocar/get_flags); jamás en tablas.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) PARIDAD DE SCHEMA — 2 columnas que la HOJA DISPOSITIVOS tiene (_DISP_COLS_EXTRA, Config.gs:515) y la sombra no.
--    Idempotente (add column if not exists). Tipos coherentes con el resto (timestamptz, igual que suspendido_desde).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
alter table mos.dispositivos add column if not exists fecha_caducidad            timestamptz;
alter table mos.dispositivos add column if not exists desbloqueo_temporal_hasta  timestamptz;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) SEED — DEVICE_VERIFY_VERSION en mos.config (clave para invalidar cache de la flota; bumpearla = re-verify global).
--    Idempotente: no pisa un valor ya puesto. Default '1'.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
insert into mos.config (clave, valor, descripcion) values
  ('DEVICE_VERIFY_VERSION', '1', 'Versión de verificación de dispositivos (bump = re-verify de toda la flota / kill de cache)')
on conflict (clave) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) TABLA mos.auth_intentos — rate-limit / lockout de intentos privilegiados (aprobar/revocar con clave admin).
--    Una fila por intento. La clave NUNCA se guarda (solo ok true/false). El lockout se calcula contando los
--    FALLIDOS recientes por id_dispositivo dentro de una ventana → backoff exponencial. RLS on, sin grants a anon
--    ni authenticated: SOLO las RPCs security definer la tocan (el invocador anon no tiene grant de tabla).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create table if not exists mos.auth_intentos (
  id             bigint generated always as identity primary key,
  id_dispositivo text,                          -- device sobre el que se intentó la acción (puede no existir aún)
  accion         text,                           -- APROBAR_DISPOSITIVO / REVOCAR_DISPOSITIVO / ...
  ok             boolean not null,               -- ¿la clave validó? (true = no cuenta para el lockout)
  ts             timestamptz not null default now()
);
create index if not exists ix_auth_intentos_disp_ts on mos.auth_intentos (id_dispositivo, ts desc);
create index if not exists ix_auth_intentos_ts       on mos.auth_intentos (ts desc);
alter table mos.auth_intentos enable row level security;   -- sin policies → nadie por PostgREST; solo SECURITY DEFINER.
revoke all on table mos.auth_intentos from anon, authenticated;
grant all  on table mos.auth_intentos to service_role;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3a) mos._auth_lockout_estado(p_device) — ¿está bloqueado este device por fuerza bruta? Backoff EXPONENCIAL.
--     Modelo: cuenta intentos FALLIDOS en la ventana de observación (15 min). A partir de FALLOS_LIBRES (5) fallidos,
--     bloquea por un tiempo que crece exponencial con el nº de fallos por encima del umbral, con techo (30 min):
--        bloqueo = min( BASE * 2^(fallos-FALLOS_LIBRES) , TECHO )   [solo si fallos > FALLOS_LIBRES]
--     "bloqueado" = (fallos > FALLOS_LIBRES) AND (ahora < ultimo_fallo + bloqueo). Devuelve jsonb con diagnóstico.
--     Internal: security definer, search_path='', sin grants a anon (solo la usan las RPCs definer).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos._auth_lockout_estado(p_device text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  c_ventana       constant interval := interval '15 minutes';  -- ventana de observación de fallos
  c_fallos_libres constant int      := 5;                       -- fallos permitidos antes de empezar a bloquear
  c_base          constant interval := interval '30 seconds';   -- bloqueo base (primer fallo excedente)
  c_techo         constant interval := interval '30 minutes';   -- techo del bloqueo exponencial
  v_fallos    int;
  v_ult_fallo timestamptz;
  v_exp       int;
  v_bloqueo   interval;
  v_hasta     timestamptz;
  v_locked    boolean := false;
begin
  if coalesce(btrim(p_device),'') = '' then
    return jsonb_build_object('locked', false, 'fallos', 0);
  end if;
  select count(*), max(ts) into v_fallos, v_ult_fallo
    from mos.auth_intentos
   where id_dispositivo = p_device
     and ok = false
     and ts > now() - c_ventana;

  if v_fallos > c_fallos_libres then
    v_exp     := v_fallos - c_fallos_libres;                       -- 1,2,3,... fallos por encima del umbral
    -- min(base * 2^(exp-1), techo). exp=1 → base; cada fallo extra duplica, con techo.
    -- [fix 40x] recortar el exponente ANTES de multiplicar: 2^(v_exp-1) con v_exp>~45
    -- desborda 'interval out of range' ANTES de que least() recorte (Postgres evalua la
    -- multiplicacion primero) => un atacante con ~45 fallos sobre un device_id volvia
    -- aprobar/revocar de ESE id un error permanente (DoS dirigido, fail-closed). Cap a 2^16
    -- (30s*65536 ~ 22 dias) que igual queda recortado por c_techo (30min) => mismo comportamiento.
    v_bloqueo := least(c_base * (2 ^ least(v_exp - 1, 16)), c_techo);
    v_hasta   := v_ult_fallo + v_bloqueo;
    v_locked  := now() < v_hasta;
  end if;

  return jsonb_build_object(
    'locked',  v_locked,
    'fallos',  v_fallos,
    'hasta',   v_hasta,
    'retry_seg', case when v_locked then ceil(extract(epoch from (v_hasta - now())))::int else 0 end
  );
end;
$fn$;
revoke all on function mos._auth_lockout_estado(text) from public, anon, authenticated;
grant execute on function mos._auth_lockout_estado(text) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3b) mos._auth_registrar_intento(p_device, p_accion, p_ok) — registra un intento (para el lockout). Internal.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos._auth_registrar_intento(p_device text, p_accion text, p_ok boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  insert into mos.auth_intentos (id_dispositivo, accion, ok) values (nullif(btrim(coalesce(p_device,'')),''), p_accion, p_ok);
exception when others then null;  -- el registro de intento jamás bloquea la operación
end;
$fn$;
revoke all on function mos._auth_registrar_intento(text,text,boolean) from public, anon, authenticated;
grant execute on function mos._auth_registrar_intento(text,text,boolean) to service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) mos._validar_clave_admin_core(...) — NÚCLEO de la validación bcrypt SIN gate de claim.
--    Extrae EXACTAMENTE el cuerpo de verificar_clave_admin (74) salvo la línea del gate _claim_ok().
--    Mismo bcrypt, mismos niveles (cascada rol_nivel >= permisos_accion.nivel_minimo), MISMA auditoría única.
--    Reusable por las RPCs anon (aprobar/revocar) que no pueden pasar por el gate de claim (bootstrap sin token).
--    NO se otorga a anon directamente: solo las RPCs definer la invocan (definer→definer hereda el owner).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos._validar_clave_admin_core(
  p_clave       text,
  p_accion      text    default 'GENERICA',
  p_ref         text    default '',
  p_app         text    default '',
  p_device      text    default '',
  p_detalle     text    default '',
  p_tier        int     default null,
  p_cliente_meta jsonb  default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_global text; v_user text; v_ghash text;
  v_id text; v_nombre text; v_apellido text; v_rol text;
  v_nivel int; v_nivelmin int; v_tier int; v_idacc text; v_nom text;
begin
  -- (SIN gate de claim — esa es la única diferencia con verificar_clave_admin; la barrera real es el bcrypt de abajo)
  -- formato 8 dígitos (igual que GAS)
  if p_clave is null or length(btrim(p_clave)) <> 8 or btrim(p_clave) !~ '^\d{8}$' then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'La clave debe ser de 8 dígitos numéricos');
  end if;
  v_global := substr(btrim(p_clave), 1, 4);
  v_user   := substr(btrim(p_clave), 5, 4);

  -- global vs hash
  select valor into v_ghash from mos.config where clave = 'ADMIN_GLOBAL_PIN_HASH' limit 1;
  if v_ghash is null then
    return jsonb_build_object('ok', false, 'error', 'ADMIN_GLOBAL_PIN_HASH no configurado en MOS');
  end if;
  if v_ghash <> extensions.crypt(v_global, v_ghash) then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Clave incorrecta');
  end if;

  -- admin por pin personal (hash), rol nivel>=2 (ADMIN/MASTER), estado activo
  select p.id_personal, p.nombre, p.apellido, p.rol
    into v_id, v_nombre, v_apellido, v_rol
    from mos.personal p
   where mos.rol_nivel(p.rol) >= 2
     and p.estado = true
     and p.pin_hash is not null
     and p.pin_hash = extensions.crypt(v_user, p.pin_hash)
   limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Clave incorrecta');
  end if;

  -- nivel requerido por la acción (default admin=2 si no está en catálogo)
  v_nivel := mos.rol_nivel(v_rol);
  select nivel_minimo, tier into v_nivelmin, v_tier from mos.permisos_accion where accion = upper(coalesce(p_accion,'')) limit 1;
  v_nivelmin := coalesce(v_nivelmin, 2);
  if v_nivel < v_nivelmin then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'NIVEL_INSUFICIENTE',
      'requiere', case when v_nivelmin >= 3 then 'master' else 'admin' end, 'rol_actor', v_rol);
  end if;

  -- auditoría única (no bloquea el resultado si algo raro pasa con la inserción)
  v_nom  := btrim(v_nombre || ' ' || coalesce(v_apellido, ''));
  v_tier := coalesce(p_tier, v_tier, 2);
  v_idacc := 'AUD' || to_char(now(), 'YYYYMMDDHH24MISSMS') || substr(md5(random()::text), 1, 4);
  begin
    insert into mos.auditoria_admin (id_accion, accion, ref_documento, id_personal_autoriza, nombre_autoriza,
      rol_autoriza, nivel_autoriza, app_origen, dispositivo, tier, device_id, cliente_meta, detalle)
    values (v_idacc, upper(coalesce(p_accion,'GENERICA')), p_ref, v_id, v_nom, v_rol, v_nivel,
      p_app, p_device, v_tier, p_device, p_cliente_meta, p_detalle);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'autorizado', true, 'validado_por', 'admin:' || v_nom,
    'id_personal', v_id, 'nombre', v_nom, 'rol', v_rol, 'nivel', v_nivel, 'id_accion', v_idacc);
end;
$fn$;
revoke all on function mos._validar_clave_admin_core(text,text,text,text,text,text,int,jsonb) from public, anon, authenticated;
grant execute on function mos._validar_clave_admin_core(text,text,text,text,text,text,int,jsonb) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 4b) Re-definir mos.verificar_clave_admin como WRAPPER de la core (CERO cambio de comportamiento para llamadores
--     con token). Mantiene el gate `wh._claim_ok() OR mos._claim_ok()` y delega TODO lo demás a la core.
--     Misma firma 8-arg, mismos grants (service_role/authenticated). Si el claim no pasa → APP_NO_AUTORIZADA (igual que 74).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.verificar_clave_admin(
  p_clave       text,
  p_accion      text    default 'GENERICA',
  p_ref         text    default '',
  p_app         text    default '',
  p_device      text    default '',
  p_detalle     text    default '',
  p_tier        int     default null,
  p_cliente_meta jsonb  default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if not (wh._claim_ok() or mos._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  return mos._validar_clave_admin_core(p_clave, p_accion, p_ref, p_app, p_device, p_detalle, p_tier, p_cliente_meta);
end;
$fn$;
revoke all on function mos.verificar_clave_admin(text,text,text,text,text,text,int,jsonb) from public;
grant execute on function mos.verificar_clave_admin(text,text,text,text,text,text,int,jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) RPC mos.registrar_dispositivo(p) — ANON (pre-auth, boot). Reemplaza registrarSesionDispositivo (Config.gs:901).
--    Insert idempotente PENDIENTE (on conflict no sobrescribe estado). Anti-spam: formato + cuota de PENDIENTES/hora.
--    p = { id_dispositivo, app, user_agent?, nombre_equipo? }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.registrar_dispositivo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id      text := btrim(coalesce(p->>'id_dispositivo',''));
  v_app     text := btrim(coalesce(p->>'app',''));
  v_ua      text := coalesce(p->>'user_agent','');
  v_nombre  text := coalesce(p->>'nombre_equipo', null);
  v_es_mos  boolean;
  v_existe  text;          -- estado actual si la fila ya existe
  v_pend    int;
  c_cuota_pend constant int := 20;     -- máx. PENDIENTES nuevos por hora (anti-DoS de almacenamiento)
begin
  -- (1) validación estricta del id (UUID v-cualquiera de 36 chars con guiones) → rechaza basura/enumeración.
  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false);  -- respuesta genérica
  end if;
  -- 'MOS' || '' se tratan como MOS (igual que Config.gs:2283); el master MOS no se auto-crea PENDIENTE.
  v_es_mos := upper(v_app) in ('MOS','');

  -- (2) ¿ya existe? Solo refresca heartbeat; NUNCA re-pendientea un device ACTIVO/INACTIVO por reconectar.
  select estado into v_existe from mos.dispositivos where id_dispositivo = v_id;
  if v_existe is not null then
    update mos.dispositivos
       set ultima_conexion = now(),
           user_agent      = coalesce(nullif(v_ua,''), user_agent),
           app             = coalesce(nullif(v_app,''), app),
           suspendido_desde = case when estado='ACTIVO' then null else suspendido_desde end
     where id_dispositivo = v_id;
    return jsonb_build_object('ok', true, 'estado', v_existe,
      'autorizado', (v_existe='ACTIVO'), 'nuevo', false);
  end if;

  -- (3) device nuevo. MOS: NO se auto-crea PENDIENTE (el master se aprueba in-situ) → devolver genérico sin insertar.
  if v_es_mos then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false, 'nuevo', false);
  end if;

  -- (4) ANTI-SPAM: cuota de PENDIENTES creados en la última hora. Si se supera → respuesta genérica SIN crear más.
  select count(*) into v_pend from mos.dispositivos
   where estado = 'PENDIENTE_APROBACION' and ultima_conexion > now() - interval '1 hour';
  if v_pend >= c_cuota_pend then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false, 'nuevo', false);
  end if;

  -- (5) insert idempotente. on conflict: si otra tx lo creó en la carrera, solo refresca (no duplica, no re-pendientea).
  insert into mos.dispositivos (id_dispositivo, nombre_equipo, app, estado, ultima_conexion, user_agent)
  values (v_id, v_nombre, v_app, 'PENDIENTE_APROBACION', now(), nullif(v_ua,''))
  on conflict (id_dispositivo) do update
     set ultima_conexion = now(),
         user_agent      = coalesce(nullif(excluded.user_agent,''), mos.dispositivos.user_agent);

  return jsonb_build_object('ok', true, 'estado', 'PENDIENTE_APROBACION', 'autorizado', false, 'nuevo', true);
exception when others then
  -- fail-closed + anti-enumeración: cualquier error → respuesta genérica (no revela el motivo).
  return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false);
end;
$fn$;
revoke all on function mos.registrar_dispositivo(jsonb) from public;
grant execute on function mos.registrar_dispositivo(jsonb) to anon, authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) RPC mos.verificar_dispositivo(p) — ANON (boot + heartbeat). Reemplaza consultarEstadoDispositivo (Config.gs:1230).
--    Read + heartbeat (ultima_conexion=now); limpia suspendido_desde si reaparece ACTIVO. Devuelve estado + flags +
--    verify_version + fecha_hoy_lima. Fail-closed: device inexistente → NO_REGISTRADO (no enumera/no error).
--    p = { id_dispositivo, app? }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.verificar_dispositivo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id   text := btrim(coalesce(p->>'id_dispositivo',''));
  v_ver  text;
  d      mos.dispositivos%rowtype;
begin
  select valor into v_ver from mos.config where clave = 'DEVICE_VERIFY_VERSION' limit 1;
  v_ver := coalesce(v_ver, '1');

  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false,
      'verify_version', v_ver, 'fecha_hoy_lima', to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
  end if;

  -- heartbeat + limpieza de suspendido_desde si reaparece ACTIVO; devuelve la fila actualizada.
  update mos.dispositivos
     set ultima_conexion  = now(),
         suspendido_desde = case when estado='ACTIVO' then null else suspendido_desde end
   where id_dispositivo = v_id
   returning * into d;

  if not found then
    return jsonb_build_object('ok', true, 'estado', 'NO_REGISTRADO', 'autorizado', false,
      'verify_version', v_ver, 'fecha_hoy_lima', to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'estado',                    d.estado,
    'autorizado',                (d.estado = 'ACTIVO'),
    'nombre_equipo',             d.nombre_equipo,
    'app',                       d.app,
    'forzar_wizard',             coalesce(d.forzar_wizard,false),
    'forzar_logout',             coalesce(d.forzar_logout,false),
    'forzar_push',               coalesce(d.forzar_push,false),
    'forzar_reverify',           coalesce(d.forzar_reverify,false),
    'logout_auto_ts',            d.logout_auto_ts,
    'suspendido_desde',          d.suspendido_desde,
    'desbloqueo_temporal_hasta', d.desbloqueo_temporal_hasta,
    'fecha_caducidad',           d.fecha_caducidad,
    'permisos_json',             d.permisos_json,
    'verify_version',            v_ver,
    'fecha_hoy_lima',            to_char((now() at time zone 'America/Lima')::date,'YYYY-MM-DD')
  );
exception when others then
  -- fail-soft: si la RPC falla, el front cae a su cache; la denylist de get_flags es el backstop server.
  return jsonb_build_object('ok', false, 'error', 'ERROR_VERIFICACION');
end;
$fn$;
revoke all on function mos.verificar_dispositivo(jsonb) from public;
grant execute on function mos.verificar_dispositivo(jsonb) to anon, authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 7) RPC mos.aprobar_dispositivo(p) — ANON-CALLABLE pero GATEADA por CLAVE ADMIN (bcrypt) + LOCKOUT exponencial.
--    Reemplaza aprobarDispositivoEnSitu (Config.gs:1766) / reactivarDispositivoSuspendido. La barrera REAL es la
--    clave admin (no el claim — bootstrap del primer device MOS no tiene token). Por eso usa _validar_clave_admin_core
--    (sin gate de claim), NO verificar_clave_admin (que rechazaría al anon por _claim_ok=false).
--    p = { id_dispositivo, clave_admin, app, nombre_equipo?, es_reactivar? }
--    Defensas:
--      · LOCKOUT por id_dispositivo (backoff exponencial) ANTES de tocar bcrypt → blinda el PIN expuesto a internet.
--      · El device DEBE existir en estado PENDIENTE/SUSPENDIDO/CANCELADO_AUTO/INACTIVO → no se puede "aprobar" un id inventado.
--      · Acción APROBAR_DISPOSITIVO_INSITU_MOS = master-only en el catálogo (50) → la core lo rechaza para admin (cascada).
--      · Eco del device_id aprobado (defensa anti-desfase, igual que el read-back actual).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.aprobar_dispositivo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id       text    := btrim(coalesce(p->>'id_dispositivo',''));
  v_clave    text    := coalesce(p->>'clave_admin','');
  v_app      text    := btrim(coalesce(p->>'app',''));
  v_nombre   text    := coalesce(p->>'nombre_equipo', null);
  v_react    boolean := coalesce((p->>'es_reactivar')::boolean, false);
  v_es_mos   boolean;
  v_accion   text;
  v_lock     jsonb;
  v_estado   text;
  v_val      jsonb;
begin
  -- (0) formato del id (anti-basura/enumeración)
  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Solicitud inválida');
  end if;

  -- (1) LOCKOUT: si el device está bloqueado por fuerza bruta → rechazo SIN evaluar bcrypt (corta el ataque).
  v_lock := mos._auth_lockout_estado(v_id);
  if (v_lock->>'locked')::boolean then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'DEMASIADOS_INTENTOS',
      'retry_seg', (v_lock->>'retry_seg')::int);
  end if;

  -- (2) el device debe EXISTIR y estar en un estado aprobable (reduce el espacio: no se aprueban ids inventados).
  select estado into v_estado from mos.dispositivos where id_dispositivo = v_id;
  if v_estado is null or v_estado not in ('PENDIENTE_APROBACION','SUSPENDIDO','CANCELADO_AUTO','INACTIVO') then
    -- contamos como intento fallido (un atacante probando ids+claves no debe distinguir "id malo" de "clave mala").
    perform mos._auth_registrar_intento(v_id, 'APROBAR_DISPOSITIVO', false);
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Solicitud inválida');
  end if;

  -- (3) acción/nivel: MOS in-situ = master-only; WH/ME = admin. Reactivar = admin.
  v_es_mos := upper(coalesce(v_app,'')) in ('MOS','');
  if v_react then
    v_accion := 'REACTIVAR_DISPOSITIVO_SUSPENDIDO';
  elsif v_es_mos then
    v_accion := 'APROBAR_DISPOSITIVO_INSITU_MOS';     -- master-only (catálogo 50)
  else
    v_accion := 'APROBAR_DISPOSITIVO_INSITU';          -- admin (WH/ME)
  end if;

  -- (4) validar clave admin (bcrypt + niveles + auditoría única) vía la CORE (sin gate de claim).
  v_val := mos._validar_clave_admin_core(v_clave, v_accion, v_id, v_app, v_id,
             'Aprobación de dispositivo' || case when v_react then ' (reactivar)' else '' end, null, null);

  if coalesce((v_val->>'autorizado')::boolean, false) <> true then
    perform mos._auth_registrar_intento(v_id, 'APROBAR_DISPOSITIVO', false);   -- cuenta para el lockout
    -- eco del error de la core (NIVEL_INSUFICIENTE / Clave incorrecta / formato), sin filtrar nada extra.
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', coalesce(v_val->>'error','Clave incorrecta'),
      'requiere', v_val->>'requiere');
  end if;

  -- (5) AUTORIZADO → activar (idempotente: re-aprobar un ACTIVO no rompe). Eco del device_id.
  perform mos._auth_registrar_intento(v_id, 'APROBAR_DISPOSITIVO', true);
  update mos.dispositivos
     set estado           = 'ACTIVO',
         nombre_equipo    = coalesce(nullif(v_nombre,''), nombre_equipo),
         app              = coalesce(nullif(v_app,''), app),
         suspendido_desde = null,
         ultima_conexion  = now()
   where id_dispositivo = v_id;

  return jsonb_build_object('ok', true, 'autorizado', true, 'estado', 'ACTIVO',
    'device_id', v_id, 'aprobado_por', v_val->>'nombre', 'id_accion', v_val->>'id_accion');
exception when others then
  return jsonb_build_object('ok', false, 'error', 'ERROR_APROBACION');
end;
$fn$;
revoke all on function mos.aprobar_dispositivo(jsonb) from public;
grant execute on function mos.aprobar_dispositivo(jsonb) to anon, authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 8) RPC mos.revocar_dispositivo(p) — ANON-CALLABLE + CLAVE ADMIN (master-only por catálogo) + LOCKOUT.
--    Reemplaza revocarDispositivo (Config.gs:1476). Pone INACTIVO/SUSPENDIDO. Auditoría vía la core. Idempotente.
--    p = { id_dispositivo, clave_admin, app, nuevo_estado:'INACTIVO'|'SUSPENDIDO' }
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.revocar_dispositivo(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id      text := btrim(coalesce(p->>'id_dispositivo',''));
  v_clave   text := coalesce(p->>'clave_admin','');
  v_app     text := btrim(coalesce(p->>'app',''));
  v_nuevo   text := upper(btrim(coalesce(p->>'nuevo_estado','INACTIVO')));
  v_lock    jsonb;
  v_estado  text;
  v_val     jsonb;
begin
  if v_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Solicitud inválida');
  end if;
  if v_nuevo not in ('INACTIVO','SUSPENDIDO') then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Estado inválido');
  end if;

  v_lock := mos._auth_lockout_estado(v_id);
  if (v_lock->>'locked')::boolean then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'DEMASIADOS_INTENTOS',
      'retry_seg', (v_lock->>'retry_seg')::int);
  end if;

  select estado into v_estado from mos.dispositivos where id_dispositivo = v_id;
  if v_estado is null then
    perform mos._auth_registrar_intento(v_id, 'REVOCAR_DISPOSITIVO', false);
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Solicitud inválida');
  end if;

  -- REVOCAR_DISPOSITIVO = master-only en el catálogo (50) → la core lo exige.
  v_val := mos._validar_clave_admin_core(v_clave, 'REVOCAR_DISPOSITIVO', v_id, v_app, v_id, 'Revocar dispositivo', null, null);
  if coalesce((v_val->>'autorizado')::boolean, false) <> true then
    perform mos._auth_registrar_intento(v_id, 'REVOCAR_DISPOSITIVO', false);
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', coalesce(v_val->>'error','Clave incorrecta'),
      'requiere', v_val->>'requiere');
  end if;

  perform mos._auth_registrar_intento(v_id, 'REVOCAR_DISPOSITIVO', true);
  update mos.dispositivos set estado = v_nuevo where id_dispositivo = v_id;  -- idempotente

  return jsonb_build_object('ok', true, 'autorizado', true, 'estado', v_nuevo,
    'device_id', v_id, 'revocado_por', v_val->>'nombre', 'id_accion', v_val->>'id_accion');
exception when others then
  return jsonb_build_object('ok', false, 'error', 'ERROR_REVOCACION');
end;
$fn$;
revoke all on function mos.revocar_dispositivo(jsonb) from public;
grant execute on function mos.revocar_dispositivo(jsonb) to anon, authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 9) DENYLIST en mos.get_flags() — SUPERCONJUNTO del 99 (no rompe nada: re-define con TODO lo del 99 + 2 campos nuevos).
--    Agrega:
--      · device_verify_version  (de mos.config.DEVICE_VERIFY_VERSION) — bump = re-verify de toda la flota.
--      · dispositivos_revocados[] — UUIDs INACTIVO/SUSPENDIDO recientes (≤30 días), acotado a 500 → revocación ≤2min
--        sin esperar el heartbeat. UUIDs opacos sin PII (ok servir por flags). El front aún NO los consume (INERTE).
--    Mantiene IDÉNTICOS todos los flags *_DIRECTO y *_LECTURA del 99 (mismos cfgKey). SECURITY DEFINER, STABLE,
--    search_path='', anon (callable al arrancar). Fail-safe: coalesce a '0'/[] si falta una clave.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with f as (
    select clave, valor from mos.config where clave like 'MOS\_%' or clave = 'DEVICE_VERIFY_VERSION'
  ),
  rev as (
    select id_dispositivo from mos.dispositivos
     where estado in ('INACTIVO','SUSPENDIDO')
       and ultima_conexion > now() - interval '30 days'
     order by ultima_conexion desc
     limit 500
  )
  select jsonb_build_object(
    -- ── flags *_DIRECTO existentes (NO romper: mismos cfgKey que ya consume el frontend) ──
    'catalogoDirecto',    coalesce((select valor from f where clave='MOS_CATALOGO_DIRECTO'),    '0'),
    'proveedoresDirecto', coalesce((select valor from f where clave='MOS_PROVEEDORES_DIRECTO'), '0'),
    'pedidosDirecto',     coalesce((select valor from f where clave='MOS_PEDIDOS_DIRECTO'),     '0'),
    'pagosDirecto',       coalesce((select valor from f where clave='MOS_PAGOS_DIRECTO'),       '0'),
    'provprodDirecto',    coalesce((select valor from f where clave='MOS_PROVPROD_DIRECTO'),    '0'),
    'gastosDirecto',      coalesce((select valor from f where clave='MOS_GASTOS_DIRECTO'),      '0'),
    'evalDirecto',        coalesce((select valor from f where clave='MOS_EVAL_DIRECTO'),        '0'),
    'horarioDirecto',     coalesce((select valor from f where clave='MOS_HORARIO_DIRECTO'),     '0'),
    'jornadasDirecto',    coalesce((select valor from f where clave='MOS_JORNADAS_DIRECTO'),    '0'),
    'liqdiaDirecto',      coalesce((select valor from f where clave='MOS_LIQDIA_DIRECTO'),      '0'),
    'pagosJornalDirecto', coalesce((select valor from f where clave='MOS_PAGOS_JORNAL_DIRECTO'),'0'),
    -- ── [DUAL-WRITE] maestro + flags de LECTURA por módulo (del 99) ──
    'lecturaNavegador',   coalesce((select valor from f where clave='MOS_LECTURA_NAVEGADOR'),   '0'),
    'proveedoresLectura', coalesce((select valor from f where clave='MOS_PROVEEDORES_LECTURA'), '0'),
    'pedidosLectura',     coalesce((select valor from f where clave='MOS_PEDIDOS_LECTURA'),     '0'),
    'pagosLectura',       coalesce((select valor from f where clave='MOS_PAGOS_LECTURA'),       '0'),
    'provprodLectura',    coalesce((select valor from f where clave='MOS_PROVPROD_LECTURA'),    '0'),
    'jornadasLectura',    coalesce((select valor from f where clave='MOS_JORNADAS_LECTURA'),    '0'),
    'evalLectura',        coalesce((select valor from f where clave='MOS_EVAL_LECTURA'),         '0'),
    'horarioLectura',     coalesce((select valor from f where clave='MOS_HORARIO_LECTURA'),     '0'),
    -- ── [AUTH DISPOSITIVOS · Fase 1] revocación rápida (INERTE: el front aún no lo consume) ──
    'device_verify_version',  coalesce((select valor from f where clave='DEVICE_VERIFY_VERSION'), '1'),
    'dispositivos_revocados', coalesce((select jsonb_agg(id_dispositivo) from rev), '[]'::jsonb)
  );
$fn$;
revoke all on function mos.get_flags() from public;
grant execute on function mos.get_flags() to anon, authenticated, service_role;
