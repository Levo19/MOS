-- 67_wh_envasado_corregir_anular.sql — [Tanda 2] Escritura directa: CORREGIR unidades y ANULAR un envasado. INERTE.
-- Ambas TOCAN STOCK (base + derivado). Replican fielmente _corregirUnidadesEnvasadoImpl y _anularEnvasadoConClaveImpl
-- (Envasados.gs). La autorización admin (clave) se valida ANTES en el flujo (igual que reabrir_guia); la RPC NO valida clave.
--
-- CONTRATO DE CATÁLOGO (clave): el GAS resuelve derivado/base/factor desde la hoja PRODUCTOS. La RPC NO tiene el catálogo
-- → el CLIENTE resuelve (del cache) y pasa cod_producto_base, cod_producto_envasado y factor_base ya resueltos, igual que
-- hace registrar_envasado. La RPC mueve stock por el código de base RESUELTO (cod_producto_base), espejando que el GAS usa
-- prodBase.codigoBarra. Si el cliente no logra resolver el base, cae a GAS (la RPC exige cod_producto_base presente).

insert into mos.config (clave, valor, descripcion) values
  ('WH_CORREGIR_ENVASADO_DIRECTO','0','WH: corregir unidades de un envasado directo (RPC wh.corregir_unidades_envasado). Mueve stock base+derivado por DELTA. Validar antes de prender.'),
  ('WH_ANULAR_ENVASADO_DIRECTO','0','WH: anular un envasado directo (RPC wh.anular_envasado). Reverso EXACTO de registrar_envasado. Validar antes de prender.')
on conflict (clave) do nothing;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 1. corregir_unidades_envasado — edita unidades_producidas de un envasado y propaga stock+detalles.
--   Réplica _corregirUnidadesEnvasadoImpl:
--     · cant_base_nueva = nuevas_unidades * factor_base ; delta_uds = nuevas - viejas ; delta_base = base_nueva - base_vieja.
--     · STOCK derivado += delta_uds (UPDATE atómico) ; STOCK base -= delta_base (solo si cod_base presente).
--     · ENVASADOS: unidades_producidas = nuevas, cantidad_base = base_nueva, observacion += traza.
--     · Ajusta el detalle de la guía INGRESO (derivado → nuevas_uds) y SALIDA (base → base_nueva) al valor ABSOLUTO,
--       sobre la 1ra línea no-ANULADO que matchee (id_guia + cod), igual que _ajustarDetalleEnvasado.
--   IDEMPOTENCIA: mueve stock por DELTA (no absoluto) → NO idempotente natural → DEDUP por wh._dedup_nuevo(local_id),
--     OBLIGATORIO (sin él, un reintento re-aplicaría el delta). FOR UPDATE sobre la fila de envasado serializa ediciones
--     concurrentes (la base "vieja" leída es consistente).
--   GUARD: estado ANULADO* → rechazar. delta_uds == 0 → no-op error (igual que GAS).
-- p = { id_envasado, nuevas_unidades, cod_producto_base, cod_producto_envasado, factor_base, motivo?, usuario?,
--       id_mov_der?, id_mov_base?, local_id (OBLIGATORIO) }
create or replace function wh.corregir_unidades_envasado(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idenv   text := nullif(btrim(coalesce(p->>'id_envasado','')), '');
  v_nuevas  numeric := wh._num(p->>'nuevas_unidades');
  v_nuevas_in text := nullif(btrim(coalesce(p->>'nuevas_unidades','')), '');
  v_codbase text := nullif(btrim(coalesce(p->>'cod_producto_base','')), '');
  v_codder  text := nullif(btrim(coalesce(p->>'cod_producto_envasado','')), '');
  v_factor  numeric := wh._num(p->>'factor_base');
  v_motivo  text := coalesce(nullif(btrim(p->>'motivo'),''),'sin motivo');
  v_usuario text := coalesce(nullif(btrim(p->>'usuario'),''),'admin');
  v_idmovd  text := nullif(btrim(coalesce(p->>'id_mov_der','')), '');
  v_idmovb  text := nullif(btrim(coalesce(p->>'id_mov_base','')), '');
  v_lid     text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_estado  text; v_codder_row text; v_codbase_row text;
  v_uds_viejas numeric; v_base_vieja numeric;
  v_base_nueva numeric; v_delta_uds numeric; v_delta_base numeric;
  v_gs text; v_gi text;
  v_antes numeric; v_despues numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_CORREGIR_ENVASADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CORREGIR_ENVASADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [FIX #5 100x] Validaciones de params/rango ANTES del dedup. El dedup marca trabajo EFECTIVAMENTE HECHO, no intentos
  -- fallidos: si una 1ra llamada falla validación y YA hubiera registrado el local_id en sync_directo, un reintento corregido
  -- con el MISMO localId se dedupearía como "ya hecho" ({ok,dedup}) sin aplicar nunca el delta → la corrección se pierde en
  -- silencio. Por eso el _dedup_nuevo corre solo cuando la operación realmente va a proceder (después de TODAS las validaciones).
  if v_idenv is null or v_nuevas_in is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_nuevas < 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_factor <= 0 then return jsonb_build_object('ok',false,'error','FACTOR_INVALIDO'); end if;
  -- sin local_id el dedup se salta y un reintento re-aplicaría el delta → exigirlo (el front siempre lo manda).
  if v_lid is null then return jsonb_build_object('ok',false,'error','FALTA_LOCAL_ID'); end if;
  -- [dedup] mueve stock por DELTA → NO idempotente → si este local_id ya se procesó, early-return (no re-aplica el delta).
  -- Tras pasar validaciones: registrar el local_id solo ahora que la operación procede.
  if not wh._dedup_nuevo(v_lid, 'corregir_unidades_envasado') then
    return jsonb_build_object('ok',true,'dedup',true);
  end if;

  -- localizar + BLOQUEAR el envasado
  select upper(coalesce(estado,'')), coalesce(cod_producto_envasado,''), coalesce(cod_producto_base,''),
         coalesce(unidades_producidas,0), coalesce(cantidad_base,0), coalesce(id_guia_salida,''), coalesce(id_guia_ingreso,'')
    into v_estado, v_codder_row, v_codbase_row, v_uds_viejas, v_base_vieja, v_gs, v_gi
    from wh.envasados where id_envasado = v_idenv limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','ENVASADO_NO_ENCONTRADO'); end if;
  if v_estado like 'ANULADO%' then return jsonb_build_object('ok',false,'error','ENVASADO_ANULADO'); end if;

  -- [FIX #4/#5] la FILA es la fuente de verdad de qué stock mover → gana sobre el param del cliente (manipulable);
  -- el cliente solo es fallback si la fila viene vacía. Uniforma con anular_envasado (coalesce fila→cliente) y con el GAS
  -- (que SIEMPRE lee cod_producto_envasado/cod_producto_base de la fila de wh.envasados).
  v_codder  := coalesce(nullif(v_codder_row,''),  v_codder);
  v_codbase := coalesce(nullif(v_codbase_row,''), v_codbase);
  if v_codder is null then return jsonb_build_object('ok',false,'error','SIN_COD_DERIVADO'); end if;

  -- deltas (espeja GAS: cantBaseV cae a la fila; si la fila tenía 0, GAS usaba uds*factor — acá ya viene de la fila)
  if v_base_vieja = 0 then v_base_vieja := v_uds_viejas * v_factor; end if;
  v_base_nueva := v_nuevas * v_factor;
  v_delta_uds  := v_nuevas - v_uds_viejas;
  v_delta_base := v_base_nueva - v_base_vieja;
  if v_delta_uds = 0 then return jsonb_build_object('ok',false,'error','SIN_CAMBIO'); end if;

  -- ── ENVASADOS: nuevos valores + traza ──
  update wh.envasados
     set unidades_producidas = v_nuevas,
         cantidad_base       = v_base_nueva,
         observacion = coalesce(observacion,'') || ' | editado ' || to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS')
                       || ' · ' || rtrim(rtrim(to_char(v_uds_viejas,'FM999999990.######'),'0'),'.')
                       || '→' || rtrim(rtrim(to_char(v_nuevas,'FM999999990.######'),'0'),'.')
                       || ' uds · admin=' || v_usuario || ' · ' || v_motivo
   where id_envasado = v_idenv;

  -- ── STOCK derivado += delta_uds (UPDATE atómico) ──
  update wh.stock set cantidad_disponible = cantidad_disponible + v_delta_uds, ultima_actualizacion = now()
   where id_stock = (select id_stock from wh.stock where cod_producto = v_codder order by id_stock limit 1)
   returning cantidad_disponible into v_despues;
  if found then v_antes := v_despues - v_delta_uds;
  else v_antes := 0; v_despues := v_delta_uds;
    insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
    values ('STKEDD'||v_idenv, v_codder, v_despues, now());
  end if;
  insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
  values (coalesce(v_idmovd,'MOVEDD_'||v_lid), now(), v_codder, v_delta_uds, v_antes, v_despues, 'EDICION_ENVASADO', v_idenv, v_usuario)
  on conflict (id_mov) do nothing;

  -- ── STOCK base -= delta_base (solo si hay base resuelto) ──
  if v_codbase is not null and v_delta_base <> 0 then
    update wh.stock set cantidad_disponible = cantidad_disponible - v_delta_base, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_codbase order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then v_antes := v_despues + v_delta_base;
    else v_antes := 0; v_despues := -v_delta_base;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values ('STKEDB'||v_idenv, v_codbase, v_despues, now());
    end if;
    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values (coalesce(v_idmovb,'MOVEDB_'||v_lid), now(), v_codbase, -v_delta_base, v_antes, v_despues, 'EDICION_ENVASADO', v_idenv, v_usuario)
    on conflict (id_mov) do nothing;
  end if;

  -- ── ajustar detalle de guías al valor ABSOLUTO (1ra línea no-ANULADO por id_guia+cod), igual que _ajustarDetalleEnvasado ──
  if v_gi <> '' then
    update wh.guia_detalle
       set cant_esperada = v_nuevas, cant_recibida = v_nuevas,
           observacion = coalesce(observacion,'') || ' | corregido-manual ' || to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS')
     where (id_guia, linea) = (
       select id_guia, linea from wh.guia_detalle
        where id_guia = v_gi and upper(coalesce(cod_producto,'')) = upper(v_codder) and upper(coalesce(observacion,'')) <> 'ANULADO'
        order by linea limit 1);
  end if;
  if v_gs <> '' and v_codbase is not null then
    update wh.guia_detalle
       set cant_esperada = v_base_nueva, cant_recibida = v_base_nueva,
           observacion = coalesce(observacion,'') || ' | corregido-manual ' || to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS')
     where (id_guia, linea) = (
       select id_guia, linea from wh.guia_detalle
        where id_guia = v_gs and upper(coalesce(cod_producto,'')) = upper(v_codbase) and upper(coalesce(observacion,'')) <> 'ANULADO'
        order by linea limit 1);
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'id_envasado',v_idenv,'uds_viejas',v_uds_viejas,'uds_nuevas',v_nuevas,
    'delta_uds',v_delta_uds,'delta_base',v_delta_base,'movio_base',(v_codbase is not null and v_delta_base <> 0));
end;
$fn$;

revoke all on function wh.corregir_unidades_envasado(jsonb) from public;
grant execute on function wh.corregir_unidades_envasado(jsonb) to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════
-- 2. anular_envasado — anula un envasado COMPLETADO (reverso EXACTO de registrar_envasado). Réplica _anularEnvasadoConClaveImpl.
--   registrar_envasado hizo: +unidades al DERIVADO, -cantidad_base al BASE, lote del derivado, detalles en GIE/GSE.
--   anular hace el reverso EXACTO con los MISMOS signos invertidos:
--     · STOCK derivado -= unidades_producidas (UPDATE atómico).
--     · STOCK base     += cantidad_base       (solo si cod_base presente).
--     · ANULA el lote del derivado si registrar_envasado lo creó (id_lote='LOTE'+id_envasado) → estado='ANULADO'.
--     · ANULA la 1ra línea no-ANULADO del DERIVADO en la guía INGRESO y del BASE en la guía SALIDA (observacion='ANULADO · ...').
--     · ENVASADOS.estado = 'ANULADO_MANUAL' + traza en observacion.
--   IDEMPOTENCIA: NATURAL POR ESTADO — si ya está ANULADO* → early-return (no re-revertir). FOR UPDATE sobre la fila de
--     envasado serializa contra anulación concurrente → un solo reverso. (No necesita dedup por local_id: el estado es el
--     candado natural, igual que reabrir_guia / anular_detalle.)
--   La autorización admin (clave) se valida ANTES (la RPC no la chequea, igual que reabrir_guia).
-- p = { id_envasado, cod_producto_base?, cod_producto_envasado?, motivo?, usuario?, id_mov_der?, id_mov_base? }
create or replace function wh.anular_envasado(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idenv   text := nullif(btrim(coalesce(p->>'id_envasado','')), '');
  v_codbase text := nullif(btrim(coalesce(p->>'cod_producto_base','')), '');
  v_codder  text := nullif(btrim(coalesce(p->>'cod_producto_envasado','')), '');
  v_motivo  text := coalesce(nullif(btrim(p->>'motivo'),''),'sin motivo');
  v_usuario text := coalesce(nullif(btrim(p->>'usuario'),''),'admin');
  v_idmovd  text := nullif(btrim(coalesce(p->>'id_mov_der','')), '');
  v_idmovb  text := nullif(btrim(coalesce(p->>'id_mov_base','')), '');
  v_estado  text; v_codder_row text; v_codbase_row text;
  v_uds numeric; v_base numeric; v_gs text; v_gi text;
  v_antes numeric; v_despues numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_ANULAR_ENVASADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ANULAR_ENVASADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idenv is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- localizar + BLOQUEAR (FOR UPDATE evita doble-reverso concurrente; el estado es el candado de idempotencia)
  select upper(coalesce(estado,'')), coalesce(cod_producto_envasado,''), coalesce(cod_producto_base,''),
         coalesce(unidades_producidas,0), coalesce(cantidad_base,0), coalesce(id_guia_salida,''), coalesce(id_guia_ingreso,'')
    into v_estado, v_codder_row, v_codbase_row, v_uds, v_base, v_gs, v_gi
    from wh.envasados where id_envasado = v_idenv limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','ENVASADO_NO_ENCONTRADO'); end if;

  -- idempotencia NATURAL por estado: ya anulado → no re-revertir stock
  if v_estado like 'ANULADO%' then return jsonb_build_object('ok',true,'yaAnulado',true,'id_envasado',v_idenv); end if;

  -- preferir cod de la FILA (fuente de verdad); el cliente los manda como respaldo si el cache los resolvió
  v_codder  := coalesce(nullif(v_codder_row,''),  v_codder);
  v_codbase := coalesce(nullif(v_codbase_row,''), v_codbase);

  -- ── reverso STOCK derivado -= unidades ──
  if v_codder is not null and v_uds <> 0 then
    update wh.stock set cantidad_disponible = cantidad_disponible - v_uds, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_codder order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then v_antes := v_despues + v_uds;
    else v_antes := 0; v_despues := -v_uds;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values ('STKANDD'||v_idenv, v_codder, v_despues, now());
    end if;
    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values (coalesce(v_idmovd,'MOVANDD_'||v_idenv), now(), v_codder, -v_uds, v_antes, v_despues, 'ANULACION_ENVASADO', v_idenv, v_usuario)
    on conflict (id_mov) do nothing;
  end if;

  -- ── reverso STOCK base += cantidad_base ──
  if v_codbase is not null and v_base <> 0 then
    update wh.stock set cantidad_disponible = cantidad_disponible + v_base, ultima_actualizacion = now()
     where id_stock = (select id_stock from wh.stock where cod_producto = v_codbase order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then v_antes := v_despues - v_base;
    else v_antes := 0; v_despues := v_base;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values ('STKANDB'||v_idenv, v_codbase, v_despues, now());
    end if;
    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values (coalesce(v_idmovb,'MOVANDB_'||v_idenv), now(), v_codbase, v_base, v_antes, v_despues, 'ANULACION_ENVASADO', v_idenv, v_usuario)
    on conflict (id_mov) do nothing;
  end if;

  -- ── anular el lote del derivado que registrar_envasado creó (id determinista 'LOTE'+idEnvasado) ──
  -- [FIX #8] COMPORTAMIENTO NUEVO vs GAS (intencional): el GAS NO toca el lote al anular. Acá SÍ lo marcamos ANULADO para
  -- no dejar un lote de vencimiento huérfano ACTIVO de un envasado que ya no existe (mejora de consistencia). OJO: esto NO
  -- restituye cantidad_actual consumida por FIFO en lotes BASE — el reverso de stock por unidades completas (no por lote FIFO)
  -- mantiene paridad EXACTA con el GAS y NO se cambia. Solo se invalida el lote propio del derivado.
  update wh.lotes_vencimiento set estado = 'ANULADO' where id_lote = 'LOTE'||v_idenv and upper(coalesce(estado,'')) <> 'ANULADO';

  -- ── anular el detalle del DERIVADO en la guía INGRESO (1ra línea no-ANULADO por cod) ──
  if v_gi <> '' and v_codder is not null then
    update wh.guia_detalle set observacion = 'ANULADO · anulación envasado ' || v_idenv
     where (id_guia, linea) = (
       select id_guia, linea from wh.guia_detalle
        where id_guia = v_gi and upper(coalesce(cod_producto,'')) = upper(v_codder) and upper(coalesce(observacion,'')) <> 'ANULADO'
        order by linea limit 1);
  end if;
  -- ── anular el detalle del BASE en la guía SALIDA ──
  if v_gs <> '' and v_codbase is not null then
    update wh.guia_detalle set observacion = 'ANULADO · anulación envasado ' || v_idenv
     where (id_guia, linea) = (
       select id_guia, linea from wh.guia_detalle
        where id_guia = v_gs and upper(coalesce(cod_producto,'')) = upper(v_codbase) and upper(coalesce(observacion,'')) <> 'ANULADO'
        order by linea limit 1);
  end if;

  -- ── marcar ENVASADO anulado + traza ──
  update wh.envasados
     set estado = 'ANULADO_MANUAL',
         observacion = coalesce(observacion,'') || ' | anulado ' || to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS')
                       || ' · ' || rtrim(rtrim(to_char(v_uds,'FM999999990.######'),'0'),'.')
                       || ' uds revertidas · admin=' || v_usuario || ' · ' || v_motivo
   where id_envasado = v_idenv;

  return jsonb_build_object('ok',true,'dedup',false,'id_envasado',v_idenv,'uds_anuladas',v_uds,'cant_base_restit',v_base,
    'revirtio_base',(v_codbase is not null and v_base <> 0));
end;
$fn$;

revoke all on function wh.anular_envasado(jsonb) from public;
grant execute on function wh.anular_envasado(jsonb) to service_role, authenticated;
