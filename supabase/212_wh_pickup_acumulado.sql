-- ════════════════════════════════════════════════════════════════════════════
-- 212 · Lista de pickup ACUMULADA SEMANAL (lo no despachado, por zona) — ÚNICA despachable
-- ════════════════════════════════════════════════════════════════════════════
-- Pedido: cada noche, juntar TODO lo no despachado (PENDIENTE nunca tocado + el
-- remanente de los PARCIAL), agrupado POR ZONA y SUMADO por producto, en UNA sola
-- lista por zona. Ventana semanal lunes→domingo (TZ Lima): cada lunes la lista
-- anterior se cierra y arranca una nueva (el remanente no despachado rueda a la
-- nueva). Modelo "ÚNICA despachable": el pickup individual se marca ABSORBIDO
-- (terminal, ya no visible ni despachable) y su remanente vive solo en la acumulada.
-- Despachar la acumulada usa el mismo wh.cerrar_pickup_con_despacho (emite guía +
-- descuenta stock). El guard endurecido (SQL 210: solo PENDIENTE/EN_PROCESO son
-- despachables) impide doble-descuento: un ABSORBIDO nunca puede despacharse.
--
-- INERTE: flag WH_PICKUP_ACUMULADO='0'. La consolidación la dispara un pg_cron
-- nocturno (SQL 213) — no-op mientras el flag esté OFF.
-- NO mueve stock (solo reorganiza pickups). Idempotente (re-correr no duplica).
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor)
values ('WH_PICKUP_ACUMULADO', '0')
on conflict (clave) do nothing;

create or replace function wh.consolidar_pickups_semana(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_wk_monday date := (date_trunc('week', (now() at time zone 'America/Lima')))::date;
  v_wk        text := to_char(v_wk_monday, 'IYYY-"W"IW');     -- p.ej. 2026-W26
  v_now       timestamptz := now();
  v_zona      text;
  v_acum_id   text;
  v_acum_est  text;
  v_existing  jsonb;
  v_map       jsonb;
  v_cand      record;
  v_it        jsonb;
  v_sku       text;
  v_rem       numeric;
  v_items_out jsonb;
  v_total_abs int := 0;
  v_zonas     int := 0;
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ACUMULADO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ACUMULADO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- Zonas con candidatos a consolidar. REGLAS (corregidas):
  --  · SOLO pickups creados DESDE el lunes de ESTA semana (fecha_creado >= lunes Lima).
  --    NO se jala backlog viejo de semanas anteriores.
  --  · EXCLUYE fuente='ACUMULADO_SEMANAL' → el acumulado NUNCA se re-acumula a sí mismo
  --    ni rueda al siguiente. Cada lunes arranca uno nuevo SOLO de los pickups nuevos.
  --  · EN_PROCESO se excluye: alguien está trabajando, no se toca.
  for v_zona in
    select distinct coalesce(id_zona,'') as z
    from wh.pickups
    where upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
      and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
      and (fecha_creado at time zone 'America/Lima')::date >= v_wk_monday
  loop
    v_acum_id := 'PCK-ACU-'||v_zona||'-'||v_wk;

    -- Lock + estado de la acumulada de la semana. Si está EN_PROCESO (operador
    -- despachándola justo ahora) NO la tocamos este ciclo (se hará la próxima noche).
    select items, estado into v_existing, v_acum_est
    from wh.pickups where id_pickup = v_acum_id for update;
    if v_acum_est is not null and upper(v_acum_est) = 'EN_PROCESO' then
      continue;
    end if;

    -- Sembrar el map con lo que YA tiene la acumulada (preserva el despachado parcial).
    v_map := '{}'::jsonb;
    if v_existing is not null and jsonb_typeof(v_existing) = 'array' then
      for v_it in select * from jsonb_array_elements(v_existing) loop
        v_sku := coalesce(v_it->>'skuBase','');
        if v_sku = '' then continue; end if;
        v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
          'skuBase', v_sku,
          'nombre', coalesce(v_it->>'nombre', v_sku),
          'solicitado', wh._num(coalesce(v_it->>'solicitado','0')),
          'despachado', wh._num(coalesce(v_it->>'despachado','0')),
          'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)
        ), true);
      end loop;
    end if;

    -- Sumar el remanente (solicitado-despachado) de cada candidato + marcarlo ABSORBIDO.
    for v_cand in
      select id_pickup, items from wh.pickups
      where coalesce(id_zona,'') = v_zona
        and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
        and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
        and (fecha_creado at time zone 'America/Lima')::date >= v_wk_monday
      for update
    loop
      if jsonb_typeof(v_cand.items) = 'array' then
        for v_it in select * from jsonb_array_elements(v_cand.items) loop
          v_sku := coalesce(v_it->>'skuBase','');
          if v_sku = '' then continue; end if;
          v_rem := wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0'));
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
             notas = coalesce(notas,'') || ' [absorbido:'||v_acum_id||']',
             ultima_actividad = v_now
       where id_pickup = v_cand.id_pickup;
      v_total_abs := v_total_abs + 1;
    end loop;

    -- Construir items desde el map.
    select coalesce(jsonb_agg(value), '[]'::jsonb) into v_items_out from jsonb_each(v_map);
    if jsonb_array_length(v_items_out) = 0 then continue; end if;

    -- Upsert de la acumulada de la semana.
    if v_existing is not null then
      update wh.pickups
         set items = v_items_out, ultima_actividad = v_now,
             estado = case when upper(coalesce(estado,'')) in ('PENDIENTE','EN_PROCESO') then estado else 'PENDIENTE' end
       where id_pickup = v_acum_id;
    else
      insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
      values (v_acum_id, 'ACUMULADO_SEMANAL', 'PENDIENTE', v_items_out, v_zona,
              'ACUMULADO semana '||v_wk||' (lunes a domingo)', 'sistema', v_now, v_now);
    end if;
    v_zonas := v_zonas + 1;
  end loop;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'semana', v_wk, 'zonas', v_zonas, 'absorbidos', v_total_abs));
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$fn$;

revoke all on function wh.consolidar_pickups_semana(jsonb) from public;
grant execute on function wh.consolidar_pickups_semana(jsonb) to service_role, authenticated;
