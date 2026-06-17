-- 132_riz_wrappers_mos.sql — [RIZ · CAPA 4 · WRAPPERS mos.* PARA LAS 7 RPCs RIZ] — INERTE (gate módulo OFF)
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md.
--
-- ── POR QUÉ ESTE ARCHIVO ────────────────────────────────────────────────────────────────────────────────────
--   Las RPCs RIZ se definieron en el esquema `me` (supabase/128/129/131). Pero el frontend MOS llama a PostgREST
--   con el perfil de esquema 'mos' (Accept-Profile/Content-Profile = 'mos'), que es el ÚNICO esquema-app que
--   PostgREST tiene expuesto para MOS. Las funciones `me.*` NO son alcanzables vía RPC con profile 'mos'
--   (PostgREST resuelve el nombre de la función dentro del esquema del perfil). El patrón YA establecido en prod
--   es WRAPPEAR la función `me.*` con una `mos.*` homónima (ej. mos.me_creditos_pendientes → me.creditos_pendientes,
--   supabase/124). Aquí se replica ese patrón para las 7 RPCs RIZ que el frontend consume.
--
-- ── PATRÓN (idéntico a mos.me_creditos_pendientes, 124) ─────────────────────────────────────────────────────
--   security definer · set search_path='' · gate mos._claim_ok() (app='MOS' o service_role/GAS) ·
--   grants revoke public + service_role, authenticated. El cuerpo SOLO hace `return me.<misma>(p);` (pass-through
--   puro). La función `me.*` interna re-evalúa su propio gate mos._claim_ok() (doble-gate inocuo) y emite el
--   shape final {ok, data, _fresh...}; el wrapper lo devuelve TAL CUAL (no re-envuelve → no rompe el shape).
--   Como `me.*` corre dentro de un DEFINER mos.* propiedad del owner (service_role), hereda acceso a me.*/wh.*.
--
-- ── INERTE ──────────────────────────────────────────────────────────────────────────────────────────────────
--   El módulo RIZ del frontend está gated OFF (flag `mos_zona_modulo`, default OFF). Con el flag OFF el nav está
--   oculto y loadZona() nunca se invoca → estos wrappers NUNCA se llaman. Definirlos no cambia el comportamiento
--   de hoy. No toca flags/sync/GAS/cerrar_guia ni ninguna RPC de dinero.
--
-- ── SHAPE DE CADA WRAPPER (= el de la me.* envuelta; confirmado contra el SQL fuente) ───────────────────────
--   mos.zona_panel(p {zona, filtro?})        → {ok, data:{zona, filtro, items:[{skuBase, descripcion, stockZona,
--                                                esperada, brecha, stockAlmacen, tendencia, bcg, picos[],
--                                                vencimientoProximo:{fecha,dias}|null, countLotes}]}, _fresh...}
--   mos.tendencia_zona(p {zona, skuBase?, semanas?}) → {ok, data:{zona, semanas, umbral, items:[{skuBase, picos[],
--                                                picoUltima, volumen, pendiente, tendencia, bcg}]}, _fresh...}
--   mos.zona_ticket_dia(p {zona, fecha})     → {ok, data:{zona, fecha, origen, lotes:[{loteDia, estado, items[]}]}, _fresh...}
--   mos.zona_lotes_historial(p {zona, skuBase}) → {ok, data:{zona, skuBase, totalRestante, vencimientoProximo|null,
--                                                items:[{idLote, fechaIngreso, fechaVencimiento, diasRestantes,
--                                                cantIngresada, cantRestante, idGuiaOrigen, estado}]}, _fresh...}
--   mos.zona_ajustar_stock(p {zona, skuBase, nuevo, usuario?, localId?, codBarras?}) → {ok, [dedup], data:{...}}
--   mos.zona_pedir_almacen(p {zona, items:[{skuBase,cantidad}], usuario?, localId?}) → {ok, [dedup], data:{idPickup,...}}
--   mos.zona_lista_compras(p {zona, semana}) → {ok, data:{zona, semana, items[], totalItems, unidades, upserted}}
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;


-- ── 1) LECTURA: panel (cards del módulo) ────────────────────────────────────────────────────────────────────
create or replace function mos.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_panel(p);
end;
$fn$;
revoke all on function mos.zona_panel(jsonb) from public;
grant execute on function mos.zona_panel(jsonb) to service_role, authenticated;


-- ── 2) LECTURA: tendencia por zona ──────────────────────────────────────────────────────────────────────────
create or replace function mos.tendencia_zona(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.tendencia_zona(p);
end;
$fn$;
revoke all on function mos.tendencia_zona(jsonb) from public;
grant execute on function mos.tendencia_zona(jsonb) to service_role, authenticated;


-- ── 3) LECTURA: ticket/lote del día ─────────────────────────────────────────────────────────────────────────
create or replace function mos.zona_ticket_dia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_ticket_dia(p);
end;
$fn$;
revoke all on function mos.zona_ticket_dia(jsonb) from public;
grant execute on function mos.zona_ticket_dia(jsonb) to service_role, authenticated;


-- ── 4) LECTURA: historial de lotes FIFO ─────────────────────────────────────────────────────────────────────
create or replace function mos.zona_lotes_historial(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_lotes_historial(p);
end;
$fn$;
revoke all on function mos.zona_lotes_historial(jsonb) from public;
grant execute on function mos.zona_lotes_historial(jsonb) to service_role, authenticated;


-- ── 5) ACCIÓN: ajustar stock de zona (escritura) ───────────────────────────────────────────────────────────
create or replace function mos.zona_ajustar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_ajustar_stock(p);
end;
$fn$;
revoke all on function mos.zona_ajustar_stock(jsonb) from public;
grant execute on function mos.zona_ajustar_stock(jsonb) to service_role, authenticated;


-- ── 6) ACCIÓN: pedir a almacén (escritura, crea pickup) ─────────────────────────────────────────────────────
create or replace function mos.zona_pedir_almacen(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_pedir_almacen(p);
end;
$fn$;
revoke all on function mos.zona_pedir_almacen(jsonb) from public;
grant execute on function mos.zona_pedir_almacen(jsonb) to service_role, authenticated;


-- ── 7) ACCIÓN: lista de compras externa (escritura, materializa) ────────────────────────────────────────────
create or replace function mos.zona_lista_compras(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_lista_compras(p);
end;
$fn$;
revoke all on function mos.zona_lista_compras(jsonb) from public;
grant execute on function mos.zona_lista_compras(jsonb) to service_role, authenticated;
