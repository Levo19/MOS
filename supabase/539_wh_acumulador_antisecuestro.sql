-- ════════════════════════════════════════════════════════════════════════════
-- 539 · Acumulador: anti-secuestro 1h + week-death implacable + rescate de huérfanos
-- ════════════════════════════════════════════════════════════════════════════
-- Incidente ZONA-01 (2026-07-20): 3 cards sueltas en el feed. Cadena causal:
--   acumulada jalada y abandonada EN_PROCESO (sin timeout) → el consolidador la
--   SALTA (skip EN_PROCESO) → los cierres de caja de esa semana no se absorben
--   (huérfano 04-jul) → el WEEK-DEATH tampoco la mata (solo PENDIENTE/PARCIAL)
--   → bucket inmortal cruzando domingos (05-jul EN_PROCESO con lock 300h).
--
-- FIX (reglas del dueño, 2026-07-20):
--  A. ANTI-SECUESTRO 1 HORA: pickup EN_PROCESO cuya ultima_actividad > 1h
--     (ultima_actividad se refresca con CADA producto agregado, vía autosave
--     guardar_progreso_pickup) → vuelve a PENDIENTE y suelta el lock. El avance
--     de items NO se pierde (vive en la fila). Corre al inicio de cada
--     consolidación (trigger de pickup nuevo + cron).
--  B. WEEK-DEATH IMPLACABLE: el rollover también mata buckets EN_PROCESO de
--     semanas anteriores → REZAGADO. Nada sobrevive al domingo.
--  C. RESCATE DE HUÉRFANOS: la absorción toma pickups sueltos PENDIENTE/PARCIAL
--     de buckets ANTERIORES O IGUAL al vigente (antes: solo el mismo bucket).
--     La deuda a una zona no caduca por un accidente de timing.
--  D. Cron horario: wh-pickup-acumular pasa de diario 07:10 a CADA HORA (:10)
--     para que el timeout de 1h tenga efecto real, no "al día siguiente".
--
-- NOTA operación concurrente (pregunta del dueño): si un pickup nuevo entra
-- MIENTRAS el operador tiene la acumulada jalada (activa <1h), la consolidación
-- se salta ese ciclo (no cambiar la lista bajo sus manos) y el pickup queda
-- PENDIENTE visible; al cerrar el operador su despacho (acumulada→PARCIAL), el
-- próximo ciclo (cron horario o siguiente pickup) lo absorbe. Nunca se pierde:
-- solo espera al siguiente ciclo. Money-safe: la guía sigue saliendo SOLO de lo
-- escaneado (RPC 210/414 intacta); acá solo se mueve la DEMANDA.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function wh.consolidar_pickup_zona(p_zona text, p_bucket date)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_acum_id   text := 'PCK-ACU-' || p_zona || '-' || to_char(p_bucket, 'YYYY-MM-DD');
  v_existing  jsonb;
  v_est       text;
  v_map       jsonb := '{}'::jsonb;
  v_it        jsonb;
  v_sku       text;
  v_rem       numeric;
  v_pend      numeric;
  v_cand      record;
  v_items_out jsonb;
  v_abs       int := 0;
  v_rez       int := 0;
  v_lib       int := 0;
  v_now       timestamptz := now();
begin
  -- [539-A] ANTI-SECUESTRO: EN_PROCESO sin actividad por > 1h → PENDIENTE + sin lock.
  -- ultima_actividad la refresca cada autosave (cada producto agregado) → es el
  -- "timestamp del último producto" que pidió el dueño. Aplica a la acumulada de la
  -- zona Y a pickups sueltos de la zona (mismo criterio: jalado = atender rápido).
  update wh.pickups
     set estado = 'PENDIENTE', atendido_por = '', ultima_actividad = v_now
   where coalesce(id_zona,'') = p_zona
     and upper(coalesce(estado,'')) = 'EN_PROCESO'
     and ultima_actividad < v_now - interval '1 hour';
  get diagnostics v_lib = row_count;

  -- Lock de la acumulada destino. Si el operador la está despachando (EN_PROCESO
  -- ACTIVA, <1h desde su último producto) NO la tocamos este ciclo — se folda al cerrar.
  select items, estado into v_existing, v_est
    from wh.pickups where id_pickup = v_acum_id for update;
  if v_est is not null and upper(v_est) = 'EN_PROCESO' then
    return jsonb_build_object('ok', true, 'skip', 'EN_PROCESO', 'acum', v_acum_id, 'liberados', v_lib);
  end if;

  -- SEED: asentar lo que ya tenía la acumulada → pendiente = max(0, sol-desp), reset desp.
  -- (Aquí muere el sobre-despacho: si desp>sol, pendiente=0, el excedente NO se acredita.)
  if v_existing is not null and jsonb_typeof(v_existing) = 'array' then
    for v_it in select * from jsonb_array_elements(v_existing) loop
      v_sku := coalesce(v_it->>'skuBase', '');
      if v_sku = '' then continue; end if;
      v_pend := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
      if v_pend <= 0 then continue; end if;
      v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
        'skuBase', v_sku,
        'nombre', coalesce(v_it->>'nombre', v_sku),
        'solicitado', v_pend,
        'despachado', 0,
        'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)
      ), true);
    end loop;
  end if;

  -- [539-C] Absorber pickups sueltos despachables del bucket vigente O ANTERIORES
  -- (huérfanos de semanas donde la acumulada estuvo secuestrada). Antes: = p_bucket.
  for v_cand in
    select id_pickup, items from wh.pickups
    where coalesce(id_zona,'') = p_zona
      and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
      and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
      and wh._bucket_dom((fecha_creado at time zone 'America/Lima')::date) <= p_bucket
    for update
  loop
    if jsonb_typeof(v_cand.items) = 'array' then
      for v_it in select * from jsonb_array_elements(v_cand.items) loop
        v_sku := coalesce(v_it->>'skuBase', '');
        if v_sku = '' then continue; end if;
        v_rem := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
        if v_rem <= 0 then continue; end if;
        if v_map ? v_sku then
          v_map := jsonb_set(v_map, array[v_sku,'solicitado'],
            to_jsonb(wh._num(coalesce(v_map->v_sku->>'solicitado','0')) + v_rem), true);
        else
          v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
            'skuBase', v_sku,
            'nombre', coalesce(v_it->>'nombre', v_sku),
            'solicitado', v_rem,
            'despachado', 0,
            'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)
          ), true);
        end if;
      end loop;
    end if;
    update wh.pickups
       set estado = 'ABSORBIDO',
           notas = coalesce(notas,'') || ' [abs:' || v_acum_id || ']',
           ultima_actividad = v_now
     where id_pickup = v_cand.id_pickup;
    v_abs := v_abs + 1;
  end loop;

  select coalesce(jsonb_agg(value), '[]'::jsonb) into v_items_out from jsonb_each(v_map);

  -- Upsert de la acumulada. PARCIAL se resetea a PENDIENTE (vuelve a ser visible/despachable).
  if v_existing is not null then
    update wh.pickups
       set items = v_items_out, ultima_actividad = v_now,
           estado = case when upper(coalesce(estado,'')) in ('PENDIENTE','EN_PROCESO') then estado else 'PENDIENTE' end
     where id_pickup = v_acum_id;
  elsif jsonb_array_length(v_items_out) > 0 then
    insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
    values (v_acum_id, 'ACUMULADO_SEMANAL', 'PENDIENTE', v_items_out, p_zona,
            'ACUMULADO semana-domingo ' || to_char(p_bucket,'YYYY-MM-DD'), 'sistema', v_now, v_now);
  end if;

  -- [539-B] WEEK-DEATH IMPLACABLE: acumuladas de bucket ANTERIOR con pendiente →
  -- REZAGADO, incluyendo EN_PROCESO (antes sobrevivían secuestradas cruzando domingos).
  update wh.pickups
     set estado = 'REZAGADO', atendido_por = '', ultima_actividad = v_now
   where coalesce(id_zona,'') = p_zona
     and fuente = 'ACUMULADO_SEMANAL'
     and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL','EN_PROCESO')
     and id_pickup <> v_acum_id
     and id_pickup like 'PCK-ACU-' || p_zona || '-%'
     and right(id_pickup, 10) ~ '^\d{4}-\d{2}-\d{2}$'
     and to_date(right(id_pickup, 10), 'YYYY-MM-DD') < p_bucket;
  get diagnostics v_rez = row_count;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'acum', v_acum_id, 'absorbidos', v_abs, 'rezagados', v_rez, 'liberados', v_lib,
    'items', jsonb_array_length(v_items_out)));
end;
$fn$;

revoke all on function wh.consolidar_pickup_zona(text, date) from public;

-- [539-D] Cron horario (antes diario 07:10): el timeout de 1h actúa dentro de la hora.
select cron.unschedule('wh-pickup-acumular');
select cron.schedule('wh-pickup-acumular', '10 * * * *', $$ select wh.consolidar_pickups_todas('{}'::jsonb); $$);
