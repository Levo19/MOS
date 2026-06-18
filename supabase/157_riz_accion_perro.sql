-- 157_riz_accion_perro.sql — [RIZ · CAPA 5 · ACCIONES BCG "PERRO": Promocionar / Mover a góndola / Rematar]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- CONTEXTO: en el card de un producto 🐕 PERRO (rotación nula/decreciente + bajo volumen) el frontend mostraba
--   3 botones STUB (toast "Capa 5"). El diseño RIZ es claro: el sistema INFORMA, el admin DECIDE — y la decisión
--   sobre stock muerto (promocionar / reubicar en góndola visible / rematar) NO es una mutación de stock ni de
--   dinero (no se toca me.stock_zonas, no hay guía, no hay caja). Es una DECISIÓN del admin que conviene:
--     (a) PERSISTIR (auditable: quién, cuándo, qué decidió) y
--     (b) que el panel/sugerencias la REFLEJEN (el card "perro" ya tiene una acción tomada).
--   Cross-zone transfer queda DESCARTADO a propósito: el diseño RIZ prohíbe zona↔zona (solo zona↔almacén) para
--   evitar disputas; "mover a góndola" = reubicar DENTRO de la zona (decisión, no traslado de inventario). Si el
--   admin quiere sacar stock físicamente, usa el flujo de guía/pedido a almacén ya existente.
--
-- DISEÑO: una tabla de decisiones [F] me.zona_accion_perro (idempotente por (zona, sku) → 1 decisión vigente que
--   se reemplaza; el log histórico se conserva por ts en filas previas vía local_id distinto) + RPC
--   me.zona_marcar_accion (escritura) + lectura en zona_panel (último accion por sku). 100% money-safe: NUNCA
--   toca stock/caja/guías. Idempotente por localId (reintento del gesto no duplica).
--
-- PATRÓN: security definer · search_path='' · gate mos._claim_ok() · grants revoke public + service_role,authenticated.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- [F] me.zona_accion_perro — decisión del admin sobre stock muerto. Una fila VIGENTE por (zona, sku) (upsert).
--     accion: 'PROMOCIONAR' | 'GONDOLA' | 'REMATAR'. NO muta inventario. Auditable (usuario, ts).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists me.zona_accion_perro (
  zona_id     text not null,
  sku_base    text not null,
  accion      text not null,                  -- PROMOCIONAR | GONDOLA | REMATAR
  usuario     text,
  local_id    text,                           -- idempotencia del gesto
  ts          timestamptz default now(),
  primary key (zona_id, sku_base)
);
create index if not exists ix_riz_accion_perro_zona on me.zona_accion_perro (zona_id);
create unique index if not exists ux_riz_accion_perro_localid on me.zona_accion_perro (local_id) where local_id is not null;

alter table me.zona_accion_perro enable row level security;
grant all on me.zona_accion_perro to service_role;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_marcar_accion(p jsonb { zona (req), skuBase (req), accion (req), usuario?, localId? })
--   Registra/actualiza la decisión BCG-perro. Idempotente por localId. NO toca stock/dinero. Devuelve la fila.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_marcar_accion(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_accion text := upper(btrim(coalesce(p->>'accion','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_local  text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_existe bigint;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y skuBase');
  end if;
  if v_accion not in ('PROMOCIONAR','GONDOLA','REMATAR') then
    return jsonb_build_object('ok',false,'error','accion inválida (PROMOCIONAR|GONDOLA|REMATAR)');
  end if;

  -- idempotencia por localId (dedup del gesto reenviado).
  if v_local is not null then
    if exists (select 1 from me.zona_accion_perro where local_id = v_local) then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object(
        'zona', v_zona, 'skuBase', v_sku, 'accion', v_accion));
    end if;
  end if;

  insert into me.zona_accion_perro as a (zona_id, sku_base, accion, usuario, local_id, ts)
  values (v_zona, v_sku, v_accion, v_user, v_local, now())
  on conflict (zona_id, sku_base) do update set
    accion = excluded.accion, usuario = excluded.usuario, local_id = excluded.local_id, ts = now();

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona', v_zona, 'skuBase', v_sku, 'accion', v_accion, 'usuario', v_user));
end;
$fn$;
revoke all on function me.zona_marcar_accion(jsonb) from public;
grant execute on function me.zona_marcar_accion(jsonb) to service_role, authenticated;

-- wrapper mos.* (pass-through puro, profile 'mos' — patrón 132).
create or replace function mos.zona_marcar_accion(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_marcar_accion(p);
end;
$fn$;
revoke all on function mos.zona_marcar_accion(jsonb) from public;
grant execute on function mos.zona_marcar_accion(jsonb) to service_role, authenticated;
