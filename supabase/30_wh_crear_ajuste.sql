-- 30_wh_crear_ajuste.sql — [PASO 4 · sesión 1] Escritura directa: ajuste manual de stock.
-- ⚠️ NACE INERTE: gateada por mos.config.WH_CREAR_AJUSTE_DIRECTO (default '0'). No corre hasta flipear.
-- Replica crearAjuste (Productos.gs) + _actualizarStock (Code.gs): 1 transacción atómica que
--   1. valida flag + params,
--   2. idempotencia por id_ajuste (si ya existe → dedup, no re-aplica),
--   3. lee stock actual de wh.stock (0 si no existe),
--   4. aplica delta (INC:+ / DEC:-) al stock (UPDATE o INSERT),
--   5. inserta la fila en wh.ajustes,
--   6. inserta el movimiento en wh.stock_movimientos (tipo AJUSTE_MANUAL).
-- Los ids (id_ajuste/id_stock_nuevo/id_mov) los genera GAS y se pasan → idempotencia y mismos ids que Sheets.
-- Se llama desde GAS con service_role (WH no hace llamadas directas del navegador). El flag es el kill-switch.

insert into mos.config (clave, valor, descripcion) values
  ('WH_CREAR_AJUSTE_DIRECTO','0','WH: crear ajuste de stock directo a Supabase (RPC wh.crear_ajuste). Validar antes de prender.')
on conflict (clave) do nothing;

-- [40x A3] coerción numérica TOLERANTE (como parseFloat de GAS): coma decimal, null, basura → no revienta la tx.
create or replace function wh._num(t text) returns numeric language sql immutable as $$
  select case
    when t is null then 0
    when btrim(replace(t, ',', '.')) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(replace(t, ',', '.'))::numeric
    else 0 end;
$$;
-- [B2 · PASO 5] gate de acceso reutilizable: service_role/GAS (sin claim app) o frontend con JWT app='warehouseMos'.
-- Cualquier otro claim (ej. mosExpress) → false. Reusado por las 12 RPCs de escritura.
create or replace function wh._claim_ok() returns boolean language sql stable as $$
  select coalesce(me.jwt_app(),'') in ('', 'warehouseMos');
$$;

create or replace function wh.crear_ajuste(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_ajuste','')), '');
  v_cod     text := nullif(btrim(coalesce(p->>'codigo_producto','')), '');
  v_tipo    text := upper(coalesce(p->>'tipo',''));
  v_cant    numeric := wh._num(p->>'cantidad');
  v_motivo  text := coalesce(p->>'motivo','');
  v_usuario text := coalesce(p->>'usuario','');
  v_id_aud  text := coalesce(p->>'id_auditoria','');
  v_id_stk  text := nullif(btrim(coalesce(p->>'id_stock_nuevo','')), '');
  v_id_mov  text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_fecha   timestamptz := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz, now());
  v_delta   numeric;
  v_antes   numeric;
  v_despues numeric;
  v_existe  boolean := false;
begin
  -- 1. kill-switch server-side (además del gate del frontend/GAS)
  if coalesce((select valor from mos.config where clave='WH_CREAR_AJUSTE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_AJUSTE_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_tipo not in ('INC','DEC')    then return jsonb_build_object('ok',false,'error','TIPO_INVALIDO'); end if;
  if v_cant <= 0                    then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;

  -- 2. idempotencia: si el ajuste ya se aplicó, NO re-tocar el stock (doble-tap / reintento)
  if exists (select 1 from wh.ajustes where id_ajuste = v_id) then
    select cantidad_disponible into v_despues from wh.stock where cod_producto = v_cod limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'id_ajuste',v_id,'stockNuevo',coalesce(v_despues,0));
  end if;

  v_delta := case when v_tipo='INC' then v_cant else -v_cant end;

  -- 3-4. aplicar al stock de forma ATÓMICA (set = cantidad + delta) → evita lost-update bajo concurrencia
  -- (GAS serializaba con _conLock global; acá el UPDATE incremental + lock de fila implícito lo reemplaza).
  -- [B-1] actualiza UNA fila determinista (la 1ra por id_stock, como _getStockProducto de GAS) → un producto
  -- con filas duplicadas no recibe el delta dos veces. Atómico sobre la PK.
  update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = v_fecha
   where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
   returning cantidad_disponible into v_despues;
  if found then
    v_antes := v_despues - v_delta;
  else
    v_antes := 0; v_despues := v_delta;
    insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
    values (coalesce(v_id_stk, 'STK'||v_id), v_cod, v_despues, v_fecha);
  end if;

  -- 5. fila de ajuste (PK id_ajuste → la idempotencia del paso 2 ya garantizó que no existe)
  insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
  values (v_id, v_cod, v_tipo, v_cant, v_motivo, v_usuario, v_id_aud, v_fecha);

  -- 6. movimiento de trazabilidad (idempotente por id_mov)
  if v_id_mov is not null then
    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values (v_id_mov, v_fecha, v_cod, v_delta, v_antes, v_despues, 'AJUSTE_MANUAL', v_id, v_usuario)
    on conflict (id_mov) do nothing;
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'id_ajuste',v_id,
    'stockAntes',v_antes,'stockNuevo',v_despues,'delta',v_delta);
end;
$fn$;

revoke all on function wh.crear_ajuste(jsonb) from public;
grant execute on function wh.crear_ajuste(jsonb) to service_role, authenticated;  -- [B2] frontend con JWT WH
