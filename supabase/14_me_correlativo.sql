-- ============================================================
-- 14_me_correlativo.sql — Correlativo atómico en Postgres (cutover del minter, flag-gated en GAS)
-- Reemplaza el LockService+Sheets de obtenerSiguienteCorrelativoRapido por un mint atómico.
-- IDEMPOTENTE (clave = localId de la venta → mismo número ante reintentos, sin huecos) y
-- CONCURRENCIA-SAFE multi-cajero (UPDATE..RETURNING toma lock de fila por serie).
-- NO se usa hasta que GAS flipee CORRELATIVO_SOURCE='supabase' (cutover deliberado).
-- security definer + revoke public + grant service_role (Fase 1).
-- ============================================================

create schema if not exists me;

-- Idempotencia: clave de la venta (localId UUID) → número ya emitido.
create table if not exists me.correlativos_emitidos (
  idem_key   text primary key,
  serie      text   not null,
  numero     bigint not null,
  emitido_at timestamptz default now()
);
create index if not exists ix_me_corr_emit_serie on me.correlativos_emitidos(serie);

create or replace function me.siguiente_correlativo(p_serie text, p_idem_key text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_num bigint; v_ins integer;
begin
  if p_serie is null or p_serie = '' then raise exception 'serie requerida'; end if;
  -- crear la serie si no existe (serie nueva sin historial parte en 1). Idempotente.
  insert into me.correlativos (serie, siguiente) values (p_serie, 1) on conflict (serie) do nothing;

  -- Sin clave de idempotencia: mint directo (lock de fila → multi-cajero safe).
  if p_idem_key is null or p_idem_key = '' then
    update me.correlativos set siguiente = siguiente + 1 where serie = p_serie returning siguiente - 1 into v_num;
    return v_num;
  end if;

  -- Con clave: si ya se emitió, devolver el MISMO número (idempotente, sin re-mintear).
  select numero into v_num from me.correlativos_emitidos where idem_key = p_idem_key;
  if found then return v_num; end if;

  -- Gate por unique: el que inserta la clave gana el derecho a mintear. Un reintento
  -- concurrente con la misma clave BLOQUEA en el índice unique hasta que el ganador commitee,
  -- luego ON CONFLICT → v_ins=0 → lee el número ya emitido (race-safe, sin número desperdiciado).
  insert into me.correlativos_emitidos (idem_key, serie, numero) values (p_idem_key, p_serie, 0)
    on conflict (idem_key) do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 0 then
    select numero into v_num from me.correlativos_emitidos where idem_key = p_idem_key;
    return v_num;
  end if;

  -- Ganamos el gate: mintear y completar la fila de idempotencia.
  update me.correlativos set siguiente = siguiente + 1 where serie = p_serie returning siguiente - 1 into v_num;
  update me.correlativos_emitidos set numero = v_num where idem_key = p_idem_key;
  return v_num;
end;
$fn$;

revoke all on function me.siguiente_correlativo(text, text) from public;
grant execute on function me.siguiente_correlativo(text, text) to service_role;
