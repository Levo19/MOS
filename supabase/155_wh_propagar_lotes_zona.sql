-- 155_wh_propagar_lotes_zona.sql
-- ============================================================
-- [RIZ · CABLEO ACTIVO] WH cierra SALIDA_ZONA → hereda lote+vencimiento a la ZONA (FIFO)
-- ------------------------------------------------------------
-- CONTEXTO. Cuando WH despacha a una ZONA ME, la guía es tipo SALIDA_ZONA con
-- wh.guias.id_zona = zona destino (289/292 guías reales la tienen poblada). El stock
-- de WH baja por FIFO consumiendo wh.lotes_vencimiento (el lote que vence primero sale
-- primero). ESOS lotes consumidos — con su id_lote y fecha_vencimiento reales — son los
-- que físicamente llegan a la zona y deben anotarse en su "libro de lotes" me.zona_lotes
-- (vía me.zona_recibir_lote, 131_riz_lotes_zona.sql), para que la venta en zona pueda
-- consumir FIFO/alertar vencimientos.
--
-- POR QUÉ ESTA RPC (y no dentro de cerrar_guia_idempotente). El FIFO de lotes de WH se
-- ejecuta HOY en GAS (_consumirLotesFIFO sobre la Hoja LOTES_VENCIMIENTO, que es la fuente
-- de verdad de lotes hasta el corte de Sheets). cerrar_guia_idempotente sólo mueve el
-- stock por delta; NO consume wh.lotes_vencimiento. Por eso el lado que SABE exactamente
-- qué lotes salieron (id_lote + vencimiento + cantidad por lote) es el GAS, justo tras
-- _consumirLotesFIFO. Esta RPC recibe esa lista y la registra en la zona de forma ATÓMICA,
-- IDEMPOTENTE y bajo gate. Mantiene la regla "una sola verdad de stock": NO escribe
-- me.stock_zonas (eso sigue por el sync/zona_ajustar_stock); sólo el desglose de lotes [E].
--
-- IDEMPOTENCIA. me.zona_recibir_lote dedup por (zona, id_lote, id_guia_origen): recerrar /
-- reintentar la MISMA guía NO re-acumula el mismo lote. Si esta RPC se llama N veces para
-- la misma guía → mismo resultado (cada (lote,guia) entra una sola vez).
--
-- SEGURIDAD. security definer · search_path='' · gate wh._claim_ok() (token WH y
-- service_role/cron pasan; otras apps NO). NUNCA lanza (sub-bloque por lote): un problema
-- del libro de lotes JAMÁS debe tumbar el cierre de guía (que es dinero). grants service_role+authenticated.
-- 100% ADITIVO: no toca cerrar_guia / cerrar_guia_idempotente / stock.
--
-- CONTRATO:
--   p = { id_guia (req), zona (req), lotes:[{ idLote (req), codBarra|skuBase, fechaVencimiento?, cantidad (req>0) }] }
--   → { ok, idGuia, zona, recibidos, dedup, omitidos, detalle:[...] }
-- ============================================================

create or replace function wh.propagar_lotes_zona_cierre(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_guia   text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_lotes  jsonb := coalesce(p->'lotes','[]'::jsonb);
  v_l      jsonb;
  v_res    jsonb;
  v_recib  int := 0;
  v_dedup  int := 0;
  v_omit   int := 0;
  v_det    jsonb := '[]'::jsonb;
  v_cant   numeric;
  v_idlote text;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null or v_zona = '' then
    return jsonb_build_object('ok',false,'error','Requiere id_guia y zona');
  end if;
  if jsonb_typeof(v_lotes) <> 'array' then
    return jsonb_build_object('ok',false,'error','lotes debe ser array');
  end if;

  for v_l in select jsonb_array_elements(v_lotes) loop
    v_idlote := nullif(btrim(coalesce(v_l->>'idLote','')), '');
    v_cant   := wh._num(coalesce(v_l->>'cantidad',''));
    -- sin lote o cantidad <= 0 → omitir (no rompe). Refleja "consumo sin lote" (huérfano FIFO).
    if v_idlote is null or v_cant is null or v_cant <= 0 then
      v_omit := v_omit + 1;
      continue;
    end if;
    -- sub-bloque blindado: el libro de lotes NUNCA debe tumbar el cierre.
    begin
      v_res := me.zona_recibir_lote(jsonb_build_object(
        'zona',             v_zona,
        'skuBase',          nullif(btrim(coalesce(v_l->>'skuBase','')), ''),
        'codBarra',         nullif(btrim(coalesce(v_l->>'codBarra','')), ''),
        'idLote',           v_idlote,
        'fechaVencimiento', nullif(btrim(coalesce(v_l->>'fechaVencimiento','')), ''),
        'cantidad',         v_cant,
        'idGuiaOrigen',     v_guia));
      if coalesce((v_res->>'ok')::boolean,false) then
        if coalesce((v_res->>'dedup')::boolean,false) then v_dedup := v_dedup + 1;
        else v_recib := v_recib + 1; end if;
        v_det := v_det || jsonb_build_object('idLote', v_idlote, 'res', v_res->'data',
                  'dedup', coalesce((v_res->>'dedup')::boolean,false));
      else
        v_omit := v_omit + 1;
        v_det := v_det || jsonb_build_object('idLote', v_idlote, 'error', v_res->>'error');
      end if;
    exception when others then
      v_omit := v_omit + 1;
      v_det := v_det || jsonb_build_object('idLote', v_idlote, 'error', SQLERRM);
    end;
  end loop;

  return jsonb_build_object('ok',true,'idGuia',v_guia,'zona',v_zona,
    'recibidos',v_recib,'dedup',v_dedup,'omitidos',v_omit,'detalle',v_det);
end;
$fn$;
revoke all on function wh.propagar_lotes_zona_cierre(jsonb) from public;
grant execute on function wh.propagar_lotes_zona_cierre(jsonb) to service_role, authenticated;
