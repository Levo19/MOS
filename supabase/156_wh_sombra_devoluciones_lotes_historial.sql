-- 156_wh_sombra_devoluciones_lotes_historial.sql
-- ============================================================
-- [WH MIGRACIÓN · SOMBRA] Tablas faltantes: DEVOLUCIONES_ZONA + LOTES_HISTORIAL
-- ------------------------------------------------------------
-- Hasta hoy estas dos hojas NO tenían sombra Supabase (ni spec de sync ni dual-write).
-- Para completar la migración 100% se crean las tablas wh.* + RPCs de lectura idempotentes.
-- El dual-write desde GAS se cablea aparte (MigracionWH._WH_SPECS + puntos de escritura).
--
-- DISEÑO:
--  · wh.devoluciones_zona  → 1 fila por devolución (PK id_devolucion). UPSERT idempotente.
--      Espeja la hoja DEVOLUCIONES_ZONA (header _DEVZONA_HEADERS en DevolucionesZona.gs).
--      Los 3 payloads JSON se guardan como jsonb (no text) para poder consultarlos server-side.
--  · wh.lotes_historial    → log append-only de movimientos de lote (CONSUMO/INSERT/UPDATE/ANULA).
--      La hoja LOTES_HISTORIAL no tiene PK natural (solo ts+idLote+...). Se le da un id_hist
--      DETERMINISTA = md5(ts|idLote|codigoProducto|idGuia|accion|cantidad) → re-sync NO duplica
--      (mismo evento → mismo hash → upsert no-op). GAS arma ese id al dual-write.
--
-- SEGURIDAD: tablas con RLS habilitada (deny-by-default; service_role la salta). Las lecturas
-- van por RPC security definer con gate wh._claim_ok(). 100% aditivo, idempotente (re-correr = no-op).
-- ============================================================

create schema if not exists wh;

-- ── 1) wh.devoluciones_zona ─────────────────────────────────────────────────
create table if not exists wh.devoluciones_zona (
  id_devolucion            text primary key,
  fecha_inicio             timestamptz,
  zona_origen              text,
  vendedor                 text,
  id_dispositivo_origen    text,
  fecha_recepcion          timestamptz,
  operador_almacen         text,
  id_dispositivo_wh        text,
  estado                   text,            -- EN_TRANSITO | RECEPCIONADO | RECONCILIADO | ANULADA
  payload_zona             jsonb,
  payload_almacen          jsonb,
  diferencias_json         jsonb,
  id_guia_ingreso_generada text,
  foto_zona                text,
  foto_almacen             text,
  revisado_por             text,
  fecha_revision           timestamptz,
  nota_admin_mos           text
);
create index if not exists ix_wh_devzona_estado on wh.devoluciones_zona (estado);
create index if not exists ix_wh_devzona_zona   on wh.devoluciones_zona (zona_origen);
create index if not exists ix_wh_devzona_fecha  on wh.devoluciones_zona (fecha_inicio);
alter table wh.devoluciones_zona enable row level security;

-- ── 2) wh.lotes_historial ───────────────────────────────────────────────────
create table if not exists wh.lotes_historial (
  id_hist          text primary key,        -- md5 determinista del evento (GAS lo arma)
  ts               timestamptz,
  id_lote          text,
  cod_producto     text,
  id_guia          text,
  accion           text,                     -- INSERT | UPDATE | CONSUMO | ANULA | ...
  cantidad         numeric,
  motivo           text,
  usuario          text
);
create index if not exists ix_wh_lotehist_lote  on wh.lotes_historial (id_lote);
create index if not exists ix_wh_lotehist_guia  on wh.lotes_historial (id_guia);
create index if not exists ix_wh_lotehist_ts    on wh.lotes_historial (ts);
alter table wh.lotes_historial enable row level security;

grant select, insert, update on wh.devoluciones_zona to service_role;
grant select, insert, update on wh.lotes_historial   to service_role;


-- ═══════════════════════════════════════════════════════════════════════════
-- RPCs DE LECTURA (security definer · gate wh._claim_ok · shape {ok,data} camelCase)
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) wh.get_devoluciones_zona(p { estado?(csv), zonaOrigen?, limit? })
create or replace function wh.get_devoluciones_zona(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_est   text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_zona  text := nullif(btrim(coalesce(p->>'zonaOrigen','')), '');
  v_lim   int  := least(greatest(coalesce((p->>'limit')::int, 200), 1), 2000);
  v_ests  text[];
  v_data  jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_est is not null then v_ests := (select array_agg(btrim(x)) from unnest(string_to_array(v_est,',')) x); end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t."fechaInicio" desc nulls last), '[]'::jsonb)
    into v_data
  from (
    select id_devolucion        as "idDevolucion",
           fecha_inicio          as "fechaInicio",
           zona_origen           as "zonaOrigen",
           vendedor              as "vendedor",
           id_dispositivo_origen as "idDispositivoOrigen",
           fecha_recepcion       as "fechaRecepcion",
           operador_almacen      as "operadorAlmacen",
           id_dispositivo_wh     as "idDispositivoWH",
           estado                as "estado",
           payload_zona          as "payload_zona",
           payload_almacen       as "payload_almacen",
           diferencias_json      as "diferenciasJson",
           id_guia_ingreso_generada as "idGuiaIngresoGenerada",
           foto_zona             as "fotoZona",
           foto_almacen          as "fotoAlmacen",
           revisado_por          as "revisadoPor",
           fecha_revision        as "fechaRevision",
           nota_admin_mos        as "notaAdminMOS"
    from wh.devoluciones_zona
    where (v_ests is null or estado = any(v_ests))
      and (v_zona is null or zona_origen = v_zona)
    order by fecha_inicio desc nulls last
    limit v_lim
  ) t;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function wh.get_devoluciones_zona(jsonb) from public;
grant execute on function wh.get_devoluciones_zona(jsonb) to service_role, authenticated;

-- 2) wh.get_historial_lote(p { idLote (req) })  — historial de UN lote, FIFO desc por ts.
create or replace function wh.get_historial_lote(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_lote text := nullif(btrim(coalesce(p->>'idLote','')), '');
  v_data jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_lote is null then return jsonb_build_object('ok',false,'error','idLote requerido'); end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.ts desc nulls last), '[]'::jsonb)
    into v_data
  from (
    select ts, id_lote as "idLote", cod_producto as "codigoProducto", id_guia as "idGuia",  -- ts conserva nombre para el order

           accion, cantidad, motivo, usuario
    from wh.lotes_historial
    where id_lote = v_lote
    order by ts desc nulls last
  ) t;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function wh.get_historial_lote(jsonb) from public;
grant execute on function wh.get_historial_lote(jsonb) to service_role, authenticated;
