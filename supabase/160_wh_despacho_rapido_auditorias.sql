-- 160_wh_despacho_rapido_auditorias.sql
-- ============================================================
-- [CIERRE 100% · escritura DIRECTA de las 2 migraciones que faltaban en WH]
--
-- 1) wh.crear_despacho_rapido(p)  — ORQUESTADOR ATÓMICO del despacho rápido (SALIDA).
--    Replica _crearDespachoRapidoImpl (Guias.gs) PARTE DE DATOS (la impresión queda en GAS):
--      a. crea la guía cabecera (estado ABIERTA, monto 0),
--      b. inserta el detalle consolidado (1 línea por codigoBarra, cant_aplicada=0),
--      c. cierra la guía aplicando stock ATÓMICO (cantidad += signo·delta) + kardex único
--         por (guia,linea) — MISMA semántica que wh.cerrar_guia_idempotente (152).
--    TODO en UNA transacción. Idempotente por id_guia: re-enviar el MISMO id_guia (sembrado
--    del localId del front) NO duplica guía/detalle/stock/kardex (dedup temprano + on conflict
--    en kardex + cantidad_aplicada como red anti-doble-conteo). Money-safe: nunca read-modify-write.
--    La IMPRESIÓN del ticket NO está acá (la dispara el front aparte vía imprimirTicketGuia → GAS).
--
-- 2) wh.asignar_auditoria(p)  — inserta fila AUDITORIAS estado ASIGNADA con el stock_sistema
--    VIGENTE de wh.stock (lo que el auditor comparará). NO mueve stock. Idempotente por id_auditoria.
--
-- 3) wh.ejecutar_auditoria(p) — registra el conteo físico sobre una auditoría ASIGNADA:
--    setea stock_fisico/diferencia/resultado/observacion/estado=EJECUTADA. NO mueve stock
--    (el path que mueve stock es auditar_producto, ya directo). Idempotente por estado/local_id.
--
-- SEGURIDAD: gates server-side WH_*_DIRECTO=0 (nacen INERTES) + wh._claim_ok(). Idempotente
--   (re-correr el script = redefinir funciones, no-op). No toca datos, sync ni otras RPCs.
-- ============================================================

insert into mos.config (clave, valor, descripcion) values
  ('WH_CREAR_DESPACHO_RAPIDO_DIRECTO','0','WH: despacho rapido directo (orquestador atomico guia+detalle+cierre stock).'),
  ('WH_ASIGNAR_AUDITORIA_DIRECTO','0','WH: asignar auditoria directo (fila AUDITORIAS estado ASIGNADA).'),
  ('WH_EJECUTAR_AUDITORIA_DIRECTO','0','WH: ejecutar auditoria directo (registra conteo fisico, no mueve stock).')
on conflict (clave) do nothing;


-- ── 1) wh.crear_despacho_rapido(p) ───────────────────────────────────────────
-- p = { id_guia, tipo, id_zona, usuario, comentario, local_id,
--       items: [ { codigo_barra, cantidad } ] }
create or replace function wh.crear_despacho_rapido(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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

    update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
    v_aplicadas := v_aplicadas + 1;
  end loop;

  update wh.guias set estado = 'CERRADA', monto_total = 0 where id_guia = v_id;

  return jsonb_build_object('ok',true,'dedup',false,'idGuia',v_id,'estado','CERRADA',
    'items',v_linea,'lineasAplicadas',v_aplicadas,'errores',jsonb_build_array());
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM,'idGuia',v_id);
end;
$fn$;

revoke all on function wh.crear_despacho_rapido(jsonb) from public;
grant execute on function wh.crear_despacho_rapido(jsonb) to service_role, authenticated;


-- ── 2) wh.asignar_auditoria(p) ───────────────────────────────────────────────
-- p = { id_auditoria, codigo_producto, usuario }
-- Inserta fila AUDITORIAS estado ASIGNADA con stock_sistema = stock vigente. NO mueve stock.
create or replace function wh.asignar_auditoria(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_auditoria','')), '');
  v_cod     text := nullif(btrim(coalesce(p->>'codigo_producto', p->>'codigo_barra', '')), '');
  v_usuario text := coalesce(p->>'usuario','');
  v_sistema numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_ASIGNAR_AUDITORIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ASIGNAR_AUDITORIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- idempotencia por id_auditoria
  if exists (select 1 from wh.auditorias where id_auditoria = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'idAuditoria',v_id);
  end if;

  select cantidad_disponible into v_sistema from wh.stock where cod_producto = v_cod order by id_stock limit 1;
  v_sistema := coalesce(v_sistema, 0);

  insert into wh.auditorias (id_auditoria, fecha_asignacion, cod_producto, usuario, stock_sistema, stock_fisico,
    diferencia, resultado, observacion, estado, fecha_ejecucion)
  values (v_id, now(), v_cod, v_usuario, v_sistema, 0, 0, '', '', 'ASIGNADA', null);

  return jsonb_build_object('ok',true,'dedup',false,'idAuditoria',v_id,'stockSistema',v_sistema);
end;
$fn$;

revoke all on function wh.asignar_auditoria(jsonb) from public;
grant execute on function wh.asignar_auditoria(jsonb) to service_role, authenticated;


-- ── 3) wh.ejecutar_auditoria(p) ──────────────────────────────────────────────
-- p = { id_auditoria, stock_fisico, observacion, usuario }
-- Registra el conteo físico sobre una auditoría ASIGNADA. NO mueve stock.
create or replace function wh.ejecutar_auditoria(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_auditoria','')), '');
  v_fisico  numeric := wh._num(p->>'stock_fisico');
  v_obs     text := coalesce(p->>'observacion','');
  v_sistema numeric;
  v_estado  text;
  v_diff    numeric;
  v_result  text;
begin
  if coalesce((select valor from mos.config where clave='WH_EJECUTAR_AUDITORIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_EJECUTAR_AUDITORIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_fisico < 0 then return jsonb_build_object('ok',false,'error','STOCK_FISICO_INVALIDO'); end if;

  -- lock de la fila: serializa contra doble-tap; idempotente por estado (EJECUTADA → no re-procesa)
  select stock_sistema, estado into v_sistema, v_estado
    from wh.auditorias where id_auditoria = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','AUDITORIA_NO_ENCONTRADA'); end if;
  if upper(coalesce(v_estado,'')) = 'EJECUTADA' then
    return jsonb_build_object('ok',true,'dedup',true,'idAuditoria',v_id,
      'diferencia',(select diferencia from wh.auditorias where id_auditoria = v_id),
      'resultado',(select resultado from wh.auditorias where id_auditoria = v_id));
  end if;

  v_sistema := coalesce(v_sistema, 0);
  v_diff := v_fisico - v_sistema;
  v_result := case when abs(v_diff) <= 0.5 then 'OK' else 'DIFERENCIA' end;

  update wh.auditorias
     set stock_fisico = v_fisico, diferencia = v_diff, resultado = v_result,
         observacion = v_obs, estado = 'EJECUTADA', fecha_ejecucion = now()
   where id_auditoria = v_id;

  return jsonb_build_object('ok',true,'dedup',false,'idAuditoria',v_id,'diferencia',v_diff,'resultado',v_result);
end;
$fn$;

revoke all on function wh.ejecutar_auditoria(jsonb) from public;
grant execute on function wh.ejecutar_auditoria(jsonb) to service_role, authenticated;
