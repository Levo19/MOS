-- 57_wh_sync_directo.sql — [PASO 5 · B4 soporte] Dedup de idempotencia para escritura DIRECTA (= SYNC_LOG de GAS).
-- Resuelve el HALLAZGO 40x #2: RPCs NO idempotentes (agregar_detalle_guia AUTO-SUMA) duplicarían bajo reintento.
-- El helper registra el local_id de cada operación; si ya fue procesado → la RPC hace early-return (no re-ejecuta).
-- RLS habilitado (REGLA: toda tabla nueva post-04). El helper es security definer (escribe como owner, bypassa RLS).

create table if not exists wh.sync_directo (
  local_id text primary key,
  accion   text,
  ts       timestamptz not null default now()
);
alter table wh.sync_directo enable row level security;   -- deny-all a authenticated; solo el helper (definer) escribe
revoke all on wh.sync_directo from public;
grant select on wh.sync_directo to service_role;          -- diagnóstico

-- TRUE si local_id es NUEVO (lo registra y la RPC debe proceder); FALSE si ya procesado (la RPC debe dedup/early-return).
-- Sin local_id → TRUE (siempre procesa, = comportamiento sin dedup).
create or replace function wh._dedup_nuevo(p_local_id text, p_accion text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if p_local_id is null or btrim(p_local_id) = '' then return true; end if;
  insert into wh.sync_directo (local_id, accion) values (p_local_id, p_accion)
    on conflict (local_id) do nothing;
  return found;   -- found = true si insertó (nuevo); false si conflict (ya existía → dedup)
end;
$fn$;

revoke all on function wh._dedup_nuevo(text, text) from public;
grant execute on function wh._dedup_nuevo(text, text) to service_role, authenticated;
