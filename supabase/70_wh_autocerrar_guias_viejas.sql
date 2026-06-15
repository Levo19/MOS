-- 70_wh_autocerrar_guias_viejas.sql
-- Reemplazo Supabase del trigger GAS `cerrarGuiasAbiertasGlobal` (Auditoria.gs ~14), apagado en el cutover
-- porque corria sobre el Sheet congelado. Cierra guias ABIERTA de DIAS ANTERIORES (dia-negocio Lima).
--
-- CRITERIO (mas conservador que el GAS a proposito):
--   - El GAS cerraba TODAS las ABIERTA sin mirar fecha. Aqui EXCLUIMOS las de HOY (estan en progreso):
--     estado='ABIERTA' AND (fecha at tz Lima)::date < (now() at tz Lima)::date.
--   - Esto evita cerrar trabajo del dia en curso. Las viejas son las que quedaron olvidadas abiertas.
--
-- LOGICA DE STOCK: clonada EXACTA de 35_wh_cerrar_guia.sql (_cerrarGuiaImpl):
--   - delta = +cant_recibida si tipo like 'INGRESO%', si no -cant_recibida.
--   - UPDATE atomico  cantidad_disponible = cantidad_disponible + delta  (NUNCA read-modify-write).
--   - usa la 1ra fila de stock por cod_producto (order by id_stock), si no existe la crea.
--   - ENVASADO (INGRESO_ENVASADO / SALIDA_ENVASADO): NO toca stock (lo aplico Envasados); solo marca CERRADA.
--   - INGRESO con fecha_vencimiento -> sincroniza lote (reusa cod+guia+fecha, o UPDATE id_lote, o INSERT nuevo).
--   - INGRESO con id_lote y sin fecha -> path legacy (UPDATE/INSERT lote sin fecha).
--   - SALIDA -> consume lotes FIFO (vence primero), huerfano se ignora (stock ya bajo).
--   - movimiento idempotente por id_mov determinista; lote nuevo idempotente por id_lote determinista.
--
-- DIFERENCIA con cerrar_guia: aqui LEEMOS el detalle de wh.guia_detalle (que SI tiene fecha_vencimiento e
--   id_detalle en la sombra post-cutover), no lo recibimos por parametro. El cron corre sin GAS.
--
-- GATE: para cron (sin JWT) usamos service_role. NO usamos _claim_ok() (requiere JWT de la app) ni el
--   kill-switch WH_CERRAR_GUIA_DIRECTO (ese gatea el camino interactivo; el autocierre es server-side de sistema).
--   El grant execute queda SOLO para service_role -> nadie con JWT de usuario puede invocarla.
--
-- Atomica (1 tx por llamada). Idempotente (early-return si guia ya CERRADA/AUTOCERRADA). FOR UPDATE por guia.
-- Marca estado='CERRADA' (igual que cerrar_guia: ambas APLICAN stock; AUTOCERRADA significaria "no aplico" para
--   64/36 y descuadraria al editar/reabrir). La traza del cron queda en usuario='sistema-autocierre' (movimientos).
-- WHERE/guard coherente: selecciona ABIERTA -> aplica stock -> marca CERRADA; si ya CERRADA/AUTOCERRADA, skip (no reaplica).

create or replace function wh.autocerrar_guias_viejas()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_usuario   text := 'sistema-autocierre';
  v_g         record;
  v_estado    text;
  v_tipo      text;
  v_ingreso   boolean;
  v_envasado  boolean;
  v_monto     numeric;
  v_d         record;
  v_cod       text;
  v_cant      numeric;
  v_idlote    text;
  v_fvenc     date;
  v_idmov     text;
  v_idlotenew text;
  v_delta     numeric;
  v_antes     numeric;
  v_despues   numeric;
  v_restante  numeric;
  v_consumir  numeric;
  v_reuse     text;
  v_lote      record;
  v_cerradas  int := 0;
  v_errores   int := 0;
  v_detalle   jsonb := '[]'::jsonb;
begin
  -- Recorrer las guias ABIERTA de dias anteriores (dia-negocio Lima). Bloqueamos cada cabecera (FOR UPDATE)
  -- al releerla dentro del loop para serializar contra un cierre interactivo concurrente.
  for v_g in
    select id_guia
      from wh.guias
     where upper(coalesce(estado,'')) = 'ABIERTA'
       and (fecha at time zone 'America/Lima')::date < (now() at time zone 'America/Lima')::date
     order by fecha asc
  loop
    begin
      -- re-leer + lock (FOR UPDATE): si otro cierre la tomo, esperamos y re-evaluamos estado
      select estado, tipo into v_estado, v_tipo
        from wh.guias where id_guia = v_g.id_guia limit 1 for update;
      if not found then continue; end if;

      -- idempotencia: si ya la cerraron mientras esperabamos el lock -> skip (no reaplica stock)
      if upper(coalesce(v_estado,'')) in ('CERRADA','AUTOCERRADA') then
        continue;
      end if;

      v_tipo     := upper(coalesce(v_tipo,''));
      v_ingreso  := v_tipo like 'INGRESO%';
      v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');
      v_monto    := 0;

      -- monto total = Σ(cant_recibida × precio_unitario)   (igual que cerrar_guia)
      select coalesce(sum(wh._num(cant_recibida::text) * wh._num(precio_unitario::text)), 0)
        into v_monto
        from wh.guia_detalle where id_guia = v_g.id_guia;

      -- aplicar por detalle (saltar si envasado: el stock ya lo aplico Envasados)
      if not v_envasado then
        for v_d in
          select cod_producto, cant_recibida, id_lote, fecha_vencimiento, id_detalle, linea
            from wh.guia_detalle
           where id_guia = v_g.id_guia
           order by linea asc nulls last
        loop
          v_cod  := nullif(btrim(v_d.cod_producto), '');
          v_cant := wh._num(v_d.cant_recibida::text);
          if v_cod is null or v_cant = 0 then continue; end if;
          v_idlote    := coalesce(v_d.id_lote, '');
          v_fvenc     := v_d.fecha_vencimiento;   -- ya es date en la sombra
          v_delta     := case when v_ingreso then v_cant else -v_cant end;
          -- ids deterministas (idempotencia por id_mov / id_lote en reintentos del mismo cron)
          v_idmov     := 'MOVAC_' || v_g.id_guia || '_' || coalesce(nullif(btrim(v_d.id_detalle),''), v_cod);
          v_idlotenew := 'LOTAC_' || v_g.id_guia || '_' || v_cod ||
                         coalesce('_' || to_char(v_fvenc,'YYYYMMDD'), '');

          -- ── stock (delta) ATOMICO ──
          update wh.stock set cantidad_disponible = cantidad_disponible + v_delta, ultima_actualizacion = now()
           where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
           returning cantidad_disponible into v_despues;
          if found then
            v_antes := v_despues - v_delta;
          else
            v_antes := 0; v_despues := v_delta;
            insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
            values ('STK'||v_g.id_guia||'_'||v_cod, v_cod, v_despues, now());
          end if;

          -- movimiento (idempotente por id_mov)
          insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
          values (v_idmov, now(), v_cod, v_delta, v_antes, v_despues, 'CIERRE_GUIA', v_g.id_guia, v_usuario)
          on conflict (id_mov) do nothing;

          -- ── lotes ──
          if v_ingreso and v_fvenc is not null then
            if v_idlote <> '' then
              update wh.lotes_vencimiento
                 set cantidad_inicial = v_cant, cantidad_actual = v_cant,
                     fecha_vencimiento = v_fvenc, estado = 'ACTIVO'
               where id_lote = v_idlote;
              if not found then
                insert into wh.lotes_vencimiento (id_lote, cod_producto, fecha_vencimiento, cantidad_inicial, cantidad_actual, id_guia, estado, fecha_creacion)
                values (v_idlote, v_cod, v_fvenc, v_cant, v_cant, v_g.id_guia, 'ACTIVO', now())
                on conflict (id_lote) do nothing;
              end if;
            else
              select id_lote into v_reuse from wh.lotes_vencimiento
               where upper(cod_producto) = upper(v_cod) and id_guia = v_g.id_guia
                 and fecha_vencimiento::date = v_fvenc limit 1;
              if v_reuse is not null then
                update wh.lotes_vencimiento
                   set cantidad_inicial = v_cant, cantidad_actual = v_cant, estado = 'ACTIVO'
                 where id_lote = v_reuse;
              else
                insert into wh.lotes_vencimiento (id_lote, cod_producto, fecha_vencimiento, cantidad_inicial, cantidad_actual, id_guia, estado, fecha_creacion)
                values (v_idlotenew, v_cod, v_fvenc, v_cant, v_cant, v_g.id_guia, 'ACTIVO', now())
                on conflict (id_lote) do nothing;
              end if;
            end if;
          elsif v_ingreso and v_idlote <> '' then
            update wh.lotes_vencimiento set cantidad_inicial = v_cant, cantidad_actual = v_cant where id_lote = v_idlote;
            if not found then
              insert into wh.lotes_vencimiento (id_lote, cod_producto, fecha_vencimiento, cantidad_inicial, cantidad_actual, id_guia, estado, fecha_creacion)
              values (v_idlote, v_cod, null, v_cant, v_cant, v_g.id_guia, 'ACTIVO', now())
              on conflict (id_lote) do nothing;
            end if;
          elsif not v_ingreso then
            -- SALIDA -> consumir FIFO (NO toca stock, ya bajo arriba)
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
          end if;
        end loop;
      end if;

      -- cerrar cabecera. ⚠️ COHERENCIA DE STOCK: marcamos 'CERRADA' (NO 'AUTOCERRADA'), igual que el cierre
      -- manual cerrar_guia. Razon: el resto del sistema (64 editar/anular detalle, 36 reabrir) trata
      -- 'AUTOCERRADA' como "NUNCA aplico stock" (v_cerrada := estado='CERRADA' estricto), pero aqui SI aplicamos
      -- stock arriba. Si marcaramos AUTOCERRADA, una edicion/anulacion/reapertura posterior NO ajustaria/revertiria
      -- el stock -> DESCUADRE. La traza de "lo cerro el cron" queda en usuario='sistema-autocierre' (movimientos).
      update wh.guias set estado = 'CERRADA', monto_total = v_monto where id_guia = v_g.id_guia;

      v_cerradas := v_cerradas + 1;
      v_detalle := v_detalle || jsonb_build_object('id_guia', v_g.id_guia, 'tipo', v_tipo, 'monto', v_monto);
    exception when others then
      v_errores := v_errores + 1;
      v_detalle := v_detalle || jsonb_build_object('id_guia', v_g.id_guia, 'error', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('ok', true, 'cerradas', v_cerradas, 'errores', v_errores, 'detalle', v_detalle);
end;
$fn$;

revoke all on function wh.autocerrar_guias_viejas() from public;
grant execute on function wh.autocerrar_guias_viejas() to service_role;
