-- ════════════════════════════════════════════════════════════════════════════
-- 216 · CUTOVER del acumulador a v2 (100% Supabase) — requiere 214 + 215 aplicados
-- ════════════════════════════════════════════════════════════════════════════
-- 1. Migra los ACU vivos de formato viejo (…-YYYY-Www, modelo lunes/acumulación cruda)
--    al formato bucket-domingo (…-YYYY-MM-DD) con items ASENTADOS (pendiente = max(0,
--    sol-desp), despachado reseteado). El viejo queda MIGRADO (terminal, no despachable).
-- 2. Repunta el cron nocturno: consolidar_pickups_semana (v1) → consolidar_pickups_todas (v2).
-- 3. Agrega la impresión automática del REZAGADO (lunes temprano, pg_cron → Edge pickup-ticket).
-- Idempotente. NO mueve stock.
-- ════════════════════════════════════════════════════════════════════════════

-- Helper: fusiona dos arrays de items de acumulada sumando `solicitado` por skuBase
-- (defensivo: solo se usa si dos ACU viejos de la misma zona caen en el mismo id nuevo).
create or replace function wh._merge_items_acu(a jsonb, b jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $mrg$
declare v_map jsonb := '{}'::jsonb; v_it jsonb; v_sku text;
begin
  for v_it in
    select value from jsonb_array_elements(coalesce(a,'[]'::jsonb))
    union all
    select value from jsonb_array_elements(coalesce(b,'[]'::jsonb))
  loop
    v_sku := coalesce(v_it->>'skuBase',''); if v_sku='' then continue; end if;
    if v_map ? v_sku then
      v_map := jsonb_set(v_map, array[v_sku,'solicitado'],
        to_jsonb(wh._num(coalesce(v_map->v_sku->>'solicitado','0')) + wh._num(coalesce(v_it->>'solicitado','0'))), true);
    else
      v_map := jsonb_set(v_map, array[v_sku], v_it, true);
    end if;
  end loop;
  return coalesce((select jsonb_agg(value) from jsonb_each(v_map)), '[]'::jsonb);
end;
$mrg$;

-- ── 1. Migración de los ACU vivos al bucket-domingo de la semana en curso ────
do $mig$
declare
  r        record;
  v_bucket date := wh._bucket_dom((now() at time zone 'America/Lima')::date);
  v_newid  text;
  v_map    jsonb;
  v_it     jsonb;
  v_sku    text;
  v_pend   numeric;
  v_items  jsonb;
begin
  for r in
    select id_pickup, coalesce(id_zona,'') as zona, items
      from wh.pickups
     where fuente = 'ACUMULADO_SEMANAL'
       and upper(coalesce(estado,'')) in ('PENDIENTE','EN_PROCESO','PARCIAL')
       and right(id_pickup, 10) !~ '^\d{4}-\d{2}-\d{2}$'   -- solo formato viejo (…-Www)
  loop
    v_newid := 'PCK-ACU-' || r.zona || '-' || to_char(v_bucket, 'YYYY-MM-DD');
    -- asentar items (pendiente, desp=0)
    v_map := '{}'::jsonb;
    if jsonb_typeof(r.items) = 'array' then
      for v_it in select * from jsonb_array_elements(r.items) loop
        v_sku := coalesce(v_it->>'skuBase', '');
        if v_sku = '' then continue; end if;
        v_pend := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
        if v_pend <= 0 then continue; end if;
        v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
          'skuBase', v_sku, 'nombre', coalesce(v_it->>'nombre', v_sku),
          'solicitado', v_pend, 'despachado', 0,
          'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)), true);
      end loop;
    end if;
    select coalesce(jsonb_agg(value), '[]'::jsonb) into v_items from jsonb_each(v_map);

    -- upsert del nuevo ACU (si dos viejos cayeran en el mismo id, suma pendientes)
    insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
    values (v_newid, 'ACUMULADO_SEMANAL', 'PENDIENTE', v_items, r.zona,
            'migrado de ' || r.id_pickup, 'sistema', now(), now())
    on conflict (id_pickup) do update
      set items = wh._merge_items_acu(wh.pickups.items, excluded.items);

    -- el viejo queda terminal (oculto, no despachable por guard 210)
    update wh.pickups
       set estado = 'MIGRADO', notas = coalesce(notas,'') || ' [migrado→' || v_newid || ']', ultima_actividad = now()
     where id_pickup = r.id_pickup;
  end loop;
end $mig$;

-- ── 2. Repuntar el cron nocturno a la v2 ────────────────────────────────────
do $cr$
begin
  if exists (select 1 from cron.job where jobname='wh-pickup-acumular') then
    perform cron.unschedule('wh-pickup-acumular');
  end if;
  perform cron.schedule('wh-pickup-acumular', '10 7 * * *', $q$ select wh.consolidar_pickups_todas('{}'::jsonb); $q$);
end $cr$;

-- ── 3. Impresión automática del REZAGADO (lunes 6:00 Lima ≈ 11:00 UTC) ───────
-- Invoca la Edge print-adhesivo (mode pickup-ticket) por cada acumulada REZAGADA
-- aún no impresa. La Edge dedupea por [impreso] y descuenta del PrintNode WH_TICKET_PRINTER_ID.
create or replace function wh.cron_rezagado_compra()
returns void language plpgsql security definer set search_path = '' as $fn$
declare
  v_key text;
  v_url text := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/print-adhesivo';
  r     record;
begin
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name='wh_edge_service_key' limit 1;
  exception when others then v_key := null;
  end;
  if v_key is null then return; end if;

  for r in
    select id_pickup from wh.pickups
     where fuente = 'ACUMULADO_SEMANAL'
       and upper(coalesce(estado,'')) = 'REZAGADO'
       and coalesce(notas,'') not like '%[impreso]%'
  loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Authorization','Bearer '||v_key, 'Content-Type','application/json'),
      body    := jsonb_build_object('mode','pickup-ticket','id_pickup', r.id_pickup, 'force', true)
    );
  end loop;
end;
$fn$;
revoke all on function wh.cron_rezagado_compra() from public;
grant execute on function wh.cron_rezagado_compra() to service_role;

do $cr2$
begin
  if exists (select 1 from cron.job where jobname='wh-rezagado-compra') then
    perform cron.unschedule('wh-rezagado-compra');
  end if;
  perform cron.schedule('wh-rezagado-compra', '0 11 * * 1', $q$ select wh.cron_rezagado_compra(); $q$);
end $cr2$;
