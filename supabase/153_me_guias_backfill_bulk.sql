-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 153_me_guias_backfill_bulk.sql
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- RPC me.zona_guias_backfill_bulk(p) — backfill MASIVO de guías (cabecera + detalle) en UNA sola llamada.
--
-- PROBLEMA QUE RESUELVE: backfillGuiasASupabase (MigracionME.gs) hacía UN UrlFetch por guía → agotó la cuota
-- diaria de GAS (`Service invoked too many times for one day: urlfetch`) y tardaba ~5 min. Esta RPC recibe TODAS
-- las guías en un solo jsonb y las procesa server-side → 1 UrlFetch en vez de N.
--
-- INVARIANTE MONEY-SAFETY: NO toca me.stock_zonas NI el kardex. Solo escribe cabecera/detalle, reusando
-- me.zona_guia_registrar_meta (que ya marca cantidad_aplicada = cantidad → un autocierre posterior calcula
-- delta 0 → NO re-aplica saldo). NO se duplica lógica: iteramos llamando a esa función por cada guía.
--
-- IDEMPOTENTE: por idGuia (cabecera on conflict do update sin pisar fecha/vendedor/zona/tipo; detalle
-- delete+reinsert solo si hay líneas válidas). Re-correr el backfill NO duplica filas ni cambia stock.
--
-- Payload: { guias: [ { idGuia, fecha, vendedor, zona, tipo, observacion, zonaDestino, estado, items:[...] }, ... ] }
--   (items: [{ codBarra|cod_barras, cantidad }, ...]) — MISMO shape que zona_guia_registrar_meta.
-- Devuelve: { ok, total, escritas, errores:[{idGuia, error}, ...] }.
--
-- Gate me._claim_zona_ok() (acepta '' GAS/service_role · 'MOS' · 'mosExpress'). Grants service_role + authenticated.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function me.zona_guias_backfill_bulk(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_guias   jsonb := coalesce(p->'guias', '[]'::jsonb);
  v_g       jsonb;
  v_r       jsonb;
  v_total   int := 0;
  v_ok      int := 0;
  v_errs    jsonb := '[]'::jsonb;
  v_idg     text;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_guias) <> 'array' then
    return jsonb_build_object('ok',false,'error','Requiere arreglo guias');
  end if;

  for v_g in select * from jsonb_array_elements(v_guias) loop
    v_total := v_total + 1;
    v_idg := btrim(coalesce(v_g->>'idGuia',''));
    -- REUSA la lógica probada (cabecera+detalle idempotente, cantidad_aplicada=cantidad, SIN stock).
    -- Aislamos cada guía: un error en una NO aborta el resto del lote.
    begin
      v_r := me.zona_guia_registrar_meta(v_g);
      if coalesce((v_r->>'ok')::boolean, false) then
        v_ok := v_ok + 1;
      else
        v_errs := v_errs || jsonb_build_object('idGuia', v_idg, 'error', coalesce(v_r->>'error','desconocido'));
      end if;
    exception when others then
      v_errs := v_errs || jsonb_build_object('idGuia', v_idg, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('ok', true, 'total', v_total, 'escritas', v_ok, 'errores', v_errs);
end;
$fn$;
revoke all on function me.zona_guias_backfill_bulk(jsonb) from public;
grant execute on function me.zona_guias_backfill_bulk(jsonb) to service_role, authenticated;

-- wrapper mos.* (profile 'mos') — pass-through con gate, consistente con las demás zona_*.
create or replace function mos.zona_guias_backfill_bulk(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_guias_backfill_bulk(p);
end; $fn$;
revoke all on function mos.zona_guias_backfill_bulk(jsonb) from public;
grant execute on function mos.zona_guias_backfill_bulk(jsonb) to service_role, authenticated;
