-- ============================================================
-- 149_me_zona_stock.sql
-- LECTURA del saldo operativo por zona desde Supabase (cutover stock ME).
--
-- CONTEXTO: con ME_SYNC_OFF_TABLAS = stock_zonas,guias_cabecera,guias_detalle,
-- la Hoja STOCK_ZONAS quedó CONGELADA (ya no recibe el sync). Las ESCRITURAS de
-- stock (ventas/ajustes/guías/recepciones) van directo a me.stock_zonas. Esta RPC
-- da la LECTURA equivalente para que getStockZonas() (GAS) la sirva al frontend
-- bajo el flag FUENTE_DATOS (mismo patrón que estado_cajas/ventas_hoy_zona).
--
-- SHAPE: devuelve un ARRAY JSONB de filas con EXACTAMENTE las keys que el
-- frontend ya consume desde la Hoja (Cod_Barras / Zona_ID / Cantidad). NO se
-- toca la UI; solo cambia la fuente del dato.
--
-- Devuelve TODAS las zonas (el frontend carga el stock completo, no por-zona:
-- cargarStockZonas() no manda parámetro de zona y arma el set de zonas desde
-- las filas). Solo filas con cantidad <> 0 (payload chico; el frontend ya
-- compacta a >0 y empuja filas nuevas cuando no existen).
--
-- Seguridad: igual a me.estado_cajas — SIN gate mos._claim_ok() (es lectura
-- desde GAS con service_role), security definer, search_path='', revoke public,
-- grant service_role (+ authenticated, inocuo).
-- ============================================================

create or replace function me.zona_stock(p jsonb default '{}'::jsonb)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'ok', true,
    'stock', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'Cod_Barras', sz.cod_barras,
            'Zona_ID',    sz.zona_id,
            'Cantidad',   sz.cantidad
          )
          order by sz.zona_id, sz.cod_barras
        )
        from me.stock_zonas sz
        where coalesce(sz.cantidad, 0) <> 0
      ),
      '[]'::jsonb
    )
  );
$fn$;

revoke all on function me.zona_stock(jsonb) from public;
grant execute on function me.zona_stock(jsonb) to service_role, authenticated;
