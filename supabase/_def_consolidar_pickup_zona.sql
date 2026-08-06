CREATE OR REPLACE FUNCTION wh.consolidar_pickup_zona(p_zona text, p_bucket date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_acum_id   text := 'PCK-ACU-' || p_zona || '-' || to_char(p_bucket, 'YYYY-MM-DD');
  v_existing  jsonb;
  v_est       text;
  v_map       jsonb := '{}'::jsonb;
  v_it        jsonb;
  v_sku       text;
  v_pend      numeric;
  v_sol_add   numeric;
  v_desp_add  numeric;
  v_cand      record;
  v_items_out jsonb;
  v_abs       int := 0;
  v_rez       int := 0;
  v_lib       int := 0;
  v_now       timestamptz := now();
begin
  -- [539-A] ANTI-SECUESTRO 1h (ultima_actividad = último producto agregado, vía autosave)
  update wh.pickups
     set estado = 'PENDIENTE', atendido_por = '', ultima_actividad = v_now
   where coalesce(id_zona,'') = p_zona
     and upper(coalesce(estado,'')) = 'EN_PROCESO'
     and ultima_actividad < v_now - interval '1 hour';
  get diagnostics v_lib = row_count;

  select items, estado into v_existing, v_est
    from wh.pickups where id_pickup = v_acum_id for update;
  if v_est is not null and upper(v_est) = 'EN_PROCESO' then
    return jsonb_build_object('ok', true, 'skip', 'EN_PROCESO', 'acum', v_acum_id, 'liberados', v_lib);
  end if;

  -- SEED: pendiente = max(0, sol−desp), reset desp (aquí actúa el piso en 0 de la fórmula).
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

  -- [539-C] Absorber sueltos del bucket vigente o ANTERIORES.
  -- [540] fuente LISTA_IA (cierres de sombra): mergea sol Y desp → fórmula
  --       deuda = max(0, deuda + pedido − despachado) al próximo seed.
  --       Otras fuentes: solo el remanente (comportamiento intacto).
  for v_cand in
    select id_pickup, items, coalesce(fuente,'') as fuente from wh.pickups
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
        if v_cand.fuente = 'LISTA_IA' then
          v_sol_add  := wh._num(coalesce(v_it->>'solicitado','0'));
          v_desp_add := wh._num(coalesce(v_it->>'despachado','0'));
          if v_sol_add <= 0 and v_desp_add <= 0 then continue; end if;
        else
          v_sol_add  := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
          v_desp_add := 0;
          if v_sol_add <= 0 then continue; end if;
        end if;
        if v_map ? v_sku then
          v_map := jsonb_set(v_map, array[v_sku,'solicitado'],
            to_jsonb(wh._num(coalesce(v_map->v_sku->>'solicitado','0')) + v_sol_add), true);
          if v_desp_add > 0 then
            v_map := jsonb_set(v_map, array[v_sku,'despachado'],
              to_jsonb(wh._num(coalesce(v_map->v_sku->>'despachado','0')) + v_desp_add), true);
          end if;
        else
          v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
            'skuBase', v_sku,
            'nombre', coalesce(v_it->>'nombre', v_sku),
            'solicitado', v_sol_add,
            'despachado', v_desp_add,
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

  -- [539-B] WEEK-DEATH implacable (incluye EN_PROCESO de buckets anteriores).
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
$function$
