-- 530_lote_en_ingreso_y_gate_historial.sql — 2 fixes del dueño (2026-07-19):
-- (1) BUG: "en almacén veo puros envasados con lotes" — las guías de INGRESO con fecha de
--     vencimiento casi no creaban lote (30d: 208 líneas con fecha → 1 lote). El GAS creaba el
--     lote AL CERRAR el ingreso; el cierre cero-GAS no lo portó (mismo hueco del cutover que
--     527/528). FIX: cerrar_guia_idempotente crea/sincroniza el lote por línea de ingreso con
--     fecha (reusa wh._sync_lote_desde_detalle, idempotente; id determinista LOT<guia>#<linea>;
--     solo si la línea aún no tiene lote — si ya tiene, lo gobierna actualizar_fecha_vencimiento).
-- (2) MOS no podía leer el historial de lote: wh.get_historial_lote gateaba SOLO claim WH.
--     Se amplía a mos._claim_ok (el panel Por vencer de MOS muestra historial).

-- ── (2) gate historial ──
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'wh' and p.proname = 'get_historial_lote';
  v_src := replace(v_src,
    'if not wh._claim_ok() then',
    'if not (wh._claim_ok() or mos._claim_ok()) then');
  execute v_src;
end $$;

-- ── (1) redefine wh.cerrar_guia_idempotente = versión 528 + bloque [530] de lote-en-ingreso ──
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
  v_lote_new  text;                     -- [530] lote creado/sincronizado del ingreso
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
      select linea, cod_producto, cant_recibida, cantidad_aplicada, fecha_vencimiento, id_lote
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

      -- [530] INGRESO con fecha de vencimiento y SIN lote aún → crear lote al cierre (como GAS).
      --   Id determinista LOT<guia>#<linea> → recerrar no duplica (delta 0 skip + on conflict).
      --   Si la línea YA tiene lote, lo gobierna actualizar_fecha_vencimiento (no pisar acá:
      --   un reset de cantidad borraría consumo FEFO posterior). Blindado.
      if v_ingreso and v_delta > 0 and v_d.fecha_vencimiento is not null
         and coalesce(nullif(btrim(coalesce(v_d.id_lote,'')),''),'') = '' then
        begin
          v_lote_new := wh._sync_lote_desde_detalle(
            null, v_cod, v_cant, to_char(v_d.fecha_vencimiento,'YYYY-MM-DD'),
            v_id, 'LOT'||v_id||'#'||v_d.linea);
          if coalesce(v_lote_new,'') <> '' then
            update wh.guia_detalle set id_lote = v_lote_new where id_guia = v_id and linea = v_d.linea;
          end if;
        exception when others then null;
        end;
      end if;

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
