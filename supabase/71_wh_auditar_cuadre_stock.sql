-- 71_wh_auditar_cuadre_stock.sql
-- ⚠️ SUPERADO por 73_wh_cuadre_corte_delta.sql (2026-06-14). NO re-aplicar este archivo:
--    pisaría la RPC vigente (modelo corte+delta) con el modelo teórico-absoluto que daba
--    419 falsos positivos por falta de histórico pre-sombra. Se conserva solo como referencia.
--
-- Reemplazo Supabase del trigger GAS `auditarStockGlobal` (Auditoria.gs ~51), apagado en el cutover.
--
-- QUE COMPARA (identico al GAS):
--   stock_teorico(cod) = Σ ajustes(INC|INI +, DEC -)
--                      + Σ detalle de guias CERRADA/AUTOCERRADA, no ANULADO:  INGRESO* +cant, SALIDA* -cant
--   cant del detalle   = abs(cant_recibida)  (GAS: cantidadRecibida || cantidadReal || cantidadEsperada;
--                        en la sombra solo existe cant_recibida -> fallback a cant_esperada por paridad)
--   diff = stock_real - stock_teorico ;  alerta si |diff| > 0.5
--   + productos sin fila en wh.stock pero con teorico != 0 -> alerta con stock_real=0.
--
-- PERSISTENCIA (replica _guardarAlertasStock): borra las alertas NO revisadas previas (conserva historico
--   revisado=true) y reinserta las nuevas. Todo en 1 tx (la RPC es atomica) -> sin huerfanos, sin ventana vacia.
--
-- GATE: service_role only (cron sin JWT). No _claim_ok, no kill-switch (es auditoria de solo-lectura + alertas).

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
  -- 1) purgar alertas no revisadas (paridad con el GAS que borra fisicamente las revisado != 'SI')
  delete from wh.alertas_stock where coalesce(revisado, false) = false;
  get diagnostics v_borradas = row_count;

  -- 2) teorico por codigo (ajustes + detalle de guias cerradas/autocerradas)
  create temporary table _teorico on commit drop as
  with aj as (
    select btrim(cod_producto) cod,
           sum(case when upper(coalesce(tipo_ajuste,'')) in ('INC','INI') then abs(coalesce(cantidad_ajuste,0))
                    when upper(coalesce(tipo_ajuste,'')) = 'DEC'         then -abs(coalesce(cantidad_ajuste,0))
                    else 0 end) teor
      from wh.ajustes
     where btrim(coalesce(cod_producto,'')) <> ''
     group by btrim(cod_producto)
  ),
  det as (
    select btrim(d.cod_producto) cod,
           sum(case when upper(g.tipo) like 'INGRESO%' then  abs(coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0))
                    when upper(g.tipo) like 'SALIDA%'  then -abs(coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0))
                    else 0 end) teor
      from wh.guia_detalle d
      join wh.guias g on g.id_guia = d.id_guia
     where upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
       and upper(coalesce(d.observacion,'')) <> 'ANULADO'
       and btrim(coalesce(d.cod_producto,'')) <> ''
     group by btrim(d.cod_producto)
  ),
  unidos as (
    select cod, sum(teor) teor from (
      select cod, teor from aj
      union all
      select cod, teor from det
    ) u group by cod
  )
  select cod, teor from unidos;

  -- 3) alertas: stock real vs teorico (join completo para cubrir productos sin fila en stock)
  with stk as (
    -- TOTAL por cod (refleja lo realmente guardado en stock; si hubiera filas duplicadas las suma).
    -- NOTA: alias 'realq' a proposito; 'real' es nombre de tipo y rompe el parser dentro de plpgsql.
    select btrim(cod_producto) cod, sum(coalesce(cantidad_disponible,0)) realq
      from wh.stock where btrim(coalesce(cod_producto,'')) <> ''
     group by btrim(cod_producto)
  ),
  comp as (
    select coalesce(s.cod, t.cod) cod,
           coalesce(s.realq, 0) realq,
           coalesce(t.teor, 0)  teor
      from stk s
      full outer join _teorico t on t.cod = s.cod
  ),
  alert as (
    select cod, realq, teor, (realq - teor) diff
      from comp
     where abs(realq - teor) > 0.5
  )
  insert into wh.alertas_stock (id_alerta, fecha, cod_producto, descripcion, stock_real, stock_teorico, diferencia, revisado)
  select 'ALAC_' || replace(cod,' ','_') || '_' || to_char(now(),'YYYYMMDDHH24MISS'),
         now(), cod, cod, realq, teor, diff, false
    from alert;
  get diagnostics v_alertas = row_count;

  select count(*) into v_prods from (
    select btrim(cod_producto) cod from wh.stock where btrim(coalesce(cod_producto,'')) <> '' group by btrim(cod_producto)
  ) q;

  return jsonb_build_object('ok', true, 'alertas', v_alertas, 'borradas_no_revisadas', v_borradas, 'productos', v_prods);
end;
$fn$;

revoke all on function wh.auditar_cuadre_stock() from public;
grant execute on function wh.auditar_cuadre_stock() to service_role;
