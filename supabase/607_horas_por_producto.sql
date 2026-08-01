-- 607_horas_por_producto.sql — [TRAZABILIDAD · HORA POR PRODUCTO en guías y pickups]
-- Pedido del dueño (2026-08-01): saber A QUÉ HORA entró la solicitud de cada producto y a qué
-- hora salió — visible en MOS→Zonas→pickup y en el detalle de las guías de salida.
-- (1) wh.guia_detalle.created_at (default now()): cada LÍNEA de guía queda con su hora real de
--     registro (las guías manuales se arman línea a línea → horas distintas reales). Backfill:
--     líneas viejas = fecha de su guía (mejor aproximación disponible).
-- (2) wh.zona_pickup_detalle v2: el historial por producto pasa de "por día" a POR EVENTO con
--     hora — y ahora incluye también los DESPACHOS (guías SALIDA de la zona del bucket, hora por
--     línea) además de los pedidos (cierres/RIZ/sombra). El front de MOS ya tenía la fila
--     "🏭 despachó a zona" diseñada (tipo='despacho') — por fin recibe datos.
-- (3) consolidar_pickup_zona: sella 'tsSolicitud' al entrar un producto al acumulado (hora del
--     pickup que lo trajo; la primera entrada gana). El WH (2.13.524) sella 'tsDespacho' en cada
--     marca de despacho → el checklist muestra pedido HH:mm → salió HH:mm.

-- ── (1) hora por línea de guía ──
alter table wh.guia_detalle add column if not exists created_at timestamptz default now();
update wh.guia_detalle gd
   set created_at = g.fecha
  from wh.guias g
 where g.id_guia = gd.id_guia and gd.created_at is null;

-- ── (2) zona_pickup_detalle v2: eventos con hora + despachos ──
CREATE OR REPLACE FUNCTION wh.zona_pickup_detalle(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona   text := coalesce(nullif(btrim(coalesce(p->>'zona', p->>'id_zona','')),''), '');
  v_bucket date := wh._bucket_dom((now() at time zone 'America/Lima')::date);
  v_acum   jsonb;
  v_hist   jsonb;
  v_items  jsonb;
  v_sinsku jsonb;
begin
  if v_zona = '' then return jsonb_build_object('ok', false, 'error', 'Requiere zona'); end if;

  select items into v_acum
    from wh.pickups
   where id_pickup = 'PCK-ACU-' || v_zona || '-' || to_char(v_bucket, 'YYYY-MM-DD')
   limit 1;
  v_acum := coalesce(v_acum, '[]'::jsonb);

  -- HISTORIAL por sku: PEDIDOS (cierres/RIZ/sombra, por pickup CON HORA) + DESPACHOS
  -- (líneas de guías SALIDA de la zona, hora real de cada línea = gd.created_at).
  with pedidos as (
    select it->>'skuBase' as sku,
           pk.fecha_creado as ts,
           pk.fuente,
           sum(wh._num(coalesce(it->>'solicitado','0'))) as ped
      from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where coalesce(pk.id_zona,'') = v_zona
       and coalesce(pk.fuente,'') <> 'ACUMULADO_SEMANAL'
       and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
       and coalesce(it->>'skuBase','') <> ''
       and wh._num(coalesce(it->>'solicitado','0')) > 0
     group by 1, 2, 3
  ),
  despachos as (
    select coalesce(pr.sku_base, eq.sku_base) as sku,
           coalesce(gd.created_at, g.fecha) as ts,
           sum(coalesce(gd.cant_recibida, 0)) as cant
      from wh.guias g
      join wh.guia_detalle gd on gd.id_guia = g.id_guia
      left join mos.productos    pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
     where coalesce(g.id_zona,'') = v_zona
       and g.tipo like 'SALIDA%'
       and wh._bucket_dom((g.fecha at time zone 'America/Lima')::date) = v_bucket
       and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
       and coalesce(pr.sku_base, eq.sku_base) is not null
     group by 1, 2
  ),
  eventos as (
    select sku, ts, 'pedido'::text as tipo, fuente, ped as cant from pedidos
    union all
    select sku, ts, 'despacho'::text as tipo, 'GUIA_SALIDA' as fuente, cant from despachos
  )
  select coalesce(jsonb_object_agg(sku, h), '{}'::jsonb) into v_hist
    from (
      select sku, jsonb_agg(jsonb_build_object(
               'fecha',  to_char(ts at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI'),
               'tipo',   tipo,
               'fuente', fuente,
               'pedido', case when tipo = 'pedido'  then cant end,
               'cant',   cant
             ) order by ts) h
        from eventos where coalesce(sku,'') <> ''
       group by sku
    ) z;
  v_hist := coalesce(v_hist, '{}'::jsonb);

  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', it->>'skuBase',
           'nombre', coalesce(it->>'nombre', it->>'skuBase'),
           'solicitado', wh._num(coalesce(it->>'solicitado','0')),
           'despachado', wh._num(coalesce(it->>'despachado','0')),
           'pendiente', greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))),
           'tsSolicitud', it->>'tsSolicitud',   -- [607] hora en que el producto entró al acumulado
           'tsDespacho',  it->>'tsDespacho',    -- [607] hora del último despacho marcado (WH)
           'sinSku', coalesce((it->>'sinSku')::boolean, false),
           'constancia', wh._num(coalesce(it->>'constancia','0')),
           'historial', coalesce(v_hist->(it->>'skuBase'), '[]'::jsonb)
         ) order by greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))) desc), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(v_acum) it
   where coalesce((it->>'sinSku')::boolean, false) = false;   -- [606] constancias van en sinIdentificar

  -- [no-se-entiende] constancias: ahora también CON HORA del pickup que las trajo
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'solicitado', ped, 'despachado', 0,
           'fecha', to_char(ts at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI')
         ) order by ts desc, nombre), '[]'::jsonb)
    into v_sinsku
    from (
      select upper(btrim(coalesce(it->>'nombre',''))) as nombre,
             pk.fecha_creado as ts,
             sum(wh._num(coalesce(it->>'solicitado','0'))) as ped
        from wh.pickups pk
        cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
       where coalesce(pk.id_zona,'') = v_zona
         and coalesce(pk.fuente,'') = 'LISTA_IA'
         and wh._bucket_dom((pk.fecha_creado at time zone 'America/Lima')::date) = v_bucket
         and coalesce(btrim(it->>'skuBase'),'') = ''
         and wh._num(coalesce(it->>'solicitado','0')) > 0
       group by 1, 2
      having sum(wh._num(coalesce(it->>'solicitado','0'))) > 0
    ) q;

  return jsonb_build_object(
    'ok', true, 'zona', v_zona, 'bucket', to_char(v_bucket,'YYYY-MM-DD'),
    'items', v_items,
    'sinIdentificar', coalesce(v_sinsku,'[]'::jsonb),
    'total_items', jsonb_array_length(v_items),
    'total_pendiente', (select coalesce(sum(greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0')))),0)
                          from jsonb_array_elements(v_acum) it
                         where coalesce((it->>'sinSku')::boolean, false) = false));
end;
$function$;

-- ── (3) consolidar v3: sella tsSolicitud al ENTRAR el producto (primera entrada gana)
--       y ARRASTRA tsSolicitud/tsDespacho al re-seed (antes se perdían al reconstruir el item).
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
  v_key       text;
  v_c         numeric;
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

  if v_existing is not null and jsonb_typeof(v_existing) = 'array' then
    for v_it in select * from jsonb_array_elements(v_existing) loop
      v_sku := coalesce(v_it->>'skuBase', '');
      if v_sku = '' then
        if coalesce((v_it->>'sinSku')::boolean, false) then
          v_c := wh._num(coalesce(v_it->>'constancia', v_it->>'solicitado', '0'));
          if v_c > 0 then
            v_key := 'SINSKU::' || coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE');
            v_map := jsonb_set(v_map, array[v_key], jsonb_build_object(
              'skuBase','', 'sinSku', true,
              'nombre', coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE'),
              'solicitado', 0, 'despachado', 0, 'constancia', v_c,
              'tsSolicitud', v_it->>'tsSolicitud'), true);
          end if;
        end if;
        continue;
      end if;
      v_pend := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
      if v_pend <= 0 then continue; end if;
      v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
        'skuBase', v_sku,
        'nombre', coalesce(v_it->>'nombre', v_sku),
        'solicitado', v_pend,
        'despachado', 0,
        'tsSolicitud', v_it->>'tsSolicitud',   -- [607] arrastre (primera entrada gana)
        'tsDespacho',  v_it->>'tsDespacho',    -- [607] arrastre del último despacho
        'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)
      ), true);
    end loop;
  end if;

  for v_cand in
    select id_pickup, items, coalesce(fuente,'') as fuente, fecha_creado from wh.pickups
    where coalesce(id_zona,'') = p_zona
      and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
      and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
      and wh._bucket_dom((fecha_creado at time zone 'America/Lima')::date) <= p_bucket
    for update
  loop
    if jsonb_typeof(v_cand.items) = 'array' then
      for v_it in select * from jsonb_array_elements(v_cand.items) loop
        v_sku := coalesce(v_it->>'skuBase', '');
        if v_sku = '' then
          if coalesce((v_it->>'sinSku')::boolean, false) then
            v_c := wh._num(coalesce(v_it->>'constancia', v_it->>'solicitado', '0'));
            if v_c > 0 then
              v_key := 'SINSKU::' || coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE');
              if v_map ? v_key then
                v_map := jsonb_set(v_map, array[v_key,'constancia'],
                  to_jsonb(wh._num(coalesce(v_map->v_key->>'constancia','0')) + v_c), true);
              else
                v_map := jsonb_set(v_map, array[v_key], jsonb_build_object(
                  'skuBase','', 'sinSku', true,
                  'nombre', coalesce(nullif(btrim(v_it->>'nombre'),''), 'SIN NOMBRE'),
                  'solicitado', 0, 'despachado', 0, 'constancia', v_c,
                  'tsSolicitud', to_char(v_cand.fecha_creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')), true);
              end if;
            end if;
          end if;
          continue;
        end if;
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
            'tsSolicitud', coalesce(v_it->>'tsSolicitud',            -- [607] hora en que el producto entró
                                    to_char(v_cand.fecha_creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')),
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
$function$;
