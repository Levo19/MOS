-- [1001] FIX raíz "la guía declara X pero el kardex quedó en Y" (stock correcto, kardex desfasado).
--  wh.cerrar_guia_idempotente usa un id_mov determinista por (guía,línea) = 'MOVID_<guia>#<linea>' con
--  `on conflict do nothing`. Cuando se EDITA cant_recibida (ej. 1→12) y se RE-CIERRA, el re-cierre aplica el
--  delta (+11) al STOCK (correcto) pero el `do nothing` DEJA el movimiento del kardex en su valor viejo (1) →
--  el kardex muestra "+1" aunque el stock ya tiene 12, y Σmovimientos ≠ wh.stock (cuadre). reabrir_guia NO
--  revierte stock ni resetea cantidad_aplicada (solo estado), así que el delta al re-cerrar SIEMPRE es una
--  edición real → acumularlo en el movimiento es correcto e idempotente (una re-ejecución sin cambios da
--  delta 0 → SKIP antes del insert, no acumula).
--  FIX: `on conflict do UPDATE` acumula el delta y actualiza stock_despues (mantiene stock_antes original).
--  Resultado: el movimiento del kardex refleja el TOTAL real (declara 12 = kardex 12), y Σmovs cuadra con
--  wh.stock. NO cambia stock (la lógica de stock es la misma). Solo completa/corrige la traza del kardex.
create or replace function wh.cerrar_guia_idempotente(p_id_guia text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
 set statement_timeout to '20s'
as $function$
declare
  v_id        text := nullif(btrim(coalesce(p_id_guia,'')), '');
  v_estado    text;
  v_tipo      text;
  v_zona      text;
  v_ingreso   boolean;
  v_envasado  boolean;
  v_monto     numeric := 0;
  v_d         record;
  v_cod       text;
  v_cant      numeric;
  v_apl       numeric;
  v_delta     numeric;
  v_signo     numeric;
  v_antes     numeric;
  v_despues   numeric;
  v_idmov     text;
  v_aplicadas int := 0;
  v_saltadas  int := 0;
  v_fefo      jsonb;
  v_lotesz    jsonb := '[]'::jsonb;
  v_lote_new  text;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  select estado, tipo, id_zona into v_estado, v_tipo, v_zona from wh.guias where id_guia = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  v_tipo     := upper(coalesce(v_tipo,''));
  v_ingreso  := (v_tipo like 'INGRESO%' or v_tipo like 'ENTRADA%');
  v_envasado := v_tipo in ('INGRESO_ENVASADO','SALIDA_ENVASADO');

  select coalesce(sum(wh._num(cant_recibida::text) * wh._num(precio_unitario::text)), 0)
    into v_monto from wh.guia_detalle where id_guia = v_id;

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

      if v_cod is null then
        update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
        continue;
      end if;

      if v_delta = 0 then
        v_saltadas := v_saltadas + 1;
        continue;
      end if;

      v_signo := case when v_ingreso then v_delta else -v_delta end;
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

      -- [1001] kardex con origen único (id_guia#linea). Antes `on conflict do nothing` → una edición+re-cierre
      --   aplicaba stock pero NO reflejaba el nuevo total en el kardex. Ahora ACUMULA el delta y actualiza
      --   stock_despues (mantiene el stock_antes original) → el movimiento = total real, Σmovs cuadra con stock.
      --   Idempotente: un re-cierre sin cambios da v_delta=0 → SKIP arriba, jamás llega a acumular de más.
      insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
      values (v_idmov, now(), v_cod, v_signo, v_antes, v_despues, 'CIERRE_GUIA', v_id, 'sistema-cierre-idem')
      on conflict (id_mov) do update
        set delta         = wh.stock_movimientos.delta + excluded.delta,
            stock_despues = excluded.stock_despues;

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

      update wh.guia_detalle set cantidad_aplicada = v_cant where id_guia = v_id and linea = v_d.linea;
      v_aplicadas := v_aplicadas + 1;
    end loop;
  end if;

  if v_tipo = 'SALIDA_ZONA' and coalesce(btrim(v_zona),'') <> '' and jsonb_array_length(v_lotesz) > 0 then
    begin
      perform wh.propagar_lotes_zona_cierre(jsonb_build_object(
        'id_guia', v_id, 'zona', v_zona, 'lotes', v_lotesz));
    exception when others then null;
    end;
  end if;

  update wh.guias set estado = 'CERRADA', monto_total = v_monto where id_guia = v_id;

  return jsonb_build_object('ok', true, 'id_guia', v_id, 'estado', 'CERRADA',
    'montoTotal', v_monto, 'lineasAplicadas', v_aplicadas, 'lineasSaltadas', v_saltadas,
    'eraEstado', v_estado);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM, 'id_guia', v_id);
end;
$function$;

select '1001 cerrar_guia_idempotente kardex acumula delta listo' as ok;
