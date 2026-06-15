-- 73_wh_cuadre_corte_delta.sql
-- ============================================================================
-- REEMPLAZA la lógica de 71_wh_auditar_cuadre_stock.sql (ESTE archivo queda VIGENTE).
--
-- PROBLEMA QUE RESUELVE
--   La versión 71 reconstruía el teórico ABSOLUTO desde cero:
--     teorico = Σ ajustes + Σ detalle de guías CERRADAS  (todo el histórico)
--   Pero la sombra Supabase solo tiene ~2 meses (1er mov 2026-05-03 / guías abr-2026),
--   mientras que wh.stock (backfill) es "de toda la vida". El teórico arrancaba de una
--   base perdida → 419/1358 descuadres FALSOS (192 con teórico negativo imposible).
--
-- ENFOQUE: SNAPSHOT DE CORTE + DELTA POR LIBRO-MAYOR (wh.stock_movimientos)
--   1) wh.auditoria_corte: foto de wh.stock.cantidad_disponible en fecha_corte.
--      Es SOLO LECTURA→INSERT en tabla nueva. NO toca wh.stock ni wh.ajustes.
--   2) esperado(cod) = cantidad_base(corte) + Σ(stock_movimientos.delta con fecha > fecha_corte)
--      diff = stock_real - esperado ; alerta ALAC_* si |diff| > 0.5
--
-- POR QUÉ stock_movimientos ES LA FUENTE (verificado en vivo 2026-06-14):
--   · 6353 filas, 11 tipos cubriendo TODA mutación de stock (CIERRE_GUIA, REABRIR_REVERSO,
--     AUDITORIA, ENVASADO_BASE/DERIVADO, ANULACION_DETALLE, EDICION_CANTIDAD,
--     CORRECCION_MANUAL_ENVASADO, AJUSTE_MANUAL, AUTO_SUMA_DETALLE, EDICION_ENVASADO).
--   · Vivo HOY (124 movs hoy, GAS escribe en tiempo real).
--   · Integridad perfecta: 0/6353 con stock_antes+delta != stock_despues.
--   · Concordancia total: el último stock_despues por producto == wh.stock actual en 863/863
--     productos con movimiento → el ledger ES la verdad y el stock lo refleja.
--   · delta nunca null ni 0.
--   Es estrictamente más robusto que recomponer por ajustes+guías (evita doble-conteo,
--   cubre envasado/reverso/correcciones que el cálculo por componentes ignoraba).
--
-- PERSISTENCIA (idéntica a 71 / GAS _guardarAlertasStock):
--   borra ALAC_* no revisadas, reinserta las nuevas. Conserva histórico revisado=true.
--   Todo en 1 tx (la RPC es atómica) → sin huérfanos, sin ventana vacía.
--   ⚠️ Solo purga ALAC_* (no toca otras AL* manuales/históricas).
--
-- GATE: service_role only (cron sin JWT). Auditoría de solo-lectura + alertas.
-- ============================================================================

-- ── 1) TABLA DE CORTE (snapshot) ───────────────────────────────────────────
create table if not exists wh.auditoria_corte (
  cod_producto   text primary key,
  cantidad_base  numeric not null,
  fecha_corte    timestamptz not null default now()
);
revoke all on table wh.auditoria_corte from public, anon, authenticated;
grant select, insert, update, delete on table wh.auditoria_corte to service_role;
comment on table wh.auditoria_corte is
  'Snapshot de corte para wh.auditar_cuadre_stock: foto de wh.stock.cantidad_disponible. '
  'esperado = cantidad_base + Σ(stock_movimientos.delta con fecha > fecha_corte). Solo lectura→insert; no afecta stock.';

-- ── 2) POBLAR EL CORTE (idempotente: si ya hay filas, NO re-snapshotear) ────
-- Foto del stock consolidado de HOY (0 guías ABIERTA → teórico==real de lo aplicado).
-- Si la tabla ya tiene filas se respeta el corte existente (no se pisa la base histórica).
insert into wh.auditoria_corte (cod_producto, cantidad_base, fecha_corte)
select btrim(s.cod_producto), sum(coalesce(s.cantidad_disponible,0)), now()
  from wh.stock s
 where btrim(coalesce(s.cod_producto,'')) <> ''
 group by btrim(s.cod_producto)
on conflict (cod_producto) do nothing;

-- ── 3) RPC REESCRITA: corte + delta ────────────────────────────────────────
create or replace function wh.auditar_cuadre_stock()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_alertas  int := 0;
  v_prods    int := 0;
  v_borradas int := 0;
begin
  -- 0) si no hay corte aún (primer arranque), tomarlo ahora (defensivo; el .sql ya lo pobló)
  insert into wh.auditoria_corte (cod_producto, cantidad_base, fecha_corte)
  select btrim(s.cod_producto), sum(coalesce(s.cantidad_disponible,0)), now()
    from wh.stock s
   where btrim(coalesce(s.cod_producto,'')) <> ''
   group by btrim(s.cod_producto)
  on conflict (cod_producto) do nothing;

  -- 1) purgar SOLO alertas ALAC_* no revisadas (no toca AL* manuales ni el histórico revisado=true)
  delete from wh.alertas_stock
   where id_alerta like 'ALAC\_%' escape '\'
     and coalesce(revisado, false) = false;
  get diagnostics v_borradas = row_count;

  -- 2) esperado por producto = base(corte) + Σ(delta de movimientos POSTERIORES al corte de ese producto)
  --    join completo: cubre productos con stock pero sin corte, y con corte pero sin stock.
  with corte as (
    select cod_producto cod, cantidad_base base, fecha_corte fc from wh.auditoria_corte
  ),
  -- delta acumulado por producto SOLO de movimientos con fecha > fecha_corte del MISMO producto
  mov as (
    select btrim(m.cod_producto) cod, sum(coalesce(m.delta,0)) d
      from wh.stock_movimientos m
      join corte c on c.cod = btrim(m.cod_producto)
     where m.fecha > c.fc
     group by btrim(m.cod_producto)
  ),
  stk as (
    select btrim(cod_producto) cod, sum(coalesce(cantidad_disponible,0)) realq
      from wh.stock where btrim(coalesce(cod_producto,'')) <> ''
     group by btrim(cod_producto)
  ),
  comp as (
    select coalesce(s.cod, c.cod)                              cod,
           coalesce(s.realq, 0)                                realq,
           coalesce(c.base, 0) + coalesce(m.d, 0)              esperado
      from stk s
      full outer join corte c on c.cod = s.cod
      left  join mov   m on m.cod = coalesce(s.cod, c.cod)
  ),
  alert as (
    select cod, realq, esperado, (realq - esperado) diff
      from comp
     where abs(realq - esperado) > 0.5
  )
  insert into wh.alertas_stock
        (id_alerta, fecha, cod_producto, descripcion, stock_real, stock_teorico, diferencia, revisado)
  select 'ALAC_' || replace(cod,' ','_') || '_' || to_char(now(),'YYYYMMDDHH24MISS'),
         now(), cod, cod, realq, esperado, diff, false
    from alert;
  get diagnostics v_alertas = row_count;

  select count(*) into v_prods from (
    select btrim(cod_producto) cod from wh.stock
     where btrim(coalesce(cod_producto,'')) <> '' group by btrim(cod_producto)
  ) q;

  return jsonb_build_object('ok', true, 'modelo', 'corte+delta',
    'alertas', v_alertas, 'borradas_no_revisadas', v_borradas, 'productos', v_prods);
end;
$fn$;

revoke all on function wh.auditar_cuadre_stock() from public;
grant execute on function wh.auditar_cuadre_stock() to service_role;
