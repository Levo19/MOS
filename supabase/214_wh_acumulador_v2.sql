-- ════════════════════════════════════════════════════════════════════════════
-- 214 · Acumulador de pickup v2 — 100% SUPABASE (reemplaza el modelo de 212)
-- ════════════════════════════════════════════════════════════════════════════
-- Cambios vs 212 (pedido del dueño, 2026-06-24):
--  1. BUCKET SEMANA-DOMINGO (no lunes). Regla "se emite hoy, se despacha mañana":
--     el pickup emitido el DOMINGO nace LIMPIO (semana nueva), no se mezcla con el
--     acumulado de la semana que muere. bucket(d) = domingo <= d (Lima).
--  2. BALANCE CORRIENTE: pendiente = max(0, solicitado - despachado). Al consolidar
--     se ASIENTA (settle) y se resetea `despachado`. El SOBRE-DESPACHO NO ACREDITA
--     el pedido siguiente (dar 25 de 20 ⇒ falta 0, NO -5; el próximo 20 sigue siendo 20).
--  3. DISPARO POR TRIGGER al llegar cada pickup (varios cierres/día ⇒ UNA sola lista
--     por zona). El cron nocturno queda solo como red de seguridad.
--  4. Al cambiar de semana, el bucket viejo con pendiente ⇒ REZAGADO (oculto, terminal,
--     NO despachable) — queda listo para la impresión "lista de compra" del lunes (216).
--
-- Money-safe: la guía sigue saliendo SOLO de lo escaneado (RPC 210 intacta). REZAGADO y
-- ABSORBIDO no pasan el guard de 210 ⇒ nunca se re-despachan (cero doble descuento).
-- Una lista por ZONA (id lleva la zona); zonas independientes y en paralelo.
-- ════════════════════════════════════════════════════════════════════════════

-- ── Helper: domingo que inicia la semana de despacho que contiene a d (TZ Lima) ──
-- bucket(d) = date_trunc('week', d+1) - 1  ⇒  el domingo <= d.
--   sáb 27 → dom 21 · dom 28 → dom 28 (nueva) · lun 22..sáb 27 → dom 21.
create or replace function wh._bucket_dom(d date)
returns date language sql immutable set search_path = '' as $$
  select (date_trunc('week', ((d + 1))::timestamp)::date - 1)
$$;

-- ── Consolida UNA zona en su acumulada del bucket-domingo dado ───────────────
-- Idempotente. Asienta el pendiente, absorbe los pickups del MISMO bucket, y
-- marca REZAGADO cualquier acumulada de bucket ANTERIOR que aún tenga pendiente.
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
  v_now       timestamptz := now();
begin
  -- Lock de la acumulada destino. Si el operador la está despachando (EN_PROCESO)
  -- NO la tocamos este ciclo (no cambiar la lista bajo sus manos) — se folda al cerrar.
  select items, estado into v_existing, v_est
    from wh.pickups where id_pickup = v_acum_id for update;
  if v_est is not null and upper(v_est) = 'EN_PROCESO' then
    return jsonb_build_object('ok', true, 'skip', 'EN_PROCESO', 'acum', v_acum_id);
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

  -- Absorber pickups del MISMO bucket-domingo (no acumulados, despachables).
  -- Suma el remanente max(0, sol-desp) de cada uno y los marca ABSORBIDO (ocultos).
  for v_cand in
    select id_pickup, items from wh.pickups
    where coalesce(id_zona,'') = p_zona
      and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
      and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
      and wh._bucket_dom((fecha_creado at time zone 'America/Lima')::date) = p_bucket
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

  -- WEEK-DEATH: acumuladas de bucket ANTERIOR (formato fecha) con pendiente → REZAGADO.
  -- No ruedan a la semana nueva; quedan para la impresión "lista de compra" del lunes.
  update wh.pickups
     set estado = 'REZAGADO', ultima_actividad = v_now
   where coalesce(id_zona,'') = p_zona
     and fuente = 'ACUMULADO_SEMANAL'
     and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
     and id_pickup <> v_acum_id
     and id_pickup like 'PCK-ACU-' || p_zona || '-%'
     and right(id_pickup, 10) ~ '^\d{4}-\d{2}-\d{2}$'
     and to_date(right(id_pickup, 10), 'YYYY-MM-DD') < p_bucket;
  get diagnostics v_rez = row_count;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'acum', v_acum_id, 'absorbidos', v_abs, 'rezagados', v_rez,
    'items', jsonb_array_length(v_items_out)));
end;
$fn$;

-- ── Consolidar TODAS las zonas (red de seguridad nocturna · cron) ────────────
create or replace function wh.consolidar_pickups_todas(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_today  date := (now() at time zone 'America/Lima')::date;
  v_bucket date := wh._bucket_dom(v_today);
  v_zona   text;
  v_n      int := 0;
begin
  for v_zona in
    select distinct coalesce(id_zona,'') as z
    from wh.pickups
    where upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
      and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
      and wh._bucket_dom((fecha_creado at time zone 'America/Lima')::date) = v_bucket
  loop
    perform wh.consolidar_pickup_zona(v_zona, v_bucket);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('bucket', v_bucket, 'zonas', v_n));
end;
$fn$;

-- ── TRIGGER: cada pickup que llega (no acumulado) consolida su zona al instante ──
-- Varios cierres/día ⇒ una sola lista. Sin recursión: el WHEN excluye fuente
-- ACUMULADO_SEMANAL (los upserts/updates de la acumulada no re-disparan).
create or replace function wh._tg_pickup_consolidar()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_bucket date;
begin
  -- [40x · A] La consolidación NUNCA debe bloquear la creación del pickup
  -- (= el cierre de caja de ME). Si algo falla, la subtransacción del EXCEPTION
  -- revierte SOLO la consolidación parcial; el INSERT del pickup persiste y el
  -- cron nocturno repara. Money/ops-safe: jamás se pierde una venta por esto.
  v_bucket := wh._bucket_dom((NEW.fecha_creado at time zone 'America/Lima')::date);
  perform wh.consolidar_pickup_zona(coalesce(NEW.id_zona,''), v_bucket);
  return null;
exception when others then
  return null;
end;
$$;

drop trigger if exists tg_pickup_consolidar on wh.pickups;
create trigger tg_pickup_consolidar
after insert on wh.pickups
for each row
when (coalesce(NEW.fuente,'') <> 'ACUMULADO_SEMANAL'
      and coalesce(NEW.id_zona,'') <> ''                       -- [40x · B] sin zona no acumula
      and upper(coalesce(NEW.estado,'')) in ('PENDIENTE','PARCIAL'))
execute function wh._tg_pickup_consolidar();

-- Grants: solo service_role/definer las usan (trigger + cron). No exponer a anon.
revoke all on function wh._bucket_dom(date)                      from public;
revoke all on function wh.consolidar_pickup_zona(text, date)     from public;
revoke all on function wh.consolidar_pickups_todas(jsonb)        from public;
grant execute on function wh.consolidar_pickups_todas(jsonb) to service_role;
