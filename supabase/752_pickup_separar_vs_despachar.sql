-- 752 · SEPARAR ≠ DESPACHAR (regla del dueño, 12-ago-2026)
-- "escanear en pickup es solo separar productos; este recién se despacha cuando se emite
--  la guía de salida" — la deuda (solicitado) SOLO se mueve al EMITIR la guía
-- (cerrar_pickup_con_despacho 743/749) o al ABSORBER pickups nuevos (cierres/sombras).
--
-- (1) wh.guardar_progreso_pickup → devuelve el REV nuevo. El front sella ese rev y así
--     reconoce el eco de su propio autosave (hoy: escaneás → autosave → trigger rev →
--     realtime → el front cree que OTRO cambió la lista → voz "la lista fue actualizada"
--     + re-siembra baseline con tu propio avance → todas las barras en CERO).
-- (2) wh.consolidar_pickup_zona → el SEED ya NO consume el `despachado` del acumulado.
--     Ese despachado (post-743) es SEPARACIÓN autoguardada sin guía: el seed lo restaba
--     de la deuda como si se hubiera despachado sin emisión, y al emitir la guía se
--     restaba OTRA VEZ (doble descuento — reproducible cuando llega un pickup nuevo en
--     plena jalada). El neteo de las sombras [540] (deuda = max(0, deuda+pedido−despachado))
--     se aplica INLINE al absorber, mismo piso 0 por producto.
-- (3) Migración one-time: acumulados vivos NO tomados netean el despachado que estaba
--     diferido al próximo seed (el mecanismo viejo del 540). Los EN_PROCESO no se tocan:
--     su despachado es separación de un operador trabajando.

-- ═══ (1) autosave devuelve rev ═══════════════════════════════════════════════
CREATE OR REPLACE FUNCTION wh.guardar_progreso_pickup(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp   text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_lock  text := coalesce(p->>'lock_usuario', p->>'lockUsuario', '');
  v_items jsonb := p->'items';
  v_atp   text;
  v_est   text;
  v_now   timestamptz := now();
  v_merge jsonb;
  v_env   jsonb := '{}'::jsonb;   -- [741] payload del dispositivo indexado por producto
  v_rev   bigint;                 -- [752] rev resultante (tg_pickup_rev es BEFORE → RETURNING lo trae)
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select atendido_por, estado into v_atp, v_est from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- [741] indexar lo que manda el dispositivo por clave de producto
  if jsonb_typeof(v_items) = 'array' then
    select coalesce(jsonb_object_agg(wh._pickup_item_key(e.value), e.value), '{}'::jsonb)
      into v_env from jsonb_array_elements(v_items) e;
  end if;

  -- Conflicto de lock; si no había lock, tomarlo (autosave implica que estoy trabajando)
  if v_lock <> '' then
    if coalesce(btrim(v_atp),'') <> '' and not wh._pickup_same_user(v_atp, v_lock) then
      return jsonb_build_object('ok',false,'error','Pickup atendido por '||v_atp,'atendidoPor',v_atp,'conflicto',true);
    end if;
  end if;

  -- [741] FUSIÓN por producto en vez de reemplazo. El dispositivo manda SU copia
  -- de la lista; si mientras la tenía abierta llegó un cierre de caja, la copia
  -- vieja borraba los productos nuevos (de ahí "a cada operador le aparece
  -- distinto" y "cero productos"). Ahora del payload solo se toma el PROGRESO
  -- (despachado y su hora) y los productos que el dispositivo no tenía se
  -- conservan intactos.
  if jsonb_typeof(v_items) = 'array' then
    select coalesce(jsonb_agg(
             case when v_env ? wh._pickup_item_key(base.value)
                  then base.value
                       -- El progreso lo manda quien tiene el candado (uno solo a la vez):
                       -- se toma su valor TAL CUAL, para que el boton "-" pueda corregir
                       -- hacia abajo. Lo que no puede es borrar productos: de eso se encarga
                       -- la fusion por clave.
                       || jsonb_build_object('despachado',
                            coalesce(((v_env -> wh._pickup_item_key(base.value))->>'despachado')::numeric,
                                     coalesce((base.value->>'despachado')::numeric,0)))
                       || case when (v_env -> wh._pickup_item_key(base.value)) ? 'tsDespacho'
                               then jsonb_build_object('tsDespacho', (v_env -> wh._pickup_item_key(base.value))->'tsDespacho')
                               else '{}'::jsonb end
                  else base.value end), '[]'::jsonb)
      into v_merge
      from wh.pickups pk, jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) base
     where pk.id_pickup = v_idp;

    -- productos que el dispositivo trae y en la base NO existen (raro, pero no se pierden)
    select v_merge || coalesce(jsonb_agg(nue.value), '[]'::jsonb)
      into v_merge
      from jsonb_array_elements(v_items) nue
     where not exists (
       select 1 from jsonb_array_elements(v_merge) b
        where wh._pickup_item_key(b.value) = wh._pickup_item_key(nue.value));
  end if;

  update wh.pickups
     set items            = coalesce(v_merge, items),
         atendido_por     = case when v_lock <> '' and coalesce(btrim(atendido_por),'')='' then v_lock else atendido_por end,
         estado           = case when upper(coalesce(estado,'')) = 'PENDIENTE' then 'EN_PROCESO' else estado end,
         ultima_actividad = v_now
   where id_pickup = v_idp
   returning rev into v_rev;
  -- [752] el front sella este rev: su propio autosave deja de parecer "cambio ajeno"
  return jsonb_build_object('ok',true,'rev',v_rev);
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$function$;

-- ═══ (2) consolidador: el seed preserva la separación; el neteo 540 va inline ═══
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
     set estado = 'PENDIENTE', atendido_por = ''
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
          -- Antes el despachado de la sombra se SUMABA al item y el próximo seed lo neteaba;
          -- ahora que el campo `despachado` del acumulado es separación del operador, el
          -- neteo se aplica acá mismo y ese campo no se toca.
          v_map := jsonb_set(v_map, array[v_sku,'solicitado'],
            to_jsonb(greatest(0, wh._num(coalesce(v_map->v_sku->>'solicitado','0')) + v_sol_add - v_desp_add)), true);
        else
          -- [752] item nuevo: entra ya neteado (piso 0 por producto); si el neto es 0 no
          -- genera deuda (exceso de la sombra JAMÁS acredita — regla R2).
          if greatest(0, v_sol_add - v_desp_add) > 0 then
            v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
              'skuBase', v_sku,
              'nombre', coalesce(v_it->>'nombre', v_sku),
              'solicitado', greatest(0, v_sol_add - v_desp_add),
              'despachado', 0,
              'tsSolicitud', coalesce(v_it->>'tsSolicitud',            -- [607] hora en que el producto entró
                                      to_char(v_cand.fecha_creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')),
              'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb),
              -- [742] historial: de dónde salió esta demanda y cuándo
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

  update wh.pickups
     set estado = 'REZAGADO', atendido_por = ''
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

-- ═══ (3) migración one-time: netear el 540 diferido de acumulados NO tomados ═══
-- El mecanismo viejo dejaba el `despachado` de las sombras absorbidas esperando el
-- próximo seed. Con el seed nuevo ya nadie lo netearía → se netea AHORA, una vez.
-- Los EN_PROCESO no se tocan (su despachado es separación de un operador activo).
update wh.pickups pk
   set items = (
     select coalesce(jsonb_agg(
       case when coalesce((it->>'sinSku')::boolean, false) then it
            else jsonb_set(jsonb_set(it,
                   '{solicitado}', to_jsonb(greatest(0, wh._num(coalesce(it->>'solicitado','0')) - wh._num(coalesce(it->>'despachado','0'))))),
                   '{despachado}', to_jsonb(0))
       end), '[]'::jsonb)
     from jsonb_array_elements(pk.items) it)
 where pk.fuente = 'ACUMULADO_SEMANAL'
   and upper(coalesce(pk.estado,'')) in ('PENDIENTE','PARCIAL')
   and jsonb_typeof(pk.items) = 'array'
   and exists (select 1 from jsonb_array_elements(pk.items) x
               where not coalesce((x->>'sinSku')::boolean, false)
                 and wh._num(coalesce(x->>'despachado','0')) > 0);
