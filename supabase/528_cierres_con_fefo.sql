-- 528_cierres_con_fefo.sql — FASE 2 · hooks FEFO en los 3 cierres (ver 527 para la historia).
-- Cada hook va BLINDADO (begin/exception → null): el libro de lotes JAMÁS tumba un cierre de
-- dinero. Los redefines son fieles a prod (dump 2026-07-19) + el bloque [527] marcado.

-- ── 1) wh.cerrar_guia_idempotente ─ salidas consumen lotes FEFO; SALIDA_ZONA hereda a la zona;
--       INGRESO_DEVOLUCION_ZONA descuenta el libro de la zona (la zona devolvió esas unidades).
CREATE OR REPLACE FUNCTION wh.cerrar_guia_idempotente(p_id_guia text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '20s'
AS $function$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_zona      text;      -- [527] id_zona de la guía (herencia de lotes / devolución)
  v_ingreso   boolean;
  v_envasado  boolean;
  v_monto     numeric := 0;
  v_d         record;
  v_cod       text;
  v_cant      numeric;
  v_apl       numeric;
  v_delta     numeric;   -- cant_recibida − cantidad_aplicada (lo que falta aplicar)
  v_signo     numeric;   -- delta de stock con signo según ingreso/salida
  v_antes     numeric;
  v_despues   numeric;
  v_idmov     text;
  v_aplicadas int := 0;
  v_saltadas  int := 0;
  v_fefo      jsonb;                    -- [527] asignaciones FEFO de la línea
  v_lotesz    jsonb := '[]'::jsonb;     -- [527] acumulado para heredar a la zona
begin
  -- [152] gate de app: pasa para token WH (jwt_app='warehouseMos') y para
  -- service_role/cron (jwt_app=''). Bloquea otras apps. Consistencia con el
  -- resto de RPCs de dinero (cerrar_guia/reabrir_guia ya lo tienen).
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- lock de cabecera: serializa contra cierres concurrentes (doble-tap / cron + manual)
  select estado, tipo, id_zona into v_estado, v_tipo, v_zona from wh.guias where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo     := upper(coalesce(v_tipo,''));
  v_ingreso  := (v_tipo like 'INGRESO%' or v_tipo like 'ENTRADA%');
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  -- monto total = Σ(cant_recibida × precio_unitario)   (igual que cerrar_guia)
  select coalesce(sum(wh._num(cant_recibida::text) * wh._num(precio_unitario::text)), 0)
    into v_monto from wh.guia_detalle where id_guia = v_id;

  -- aplicar por detalle (saltar si envasado: el stock ya lo aplicó Envasados)
  if not v_envasado then
    for v_d in
      select linea, cod_producto, cant_recibida, cantidad_aplicada
        from wh.guia_detalle
       where id_guia = v_id
       order by linea asc nulls last
    loop
      v_cod  := nullif(btrim(v_d.cod_producto), '');
      v_cant := wh._num(v_d.cant_recibida::text);
      v_apl  := wh._num(coalesce(v_d.cantidad_aplicada, 0)::text);
      v_delta := v_cant - v_apl;

      -- línea sin producto → solo alinear marca, sin stock
      if v_cod is null then
        update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
        continue;
      end if;

      -- delta 0 → SKIP TOTAL: no toca stock ni kardex. (red de seguridad anti-duplicado)
      if v_delta = 0 then
        v_saltadas := v_saltadas + 1;
        continue;
      end if;

      v_signo := case when v_ingreso then v_delta else -v_delta end;
      -- origen único por línea: una sola fila de kardex por (guia, linea) aunque se recierre N veces.
      v_idmov := 'MOVID_' || v_id || '#' || v_d.linea;

      -- ── stock ATÓMICO: cantidad + signo (nunca read-modify-write). 1ra fila por producto (como GAS).
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

      -- kardex con origen único (id_guia#linea) → on conflict do nothing protege la traza
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_idmov, now(), v_cod, v_signo, v_antes, v_despues, 'CIERRE_GUIA', v_id, 'sistema-cierre-idem')
      on conflict (id_mov) do nothing;

      -- [527] LIBRO DE LOTES (blindado — jamás tumba el cierre):
      --   salida → consume lotes WH FEFO (vence primero, sale primero); SALIDA_ZONA acumula
      --   las asignaciones para heredarlas a la zona. Devolución de zona → descuenta el libro
      --   de esa zona (la zona ya no tiene esas unidades).
      begin
        if v_signo < 0 then
          v_fefo := wh._consumir_lotes_fefo(v_cod, -v_signo, v_id||'#'||v_d.linea,
                      'cierre '||v_tipo, 'sistema-cierre-idem');
          if v_tipo = 'SALIDA_ZONA' then v_lotesz := v_lotesz || v_fefo; end if;
        elsif v_tipo = 'INGRESO_DEVOLUCION_ZONA' and v_signo > 0 and coalesce(btrim(v_zona),'') <> '' then
          perform me.zona_consumir_fefo_cod(v_zona, v_cod, v_signo, 'devolucion '||v_id);
        end if;
      exception when others then null;
      end;

      -- marcar la línea como aplicada al 100% (recerrar dará delta 0)
      update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      v_aplicadas := v_aplicadas + 1;
    end loop;
  end if;

  -- [527] herencia de lotes a la zona destino (RPC existente, idempotente por zona/lote/guía)
  if v_tipo = 'SALIDA_ZONA' and coalesce(btrim(v_zona),'') <> '' and jsonb_array_length(v_lotesz) > 0 then
    begin
      perform wh.propagar_lotes_zona_cierre(jsonb_build_object(
        'id_guia', v_id, 'zona', v_zona, 'lotes', v_lotesz));
    exception when others then null;
    end;
  end if;

  -- cerrar cabecera
  update wh.guias set estado = 'CERRADA', monto_total = v_monto where id_guia = v_id;

  return jsonb_build_object('ok', true, 'id_guia', v_id, 'estado', 'CERRADA',
    'montoTotal', v_monto, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'id_guia', v_id);
end;
$function$;

-- ── 2) wh.crear_despacho_rapido ─ mismos hooks en su cierre inline.
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
  -- consolidación in-memory (1 línea por codigoBarra), igual que _agregarDetallesBatchImpl
  v_consol  jsonb := '{}'::jsonb;
  v_key     text;
  v_acum    numeric;
  -- cierre de stock
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

  -- IDEMPOTENCIA: la guía es la clave única estable (id sembrado del localId del front).
  -- Si ya existe, la operación entera ya se hizo (header+detalle+stock se commitearon juntos
  -- en la tx original) → devolver dedup sin re-aplicar nada. Lock de cabecera FOR UPDATE
  -- serializa contra un retry concurrente del mismo id.
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
  for v_it in select * from jsonb_array_elements(v_items)
  loop
    v_cod  := nullif(btrim(upper(coalesce(v_it->>'codigo_barra', v_it->>'codigoBarra', ''))), '');
    v_cant := wh._num(coalesce(v_it->>'cantidad', '0'));
    if v_cod is null or v_cant <= 0 then continue; end if;
    v_acum := wh._num(coalesce(v_consol->>v_cod, '0')) + v_cant;
    v_consol := jsonb_set(v_consol, array[v_cod], to_jsonb(v_acum), true);
  end loop;

  if v_consol = '{}'::jsonb then
    -- sin items válidos: dejar la guía vacía cerrada (no mueve stock) — coherente y no rompe
    update wh.guias set estado = 'CERRADA', monto_total = 0 where id_guia = v_id;
    return jsonb_build_object('ok',true,'dedup',false,'idGuia',v_id,'estado','CERRADA',
      'items',0,'errores',jsonb_build_array());
  end if;

  -- Insertar detalle (1 línea por cod) con cantidad_aplicada=0 (se aplica en el cierre de abajo).
  for v_key, v_acum in select key, value::text::numeric from jsonb_each_text(v_consol)
  loop
    v_linea := v_linea + 1;
    insert into wh.guia_detalle (id_guia, linea, cod_producto, cant_esperada, cant_recibida,
      precio_unitario, id_lote, observacion, id_producto_nuevo, id_detalle, fecha_vencimiento, cantidad_aplicada)
    values (v_id, v_linea, v_key, v_acum, v_acum, 0, '', '', '',
      'DET_'||v_id||'#'||v_linea, null, 0);
  end loop;

  -- CIERRE: aplicar stock por línea (ATÓMICO) + kardex único (guia#linea). Misma semántica que
  -- wh.cerrar_guia_idempotente: delta = cant_recibida − cantidad_aplicada (=cant_recibida, aplicada=0
  -- recién insertada) → setea aplicada=cant_recibida (re-cierre futuro daría delta 0). Despacho = SALIDA
  -- normalmente → signo negativo. monto_total = Σ(cant×precio)=0 (despacho rápido sin precios).
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

    -- [527] LIBRO DE LOTES (blindado) — misma semántica que cerrar_guia_idempotente.
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

-- ── 3) me.cerrar_guia_zona_idempotente ─ salidas de zona (SALIDA_JEFA / SALIDA_MOVIMIENTO)
--       consumen el libro de la zona; el traslado hereda los lotes consumidos a la zona destino.
CREATE OR REPLACE FUNCTION me.cerrar_guia_zona_idempotente(p_id_guia text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_zona      text;
  v_zdest     text;          -- zona destino (solo SALIDA_MOVIMIENTO) → espejo IN
  v_signo_in  boolean;       -- la guía SUMA al saldo (entrada/traslado-in) vs resta (salida)
  v_es_venta  boolean;       -- SALIDA_VENTAS: no mueve saldo aquí (lo hace zona_descontar_venta)
  v_es_trasl_in boolean;     -- ENTRADA_TRASLADO: espejo metadata-only de un SALIDA_MOVIMIENTO → NO re-sumar aquí
  v_es_mov    boolean;       -- SALIDA_MOVIMIENTO con destino → aplicar OUT origen + IN espejo destino
  v_aplicar_stock boolean := true;    -- ✅ [GATE-STOCK] ACTIVO (go-live 2026-06-17, sync OFF).
  v_d         record;
  v_cb        text;
  v_cant      numeric(20,3);
  v_apl       numeric(20,3);
  v_delta     numeric(20,3);
  v_signo     numeric(20,3);
  v_refk      text;
  v_kres      jsonb;          -- resultado del kardex → gatear el saldo por dedup (anti doble-conteo)
  v_dedup     boolean;        -- [527] dedup del kardex origen (gobierna saldo Y libro de lotes)
  v_fefo      jsonb;          -- [527]
  v_a         jsonb;          -- [527] iterador de asignaciones para heredar al destino
  v_aplicadas int := 0;
  v_saltadas  int := 0;
begin
  -- Gate: _claim_zona_ok acepta '' (GAS/service_role), 'MOS' y 'mosExpress' (PWA ME). Superset seguro,
  --   consistente con reabrir_guia_zona / zona_guia_registrar_meta / zona_kardex_registrar. El execute sigue
  --   limitado a service_role (los wrappers me/mos.cerrar_guia_zona, granted a authenticated, son la puerta gated).
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- lock de cabecera: serializa contra cierres concurrentes (doble-tap / cron + manual)
  select estado, tipo, zona_id, zona_destino into v_estado, v_tipo, v_zona, v_zdest
    from me.guias_cabecera where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo        := upper(coalesce(v_tipo,''));
  v_zona        := upper(btrim(coalesce(v_zona,'')));
  v_zdest       := upper(nullif(btrim(coalesce(v_zdest,'')),''));
  v_signo_in    := (v_tipo like 'ENTRADA%' or v_tipo like 'TRASLADO_IN%');
  v_es_venta    := (v_tipo = 'SALIDA_VENTAS' or v_tipo = 'SALIDA_VENTA');
  v_es_trasl_in := (v_tipo = 'ENTRADA_TRASLADO');                       -- espejo metadata-only → no mueve saldo aquí
  v_es_mov      := (v_tipo = 'SALIDA_MOVIMIENTO' and v_zdest is not null);

  for v_d in
    select linea, cod_barras, cantidad, cantidad_aplicada
      from me.guias_detalle
     where id_guia = v_id
     order by linea asc nulls last
  loop
    v_cb   := nullif(btrim(coalesce(v_d.cod_barras,'')), '');
    v_cant := coalesce(v_d.cantidad, 0);
    v_apl  := coalesce(v_d.cantidad_aplicada, 0);
    v_delta := v_cant - v_apl;

    -- línea sin código → solo alinear marca, sin stock
    if v_cb is null then
      update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      continue;
    end if;

    -- delta 0 → SKIP TOTAL (red de seguridad anti-duplicado: recerrar/reabrir+recerrar no toca nada)
    if v_delta = 0 then
      v_saltadas := v_saltadas + 1;
      continue;
    end if;

    -- VENTA o ENTRADA_TRASLADO (espejo) → NO mueve saldo aquí. Solo marca aplicado (evita doble-conteo).
    --   · SALIDA_VENTAS: el saldo lo aplica zona_descontar_venta por caja.
    --   · ENTRADA_TRASLADO: su IN ya lo aplica el cierre del SALIDA_MOVIMIENTO origen (espejo abajo).
    if not v_es_venta and not v_es_trasl_in then
      v_signo := case when v_signo_in then v_delta else -v_delta end;
      v_refk  := 'CIERRE-GUIA:'||v_id||':'||v_d.linea;

      -- KARDEX origen (ref única determinista; idempotente aunque se recierre N veces). Gateamos el saldo por dedup.
      v_kres := me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zona, 'codBarra', v_cb,
        'tipo', case when v_signo_in then 'TRASLADO_IN'
                     when v_es_mov   then 'TRASLADO_OUT'
                     else 'SALIDA_JEFA' end,
        'delta', v_signo, 'refTipo', 'GUIA', 'refId', v_refk,
        'usuario', 'sistema-cierre-zona', 'origen', 'CIERRE-IDEM'));
      v_dedup := coalesce((v_kres->>'dedup')::boolean, false);

      -- SALDO atómico origen — SOLO si el kardex NO fue dedup (reintento/doble-tap NO dobla el saldo).
      if v_aplicar_stock and not v_dedup then
        insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
          values (v_cb, v_zona, v_signo, 'sistema-cierre-zona', now())
        on conflict (cod_barras, zona_id) do update
          set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_signo,
              fecha_ultimo_registro = now();
      end if;

      -- [527] LIBRO DE LOTES de la zona (blindado; mismo gate anti-dedup que el saldo):
      --   salida real (jefa / traslado-out / devolución) → consume FEFO de la zona; el traslado
      --   hereda las asignaciones consumidas a la zona destino (idempotente por zona/lote/guía).
      if not v_signo_in and not v_dedup then
        begin
          v_fefo := me.zona_consumir_fefo_cod(v_zona, v_cb, v_delta, v_refk);
          if v_es_mov and coalesce((v_fefo->>'ok')::boolean, false) then
            for v_a in select jsonb_array_elements(coalesce(v_fefo->'aplicados','[]'::jsonb))
            loop
              perform me.zona_recibir_lote(jsonb_build_object(
                'zona', v_zdest,
                'skuBase', v_a->>'skuBase', 'codBarra', coalesce(nullif(v_a->>'codBarra',''), v_cb),
                'idLote', v_a->>'idLote', 'fechaVencimiento', v_a->>'fechaVencimiento',
                'cantidad', (v_a->>'cantidad')::numeric, 'idGuiaOrigen', v_id));
            end loop;
          end if;
        exception when others then null;
        end;
      end if;

      -- ESPEJO DE TRASLADO: SALIDA_MOVIMIENTO con destino → IN en la zona destino (+v_delta). Mismo gate por dedup.
      --   refId distinto (CIERRE-GUIA-IN) → el OUT y el IN nunca se pisan. cantidad_aplicada de la línea (del OUT)
      --   gobierna AMBOS lados → recerrar = delta 0 = SKIP = ni OUT ni IN se re-aplican.
      if v_es_mov then
        v_kres := me.zona_kardex_registrar(jsonb_build_object(
          'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN',
          'delta', v_delta, 'refTipo', 'GUIA', 'refId', 'CIERRE-GUIA-IN:'||v_id||':'||v_d.linea,
          'usuario', 'sistema-cierre-zona', 'origen', 'CIERRE-IDEM'));
        if v_aplicar_stock and not coalesce((v_kres->>'dedup')::boolean, false) then
          insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
            values (v_cb, v_zdest, v_delta, 'sistema-cierre-zona', now())
          on conflict (cod_barras, zona_id) do update
            set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_delta,
                fecha_ultimo_registro = now();
        end if;
      end if;
    end if;

    update me.guias_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
    v_aplicadas := v_aplicadas + 1;
  end loop;

  update me.guias_cabecera set estado = 'CERRADA' where id_guia = v_id;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'estado', 'CERRADA',
    'stockAplicado', v_aplicar_stock, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'idGuia', v_id);
end;
$function$;
