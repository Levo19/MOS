-- ════════════════════════════════════════════════════════════════════════════
-- 135 · wh.rebasar_acumulada(p) — recomputa el acumulado de la semana desde la FUENTE
--       DE VERDAD (los pickups individuales del bucket). Self-heal de cualquier drift.
-- ════════════════════════════════════════════════════════════════════════════
-- El cutover migró la lista vieja (modelo lunes) y arrastró un sub-conteo (la lista vieja
-- no había capturado todos los pickups). Esta función reconstruye `solicitado` por sku como
-- Σ(pickups individuales del bucket) = exactamente lo que cada cierre pidió (= el historial),
-- PRESERVANDO `despachado` del acumulado (lo que el operador ya despachó por escaneo).
-- NO mueve stock (solo reescribe la lista). Idempotente. pendiente = solicitado - despachado.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function wh.rebasar_acumulada(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_zona    text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket  date := wh._bucket_dom((now() at time zone 'America/Lima')::date);
  v_acum_id text;
  v_desp    jsonb := '{}'::jsonb;   -- despachado actual del ACU por sku (a preservar)
  v_items   jsonb;
  v_it      jsonb;
  v_sku     text;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;
  v_acum_id := 'PCK-ACU-' || v_zona || '-' || to_char(v_bucket, 'YYYY-MM-DD');

  -- preservar el despachado por sku que ya tiene la acumulada
  for v_it in select value from jsonb_array_elements(coalesce((select items from wh.pickups where id_pickup = v_acum_id), '[]'::jsonb)) loop
    v_sku := coalesce(v_it->>'skuBase',''); if v_sku = '' then continue; end if;
    v_desp := jsonb_set(v_desp, array[v_sku], to_jsonb(wh._num(coalesce(v_it->>'despachado','0'))), true);
  end loop;

  -- solicitado = Σ de los pickups individuales del bucket (fuente de verdad)
  with ind as (
    select it->>'skuBase' as sku,
           sum(wh._num(coalesce(it->>'solicitado','0'))) as sol,
           max(it->>'nombre') as nombre,
           (array_agg(it->'codigosOriginales' order by pk.fecha_creado desc))[1] as cods
    from wh.pickups pk
    cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
    where coalesce(pk.id_zona,'') = v_zona
      and coalesce(pk.fuente,'') <> 'ACUMULADO_SEMANAL'
      and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
      and coalesce(it->>'skuBase','') <> ''
    group by it->>'skuBase'
    having sum(wh._num(coalesce(it->>'solicitado','0'))) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', sku,
           'nombre', coalesce(nombre, sku),
           'solicitado', sol,
           'despachado', wh._num(coalesce(v_desp->>sku,'0')),
           'codigosOriginales', coalesce(cods, '[]'::jsonb)
         ) order by sku), '[]'::jsonb)
    into v_items from ind;

  update wh.pickups set items = v_items, ultima_actividad = now() where id_pickup = v_acum_id;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'acum', v_acum_id, 'items', jsonb_array_length(v_items),
    'total_solicitado', (select coalesce(sum(wh._num(coalesce(x->>'solicitado','0'))),0) from jsonb_array_elements(v_items) x)));
end;
$fn$;

revoke all on function wh.rebasar_acumulada(jsonb) from public;
grant execute on function wh.rebasar_acumulada(jsonb) to service_role;
