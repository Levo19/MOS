-- 525_lote_historial_real.sql — BUG del dueño: el tab "📜 Historial" del modal Lotes salía
-- vacío. Causa: wh.get_historial_lote leía wh.lotes_historial — tabla-cascarón de la era
-- Hoja con 0 filas y NINGÚN escritor (el espejo nunca se alimentó). La verdad vive en:
--   · wh.lotes_vencimiento (creación: fecha_creacion, cantidad_inicial, guía de ingreso)
--   · wh.mermas (mermas que citan el lote)
--   · consumo acumulado = cantidad_inicial − cantidad_actual (las salidas rotan FEFO por
--     producto, no registran lote por línea → se muestra como acumulado del lote)
-- Redefine el RPC SINTETIZANDO el historial desde esas fuentes (+ legacy si algún día
-- se puebla). Shape idéntico (ts/idLote/codigoProducto/idGuia/accion/cantidad/motivo/
-- usuario) → el front no cambia.
create or replace function wh.get_historial_lote(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_lote text := nullif(btrim(coalesce(p->>'idLote','')), '');
  v_data jsonb;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_lote is null then return jsonb_build_object('ok',false,'error','idLote requerido'); end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.ts desc nulls last), '[]'::jsonb)
    into v_data
  from (
    -- 1) creación del lote (el ingreso que lo trajo)
    select l.fecha_creacion as ts, l.id_lote as "idLote", l.cod_producto as "codigoProducto",
           coalesce(l.id_guia,'') as "idGuia", 'INGRESO' as accion,
           l.cantidad_inicial as cantidad,
           'creación del lote (ingreso)' as motivo, '' as usuario
      from wh.lotes_vencimiento l where l.id_lote = v_lote
    union all
    -- 2) mermas que citan este lote
    select m.fecha_ingreso, m.id_lote, m.cod_producto, coalesce(m.id_guia,''),
           'MERMA', m.cantidad_original, coalesce(m.motivo,'merma'), coalesce(m.usuario,'')
      from wh.mermas m where m.id_lote = v_lote
    union all
    -- 3) consumo acumulado (salidas/envasado FEFO — sin lote por línea, se muestra el neto)
    select null::timestamptz, l.id_lote, l.cod_producto, '',
           'CONSUMO', l.cantidad_inicial - l.cantidad_actual,
           'salidas acumuladas (rotación FEFO)', 'sistema'
      from wh.lotes_vencimiento l
     where l.id_lote = v_lote and coalesce(l.cantidad_actual,0) < coalesce(l.cantidad_inicial,0)
    union all
    -- 4) legacy (hoy 0 filas; se conserva por si se puebla)
    select h.ts, h.id_lote, h.cod_producto, coalesce(h.id_guia,''),
           h.accion, h.cantidad, coalesce(h.motivo,''), coalesce(h.usuario,'')
      from wh.lotes_historial h where h.id_lote = v_lote
  ) t;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end; $fn$;
