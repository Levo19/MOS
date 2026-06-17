-- 134_riz_enviar_revision.sql — [RIZ · ACCIÓN ADMIN · "ENVIAR A REVISIÓN" DE STOCK DE ZONA] — INERTE
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md.
--
-- ── REGLA DEL DUEÑO ─────────────────────────────────────────────────────────────────────────────────────────
--   "El stock es el stock; si está negativo, muestra el producto con su stock de zona tal cual (aunque esté
--    mal/negativo). El admin puede ajustar o mandar a revisión ese producto a cajero/vendedor por medio de ME."
--   ⇒ El panel (me.zona_panel, 128) YA muestra granel y negativos SIN filtrarlos (universo = esperado ∪ stock de
--      la zona; no hay predicado `>0`; el filtro 'BRECHA' es opt-in). VERIFICADO en prod: ZONA-01 devuelve 122
--      items, 11 con stockZona<0 (incl. granel LEV024 = -17.5). No se toca el panel.
--   ⇒ Este archivo agrega SOLO la acción "enviar a revisión": el admin marca un producto de la zona para que el
--      cajero/vendedor de ESA zona lo revise (recontar / explicar el negativo) desde ME.
--
-- ── CANAL HACIA ME (reusa el que ya existe + tabla estructurada) ────────────────────────────────────────────
--   ME ya tiene un canal de notificación dirigido por ZONA: me.mensajes (92_me_mensajeria.sql), que la PWA de ME
--   POLLEA vía me.mis_mensajes(p {id_personal, zona}) (destino_tipo='zona') y por el que GAS dispara push FCM.
--   Esta RPC:
--     1) INSERTA una fila ESTRUCTURADA en me.zona_revision_stock (cola de tareas de revisión, con estado +
--        stock_actual + motivo) que ME puede listar/cerrar como TAREA (más rico que un texto suelto).
--     2) Inserta TAMBIÉN un me.mensajes destino_tipo='zona' (titulo/cuerpo) para que el cajero/vendedor lo VEA
--        de inmediato en el inbox que la PWA ya pollea (visibilidad sin esperar UI nueva). Doble salida: la cola
--        estructurada (para gestionarla) + el aviso in-app/push (para enterarse ya).
--   Si en el futuro ME quiere SOLO la cola estructurada, basta dejar de leer el mensaje; ambos son aditivos.
--
-- ── INERTE ──────────────────────────────────────────────────────────────────────────────────────────────────
--   La tabla + RPCs existen con grant, pero NADIE las llama: el módulo RIZ del frontend está gated OFF
--   (flag `mos_zona_modulo`). Crear esto NO cambia el comportamiento de hoy. NO toca flags/sync/GAS/api.js/
--   version/sw, ni ninguna RPC de dinero. Idempotente (create table if not exists / create or replace).
--
-- ── PATRÓN RPC (idéntico al resto: 129/132) ─────────────────────────────────────────────────────────────────
--   security definer · set search_path='' · gate mos._claim_ok() · shape {ok:true,data:...} camelCase ·
--   revoke public + grant service_role, authenticated. La tabla: RLS habilitado sin políticas (service_role
--   bypassa; las RPCs definer escriben/leen como owner; anon/authenticated sin grant a la tabla → doble bloqueo).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- TABLA me.zona_revision_stock — cola de solicitudes de revisión de stock por (zona, sku).
--   estado: PENDIENTE | REVISADO | DESCARTADO. La idempotencia "1 solicitud abierta por (zona,sku)" se hace con
--   un índice único PARCIAL sobre estado='PENDIENTE' (reenviar mientras hay una abierta = upsert, no duplica).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_revision_stock (
  id             bigserial primary key,
  zona_id        text not null,
  sku_base       text not null,
  cod_barras     text,                          -- código concreto sobre el que se mide el stock (canónico del sku)
  descripcion    text,
  stock_actual   numeric,                       -- stock de zona al momento de mandar a revisión (puede ser <0 / granel)
  motivo         text,                          -- texto libre del admin (ej. "stock negativo, recontar")
  estado         text not null default 'PENDIENTE',  -- PENDIENTE | REVISADO | DESCARTADO
  solicitado_por text,
  resuelto_por   text,
  resuelto_nota  text,
  mensaje_id     bigint,                         -- enlace al me.mensajes (aviso in-app) generado, si lo hubo
  ts             timestamptz default now(),
  resuelto_ts    timestamptz,
  constraint me_zona_revision_estado_chk check (estado in ('PENDIENTE','REVISADO','DESCARTADO'))
);
create index if not exists ix_riz_revision_zona_estado on me.zona_revision_stock (zona_id, estado);
-- una sola solicitud ABIERTA por (zona, sku): mientras esté PENDIENTE, reenviar la actualiza (no duplica).
create unique index if not exists ux_riz_revision_abierta
  on me.zona_revision_stock (zona_id, sku_base) where estado = 'PENDIENTE';

alter table me.zona_revision_stock enable row level security;
grant all on me.zona_revision_stock to service_role;
grant usage, select on sequence me.zona_revision_stock_id_seq to service_role;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) me.zona_enviar_revision(p jsonb { zona (req), skuBase (req), motivo?, usuario? })
--    Registra/actualiza una solicitud de revisión PENDIENTE para (zona, sku) + deja un me.mensajes a la zona.
--    El stock_actual se LEE en vivo de me.stock_zonas (suma de todas las barras del sku en esa zona) — tal cual,
--    sin filtrar negativos ni granel (regla del dueño). cod_barras = barra del canónico del sku (informativo).
--    Idempotente: si ya hay una solicitud PENDIENTE para (zona,sku) → la actualiza (refresca stock/motivo/ts) y
--    NO crea un segundo mensaje (devuelve dedup:true). Devuelve la solicitud + idMensaje.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_enviar_revision(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_motivo text := nullif(btrim(coalesce(p->>'motivo','')), '');
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_cb     text;
  v_desc   text;
  v_stock  numeric;
  v_existe bigint;
  v_id     bigint;
  v_mid    bigint;
  v_titulo text;
  v_cuerpo text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y skuBase');
  end if;

  -- barra del canónico + descripción del sku (informativo; preferir base factor1/sin-base).
  select upper(btrim(pr.codigo_barra)), pr.descripcion
    into v_cb, v_desc
  from mos.productos pr
  where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku
  order by (case when coalesce(pr.codigo_producto_base,'')='' and coalesce(pr.factor_conversion,1)=1 then 0 else 1 end), pr.id_producto
  limit 1;

  -- stock de ESA zona por el sku (suma de TODAS sus barras): tal cual, incluido negativo / granel.
  select coalesce(sum(coalesce(z.cantidad,0)),0) into v_stock
  from me.stock_zonas z
  join (
    select distinct on (cb) cb, sku from (
      select upper(btrim(p2.codigo_barra)) cb, coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, 0 ord
        from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)), e.sku_base, 1
        from mos.equivalencias e where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t order by cb, ord
  ) cs on cs.cb = upper(btrim(z.cod_barras))
  where upper(btrim(z.zona_id)) = v_zona and cs.sku = v_sku;

  -- ¿ya hay una solicitud PENDIENTE para (zona,sku)? → upsert (no duplica, no re-notifica).
  select id, mensaje_id into v_existe, v_mid
  from me.zona_revision_stock
  where zona_id = v_zona and sku_base = v_sku and estado = 'PENDIENTE'
  limit 1;

  if found then
    update me.zona_revision_stock set
      cod_barras = coalesce(v_cb, cod_barras),
      descripcion = coalesce(v_desc, descripcion),
      stock_actual = v_stock,
      motivo = coalesce(v_motivo, motivo),
      solicitado_por = coalesce(v_user, solicitado_por),
      ts = now()
    where id = v_existe;
    return jsonb_build_object('ok', true, 'dedup', true, 'data', jsonb_build_object(
      'idRevision', v_existe, 'zona', v_zona, 'skuBase', v_sku, 'codBarras', v_cb,
      'descripcion', v_desc, 'stockActual', v_stock, 'estado', 'PENDIENTE', 'idMensaje', v_mid));
  end if;

  -- aviso a la zona vía el canal existente (me.mensajes destino_tipo='zona'); la PWA de ME lo pollea por
  -- me.mis_mensajes y GAS le dispara push. NO falla la operación si el insert del mensaje fallara.
  v_titulo := 'Revisar stock: ' || coalesce(nullif(v_desc,''), v_sku);
  v_cuerpo := 'Stock actual en tu zona: ' || v_stock::text || ' u. '
              || coalesce(nullif(v_motivo,''), 'Por favor recuenta y confirma.');
  begin
    insert into me.mensajes (remitente, destino_tipo, destino_id, titulo, cuerpo, prioridad)
    values (coalesce(nullif(v_user,''),'Admin') , 'zona', v_zona, v_titulo, v_cuerpo, 'alta')
    returning id into v_mid;
  exception when others then
    v_mid := null;  -- si el canal de mensajes no estuviera disponible, la cola estructurada igual queda registrada
  end;

  insert into me.zona_revision_stock
    (zona_id, sku_base, cod_barras, descripcion, stock_actual, motivo, estado, solicitado_por, mensaje_id, ts)
  values
    (v_zona, v_sku, v_cb, v_desc, v_stock, v_motivo, 'PENDIENTE', v_user, v_mid, now())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idRevision', v_id, 'zona', v_zona, 'skuBase', v_sku, 'codBarras', v_cb,
    'descripcion', v_desc, 'stockActual', v_stock, 'estado', 'PENDIENTE', 'idMensaje', v_mid));
end;
$fn$;
revoke all on function me.zona_enviar_revision(jsonb) from public;
grant execute on function me.zona_enviar_revision(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) me.zona_revisiones(p jsonb { zona (req), estado? (default 'PENDIENTE'|'TODAS') })
--    Lista las solicitudes de revisión de una zona (para que ME las muestre como cola de tareas). estado='TODAS'
--    devuelve cualquier estado; cualquier otro valor filtra por ese estado. Orden: pendientes recientes primero.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_revisiones(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_estado text := upper(btrim(coalesce(nullif(p->>'estado',''),'PENDIENTE')));
  v_data   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'idRevision', r.id, 'skuBase', r.sku_base, 'codBarras', r.cod_barras,
           'descripcion', r.descripcion, 'stockActual', r.stock_actual, 'motivo', r.motivo,
           'estado', r.estado, 'solicitadoPor', r.solicitado_por,
           'ts', to_char(r.ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'resueltoPor', r.resuelto_por, 'resueltoNota', r.resuelto_nota,
           'resueltoTs', case when r.resuelto_ts is not null then to_char(r.resuelto_ts at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') else null end
         ) order by (r.estado='PENDIENTE') desc, r.ts desc), '[]'::jsonb)
    into v_data
  from me.zona_revision_stock r
  where r.zona_id = v_zona
    and (v_estado = 'TODAS' or r.estado = v_estado);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona', v_zona, 'estado', v_estado, 'items', v_data)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_revisiones(jsonb) from public;
grant execute on function me.zona_revisiones(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) me.zona_revision_resolver(p jsonb { idRevision (req), estado ('REVISADO'|'DESCARTADO'), usuario?, nota? })
--    El cajero/vendedor (o admin) cierra una solicitud. Idempotente: si ya está en estado final, devuelve dedup.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_revision_resolver(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     bigint := nullif(btrim(coalesce(p->>'idRevision','')), '')::bigint;
  v_estado text := upper(btrim(coalesce(p->>'estado','REVISADO')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_nota   text := nullif(btrim(coalesce(p->>'nota','')), '');
  v_cur    text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idRevision'); end if;
  if v_estado not in ('REVISADO','DESCARTADO') then v_estado := 'REVISADO'; end if;

  select estado into v_cur from me.zona_revision_stock where id = v_id;
  if not found then return jsonb_build_object('ok',false,'error','idRevision no existe'); end if;
  if v_cur <> 'PENDIENTE' then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idRevision', v_id, 'estado', v_cur));
  end if;

  update me.zona_revision_stock set
    estado = v_estado, resuelto_por = v_user, resuelto_nota = v_nota, resuelto_ts = now()
  where id = v_id;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('idRevision', v_id, 'estado', v_estado));
end;
$fn$;
revoke all on function me.zona_revision_resolver(jsonb) from public;
grant execute on function me.zona_revision_resolver(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- WRAPPERS mos.* (PostgREST profile 'mos' solo alcanza funciones del esquema mos; patrón de 132). Pass-through.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.zona_enviar_revision(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_enviar_revision(p);
end; $fn$;
revoke all on function mos.zona_enviar_revision(jsonb) from public;
grant execute on function mos.zona_enviar_revision(jsonb) to service_role, authenticated;

create or replace function mos.zona_revisiones(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_revisiones(p);
end; $fn$;
revoke all on function mos.zona_revisiones(jsonb) from public;
grant execute on function mos.zona_revisiones(jsonb) to service_role, authenticated;

create or replace function mos.zona_revision_resolver(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_revision_resolver(p);
end; $fn$;
revoke all on function mos.zona_revision_resolver(jsonb) from public;
grant execute on function mos.zona_revision_resolver(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS (honestidad)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) GRANEL / NEGATIVOS: el panel (me.zona_panel) NO los filtra — se muestran tal cual (verificado: ZONA-01 trae
--    122 items, 11 con stockZona<0, incl. granel LEV024=-17.5). No se modificó el panel. Regla del dueño cumplida.
--
-- 2) CANAL ME: se reusa me.mensajes (destino_tipo='zona') que la PWA de ME YA pollea (me.mis_mensajes) y por el
--    que GAS dispara push → el cajero/vendedor se entera de inmediato. ADEMÁS se persiste la solicitud
--    estructurada en me.zona_revision_stock (cola de tareas con estado + stock_actual + motivo) para que ME la
--    gestione (listar PENDIENTES, marcar REVISADO/DESCARTADO). Doble salida aditiva.
--
-- 3) ⚠️ me.mensajes es leído por me.mis_mensajes que exige token de ME (me.jwt_app()='mosExpress'). El INSERT del
--    aviso lo hace esta RPC como definer (owner) → entra sin problema. Solo el cajero (token ME) lo LEE. Para que
--    el cajero vea la cola ESTRUCTURADA (me.zona_revisiones) desde ME haría falta exponer un wrapper en el perfil
--    'mosExpress' o leerla por GAS/service_role — eso es cableo de la tanda de frontend ME (fuera de alcance:
--    aquí dejamos la RPC lista bajo profile 'mos'/service_role). El AVISO in-app (me.mensajes) ya llega a ME hoy.
--
-- 4) INERTE / IDEMPOTENTE: tabla create-if-not-exists; RPCs create-or-replace; índice único parcial evita
--    solicitudes PENDIENTES duplicadas por (zona,sku). Nadie llama estas RPCs (módulo RIZ gated OFF). No toca
--    dinero, flags, sync, GAS, api.js, version, sw.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
