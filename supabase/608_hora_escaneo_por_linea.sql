-- 608_hora_escaneo_por_linea.sql — [TRAZABILIDAD · LA LÍNEA LLEVA LA HORA DEL ESCANEO, NO LA DE LA GUÍA]
-- Regla del dueño (2026-08-01): la creación de la GUÍA y el ESCANEO de cada producto son dos
-- eventos con horas distintas — en TODO flujo (ingreso, salida, despacho de carrito, pickup),
-- cada línea debe registrar SU hora de escaneo. Complementa 607:
-- (1) wh.crear_despacho_rapido acepta 'ts' opcional por ítem (ISO, sellado por el front al
--     escanear/agregar al carrito o al marcar el pickup) → guia_detalle.created_at = esa hora.
--     Sin ts → now() (comportamiento previo, guías de golpe). ts inválido → now() (jamás rompe).
-- (2) wh.cerrar_pickup_con_despacho propaga el tsDespacho de cada item del acumulado (sellado
--     en cada marca por WH 2.13.524) al 'ts' del detalle de la guía GPCK.
-- WH 2.13.525 sella ts en el carrito al agregar y lo manda en el payload; el despachoDetalle del
-- pickup lleva el tsDespacho del item.

CREATE OR REPLACE FUNCTION wh.crear_despacho_rapido(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '20s'
AS $function$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_tipo    text := upper(coalesce(nullif(btrim(coalesce(p->>'tipo','')),''),'SALIDA_ZONA'));
  v_zona    text := coalesce(p->>'id_zona','');
  v_usuario text := coalesce(p->>'usuario','');
  v_coment  text := coalesce(p->>'comentario','');
  v_items   jsonb := coalesce(p->'items', '[]'::jsonb);
  v_ingreso boolean;
  v_estado  text;
  v_it      jsonb;
  v_cod     text;
  v_cant    numeric;
  v_linea   int := 0;
  v_monto   numeric := 0;
  v_consol  jsonb := '{}'::jsonb;
  v_tsmap   jsonb := '{}'::jsonb;      -- [608] cod → ts del último escaneo reportado
  v_ts      timestamptz;               -- [608]
  v_key     text;
  v_acum    numeric;
  v_d       record;
  v_signo   numeric;
  v_antes   numeric;
  v_despues numeric;
  v_idmov   text;
  v_aplicadas int := 0;
  v_fefo    jsonb;                    -- [527]
  v_lotesz  jsonb := '[]'::jsonb;     -- [527]
begin
  if coalesce((select valor from mos.config where clave='WH_CREAR_DESPACHO_RAPIDO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_DESPACHO_RAPIDO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_tipo not in ('INGRESO_PROVEEDOR','INGRESO_JEFATURA','INGRESO_ENVASADO','INGRESO_DEVOLUCION_ZONA',
                    'SALIDA_DEVOLUCION','SALIDA_ZONA','SALIDA_JEFATURA','SALIDA_ENVASADO','SALIDA_MERMA') then
    return jsonb_build_object('ok',false,'error','TIPO_INVALIDO','tipo',v_tipo);
  end if;
  if v_tipo = 'SALIDA_ZONA' and btrim(v_zona) = '' then
    return jsonb_build_object('ok',false,'error','ZONA_REQUERIDA');
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',false,'error','CARRITO_VACIO');
  end if;

  begin
    insert into wh.guias (id_guia, tipo, fecha, usuario, id_proveedor, id_zona, numero_documento,
      comentario, monto_total, estado, id_preingreso, foto)
    values (v_id, v_tipo, now(), v_usuario, '', v_zona, '', v_coment, 0, 'ABIERTA', '', '');
  exception when unique_violation then
    return jsonb_build_object('ok',true,'dedup',true,'idGuia',v_id,
      'estado',(select estado from wh.guias where id_guia = v_id));
  end;

  v_ingreso := (v_tipo like 'INGRESO%' or v_tipo like 'ENTRADA%');

  -- Consolidar items por codigoBarra (suma cantidades; descarta cod vacío / cant<=0).
  -- [608] + mapa cod→ts del escaneo (el último reportado gana).
  for v_it in select * from jsonb_array_elements(v_items)
  loop
    v_cod  := nullif(btrim(upper(coalesce(v_it->>'codigo_barra', v_it->>'codigoBarra', ''))), '');
    v_cant := wh._num(coalesce(v_it->>'cantidad', '0'));
    if v_cod is null or v_cant <= 0 then continue; end if;
    v_acum := wh._num(coalesce(v_consol->>v_cod, '0')) + v_cant;
    v_consol := jsonb_set(v_consol, array[v_cod], to_jsonb(v_acum), true);
    if nullif(btrim(coalesce(v_it->>'ts','')),'') is not null then
      v_tsmap := jsonb_set(v_tsmap, array[v_cod], to_jsonb(v_it->>'ts'), true);
    end if;
  end loop;

  if v_consol = '{}'::jsonb then
    update wh.guias set estado = 'CERRADA', monto_total = 0 where id_guia = v_id;
    return jsonb_build_object('ok',true,'dedup',false,'idGuia',v_id,'estado','CERRADA',
      'items',0,'errores',jsonb_build_array());
  end if;

  -- Insertar detalle (1 línea por cod) — [608] created_at = hora del ESCANEO si el front la mandó.
  for v_key, v_acum in select key, value::text::numeric from jsonb_each_text(v_consol)
  loop
    v_linea := v_linea + 1;
    v_ts := null;
    begin v_ts := nullif(v_tsmap->>v_key,'')::timestamptz; exception when others then v_ts := null; end;
    insert into wh.guia_detalle (id_guia, linea, cod_producto, cant_esperada, cant_recibida,
      precio_unitario, id_lote, observacion, id_producto_nuevo, id_detalle, fecha_vencimiento, cantidad_aplicada, created_at)
    values (v_id, v_linea, v_key, v_acum, v_acum, 0, '', '', '',
      'DET_'||v_id||'#'||v_linea, null, 0, coalesce(v_ts, now()));
  end loop;

  -- CIERRE: aplicar stock por línea (ATÓMICO) + kardex único (guia#linea).
  for v_d in
    select linea, cod_producto, cant_recibida from wh.guia_detalle where id_guia = v_id order by linea asc
  loop
    v_cod  := nullif(btrim(v_d.cod_producto), '');
    v_cant := wh._num(v_d.cant_recibida::text);
    if v_cod is null or v_cant = 0 then
      update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      continue;
    end if;
    v_signo := case when v_ingreso then v_cant else -v_cant end;
    v_idmov := 'MOVID_' || v_id || '#' || v_d.linea;

    update wh.stock
       set cantidad_disponible = cantidad_disponible + v_signo, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then
      v_antes := v_despues - v_signo;
    else
      v_antes := 0; v_despues := v_signo;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values ('STK'||v_id||'_'||v_cod, v_cod, v_despues, now());
    end if;

    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values (v_idmov, now(), v_cod, v_signo, v_antes, v_despues, 'CIERRE_GUIA', v_id, coalesce(nullif(v_usuario,''),'despacho-rapido'))
    on conflict (id_mov) do nothing;

    -- [527] LIBRO DE LOTES (blindado)
    begin
      if v_signo < 0 then
        v_fefo := wh._consumir_lotes_fefo(v_cod, -v_signo, v_id||'#'||v_d.linea,
                    'despacho '||v_tipo, coalesce(nullif(v_usuario,''),'despacho-rapido'));
        if v_tipo = 'SALIDA_ZONA' then v_lotesz := v_lotesz || v_fefo; end if;
      elsif v_tipo = 'INGRESO_DEVOLUCION_ZONA' and v_signo > 0 and coalesce(btrim(v_zona),'') <> '' then
        perform me.zona_consumir_fefo_cod(v_zona, v_cod, v_signo, 'devolucion '||v_id);
      end if;
    exception when others then null;
    end;

    update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
    v_aplicadas := v_aplicadas + 1;
  end loop;

  -- [527] herencia de lotes a la zona (idempotente; best-effort)
  if v_tipo = 'SALIDA_ZONA' and coalesce(btrim(v_zona),'') <> '' and jsonb_array_length(v_lotesz) > 0 then
    begin
      perform wh.propagar_lotes_zona_cierre(jsonb_build_object(
        'id_guia', v_id, 'zona', v_zona, 'lotes', v_lotesz));
    exception when others then null;
    end;
  end if;

  update wh.guias set estado = 'CERRADA', monto_total = 0 where id_guia = v_id;

  return jsonb_build_object('ok',true,'dedup',false,'idGuia',v_id,'estado','CERRADA',
    'items',v_linea,'lineasAplicadas',v_aplicadas,'errores',jsonb_build_array());
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM,'idGuia',v_id);
end;
$function$;

-- [608] cerrar_pickup_con_despacho: el despachoDetalle derivado de items lleva el tsDespacho del item.
-- (Cuando el front manda despacho_detalle explícito, ya incluye ts por código desde WH 2.13.525.)
-- Solo cambia la derivación: se agrega 'ts' al objeto. Resto de la función intacta → patch quirúrgico
-- vía recreación (la versión base es la de 603).

CREATE OR REPLACE FUNCTION wh.cerrar_pickup_con_despacho(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '20s'
AS $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup', '')), '');
  v_usuario text := coalesce(p->>'usuario', '');
  v_items   jsonb := coalesce(p->'items', '[]'::jsonb);
  v_det     jsonb := coalesce(p->'despacho_detalle', p->'despachoDetalle', '[]'::jsonb);
  v_pickup  record;
  v_est_up  text;
  v_it      jsonb;
  v_cod     text;
  v_qty     numeric;
  v_total_desp numeric := 0;
  v_no_desp int := 0;
  v_nuevo_estado text;
  v_idguia  text := null;
  v_guia_prev text;
  v_desp_res jsonb;
  v_now     timestamptz := now();
begin
  -- Gate propio (kill-switch). OFF → frontend cae a GAS.
  if coalesce((select valor from mos.config where clave = 'WH_CERRAR_PICKUP_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'WH_CERRAR_PICKUP_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok', false, 'error', 'Requiere idPickup'); end if;

  -- Leer pickup con lock (serializa contra retry/doble-tap concurrente del mismo id)
  select * into v_pickup from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pickup no encontrado'); end if;

  -- ── IDEMPOTENCIA NIVEL 1: solo PENDIENTE/EN_PROCESO son despachables ──
  v_est_up := upper(coalesce(v_pickup.estado, ''));
  if v_est_up not in ('PENDIENTE', 'EN_PROCESO', '') then
    return jsonb_build_object('ok', false,
      'error', 'El pickup ya no es despachable (estado=' || v_est_up || ')', 'yaCerrado', true);
  end if;

  -- ── IDEMPOTENCIA NIVEL 2 (FIX 414): guía para este pickup en los ÚLTIMOS 90 MIN ──
  select id_guia into v_guia_prev
  from wh.guias
  where comentario like '%[pickup:' || v_idp || ']%'
    and fecha > v_now - interval '90 minutes'
  order by fecha desc
  limit 1;
  if v_guia_prev is not null then
    -- [603] el reintento tampoco debe DESAPARECER un acumulador con deuda: si es
    -- ACUMULADO_SEMANAL queda PENDIENTE (cuenta corriente), no COMPLETADO a ciegas.
    update wh.pickups
       set estado           = case
                                when upper(coalesce(estado,'')) not in ('PENDIENTE','EN_PROCESO','') then estado
                                when coalesce(fuente,'') = 'ACUMULADO_SEMANAL'
                                     and exists (select 1 from jsonb_array_elements(coalesce(items,'[]'::jsonb)) e
                                                  where wh._num(coalesce(e->>'solicitado','0')) > wh._num(coalesce(e->>'despachado','0')))
                                  then 'PENDIENTE'
                                else 'COMPLETADO' end,
           fecha_atendido   = coalesce(fecha_atendido, v_now),
           atendido_por     = '',
           ultima_actividad = v_now
     where id_pickup = v_idp;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'idGuia', v_guia_prev, 'estado', 'COMPLETADO', 'yaCerrado', true, 'idempotente', true));
  end if;

  -- ── Derivar despachoDetalle desde items si no vino (codigosOriginales[0]) ──
  if jsonb_typeof(v_det) <> 'array' or jsonb_array_length(v_det) = 0 then
    v_det := '[]'::jsonb;
    for v_it in select * from jsonb_array_elements(v_items) loop
      v_qty := wh._num(coalesce(v_it->>'despachado', '0'));
      if v_qty <= 0 then continue; end if;
      v_cod := nullif(btrim(coalesce(v_it->'codigosOriginales'->>0, '')), '');
      if v_cod is null then continue; end if;
      v_det := v_det || jsonb_build_array(jsonb_build_object('codigo_barra', v_cod, 'cantidad', v_qty, 'ts', v_it->>'tsDespacho'));   -- [608] hora del escaneo
    end loop;
  end if;

  -- Total despachado
  for v_it in select * from jsonb_array_elements(v_det) loop
    v_total_desp := v_total_desp + wh._num(coalesce(v_it->>'cantidad', '0'));
  end loop;

  -- No despachados: solicitado > despachado
  select count(*) into v_no_desp
  from jsonb_array_elements(v_items) e
  where wh._num(coalesce(e->>'solicitado', '0')) > wh._num(coalesce(e->>'despachado', '0'));

  -- [603] CUENTA CORRIENTE: el acumulador semanal con deuda restante queda PENDIENTE
  -- (siempre visible/re-despachable). Antes: PARCIAL (oculto) o CANCELADO (cuenta muerta).
  v_nuevo_estado := case
    when v_no_desp = 0 then 'COMPLETADO'
    when coalesce(v_pickup.fuente,'') = 'ACUMULADO_SEMANAL' then 'PENDIENTE'
    when v_total_desp > 0 then 'PARCIAL'
    else 'CANCELADO'
  end;

  -- ── Crear GUIA_SALIDA si hubo al menos un item despachado ──
  -- (FIX 414) id POR CIERRE: cada despacho de la semana del acumulador genera su
  -- guía propia. El anti-duplicado del retry es la ventana de 90 min del NIVEL 2.
  if v_total_desp > 0 then
    v_idguia := 'GPCK_' || v_idp || '_' || to_char(v_now at time zone 'America/Lima', 'YYYYMMDD_HH24MISS');
    v_desp_res := wh.crear_despacho_rapido(jsonb_build_object(
      'id_guia',    v_idguia,
      'tipo',       'SALIDA_ZONA',
      'id_zona',    coalesce(v_pickup.id_zona, ''),
      'usuario',    v_usuario,
      'comentario', '[pickup:' || v_idp || ']',
      'items',      v_det
    ));
    if coalesce((v_desp_res->>'ok'), 'false') <> 'true' then
      return jsonb_build_object('ok', false,
        'error', 'Falló GUIA_SALIDA: ' || coalesce(v_desp_res->>'error', '?'));
    end if;
    v_idguia := coalesce(v_desp_res->>'idGuia', v_idguia);
  end if;

  -- ── Actualizar pickup ──
  update wh.pickups
     set items            = v_items,
         estado           = v_nuevo_estado,
         fecha_atendido   = v_now,
         atendido_por     = '',
         ultima_actividad = v_now
   where id_pickup = v_idp;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia',        v_idguia,
    'estado',        v_nuevo_estado,
    'despachados',   jsonb_array_length(v_det),
    'noDespachados', v_no_desp
  ));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$function$;
