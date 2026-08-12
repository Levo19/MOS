-- 753 · SOLTAR = LA SEPARACIÓN NUNCA EXISTIÓ (regla del dueño, 12-ago-2026)
-- "al soltar una pickup todo debe regresar a la normalidad: lo que fue separado queda en
--  cero como si no se hubiera tocado — la deuda como si no hubiera despachado nada"
-- Complementa la R3 del análisis: separación sin guía emitida NO es despacho. Se descarta en
-- los TRES caminos de soltar:
--   (1) wh.liberar_pickup (botón 🔓 SOLTAR) — antes conservaba el progreso y hasta mantenía
--       EN_PROCESO si había separación ("hayProgreso"). Ahora: despachado→0, se quita el
--       tsDespacho de lo descartado (esa hora era de la separación que nunca salió), estado
--       vuelve a PENDIENTE y el candado se suelta.
--   (2) candado vencido (1h sin actividad, dentro de consolidar_pickup_zona) — mismo reseteo.
--   (3) week-death → REZAGADO — la separación muere con la semana (la lista de compra del
--       lunes lleva la deuda completa).
-- El único camino donde la separación se convierte en despacho es EMITIR LA GUÍA
-- (cerrar_pickup_con_despacho 743/749), que colapsa deuda y resetea en el acto.

-- helper: items con la separación descartada (despachado→0, sin tsDespacho de lo descartado)
create or replace function wh._items_sin_separacion(v_items jsonb)
returns jsonb language sql immutable
set search_path to ''
as $fn$
  select case when jsonb_typeof(v_items) = 'array' then
    coalesce(
      (select jsonb_agg(
         case when wh._num(coalesce(e->>'despachado','0')) > 0
              then (e - 'tsDespacho') || jsonb_build_object('despachado', 0)
              else e end)
       from jsonb_array_elements(v_items) e),
      '[]'::jsonb)
  else v_items end
$fn$;

-- ═══ (1) soltar manual ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION wh.liberar_pickup(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp   text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_items jsonb;
  v_hay   boolean;
  v_now   timestamptz := now();
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select items into v_items from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- ¿había separación? (solo informativo — se descarta igual)
  select exists (
    select 1 from jsonb_array_elements(case when jsonb_typeof(v_items)='array' then v_items else '[]'::jsonb end) e
    where wh._num(coalesce(e->>'despachado','0')) > 0
  ) into v_hay;

  -- [753] soltar = descartar la separación: la lista queda como si no se hubiera tocado.
  update wh.pickups
     set items            = wh._items_sin_separacion(items),
         atendido_por     = '',
         estado           = case when upper(coalesce(estado,'')) = 'EN_PROCESO' then 'PENDIENTE' else estado end,
         ultima_actividad = v_now
   where id_pickup = v_idp;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('separacionDescartada', v_hay));
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$function$;

-- ═══ (2)+(3) candado vencido y week-death, dentro del consolidador ═══════════
-- Se re-crea la función completa (base = 752) tocando SOLO esos dos UPDATEs.
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
  -- [753] candado vencido (1h) = soltar: la separación se descarta (R3: "se devuelve
  -- y queda como no escaneado — nunca hubo salida").
  update wh.pickups
     set estado = 'PENDIENTE', atendido_por = '',
         items  = wh._items_sin_separacion(items)
   where coalesce(id_zona,'') = p_zona
     and upper(coalesce(estado,'')) = 'EN_PROCESO'
     and ultima_actividad < v_now - interval '1 hour';
  get diagnostics v_lib = row_count;

  select items, estado into v_existing, v_est
    from wh.pickups where id_pickup = v_acum_id for update;
  -- [741] ANTES aquí había un `return skip EN_PROCESO`: si alguien tenía la lista
  -- tomada, el consolidador se iba sin hacer NADA — no absorbía los cierres de caja
  -- nuevos y no mataba el acumulado de la semana anterior (así nacieron los dos
  -- acumulados vivos de una misma zona). Se consolida igual: la fusión SUMA por
  -- producto y conserva lo ya despachado, así que no le borra el trabajo a nadie.

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
      -- [752] SEPARAR ≠ DESPACHAR: el seed ya NO netea `solicitado − despachado`.
      -- El despachado del acumulado (post-743) es separación autoguardada SIN guía:
      -- restarla aquí mataba deuda sin emisión y la emisión la volvía a restar.
      -- La deuda solo la mueven cerrar_pickup_con_despacho (emisión) y la absorción
      -- de pickups nuevos (neteo 540 inline, más abajo).
      v_pend := wh._num(coalesce(v_it->>'solicitado','0'));
      if v_pend <= 0 then continue; end if;
      v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
        'skuBase', v_sku,
        'nombre', coalesce(v_it->>'nombre', v_sku),
        'solicitado', v_pend,
        'despachado', wh._num(coalesce(v_it->>'despachado','0')),   -- [752] separación en curso: se arrastra
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
          -- [752] neteo 540 INLINE: deuda = max(0, deuda + pedido − despachado_de_la_sombra).
          v_map := jsonb_set(v_map, array[v_sku,'solicitado'],
            to_jsonb(greatest(0, wh._num(coalesce(v_map->v_sku->>'solicitado','0')) + v_sol_add - v_desp_add)), true);
        else
          -- [752] item nuevo: entra ya neteado (piso 0 por producto).
          if greatest(0, v_sol_add - v_desp_add) > 0 then
            v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
              'skuBase', v_sku,
              'nombre', coalesce(v_it->>'nombre', v_sku),
              'solicitado', greatest(0, v_sol_add - v_desp_add),
              'despachado', 0,
              'tsSolicitud', coalesce(v_it->>'tsSolicitud',
                                      to_char(v_cand.fecha_creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')),
              'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb),
              'mov', (wh._mov_add(
                        coalesce(v_map -> v_key, '{}'::jsonb),
                        'pedido', coalesce((v_it->>'solicitado')::numeric,0),
                        coalesce(v_cand.fuente,''), v_cand.id_pickup, v_cand.fecha_creado
                      ))->'mov'
            ), true);
          end if;
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
    -- [741] NO se toca ultima_actividad: es el reloj del candado y solo debe moverla
    -- el operador. Estamparla aquí hacía que el candado no venciera nunca.
    update wh.pickups
       set items = v_items_out,
           estado = case when upper(coalesce(estado,'')) in ('PENDIENTE','EN_PROCESO') then estado else 'PENDIENTE' end
     where id_pickup = v_acum_id;
  elsif jsonb_array_length(v_items_out) > 0 then
    insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
    values (v_acum_id, 'ACUMULADO_SEMANAL', 'PENDIENTE', v_items_out, p_zona,
            'ACUMULADO semana-domingo ' || to_char(p_bucket,'YYYY-MM-DD'), 'sistema', v_now, v_now);
  end if;

  -- [753] week-death: la separación muere con la semana — el REZAGADO (lista de compra
  -- del lunes) lleva la deuda COMPLETA, sin separación fantasma.
  update wh.pickups
     set estado = 'REZAGADO', atendido_por = '',
         items  = wh._items_sin_separacion(items)
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
