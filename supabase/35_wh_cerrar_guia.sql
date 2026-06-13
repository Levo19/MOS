-- 35_wh_cerrar_guia.sql — [PASO 4 · sesión 4b] 🔴 La RPC MÁS CRÍTICA: cerrar guía (stock + lotes + FIFO).
-- ⚠️ INERTE: gateada por mos.config.WH_CERRAR_GUIA_DIRECTO (default '0').
-- Replica _cerrarGuiaImpl + _sincronizarLoteDesdeDetalle + _consumirLotesFIFO + _actualizarLote (ver DISENO_cerrar_guia.md).
-- CONTRATO: recibe los detalles COMO PARÁMETRO (la sombra wh.guia_detalle no tiene fecha_vencimiento/id_detalle).
--   p = { id_guia, usuario, tipo?, detalles:[{codigo_producto, cantidad_recibida, precio_unitario, id_lote,
--         fecha_vencimiento, id_detalle, id_mov, id_lote_nuevo}] }   (ids de mov/lote los genera GAS → idempotencia)
-- Atómica (1 tx). Idempotente (si ya CERRADA → no reaplica stock). NO toca stock si envasado (lo hace Envasados).

insert into mos.config (clave, valor, descripcion) values
  ('WH_CERRAR_GUIA_DIRECTO','0','WH: cerrar guia directo a Supabase (RPC wh.cerrar_guia). VALIDAR EXHAUSTIVO antes de prender.')
on conflict (clave) do nothing;

-- [40x A3] coerción numérica tolerante (como parseFloat). Idempotente (igual que en 30_wh_crear_ajuste.sql).
create or replace function wh._num(t text) returns numeric language sql immutable as $$
  select case
    when t is null then 0
    when btrim(replace(t, ',', '.')) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(replace(t, ',', '.'))::numeric
    else 0 end;
$$;

create or replace function wh.cerrar_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id        text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_usuario   text := coalesce(p->>'usuario','');
  v_estado    text;
  v_tipo      text;
  v_ingreso   boolean;
  v_envasado  boolean;
  v_monto     numeric := 0;
  v_d         jsonb;
  v_cod       text;
  v_cant      numeric;
  v_idlote    text;
  v_fvenc     text;       -- yyyy-MM-dd (o null)
  v_idmov     text;
  v_idlotenew text;
  v_delta     numeric;
  v_antes     numeric;
  v_despues   numeric;
  v_existe    boolean;
  v_restante  numeric;
  v_consumir  numeric;
  v_reuse     text;
  v_lote      record;
begin
  -- kill-switch
  if coalesce((select valor from mos.config where clave='WH_CERRAR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CERRAR_GUIA_DIRECTO_OFF');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  select estado, tipo into v_estado, v_tipo from wh.guias where id_guia = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  -- idempotencia: ya cerrada → NO reaplicar stock
  if upper(coalesce(v_estado,'')) in ('CERRADA','AUTOCERRADA') then
    return jsonb_build_object('ok',true,'yaCerrada',true,'estado',v_estado,
      'montoTotal',(select monto_total from wh.guias where id_guia = v_id));
  end if;

  v_tipo     := upper(coalesce(nullif(p->>'tipo',''), v_tipo, ''));
  v_ingreso  := v_tipo like 'INGRESO%';
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  -- monto total = Σ(cant_recibida × precio_unitario)
  if jsonb_typeof(p->'detalles') = 'array' then
    for v_d in select jsonb_array_elements(p->'detalles') loop
      v_monto := v_monto + wh._num(v_d->>'cantidad_recibida') * wh._num(v_d->>'precio_unitario');
    end loop;
  end if;

  -- aplicar por detalle (saltar si envasado: el stock ya lo aplicó Envasados)
  if not v_envasado and jsonb_typeof(p->'detalles') = 'array' then
    for v_d in select jsonb_array_elements(p->'detalles') loop
      v_cod  := nullif(btrim(v_d->>'codigo_producto'),'');
      v_cant := wh._num(v_d->>'cantidad_recibida');
      if v_cod is null or v_cant = 0 then continue; end if;
      v_idlote    := coalesce(v_d->>'id_lote','');
      v_fvenc     := nullif(btrim(v_d->>'fecha_vencimiento'),'');
      if v_fvenc is not null then v_fvenc := left(v_fvenc,10); end if;   -- yyyy-MM-dd
      v_idmov     := nullif(btrim(v_d->>'id_mov'),'');
      v_idlotenew := nullif(btrim(v_d->>'id_lote_nuevo'),'');
      v_delta     := case when v_ingreso then v_cant else -v_cant end;

      -- ── stock (delta) ATÓMICO: set = cantidad + delta (evita lost-update concurrente; reemplaza el _conLock de GAS).
      -- Re-lee la fila viva en CADA iteración → si el mismo producto está en 2 líneas, la 2da acumula sobre la 1ra.
      update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
       where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)  -- [B-1] 1ra fila (como GAS)
       returning cantidad_disponible into v_despues;
      if found then
        v_antes := v_despues - v_delta;
      else
        v_antes := 0; v_despues := v_delta;
        insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
        values ('STK'||v_id||'_'||v_cod, v_cod, v_despues, now());   -- [M1] id_stock determinista (no el id de lote)
      end if;
      -- movimiento (idempotente por id_mov)
      if v_idmov is not null then
        insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
        values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'CIERRE_GUIA', v_id, v_usuario)
        on conflict (id_mov) do nothing;
      end if;

      -- ── lotes ──
      if v_ingreso and v_fvenc is not null then
        -- INGRESO con fecha → sincronizar lote
        if v_idlote <> '' then
          -- caso E: ya tiene lote → UPDATE (cant_inicial/actual, fecha, ACTIVO)
          update wh.lotes_vencimiento
             set cantidad_inicial = v_cant, cantidad_actual = v_cant,
                 fecha_vencimiento = v_fvenc::date, estado = 'ACTIVO'
           where id_lote = v_idlote;
        else
          -- caso A: buscar lote (cod, id_guia, fecha) para REUSAR
          select id_lote into v_reuse from wh.lotes_vencimiento
           where upper(cod_producto) = upper(v_cod) and id_guia = v_id
             and fecha_vencimiento = v_fvenc::date limit 1;
          if v_reuse is not null then
            update wh.lotes_vencimiento
               set cantidad_inicial = v_cant, cantidad_actual = v_cant, estado = 'ACTIVO'
             where id_lote = v_reuse;
          elsif v_idlotenew is not null then
            insert into wh.lotes_vencimiento (id_lote, cod_producto, fecha_vencimiento, cantidad_inicial, cantidad_actual, id_guia, estado, fecha_creacion)
            values (v_idlotenew, v_cod, v_fvenc::date, v_cant, v_cant, v_id, 'ACTIVO', now());
          end if;
        end if;
      elsif v_ingreso and v_idlote <> '' then
        -- INGRESO con lote y SIN fecha → path legacy _actualizarLote: UPDATE cantidades; si el lote NO existe,
        -- CREARLO ([A1] GAS hace appendRow, antes la RPC lo perdía). fecha null (no había fecha). NO anula
        -- (el caso C de anular vive en _sincronizarLoteDesdeDetalle, que el cierre solo llama CON fecha).
        update wh.lotes_vencimiento set cantidad_inicial = v_cant, cantidad_actual = v_cant where id_lote = v_idlote;
        if not found then
          insert into wh.lotes_vencimiento (id_lote, cod_producto, fecha_vencimiento, cantidad_inicial, cantidad_actual, id_guia, estado, fecha_creacion)
          values (v_idlote, v_cod, null, v_cant, v_cant, v_id, 'ACTIVO', now());
        end if;
      elsif not v_ingreso then
        -- SALIDA → consumir FIFO (lote que vence primero; NO toca stock, ya bajó arriba)
        v_restante := v_cant;
        for v_lote in
          select id_lote, cantidad_actual from wh.lotes_vencimiento
           where upper(cod_producto) = upper(v_cod) and upper(estado) = 'ACTIVO' and cantidad_actual > 0
           order by fecha_vencimiento asc nulls last, id_lote asc
        loop
          exit when v_restante <= 0;
          v_consumir := least(v_lote.cantidad_actual, v_restante);
          update wh.lotes_vencimiento
             set cantidad_actual = cantidad_actual - v_consumir,
                 estado = case when (cantidad_actual - v_consumir) <= 0 then 'AGOTADO' else estado end
           where id_lote = v_lote.id_lote;
          v_restante := v_restante - v_consumir;
        end loop;
        -- v_restante > 0 → huérfano (sin lote suficiente): igual que GAS, solo se ignora (stock ya bajó)
      end if;
    end loop;
  end if;

  -- cerrar cabecera
  update wh.guias set estado = 'CERRADA', monto_total = v_monto where id_guia = v_id;

  return jsonb_build_object('ok',true,'dedup',false,'id_guia',v_id,'estado','CERRADA','montoTotal',v_monto);
end;
$fn$;

revoke all on function wh.cerrar_guia(jsonb) from public;
grant execute on function wh.cerrar_guia(jsonb) to service_role;
