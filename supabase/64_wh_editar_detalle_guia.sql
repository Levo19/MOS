-- 64_wh_editar_detalle_guia.sql — [PASO 4] EDICIÓN de líneas de guía (3 RPCs). INERTE.
-- Replica fielmente Guias.gs: _actualizarCantidadDetalleImpl, _anularDetalleImpl, _actualizarFechaVencimientoImpl
-- + el helper _sincronizarLoteDesdeDetalle (casos A-E) para los lotes.
--
-- CONTRATO COMÚN: el frontend solo conoce idDetalle (no idGuia ni la cantidad vieja). Por eso cada RPC RESUELVE la
-- fila por id_detalle en wh.guia_detalle (FOR UPDATE) y de ahí saca id_guia / cod_producto / cant_recibida vieja /
-- id_lote / fecha_vencimiento. wh.guia_detalle.id_detalle NO es único en la sombra (PK es (id_guia, linea)); igual
-- que el GAS, se toma la PRIMERA fila que matchea (order by id_guia, linea).
--
-- REGLA DE STOCK (clave): solo se toca wh.stock si la guía está CERRADA (NO AUTOCERRADA — esa nunca aplicó stock) y
-- NO es de envasado (el envasado mueve stock por su cuenta en Envasados). Guía ABIERTA → NO toca stock (se aplicará
-- al cerrar vía wh.cerrar_guia). El stock SIEMPRE se mueve con UPDATE ATÓMICO (set = cantidad + delta) sobre la 1ra
-- fila por id_stock del producto — JAMÁS leer-modificar-escribir (lost-update sin el _conLock de GAS).

insert into mos.config (clave, valor, descripcion) values
  ('WH_ACTUALIZAR_CANTIDAD_DETALLE_DIRECTO','0','WH: editar cant_recibida de una linea de guia directo (RPC wh.actualizar_cantidad_detalle).'),
  ('WH_ANULAR_DETALLE_DIRECTO','0','WH: anular una linea de guia directo (RPC wh.anular_detalle).'),
  ('WH_ACTUALIZAR_FECHA_VENCIMIENTO_DIRECTO','0','WH: editar fecha_vencimiento de una linea de guia directo (RPC wh.actualizar_fecha_vencimiento).')
on conflict (clave) do nothing;

-- ════════════════════════════════════════════════════════════════════════════════════
-- Helper interno: sincroniza un lote desde la info de un detalle (réplica de _sincronizarLoteDesdeDetalle).
-- Política: clave (cod_producto, fecha_vencimiento) por guía. NO toca stock (solo cantidades del lote).
-- Casos:
--   A) id_lote_actual vacío + fecha con valor → REUSE (cod,guia,fecha) o INSERT nuevo lote
--   B) id_lote_actual vacío + fecha vacía     → no-op
--   C) id_lote_actual existe + fecha vacía    → ANULAR lote (estado='ANULADO')
--   D) id_lote_actual existe + fecha = misma y cantidad = misma y ACTIVO → no-op
--   E) id_lote_actual existe + fecha/cant distinta → UPDATE fecha+cantidad (reactiva si estaba ANULADO)
-- Devuelve el id_lote resultante (text) o '' si no-op sin lote. El INSERT necesita p_id_lote_nuevo (idempotencia).
-- Es idempotente por valor: re-aplicar la misma fecha/cantidad cae en D (NOOP) y no duplica el lote.
-- [FIX #6 · GAP DOCUMENTADO] El GAS escribe además un historial de cambios de lote (hoja LOTES_HISTORIAL). Esa tabla
-- NO existe en la sombra y NO se replica aquí a propósito (decisión: no crear tabla nueva). El historial de lotes
-- queda como gap conocido; las cantidades/estado del lote sí se mantienen consistentes.
create or replace function wh._sync_lote_desde_detalle(
  p_id_lote_actual  text,
  p_cod_producto    text,
  p_cantidad        numeric,
  p_fecha_venc      text,      -- yyyy-MM-dd o '' / null
  p_id_guia         text,
  p_id_lote_nuevo   text       -- id determinista para el INSERT (idempotencia; lo genera el cliente)
) returns text
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  -- [FIX #11] blindaje del ::date: solo castea si los primeros 10 chars matchean yyyy-MM-dd; basura → null (no aborta la tx).
  v_fv        date := case
                        when left(btrim(coalesce(p_fecha_venc,'')),10) ~ '^\d{4}-\d{2}-\d{2}$'
                          then left(btrim(p_fecha_venc),10)::date
                        else null end;
  v_lote_act  text := nullif(btrim(coalesce(p_id_lote_actual,'')),'');
  v_cod       text := btrim(coalesce(p_cod_producto,''));
  v_reuse     text;
  v_fecha_lote date;
  v_cant_lote numeric;
  v_est_lote  text;
begin
  -- CASO C: tiene lote y se borró la fecha → ANULAR
  if v_lote_act is not null and v_fv is null then
    update wh.lotes_vencimiento set estado = 'ANULADO' where id_lote = v_lote_act;
    return v_lote_act;
  end if;

  -- CASO B: sin lote y sin fecha → nada
  if v_lote_act is null and v_fv is null then return ''; end if;

  -- CASO D/E: tiene lote y fecha
  if v_lote_act is not null then
    -- [FIX #5] día-negocio Lima: el fecha_vencimiento es timestamptz; anclarlo a America/Lima para comparar contra v_fv (date)
    select (fecha_vencimiento at time zone 'America/Lima')::date, cantidad_actual, upper(coalesce(estado,''))
      into v_fecha_lote, v_cant_lote, v_est_lote
      from wh.lotes_vencimiento where id_lote = v_lote_act limit 1;
    if found then
      -- D: misma fecha, misma cantidad, ACTIVO → no-op
      if v_fecha_lote is not distinct from v_fv and coalesce(v_cant_lote,0) = coalesce(p_cantidad,0) and v_est_lote = 'ACTIVO' then
        return v_lote_act;
      end if;
      -- E: actualizar fecha + cantidad (reactiva si estaba ANULADO/AGOTADO)
      update wh.lotes_vencimiento
         set fecha_vencimiento = v_fv, cantidad_inicial = p_cantidad, cantidad_actual = p_cantidad, estado = 'ACTIVO'
       where id_lote = v_lote_act;
      return v_lote_act;
    end if;
    -- el lote_actual ya no existe en la sombra → cae a la búsqueda por (cod,guia,fecha) abajo
  end if;

  -- CASO A: sin lote (o lote_actual inexistente) + fecha → buscar lote previo (cod, guia, fecha exacta) para REUSAR
  select id_lote into v_reuse from wh.lotes_vencimiento
   where upper(coalesce(cod_producto,'')) = upper(v_cod) and id_guia = p_id_guia
     and (fecha_vencimiento at time zone 'America/Lima')::date = v_fv limit 1;  -- [FIX #5] día Lima
  if v_reuse is not null then
    update wh.lotes_vencimiento
       set estado = 'ACTIVO', cantidad_inicial = p_cantidad, cantidad_actual = p_cantidad
     where id_lote = v_reuse;
    return v_reuse;
  end if;

  -- Crear nuevo lote (necesita id determinista; sin él no se puede insertar de forma idempotente → no-op)
  if nullif(btrim(coalesce(p_id_lote_nuevo,'')),'') is null then return ''; end if;
  insert into wh.lotes_vencimiento (id_lote, cod_producto, fecha_vencimiento, cantidad_inicial, cantidad_actual, id_guia, estado, fecha_creacion)
  values (p_id_lote_nuevo, v_cod, v_fv, p_cantidad, p_cantidad, p_id_guia, 'ACTIVO', now())
  on conflict (id_lote) do nothing;
  return p_id_lote_nuevo;
end;
$fn$;

revoke all on function wh._sync_lote_desde_detalle(text,text,numeric,text,text,text) from public;
grant execute on function wh._sync_lote_desde_detalle(text,text,numeric,text,text,text) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 1. actualizar_cantidad_detalle — edita cant_recibida de una línea (réplica _actualizarCantidadDetalleImpl).
--   · Si la guía está CERRADA (no AUTOCERRADA, no envasado): ajusta stock por el delta = cant_nueva - cant_vieja
--     (signo por INGRESO/SALIDA) Y crea una fila explícita en wh.ajustes (paridad con crearAjuste del GAS, FIX #1).
--     Movimiento tipo AJUSTE_MANUAL. → NO idempotente naturalmente (re-ejecutar re-aplicaría el delta) → DEDUP por
--     local_id (wh._dedup_nuevo) + local_id OBLIGATORIO (FIX #3). ABIERTA: solo actualiza la fila (idempotente).
--   · Des-anula la línea si estaba ANULADO y la cantidad nueva > 0.
--   · Sincroniza el lote (cantidad) solo si la línea tiene fecha_vencimiento (con lote: caso E; sin lote+fecha: A).
-- p = { id_detalle, cantidad_recibida, usuario?, id_mov?, id_lote_nuevo?, id_ajuste?, local_id (OBLIGATORIO) }
create or replace function wh.actualizar_cantidad_detalle(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_iddet   text := nullif(btrim(coalesce(p->>'id_detalle','')), '');
  v_cant    numeric := wh._num(p->>'cantidad_recibida');
  v_cant_in text := nullif(btrim(coalesce(p->>'cantidad_recibida','')), '');
  v_usuario text := coalesce(p->>'usuario','');
  v_idmov   text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_idlnew  text := nullif(btrim(coalesce(p->>'id_lote_nuevo','')), '');
  v_idaj    text := nullif(btrim(coalesce(p->>'id_ajuste','')), '');   -- [FIX #1] id determinista para wh.ajustes
  v_lid     text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_guia    text; v_linea int; v_cant_vieja numeric; v_cod text; v_obs text;
  v_idlote  text; v_fvenc date;
  v_estado  text; v_tipo text; v_cerrada boolean; v_ingreso boolean; v_envasado boolean;
  v_diff numeric; v_delta numeric; v_antes numeric; v_despues numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_ACTUALIZAR_CANTIDAD_DETALLE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ACTUALIZAR_CANTIDAD_DETALLE_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  -- [B4 · dedup] mueve stock por DELTA → NO idempotente → si este local_id ya se procesó, early-return.
  if v_lid is not null and not wh._dedup_nuevo(v_lid, 'actualizar_cantidad_detalle') then
    return jsonb_build_object('ok',true,'dedup',true);
  end if;
  if v_iddet is null or v_cant_in is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  -- [FIX #3] mueve stock por DELTA y NO es idempotente natural; sin local_id el dedup se salta y se re-aplicaría el delta.
  -- El front siempre lo manda → esto solo blinda contra llamadas mal formadas.
  if v_lid is null then return jsonb_build_object('ok',false,'error','FALTA_LOCAL_ID'); end if;

  -- localizar la línea por id_detalle (1ra por (id_guia,linea), como GAS) + bloquearla
  select id_guia, linea, coalesce(cant_recibida,0), coalesce(cod_producto,''), upper(coalesce(observacion,'')),
         coalesce(id_lote,''), fecha_vencimiento
    into v_guia, v_linea, v_cant_vieja, v_cod, v_obs, v_idlote, v_fvenc
    from wh.guia_detalle where id_detalle = v_iddet order by id_guia, linea limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','DETALLE_NO_ENCONTRADO'); end if;

  select upper(coalesce(estado,'')), upper(coalesce(tipo,'')) into v_estado, v_tipo
    from wh.guias where id_guia = v_guia limit 1;
  v_cerrada  := v_estado = 'CERRADA';   -- solo CERRADA aplicó stock (AUTOCERRADA no)
  v_ingreso  := v_tipo like 'INGRESO%';
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  -- ── stock (solo guía CERRADA, no envasado) por el delta de cantidad ──
  if v_cerrada and not v_envasado and v_cod <> '' then
    v_diff := v_cant - v_cant_vieja;
    if v_diff <> 0 then
      v_delta := case when v_ingreso then v_diff else -v_diff end;
      update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
       where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
       returning cantidad_disponible into v_despues;
      if found then v_antes := v_despues - v_delta;
      else v_antes := 0; v_despues := v_delta;
        insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
        values ('STK'||v_guia||'_'||v_cod, v_cod, v_despues, now());
      end if;
      -- [FIX #1] paridad con GAS (Guias.gs:603 → crearAjuste): editar cantidad de guía CERRADA crea una fila explícita
      -- en wh.ajustes ADEMÁS de mover el stock. id_ajuste determinista (del local_id) → idempotente ante reintento.
      insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
      values (coalesce(v_idaj, 'AJ_'||v_lid), v_cod, case when v_delta>0 then 'INC' else 'DEC' end, abs(v_delta),
              'Edición cantidad guía cerrada · idGuia=' || v_guia || ' · detalle=' || v_iddet || ' · ' ||
                rtrim(rtrim(to_char(v_cant_vieja,'FM999999990.######'),'0'),'.') || '→' ||
                rtrim(rtrim(to_char(v_cant,'FM999999990.######'),'0'),'.') || 'u',
              v_usuario, '', now())
      on conflict (id_ajuste) do nothing;
      if v_idmov is not null then
        -- tipo AJUSTE_MANUAL (paridad con crearAjuste→_actualizarStock), NO 'EDICION_CANTIDAD'
        insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
        values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'AJUSTE_MANUAL', v_iddet, v_usuario)
        on conflict (id_mov) do nothing;
      end if;
    end if;
  end if;

  -- ── actualizar la fila: cant + des-anular si correspondía ──
  update wh.guia_detalle
     set cant_recibida = v_cant,
         observacion   = case when v_obs = 'ANULADO' and v_cant > 0 then '' else observacion end
   where id_guia = v_guia and linea = v_linea;

  -- ── sincronizar cantidad del lote SOLO si la línea tiene fecha (preserva lote activo, igual que GAS) ──
  -- [BUG 3 · cutover Supabase] Modelo "aplicar al cerrar": los lotes deben existir SOLO para guías
  -- CERRADA/AUTOCERRADA. En guía ABIERTA NO se crea/sincroniza lote (eso generaba lotes ACTIVO huérfanos
  -- atados a la guía abierta — stock fantasma). El lote se crea/reusa al CERRAR (wh.cerrar_guia, CASE A)
  -- a partir de la fecha del detalle. Aquí, en ABIERTA, solo persiste la fecha en la línea (ya hecho arriba).
  if v_cerrada and v_fvenc is not null and v_cod <> '' then
    perform wh._sync_lote_desde_detalle(v_idlote, v_cod, v_cant, to_char(v_fvenc,'YYYY-MM-DD'), v_guia, v_idlnew);
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'id_guia',v_guia,'linea',v_linea,'aplico_stock',(v_cerrada and not v_envasado));
end;
$fn$;

revoke all on function wh.actualizar_cantidad_detalle(jsonb) from public;
grant execute on function wh.actualizar_cantidad_detalle(jsonb) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 2. anular_detalle — anula una línea (réplica _anularDetalleImpl).
--   · Idempotencia NATURAL por estado: si la línea ya está ANULADO → early-return (no re-devuelve stock).
--     El FOR UPDATE serializa contra una anulación concurrente del mismo detalle (evita doble-reverso).
--   · Si la guía está CERRADA (no AUTOCERRADA, no envasado) y cant>0: devuelve stock (INGRESO→-cant, SALIDA→+cant).
--   · Marca observacion='ANULADO' y cant_recibida=0.
--   · [FIX #13] Si la línea era 'PN_PENDIENTE', marca el ProductoNuevo huérfano (id_guia,codigo_barra,PENDIENTE) como
--     ANULADO en wh.producto_nuevo — paridad con _anularPNPorGuiaYCodigo (Guias.gs).
-- p = { id_detalle, usuario?, id_mov? }
create or replace function wh.anular_detalle(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_iddet   text := nullif(btrim(coalesce(p->>'id_detalle','')), '');
  v_usuario text := coalesce(p->>'usuario','');
  v_idmov   text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_guia    text; v_linea int; v_cant numeric; v_cod text; v_obs text;
  v_estado  text; v_tipo text; v_cerrada boolean; v_ingreso boolean; v_envasado boolean;
  v_delta numeric; v_antes numeric; v_despues numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_ANULAR_DETALLE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ANULAR_DETALLE_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_iddet is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- localizar + BLOQUEAR la línea (FOR UPDATE evita doble-reverso de stock concurrente)
  select id_guia, linea, coalesce(cant_recibida,0), coalesce(cod_producto,''), upper(coalesce(observacion,''))
    into v_guia, v_linea, v_cant, v_cod, v_obs
    from wh.guia_detalle where id_detalle = v_iddet order by id_guia, linea limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','DETALLE_NO_ENCONTRADO'); end if;

  -- idempotencia NATURAL: ya anulado → no re-devolver stock
  if v_obs = 'ANULADO' then return jsonb_build_object('ok',true,'yaAnulado',true); end if;

  select upper(coalesce(estado,'')), upper(coalesce(tipo,'')) into v_estado, v_tipo
    from wh.guias where id_guia = v_guia limit 1;
  v_cerrada  := v_estado = 'CERRADA';
  v_ingreso  := v_tipo like 'INGRESO%';
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  -- ── devolver stock (solo CERRADA, cant>0, no envasado): reverso del cierre ──
  if v_cerrada and not v_envasado and v_cant > 0 and v_cod <> '' then
    v_delta := case when v_ingreso then -v_cant else v_cant end;
    update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then v_antes := v_despues - v_delta;
    else v_antes := 0; v_despues := v_delta;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values ('STK'||v_guia||'_'||v_cod, v_cod, v_despues, now());
    end if;
    if v_idmov is not null then
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'ANULACION_DETALLE', v_iddet, v_usuario)
      on conflict (id_mov) do nothing;
    end if;
  end if;

  update wh.guia_detalle set observacion = 'ANULADO', cant_recibida = 0 where id_guia = v_guia and linea = v_linea;

  -- [FIX #13] paridad con GAS (Guias.gs:1156 → _anularPNPorGuiaYCodigo): si la línea era un ProductoNuevo pendiente
  -- (observacion='PN_PENDIENTE'), marcar el PN huérfano como ANULADO (si no, MOS lo sigue mostrando para aprobación).
  -- Match por (id_guia, codigo_barra, estado PENDIENTE), igual que el helper GAS. Idempotente.
  if v_obs = 'PN_PENDIENTE' and v_cod <> '' then
    update wh.producto_nuevo set estado = 'ANULADO'
     where id_guia = v_guia and upper(coalesce(codigo_barra,'')) = upper(v_cod) and upper(coalesce(estado,'')) = 'PENDIENTE';
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'id_guia',v_guia,'linea',v_linea,'devolvio_stock',(v_cerrada and not v_envasado and v_cant > 0));
end;
$fn$;

revoke all on function wh.anular_detalle(jsonb) from public;
grant execute on function wh.anular_detalle(jsonb) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 3. actualizar_fecha_vencimiento — edita fecha_vencimiento de una línea (réplica _actualizarFechaVencimientoImpl).
--   · NO toca stock NUNCA (la fecha no afecta cantidades de inventario).
--   · Escribe fecha_vencimiento en la línea (o la limpia si vacía) + sincroniza el lote (casos A-E).
--   · Idempotente NATURAL por valor: re-aplicar la misma fecha cae en el caso D del helper (NOOP) y el UPDATE de la
--     fila es el mismo valor → mismo resultado. Sin local_id (no mueve stock por delta).
-- p = { id_detalle, fecha_vencimiento, usuario?, id_lote_nuevo? }
create or replace function wh.actualizar_fecha_vencimiento(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_iddet  text := nullif(btrim(coalesce(p->>'id_detalle','')), '');
  v_fvraw  text := nullif(btrim(coalesce(p->>'fecha_vencimiento','')), '');
  v_idlnew text := nullif(btrim(coalesce(p->>'id_lote_nuevo','')), '');
  v_guia   text; v_linea int; v_cod text; v_cant numeric; v_idlote text;
  v_fv     date; v_lote_res text;
  v_estado text; v_cerrada boolean;
begin
  if coalesce((select valor from mos.config where clave='WH_ACTUALIZAR_FECHA_VENCIMIENTO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ACTUALIZAR_FECHA_VENCIMIENTO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_iddet is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  -- [FIX #11] blindaje del ::date: solo castea si matchea yyyy-MM-dd; basura → fecha ausente (null), no aborta la tx.
  if v_fvraw is not null and left(v_fvraw,10) ~ '^\d{4}-\d{2}-\d{2}$' then v_fv := left(v_fvraw,10)::date; end if;

  -- localizar + bloquear la línea
  select id_guia, linea, coalesce(cod_producto,''), coalesce(cant_recibida,0), coalesce(id_lote,'')
    into v_guia, v_linea, v_cod, v_cant, v_idlote
    from wh.guia_detalle where id_detalle = v_iddet order by id_guia, linea limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','DETALLE_NO_ENCONTRADO'); end if;

  -- estado de la guía: el lote SOLO se crea/sincroniza en guías CERRADA/AUTOCERRADA.
  select upper(coalesce(estado,'')) into v_estado from wh.guias where id_guia = v_guia limit 1;
  v_cerrada := v_estado in ('CERRADA','AUTOCERRADA');

  -- 1) escribir la fecha en el detalle (o limpiarla)
  update wh.guia_detalle set fecha_vencimiento = v_fv where id_guia = v_guia and linea = v_linea;

  -- 2) sincronizar el lote (NO toca stock)
  -- [BUG 3 · cutover Supabase] Modelo "aplicar al cerrar": NO crear/sincronizar lote en guía ABIERTA.
  -- Antes, fijar/editar la fecha en una guía abierta caía en el CASE A del helper y CREABA un lote ACTIVO
  -- huérfano por cada edición (id_lote_nuevo distinto) → 9 lotes fantasma en una sola línea. El lote se
  -- materializa al CERRAR (wh.cerrar_guia) desde la fecha que dejamos en el detalle. En ABIERTA: no-op.
  if v_cerrada then
    v_lote_res := wh._sync_lote_desde_detalle(v_idlote, v_cod, v_cant, v_fvraw, v_guia, v_idlnew);
  else
    v_lote_res := '';
  end if;

  return jsonb_build_object('ok',true,'id_guia',v_guia,'linea',v_linea,'id_lote',coalesce(v_lote_res,''),'aplico_lote',v_cerrada);
end;
$fn$;

revoke all on function wh.actualizar_fecha_vencimiento(jsonb) from public;
grant execute on function wh.actualizar_fecha_vencimiento(jsonb) to service_role, authenticated;
