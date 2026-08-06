CREATE OR REPLACE FUNCTION wh.anular_envasado(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
