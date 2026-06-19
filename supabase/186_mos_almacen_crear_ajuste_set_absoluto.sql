-- 186_mos_almacen_crear_ajuste_set_absoluto.sql — [RIZ · FIX DINERO] ajuste de almacén = SET-ABSOLUTO real.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- App de DINERO/INVENTARIO. CORRIGE el wrapper mos.almacen_crear_ajuste (SQL 185).
--
-- ── BUG CORREGIDO (🔴 race set-absoluto-vía-delta) ───────────────────────────────────────────────────────────
--   El módulo Zona/RIZ ajusta el stock del almacén "a CONTEO" (el admin contó físicamente N unidades de ESE
--   código). El frontend manda `conteo` ABSOLUTO y muestra optimista "Stock ajustado a {conteo}".
--   SQL 185 leía `v_antes` con un SELECT SIN LOCK, calculaba delta = conteo − v_antes, y aplicaba
--   `cantidad_disponible = cantidad_disponible + delta`. Si una VENTA / cierre / despacho / otro ajuste
--   tocaba la fila ENTRE ese SELECT y el UPDATE, el saldo final NO quedaba en `conteo`:
--       final = stock_real_al_update + (conteo − v_antes_stale)   ≠ conteo
--   → divergencia silenciosa entre lo que el admin contó (y vio en la UI) y lo persistido = pérdida/exceso
--     de inventario por el monto de la operación intercalada. PROBADO en DB (conteo 120, venta 30 → quedaba 90).
--
--   El path canónico de ZONA `me.zona_ajustar_stock` ya es SET-ABSOLUTO real
--   (`on conflict do update set cantidad = excluded.cantidad`, final = nuevo, sin aritmética sobre el saldo).
--   Este fix hace que ALMACÉN sea CONSISTENTE con ZONA: SET-ABSOLUTO atómico bajo LOCK de fila.
--
-- ── CÓMO ─────────────────────────────────────────────────────────────────────────────────────────────────────
--   1) SELECT ... FOR UPDATE de la fila determinista (1ra por id_stock) → bloquea la fila; una venta concurrente
--      ESPERA a que esta transacción cierre (no se intercala). El `v_antes` se lee YA bajo lock (consistente).
--   2) UPDATE cantidad_disponible = v_conteo (SET-ABSOLUTO; NO `+ delta`). El saldo final ES el conteo, siempre.
--   3) delta = v_conteo − v_antes (calculado tras el lock) sólo para auditoría/kardex (wh.ajustes + movimiento).
--   4) No-op (conteo == antes) se evalúa DESPUÉS del lock → libre de race; no escribe ajuste/movimiento.
--   Idempotencia (PK wh.ajustes / id_mov), gate mos._claim_ok(), kill-switch y grants se PRESERVAN idénticos a 185.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function mos.almacen_crear_ajuste(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_cod     text := nullif(btrim(coalesce(p->>'codProducto', p->>'codigo_producto', p->>'codBarra', '')), '');
  v_conteo  numeric := nullif(btrim(coalesce(p->>'conteo','')), '')::numeric;
  v_user    text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'');
  v_id      text := nullif(btrim(coalesce(p->>'idAjuste', p->>'id_ajuste', p->>'localId', '')), '');
  v_motivo  text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''), 'Ajuste por conteo (RIZ Almacén)');
  v_zona    text := upper(btrim(coalesce(p->>'zona','')));   -- informativo (queda en origen del movimiento)
  v_fecha   timestamptz := now();
  v_id_stk  text;       -- PK de la fila a tocar (resuelta bajo lock)
  v_antes   numeric;
  v_despues numeric;
  v_delta   numeric;
  v_tipo    text;
  v_cant    numeric;
  v_id_mov  text;
begin
  -- gate de app (token MOS) — el wrapper corre como owner pero el claim jwt sigue siendo el del caller.
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- kill-switch server-side (mismo flag que wh.crear_ajuste). OFF → idéntico a hoy (no aplica nada).
  if coalesce((select valor from mos.config where clave='WH_CREAR_AJUSTE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_AJUSTE_DIRECTO_OFF');
  end if;

  if v_cod is null or v_conteo is null then
    return jsonb_build_object('ok',false,'error','Requiere codProducto y conteo (numérico)');
  end if;
  if v_id is null then
    return jsonb_build_object('ok',false,'error','Requiere idAjuste (idempotencia)');
  end if;

  v_cod := upper(v_cod);

  -- IDEMPOTENCIA por id_ajuste (PK wh.ajustes): si ya se aplicó → devolver el stock vigente SIN re-tocar.
  if exists (select 1 from wh.ajustes a where a.id_ajuste = v_id) then
    select s.cantidad_disponible into v_despues
      from wh.stock s where upper(btrim(s.cod_producto)) = v_cod order by s.id_stock limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'id_ajuste',v_id,'stockNuevo',coalesce(v_despues,0));
  end if;

  -- ── SET-ABSOLUTO ATÓMICO ──────────────────────────────────────────────────────────────────────────────────
  -- LOCKEAR la fila determinista (1ra por id_stock) ANTES de leer el saldo. Una venta/despacho concurrente sobre
  -- la misma fila ESPERA a que esta tx cierre → el v_antes leído acá es consistente y el SET no se pisa.
  select s.id_stock, s.cantidad_disponible into v_id_stk, v_antes
    from wh.stock s where upper(btrim(s.cod_producto)) = v_cod
    order by s.id_stock limit 1
    for update;

  if v_id_stk is not null then
    v_antes := coalesce(v_antes, 0);
    v_delta := v_conteo - v_antes;

    -- conteo == stock actual (ya bajo lock) → NO-OP (no escribe ajuste ni movimiento; el inventario ya cuadra).
    if v_delta = 0 then
      return jsonb_build_object('ok',true,'dedup',false,'noop',true,'id_ajuste',v_id,
        'stockAntes',v_antes,'stockNuevo',v_antes,'delta',0);
    end if;

    -- SET-ABSOLUTO: el saldo final ES el conteo (no `+ delta`) → inmune a operaciones intercaladas.
    update wh.stock
       set cantidad_disponible = v_conteo, ultima_actualizacion = v_fecha
     where id_stock = v_id_stk;
    v_despues := v_conteo;
  else
    -- sin fila → crear el stock con el conteo (antes = 0, delta = conteo).
    v_antes := 0; v_despues := v_conteo; v_delta := v_conteo;
    if v_delta = 0 then
      -- conteo 0 sin fila previa → no hay nada que registrar (evita fila de stock/ajuste basura en 0).
      return jsonb_build_object('ok',true,'dedup',false,'noop',true,'id_ajuste',v_id,
        'stockAntes',0,'stockNuevo',0,'delta',0);
    end if;
    insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
    values ('STK'||v_id, v_cod, v_despues, v_fecha);
  end if;

  v_tipo := case when v_delta > 0 then 'INC' else 'DEC' end;
  v_cant := abs(v_delta);

  -- fila de ajuste (PK id_ajuste → la idempotencia de arriba ya garantizó que no existe).
  insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
  values (v_id, v_cod, v_tipo, v_cant, v_motivo, v_user, nullif(v_zona,''), v_fecha);

  -- movimiento de trazabilidad (idempotente por id_mov derivado del id_ajuste).
  v_id_mov := 'MOV-'||v_id;
  insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
  values (v_id_mov, v_fecha, v_cod, v_delta, v_antes, v_despues, 'AJUSTE_MANUAL', coalesce(nullif(v_zona,''),'RIZ-ALMACEN'), v_user)
  on conflict (id_mov) do nothing;

  return jsonb_build_object('ok',true,'dedup',false,'id_ajuste',v_id,
    'tipo',v_tipo,'cantidad',v_cant,'stockAntes',v_antes,'stockNuevo',v_despues,'delta',v_delta);
end;
$fn$;
revoke all on function mos.almacen_crear_ajuste(jsonb) from public;
grant execute on function mos.almacen_crear_ajuste(jsonb) to service_role, authenticated;
