-- ============================================================
-- 89_me_presencia_mensajeria.sql — EXTENSIÓN de me.presencia (presencia + base de mensajería)
-- ============================================================
-- OBJETIVO: unificar la PRESENCIA del login (88_me_presencia.sql) con la BASE de
--   una futura mensajería dirigida (admin/cajero ↔ vendedor). En esta tanda SOLO
--   sentamos la base de datos: por cada persona presente queremos saber TAMBIÉN
--   a qué dispositivo (device_id) y a qué token FCM (push_token) mandarle, y a qué
--   hora ENTRÓ al turno (ingreso). El envío real de mensajes es una fase siguiente.
--
-- ADITIVO / NO ROMPE NADA:
--   · ALTER ADD COLUMN IF NOT EXISTS (no rompe filas existentes ni el 88).
--   · registrar_presencia + presencia_por_zona se reemplazan con create or replace,
--     manteniendo gate (me.jwt_app()='mosExpress'), security definer, search_path=''
--     e idempotencia por id_personal. Solo SUMAN campos al jsonb de entrada/salida.
--   · No toca me.cajas, ventas, ni el login v2.8.9.
--
-- NOTA — ingreso (hora de entrada):
--   last_seen ya es la "última actividad" (pulso). ingreso es DISTINTO: la hora del
--   PRIMER pulso del turno. Se setea una vez con coalesce(ingreso, now()) y NO se pisa
--   en los heartbeats siguientes. (Si la persona se va y vuelve >TTL, la fila sigue;
--   el "reinicio de turno" formal será de la fase de mensajería/turnos, no de acá.)
-- ============================================================

-- ───────────────────────────────────────────────────────────────────────────
-- 1) EXTENDER me.presencia — columnas aditivas para mensajería.
--    device_id  : el deviceId del dispositivo (mismo que mos.dispositivos / PUSH_TOKENS).
--    push_token : token FCM activo de ESTE dispositivo (de _pushInit en el front).
--    ingreso    : hora de entrada al turno (1er pulso). last_seen = última actividad.
-- ───────────────────────────────────────────────────────────────────────────
alter table me.presencia add column if not exists device_id  text;
alter table me.presencia add column if not exists push_token text;
alter table me.presencia add column if not exists ingreso    timestamptz;

-- Índice opcional por device_id (cruce con mos.dispositivos / lookup de envío).
create index if not exists idx_me_presencia_device
  on me.presencia (device_id);

-- ───────────────────────────────────────────────────────────────────────────
-- 2) me.registrar_presencia(p jsonb) — pulso idempotente + base de mensajería.
--    Nuevos campos aceptados en p: device_id, push_token (ambos texto, opcionales).
--    · ingreso    = coalesce(ingreso_actual, now())  → se fija UNA vez (1er pulso),
--                   NO se resetea en heartbeats.
--    · device_id / push_token / last_seen → SÍ se refrescan en cada pulso (el token
--      puede llegar tarde: el 1er pulso quizá lo manda vacío y un pulso posterior lo
--      completa cuando _pushInit terminó).
--    p = { id_personal, nombre, zona, estacion, rol, device_id?, push_token? }
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.registrar_presencia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id        text := btrim(coalesce(p->>'id_personal',''));
  v_nombre    text := coalesce(p->>'nombre','');
  v_zona      text := coalesce(p->>'zona','');
  v_estacion  text := coalesce(p->>'estacion','');
  v_rol       text := lower(btrim(coalesce(nullif(p->>'rol',''),'vendedor')));
  -- device_id / push_token: NULL si no vienen (no pisamos un token bueno con '').
  v_device    text := nullif(btrim(coalesce(p->>'device_id','')),'');
  v_token     text := nullif(btrim(coalesce(p->>'push_token','')),'');
begin
  -- fail-closed: solo tokens de ME (la PWA). Cualquier otro claim → rechazo.
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- id_personal es obligatorio (es la PK / identidad del pulso).
  if v_id = '' then
    return jsonb_build_object('ok', false, 'error', 'id_personal requerido');
  end if;

  insert into me.presencia (id_personal, nombre, zona, estacion, rol,
                            device_id, push_token, ingreso, last_seen)
  values (v_id, v_nombre, v_zona, v_estacion, v_rol,
          v_device, v_token, now(), now())
  on conflict (id_personal) do update
    set nombre     = excluded.nombre,
        zona       = excluded.zona,
        estacion   = excluded.estacion,
        rol        = excluded.rol,
        -- device_id / push_token: refrescar SOLO si llega un valor nuevo no vacío;
        -- si el pulso no trae token (push aún no listo), conservar el que había.
        device_id  = coalesce(excluded.device_id,  me.presencia.device_id),
        push_token = coalesce(excluded.push_token, me.presencia.push_token),
        -- ingreso: se fija una sola vez (1er pulso del turno), NO se pisa.
        ingreso    = coalesce(me.presencia.ingreso, excluded.ingreso),
        last_seen  = now();

  return jsonb_build_object('ok', true, 'id_personal', v_id, 'last_seen', now());
end;
$fn$;
revoke all on function me.registrar_presencia(jsonb) from public;
grant execute on function me.registrar_presencia(jsonb) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- 3) me.presencia_por_zona() — igual que el 88, pero ahora EXPONE 'ingreso'
--    (hora de entrada) por vendedor, para que el login/admin lo muestre.
--    El cajero sigue viniendo de me.cajas (fuente de verdad); el cajero no tiene
--    fila de ingreso garantizada en presencia (puede pulsar como cajero igual),
--    así que mantenemos su shape como en el 88 (nombre/id_caja/desde).
--    NOTA: NO exponemos push_token/device_id en este endpoint público del login
--    (son base de mensajería, no info de UI). La fase de mensajería los leerá
--    server-side por su propia RPC.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.presencia_por_zona()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with guard as (select me.jwt_app() = 'mosExpress' as ok),
  -- cajero por zona: caja ABIERTA más reciente de cada zona (fuente de verdad)
  cajero as (
    select distinct on (c.zona_id)
           c.zona_id,
           c.vendedor as cajero_nombre,
           c.id_caja,
           c.fecha_apertura as desde
    from me.cajas c, guard g
    where g.ok and c.estado = 'ABIERTA' and coalesce(c.zona_id,'') <> ''
    order by c.zona_id, c.fecha_apertura desc
  ),
  -- vendedores presentes (TTL 2 min), excluyendo al cajero de su propia zona (por nombre)
  vend as (
    select pr.zona,
           jsonb_agg(jsonb_build_object(
             'id_personal', pr.id_personal,
             'nombre',      pr.nombre,
             'estacion',    pr.estacion,
             'desde',       to_char(pr.last_seen at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
             'ingreso',     case when pr.ingreso is not null
                                 then to_char(pr.ingreso at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
                                 else null end
           ) order by pr.nombre) as lista
    from me.presencia pr
    cross join guard g
    left join cajero ca on ca.zona_id = pr.zona
    where g.ok
      and pr.last_seen > now() - interval '2 minutes'   -- TTL: viejos no aparecen
      and coalesce(pr.zona,'') <> ''
      and lower(btrim(pr.nombre)) is distinct from lower(btrim(coalesce(ca.cajero_nombre,'')))
    group by pr.zona
  ),
  -- todas las zonas que aparecen (con cajero, con vendedores, o ambas)
  zonas as (
    select zona_id from cajero
    union
    select zona from vend
  )
  select coalesce(
    (select jsonb_object_agg(
       z.zona_id,
       jsonb_build_object(
         'zona_id',     z.zona_id,
         'zona_nombre', coalesce(mz.nombre, z.zona_id),
         'cajero', case when ca.zona_id is not null then jsonb_build_object(
                          'nombre',  ca.cajero_nombre,
                          'id_caja', ca.id_caja,
                          'desde',   to_char(ca.desde at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
                        ) else null end,
         'vendedores', coalesce(vd.lista, '[]'::jsonb)
       )
     )
     from zonas z
     left join cajero ca on ca.zona_id = z.zona_id
     left join vend   vd on vd.zona     = z.zona_id
     left join mos.zonas mz on mz.id_zona = z.zona_id
     where (select ok from guard)
    ),
    '{}'::jsonb
  );
$fn$;
revoke all on function me.presencia_por_zona() from public;
grant execute on function me.presencia_por_zona() to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- 4) STUB documentado (NO cableado) — me.enviar_mensaje (fase siguiente).
--    La base ya está: presencia tiene device_id + push_token + ingreso por persona,
--    y se refrescan en cada pulso. Cuando se implemente la mensajería:
--
--      create or replace function me.enviar_mensaje(p jsonb) returns jsonb ...
--        -- gate me.jwt_app()='mosExpress', security definer, search_path=''
--        -- p = { para_id_personal | para_zona, titulo, cuerpo, ... }
--        -- 1) resolver destinatarios: select push_token, device_id from me.presencia
--        --    where (id_personal = p->>'para_id_personal' OR zona = p->>'para_zona')
--        --      and last_seen > now() - interval '2 minutes'  (solo presentes)
--        --      and push_token is not null;
--        -- 2) persistir el mensaje en una tabla me.mensajes (a crear) para historial.
--        -- 3) el ENVÍO FCM real lo hace GAS (tiene la server key de proyectomos-push):
--        --    esta RPC NO llama a FCM; deja el mensaje + tokens listos y un trigger/cron
--        --    o un pull de GAS hace el push (igual patrón que el resto del ecosistema).
--    NO se crea nada de esto ahora — solo queda anotado para la próxima tanda.
-- ───────────────────────────────────────────────────────────────────────────
