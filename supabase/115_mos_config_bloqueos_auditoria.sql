-- 115_mos_config_bloqueos_auditoria.sql — RPCs de LECTURA: config pública / bloqueos / auditoría (MOS directo)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- Read-paths que hoy MOS resuelve por GAS, portados a la sombra Supabase. Estilo idéntico a 94/107: SECURITY
-- DEFINER, search_path='', gate `mos._claim_ok()` + `|| mos._frescura_sombra()`, shape camelCase paritario,
-- bools como '1'/'0' donde el front compara string, TZ Lima donde corresponde, revoke public + grant.
-- INERTE: nadie las llama todavía (el cableo en js/api.js es tanda posterior). MOS sigue 100% por GAS.
--
-- GETTERS REPLICADOS (paridad exacta):
--   · getConfigMos/getConfigPublico (Code.gs:598/609) → mos.config_publico        [SIN SECRETOS]
--   · getVendedoresMEBloqueados      (Bloqueos.gs:276) → mos.vendedores_me_bloqueados
--   · getDispositivosBloqueados      (Bloqueos.gs:611) → mos.dispositivos_bloqueados
--   · getNotificacionesConfig        (Notificaciones.gs:209) → mos.notificaciones_config
--   · getAuditoriaAdmin              (Seguridad.gs:432) → mos.auditoria_admin_lista
--   · getAuditoriaIntegridad (lectura) (Auditoria.gs:157) → mos.auditoria_integridad_lista
--   NO se construye getDispositivos → ya existe mos.listar_dispositivos (102).
--
-- ⚠️ SEGURIDAD CRÍTICA — mos.config_publico replica EXACTO el filtro de getConfigPublico:
--    SENSIBLE = /(pin|secret|key|token|pass|pwd|clave)/i  (case-insensitive, substring del NOMBRE de la clave).
--    Toda clave cuyo nombre matchee se EXCLUYE. En la sombra real eso captura, entre otras:
--      ADMIN_GLOBAL_PIN, ADMIN_GLOBAL_PIN_FECHA, ADMIN_GLOBAL_PIN_HASH (contienen 'pin'),
--      PIN_ADMIN_WH ('pin'), cualquier *_SECRET / *_KEY / *_TOKEN / *PASS* / *PWD* / *CLAVE*.
--    NUNCA exponer PINs/hashes/secretos al navegador. El filtro es por patrón → cubre claves futuras.

create schema if not exists mos;

-- Helper local: text JSON → jsonb tolerante (devuelve '{}'::jsonb si NO parsea), espejando el try/catch
-- per-fila de GAS (JSON.parse(...) || {}). IMMUTABLE; exception block evita abortar el query completo.
create or replace function mos._json_safe(t text)
returns jsonb language plpgsql immutable as $fn$
begin
  if t is null or btrim(t) = '' then return '{}'::jsonb; end if;
  begin return t::jsonb; exception when others then return '{}'::jsonb; end;
end; $fn$;
revoke all on function mos._json_safe(text) from public;
grant execute on function mos._json_safe(text) to anon, authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.config_publico(p) → getConfigPublico. Devuelve `data` como OBJETO clave→valor (igual que getConfigMos,
--    que arma `cfg[clave]=valor`), SIN las claves sensibles. El front consume cfg.XXX directo.
--    El filtro usa el MISMO regex que GAS, case-insensitive, sobre el nombre de la clave.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.config_publico(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_obj jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  -- Excluir TODA clave cuyo nombre matchee el patrón sensible (paridad EXACTA con getConfigPublico).
  select coalesce(jsonb_object_agg(c.clave, coalesce(c.valor,'')), '{}'::jsonb) into v_obj
  from mos.config c
  where c.clave !~* '(pin|secret|key|token|pass|pwd|clave)';
  return jsonb_build_object('ok',true,'data',v_obj) || v_fr;
end; $fn$;
revoke all on function mos.config_publico(jsonb) from public;
-- getConfig es accesible SIN auth en GAS (router público) → anon también, igual criterio que el catálogo público.
grant execute on function mos.config_publico(jsonb) to anon, authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.vendedores_me_bloqueados(p) → getVendedoresMEBloqueados.
--    Filas de mos.bloqueos_usuario con app_origen normalizado='mosexpress' y fecha_bloqueo seteada.
--    GAS devuelve _sheetToObjects crudo (camelCase headers) + 3 campos derivados: unlockVigente, msRestantes.
--    Headers de la hoja BLOQUEOS_USUARIO ↔ columnas sombra: idBloqueo/idPersonal/nombre/appOrigen/motivo/
--    bloqueadoPor/fechaBloqueo/unlockHasta/desbloqueadoPor. fecha_bloqueo y unlock_hasta son timestamptz.
--    · GAS: unl = parseInt(unlockHasta) (epoch ms) > ahora. Acá: unlock_hasta::timestamptz > now().
--      msRestantes = max(0, unlock_hasta - now()) en milisegundos (paridad con el ms de GAS).
--    _normalizarApp colapsa variantes (MosExpress/mosexpress/ME...) a 'mosexpress' → acá lower(replace espacios).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.vendedores_me_bloqueados(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_arr jsonb; v_fr jsonb; v_now timestamptz := now();
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idBloqueo',       coalesce(b.id_bloqueo,''),
    'idPersonal',      coalesce(b.id_personal,''),
    'nombre',          coalesce(b.nombre,''),
    'appOrigen',       coalesce(b.app_origen,''),
    'motivo',          coalesce(b.motivo,''),
    'bloqueadoPor',    coalesce(b.bloqueado_por,''),
    'fechaBloqueo',    mos._iso_z(b.fecha_bloqueo),
    'unlockHasta',     mos._iso_z(b.unlock_hasta),
    'desbloqueadoPor', coalesce(b.desbloqueado_por,''),
    'unlockVigente',   (b.unlock_hasta is not null and b.unlock_hasta > v_now),
    'msRestantes',     case when b.unlock_hasta is not null and b.unlock_hasta > v_now
                            then floor(extract(epoch from (b.unlock_hasta - v_now)) * 1000)::bigint else 0 end
  ) order by b.fecha_bloqueo desc nulls last), '[]'::jsonb) into v_arr
  from mos.bloqueos_usuario b
  -- _normalizarApp(appOrigen)=='mosexpress'  ⇔  lower contiene 'express'  OR  lower == 'me' (Bloqueos.gs:40-45)
  where (position('express' in lower(coalesce(b.app_origen,''))) > 0
         or lower(btrim(coalesce(b.app_origen,''))) = 'me')
    and b.fecha_bloqueo is not null;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.vendedores_me_bloqueados(jsonb) from public;
grant execute on function mos.vendedores_me_bloqueados(jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.dispositivos_bloqueados(p) → getDispositivosBloqueados.
--    CRUCE: filas de bloqueos_usuario con motivo LIKE 'DEVICE:%' y fecha_bloqueo seteada (= device encarcelado,
--    NO revocación de panel) × mos.dispositivos con estado='INACTIVO'. La clave de cruce es el deviceId, que en
--    GAS vive en la columna `idPersonal` de BLOQUEOS (bIdP) — el flujo DEVICE guarda el deviceId ahí.
--    Shape por item (paridad GAS): deviceId, nombreEquipo, app, ultimaSesion, nombreUsuario, bloqueadoPor,
--    fechaBloqueo. Si p.agruparPorNombre=true → data = { lista:[...], porNombre:{ key:{nombre,dispositivos[]} } }
--    (clave = lower(trim(nombreUsuario || ultimaSesion))). Si no, data = array plano.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.dispositivos_bloqueados(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_agrupar boolean := coalesce((p->>'agruparPorNombre')::boolean, false);
  v_lista jsonb; v_porNombre jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();

  -- Lista plana: bloqueos DEVICE: activos × dispositivos INACTIVO (cruce por deviceId = b.id_personal).
  with x as (
    select
      d.id_dispositivo                  as device_id,
      coalesce(d.nombre_equipo,'')      as nombre_equipo,
      coalesce(d.app,'')                as app,
      coalesce(d.ultima_sesion,'')      as ultima_sesion,
      coalesce(b.nombre,'')             as nombre_usuario,
      coalesce(b.bloqueado_por,'')      as bloqueado_por,
      b.fecha_bloqueo                   as fecha_bloqueo
    from mos.bloqueos_usuario b
    join mos.dispositivos d
      on d.id_dispositivo = b.id_personal
    where b.fecha_bloqueo is not null
      and coalesce(b.motivo,'') like 'DEVICE:%'
      and upper(coalesce(d.estado,'')) = 'INACTIVO'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'deviceId',      x.device_id,
    'nombreEquipo',  x.nombre_equipo,
    'app',           x.app,
    'ultimaSesion',  x.ultima_sesion,
    'nombreUsuario', x.nombre_usuario,
    'bloqueadoPor',  x.bloqueado_por,
    'fechaBloqueo',  mos._iso_z(x.fecha_bloqueo)
  ) order by x.fecha_bloqueo desc nulls last), '[]'::jsonb) into v_lista
  from x;

  if not v_agrupar then
    return jsonb_build_object('ok',true,'data',v_lista) || v_fr;
  end if;

  -- Agrupado por nombre (clave = lower(trim(nombreUsuario || ultimaSesion)); items sin clave se descartan).
  select coalesce(jsonb_object_agg(g.k, jsonb_build_object('nombre', g.nombre, 'dispositivos', g.disp)), '{}'::jsonb)
    into v_porNombre
  from (
    select
      lower(btrim(coalesce(nullif(item->>'nombreUsuario',''), item->>'ultimaSesion'))) as k,
      coalesce(nullif(item->>'nombreUsuario',''), item->>'ultimaSesion')               as nombre,
      jsonb_agg(item)                                                                  as disp
    from jsonb_array_elements(v_lista) item
    where btrim(coalesce(nullif(item->>'nombreUsuario',''), item->>'ultimaSesion','')) <> ''
    group by 1, 2
  ) g;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('lista', v_lista, 'porNombre', v_porNombre)) || v_fr;
end; $fn$;
revoke all on function mos.dispositivos_bloqueados(jsonb) from public;
grant execute on function mos.dispositivos_bloqueados(jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) mos.notificaciones_config(p) → getNotificacionesConfig.
--    Devuelve TODAS las filas de mos.notificaciones_config (sin filtros, igual que el getter).
--    GAS normaliza `activa` y `excluir_origen` a BOOLEAN JS (no '1'/'0') → acá se emiten como BOOLEAN JSON.
--    ⚠️ DIVERGENCIA DE TIPO HONESTA: en la sombra, excluir_origen es `text` (ver 04_schema_mos.sql:287),
--      mientras activa es `boolean`. Se normalizan AMBOS a boolean replicando la regla de GAS
--      (String(x).toLowerCase()==='true' || x===true). audiencia_roles/usuarios = CSV text tal cual.
--    Claves snake_case preservadas (el getter usa _sheetToObjects con headers snake del sheet: id_notif,
--    audiencia_roles, etc.) → el front consume esas mismas claves. NO se camelCasea.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.notificaciones_config(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id_notif',           coalesce(n.id_notif,''),
    'origen',             coalesce(n.origen,''),
    'titulo',             coalesce(n.titulo,''),
    'descripcion',        coalesce(n.descripcion,''),
    'icono',              coalesce(n.icono,''),
    'activa',             coalesce(n.activa, false),
    'audiencia_roles',    coalesce(n.audiencia_roles,''),
    'audiencia_usuarios', coalesce(n.audiencia_usuarios,''),
    'excluir_origen',     (lower(coalesce(n.excluir_origen,'')) = 'true'),
    'prioridad',          coalesce(n.prioridad,'normal'),
    'silenciada_hasta',   mos._iso_z(n.silenciada_hasta),
    'sonido_custom',      coalesce(n.sonido_custom,''),
    'ts_actualizado',     mos._iso_z(n.ts_actualizado),
    'actualizado_por',    coalesce(n.actualizado_por,'')
  ) order by n.id_notif), '[]'::jsonb) into v_arr
  from mos.notificaciones_config n;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.notificaciones_config(jsonb) from public;
grant execute on function mos.notificaciones_config(jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) mos.auditoria_admin_lista(p) → getAuditoriaAdmin.
--    Filtros opcionales (paridad GAS): accion (== UPPER), appOrigen (== LOWER), limit (default 100).
--    Orden: más recientes primero (por fecha desc). Shape camelCase espejando la hoja AUDITORIA_ADMIN.
--    La tabla mos.auditoria_admin (49_mos_autorizacion_f0.sql) tiene columnas snake; se mapean a las claves
--    que el panel consume. Se incluyen las columnas equivalentes a la hoja: idAccion, fecha, accion,
--    refDocumento, idPersonalAutoriza, nombreAutoriza, rolAutoriza, nivelAutoriza, appOrigen, dispositivo,
--    tier, deviceId, detalle. (cliente_meta se emite como objeto jsonb por completitud; el front lo ignora.)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.auditoria_admin_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_accion text := upper(nullif(btrim(coalesce(p->>'accion','')), ''));
  v_app    text := lower(nullif(btrim(coalesce(p->>'appOrigen','')), ''));
  v_limit  int  := greatest(1, coalesce((p->>'limit')::int, 100));
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(obj), '[]'::jsonb) into v_arr from (
    select jsonb_build_object(
      'idAccion',           coalesce(a.id_accion,''),
      'fecha',              mos._iso_z(a.fecha),
      'accion',             coalesce(a.accion,''),
      'refDocumento',       coalesce(a.ref_documento,''),
      'idPersonalAutoriza', coalesce(a.id_personal_autoriza,''),
      'nombreAutoriza',     coalesce(a.nombre_autoriza,''),
      'rolAutoriza',        coalesce(a.rol_autoriza,''),
      'nivelAutoriza',      coalesce(a.nivel_autoriza, 0),
      'appOrigen',          coalesce(a.app_origen,''),
      'dispositivo',        coalesce(a.dispositivo,''),
      'tier',               coalesce(a.tier, 0),
      'deviceId',           coalesce(a.device_id,''),
      'clienteMeta',        coalesce(a.cliente_meta, '{}'::jsonb),
      'detalle',            coalesce(a.detalle,'')
    ) as obj
    from mos.auditoria_admin a
    where (v_accion is null or upper(coalesce(a.accion,'')) = v_accion)
      and (v_app    is null or lower(coalesce(a.app_origen,'')) = v_app)
    order by a.fecha desc nulls last
    limit v_limit
  ) s;
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $fn$;
revoke all on function mos.auditoria_admin_lista(jsonb) from public;
grant execute on function mos.auditoria_admin_lista(jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) mos.auditoria_integridad_lista(p) → getAuditoriaIntegridad SOLO MODO LECTURA (sin run=true).
--    ⚠️ NO ejecuta ninguna auditoría (eso es auditarIntegridadProductos, que ESCRIBE — fuera de alcance).
--    Devuelve alertas activas de mos.alertas_log: tipo IN ('AUDIT_INTEGRIDAD','MOD_NO_AUTORIZADA') y NO leídas.
--    En la sombra (04_schema_mos.sql:216) `leida` es boolean → "no leída" = leida IS NOT TRUE (GAS comparaba
--    el text contra '1'; acá la sombra ya es boolean). `datos` es text-JSON en la hoja → se intenta parsear a
--    jsonb (igual que GAS hace JSON.parse, con fallback {}). Shape: { alertas:[{idAlerta,tipo,urgencia,mensaje,
--    fecha,appOrigen,datos}], ultimaAuditoriaLimpia:null }.
--    ⚠️ ultimaAuditoriaLimpia: en GAS sale de PropertiesService (AUDIT_ULTIMA_LIMPIA). No hay sombra de esa
--      property → se devuelve null. GAP DOCUMENTADO (ver análisis). El front lo trata como "—"/sin dato.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.auditoria_integridad_lista(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_alertas jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idAlerta',  coalesce(l.id,''),
    'tipo',      coalesce(l.tipo,''),
    'urgencia',  coalesce(l.urgencia,''),
    'mensaje',   coalesce(l.mensaje,''),
    'fecha',     mos._iso_z(l.fecha),
    'appOrigen', coalesce(l.app_origen,''),
    'datos',     mos._json_safe(l.datos)   -- text JSON → jsonb tolerante (fallback {} si no parsea)
  ) order by l.fecha desc nulls last), '[]'::jsonb) into v_alertas
  from mos.alertas_log l
  where l.tipo in ('AUDIT_INTEGRIDAD','MOD_NO_AUTORIZADA')
    and coalesce(l.leida, false) is not true;
  return jsonb_build_object('ok',true,'data',
    jsonb_build_object('alertas', v_alertas, 'ultimaAuditoriaLimpia', null)) || v_fr;
end; $fn$;
revoke all on function mos.auditoria_integridad_lista(jsonb) from public;
grant execute on function mos.auditoria_integridad_lista(jsonb) to authenticated, service_role;
