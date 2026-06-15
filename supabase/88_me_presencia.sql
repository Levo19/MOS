-- ============================================================
-- 88_me_presencia.sql — PRESENCIA de vendedores para el login de MosExpress (ME)
-- ============================================================
-- OBJETIVO: que el wizard de login muestre, EN VIVO y por zona:
--   · el CAJERO real (fuente de verdad = me.cajas ABIERTA, server-side), y
--   · los VENDEDORES presentes (pulso/heartbeat del front → me.presencia).
--
-- MODELO DE ACCESO (confirmado en el código real):
--   ME habla DIRECTO a Supabase (PostgREST /rest/v1/rpc/...) con un JWT scoped
--   minteado por GAS (Fase2Auth.gs:mintSupabaseToken), claim app='mosExpress',
--   role='authenticated'. El gate de toda RPC de ME es me.jwt_app()='mosExpress'
--   (ver 16_fase2_rls_ventas_zona.sql). service_role/GAS (claim '') NO se gatea acá
--   porque estas RPCs son exclusivas de la PWA — usamos el gate estricto = 'mosExpress'
--   igual que ventas_hoy_zona_auth (que es el patrón vivo de ME directo).
--
-- ZONA = zona_id (ej. 'ZONA-02'). CONFIRMADO:
--   · me.cajas.zona_id guarda el id de zona ('ZONA-02').
--   · El front (index.html) indexa wizCajerosActivosPorZona[Zona_ID]; zonasUnicas
--     son Zona_ID. Por eso presencia_por_zona devuelve un objeto keyed por zona_id,
--     para que el wizard lo consuma idéntico al porZona de cajeros_activos_todos.
--   · Se hace LEFT JOIN a mos.zonas para devolver también el nombre legible.
--
-- ADITIVO / NO ROMPE NADA: tabla nueva + 2 RPCs nuevas. No toca cajas, ventas,
-- ni el login actual. El front lo cableará en la próxima tanda.
-- ============================================================

-- ───────────────────────────────────────────────────────────────────────────
-- 1) Tabla me.presencia — una fila por persona (PK id_personal). Al cambiar de
--    zona, se ACTUALIZA la fila (upsert) — un vendedor está en una zona a la vez.
--    last_seen = pulso; el TTL (lectura) decide quién sigue "presente".
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists me.presencia (
  id_personal text primary key,
  nombre      text not null default '',
  zona        text not null default '',     -- zona_id (ej. 'ZONA-02')
  estacion    text not null default '',
  rol         text not null default 'vendedor',
  last_seen   timestamptz not null default now()
);

-- Índice para la lectura por zona + recencia (TTL).
create index if not exists idx_me_presencia_zona_seen
  on me.presencia (zona, last_seen desc);

-- RLS defensiva: nadie toca la tabla directo por PostgREST; todo va por las RPCs
-- security definer. (authenticated NO recibe grants de tabla → no puede leer/escribir
-- la tabla cruda; solo ejecutar las funciones de abajo.)
alter table me.presencia enable row level security;
revoke all on table me.presencia from anon, authenticated;
grant all on table me.presencia to service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- 2) me.registrar_presencia(p jsonb) — "pulso" idempotente del vendedor.
--    Lo llama el front al ENTRAR y cada ~60s mientras está logueado.
--    Gate: claim app='mosExpress' (fail-closed). Upsert por id_personal:
--    misma persona 2x → 1 fila, last_seen=now() y zona/estacion actualizadas.
--    p = { id_personal, nombre, zona, estacion, rol }  (todos texto)
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
begin
  -- fail-closed: solo tokens de ME (la PWA). Cualquier otro claim → rechazo.
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- id_personal es obligatorio (es la PK / identidad del pulso).
  if v_id = '' then
    return jsonb_build_object('ok', false, 'error', 'id_personal requerido');
  end if;

  insert into me.presencia (id_personal, nombre, zona, estacion, rol, last_seen)
  values (v_id, v_nombre, v_zona, v_estacion, v_rol, now())
  on conflict (id_personal) do update
    set nombre    = excluded.nombre,
        zona      = excluded.zona,
        estacion  = excluded.estacion,
        rol       = excluded.rol,
        last_seen = now();

  return jsonb_build_object('ok', true, 'id_personal', v_id, 'last_seen', now());
end;
$fn$;
revoke all on function me.registrar_presencia(jsonb) from public;
grant execute on function me.registrar_presencia(jsonb) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- 3) me.presencia_por_zona() — vista combinada para el wizard.
--    · CAJERO: SIEMPRE de me.cajas ABIERTA (server-side, fuente de verdad). NO
--      de presencia. 1 cajero por zona (el de la caja abierta más reciente).
--    · VENDEDORES: de me.presencia con last_seen > now()-2min (TTL). Se excluye
--      del listado de vendedores a quien sea el cajero de esa zona (mismo nombre),
--      para no duplicarlo. (No tenemos id_personal en cajas → match por nombre.)
--    Salida keyed por zona_id, consumible igual que porZona de cajeros_activos_todos:
--      { "ZONA-02": { zona_id, zona_nombre,
--                     cajero: {nombre, id_caja, desde} | null,
--                     vendedores: [ {id_personal, nombre, estacion, desde} ] } }
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
             'desde',       to_char(pr.last_seen at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
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
-- 4) Limpieza (opcional): el TTL en la lectura ya descarta lo viejo, así que un
--    purge no es crítico. Función de mantenimiento por si se quiere correr suelta
--    o vía pg_cron (no se programa cron acá; aditivo e inerte).
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.purgar_presencia_vieja()
returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_n integer;
begin
  delete from me.presencia where last_seen < now() - interval '10 minutes';
  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;
revoke all on function me.purgar_presencia_vieja() from public;
grant execute on function me.purgar_presencia_vieja() to service_role;
