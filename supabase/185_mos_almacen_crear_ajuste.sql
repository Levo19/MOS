-- 185_mos_almacen_crear_ajuste.sql — [RIZ · AJUSTE DE ALMACÉN DESDE MOS] — escribe wh.stock (ajuste real WH).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- App de DINERO/INVENTARIO. Wrapper para que el módulo Zona/RIZ de MOS pueda AJUSTAR el stock REAL del almacén
-- (wh.stock) cuando el ámbito de la card es ALMACEN. Hasta hoy el ajuste de almacén iba (por bug) a
-- me.zona_ajustar_stock → me.stock_zonas, tabla que para ALMACEN NO se usa → wh.stock JAMÁS se tocaba.
--
-- ── POR QUÉ UN WRAPPER (y no llamar wh.crear_ajuste directo) ─────────────────────────────────────────────────
--   wh.crear_ajuste(p) tiene gate INTERNO `wh._claim_ok()` = `me.jwt_app() in ('', 'warehouseMos')`. El token de
--   MOS lleva app='MOS' → NO pasa ese gate (devolvería APP_NO_AUTORIZADA). SECURITY DEFINER cambia el ROL de
--   ejecución, NO el claim jwt (es un GUC de la sesión) → llamar wh.crear_ajuste desde el wrapper igual fallaría.
--   Por eso el wrapper REPLICA exactamente la lógica atómica de wh.crear_ajuste (mismas tablas, mismas columnas,
--   misma idempotencia por id_ajuste) bajo el gate mos._claim_ok(). Verificado contra el cuerpo vivo de
--   wh.crear_ajuste (paridad 1:1). Si en el futuro wh._claim_ok aceptara 'MOS', se puede colapsar a un pass-through.
--
-- ── CONTRATO (DELTA, igual que wh.crear_ajuste) ──────────────────────────────────────────────────────────────
--   p = { codProducto (req), conteo (req, el conteo físico ABSOLUTO de ESE código), usuario?, idAjuste? (req
--         para idempotencia/dedup), motivo?, zona? (informativo) }
--   El wrapper LEE wh.stock actual del código (1ra fila determinista por id_stock, como _getStockProducto de GAS),
--   calcula delta = conteo − antes → tipo INC/DEC con cantidad ABS, y aplica el ajuste atómico. El conteo es en
--   la UNIDAD de ESE código (wh.stock guarda por cod_producto; el almacén maneja sólo canónicos factor=1 y
--   equivalentes activos → no hay presentaciones-caja en wh.stock; el conteo por código no necesita factor).
--
-- ── SEGURIDAD / DINERO ───────────────────────────────────────────────────────────────────────────────────────
--   · kill-switch server-side WH_CREAR_AJUSTE_DIRECTO (mismo flag que wh.crear_ajuste). OFF → no aplica.
--   · gate mos._claim_ok() (token MOS). search_path='' (qualifies todo).
--   · IDEMPOTENTE por id_ajuste (PK wh.ajustes): re-aplicar el MISMO id NO vuelve a tocar el stock (dedup).
--   · UPDATE ATÓMICO (cantidad_disponible + delta) sobre la PK → libre de lost-update (lección WH _conLock).
--   · conteo = antes → delta 0 → NO-OP explícito (no escribe ajuste/movimiento; devuelve dedup-lógico).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;

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

  -- stock ANTES: 1ra fila determinista por id_stock (igual criterio que wh.crear_ajuste / _getStockProducto GAS).
  select s.cantidad_disponible into v_antes
    from wh.stock s where upper(btrim(s.cod_producto)) = v_cod order by s.id_stock limit 1;
  v_antes := coalesce(v_antes, 0);

  v_delta := v_conteo - v_antes;

  -- conteo == stock actual → NO-OP (no escribe ajuste ni movimiento; el inventario ya cuadra).
  if v_delta = 0 then
    return jsonb_build_object('ok',true,'dedup',false,'noop',true,'id_ajuste',v_id,
      'stockAntes',v_antes,'stockNuevo',v_antes,'delta',0);
  end if;

  v_tipo := case when v_delta > 0 then 'INC' else 'DEC' end;
  v_cant := abs(v_delta);

  -- UPDATE ATÓMICO de wh.stock (cantidad + delta) sobre la 1ra fila determinista. NUNCA read-modify-write.
  update wh.stock
     set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = v_fecha
   where id_stock = (select id_stock from wh.stock s2 where upper(btrim(s2.cod_producto)) = v_cod order by s2.id_stock limit 1)
   returning cantidad_disponible into v_despues;
  if found then
    v_antes := v_despues - v_delta;   -- recomputar antes desde el saldo post-update (consistente)
  else
    -- sin fila → crear el stock con el conteo (delta = conteo, antes = 0).
    v_antes := 0; v_despues := v_delta;
    insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
    values ('STK'||v_id, v_cod, v_despues, v_fecha);
  end if;

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
