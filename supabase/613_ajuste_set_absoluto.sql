-- 613 · El AJUSTE fija el conteo (SET absoluto), no suma diferencias. WH + MOS igual.
--
-- Orden de Luis (03/08/2026): "el ajuste justamente hace eso: da la diferencia sea
-- positivo o negativo... si a 49.99 le pongo 50, el stock nuevo debe ser 50. El ajuste
-- no tiene nada que ver con lo que el resto envasa o consume. Ambos [WH y MOS] deben funcionar."
--
-- QUÉ ESTABA MAL (verificado 03/08):
--   · wh.crear_ajuste sumaba un DELTA calculado EN LA PANTALLA (25 − 24.9 = 0.1). Si entre
--     el conteo y el guardado alguien envasa/despacha, el saldo final NO es el contado.
--   · Ese delta viene con basura de coma flotante del navegador (0.10000000000000142) y
--     dejaba saldos como 1e-17 en vez de 0 (arándano granel: ajustar a 0 dejaba 0.00000000000000001).
--   · mos.almacen_crear_ajuste YA hacía SET absoluto (correcto) pero sin redondear.
--
-- QUÉ HACE AHORA (ambas RPC):
--   · Si llega `conteo` → SET ABSOLUTO bajo lock de fila: el saldo final ES el conteo. Inmune
--     a lo que pase en paralelo (un envasado intercalado se refleja como delta distinto en el
--     kardex, pero el saldo queda en lo contado, que es la verdad física).
--   · Redondeo a 3 DECIMALES del saldo y del delta (NO 2: los insumos se mueven en millares y
--     1 unidad = 0.001 MIL — con 2 decimales el consumo de celofanes se perdería).
--   · wh.crear_ajuste conserva la vía vieja (tipo INC/DEC + cantidad) para no romper llamadas
--     en cola/legacy, pero TAMBIÉN redondea el resultado.

create or replace function wh.crear_ajuste(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_ajuste','')), '');
  v_cod     text := nullif(btrim(coalesce(p->>'codigo_producto','')), '');
  v_tipo    text := upper(coalesce(p->>'tipo',''));
  v_cant    numeric := wh._num(p->>'cantidad');
  -- [613] conteo ABSOLUTO (nueva vía preferente). null → vía delta legacy.
  v_conteo  numeric := case when nullif(btrim(coalesce(p->>'conteo','')),'') is null
                            then null else wh._num(p->>'conteo') end;
  v_motivo  text := coalesce(p->>'motivo','');
  v_usuario text := coalesce(p->>'usuario','');
  v_id_aud  text := coalesce(p->>'id_auditoria','');
  v_id_stk  text := nullif(btrim(coalesce(p->>'id_stock_nuevo','')), '');
  v_id_mov  text := nullif(btrim(coalesce(p->>'id_mov','')), '');
  v_fecha   timestamptz := coalesce(nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz, now());
  v_delta   numeric;
  v_antes   numeric;
  v_despues numeric;
  v_fila    text;
begin
  if coalesce((select valor from mos.config where clave='WH_CREAR_AJUSTE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_AJUSTE_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- validaciones SOLO de la vía legacy (con `conteo` el tipo/cantidad son irrelevantes)
  if v_conteo is null then
    if v_tipo not in ('INC','DEC') then return jsonb_build_object('ok',false,'error','TIPO_INVALIDO'); end if;
    if v_cant <= 0                 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  else
    if v_conteo < 0 then return jsonb_build_object('ok',false,'error','CONTEO_NEGATIVO'); end if;
  end if;

  -- idempotencia: el mismo gesto reintentado NO re-toca el stock
  if exists (select 1 from wh.ajustes where id_ajuste = v_id) then
    select cantidad_disponible into v_despues from wh.stock where cod_producto = v_cod limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'id_ajuste',v_id,'stockNuevo',coalesce(v_despues,0));
  end if;

  if v_conteo is not null then
    -- ── SET ABSOLUTO ──────────────────────────────────────────────────────────
    -- Lock de la fila determinista ANTES de leer: un despacho/envasado concurrente
    -- espera → el saldo final es EXACTAMENTE lo contado.
    select id_stock, cantidad_disponible into v_fila, v_antes
      from wh.stock where cod_producto = v_cod order by id_stock limit 1 for update;
    v_despues := round(v_conteo, 3);
    if v_fila is not null then
      v_antes := round(coalesce(v_antes,0), 3);
      v_delta := round(v_despues - v_antes, 3);
      if v_delta = 0 then
        return jsonb_build_object('ok',true,'dedup',false,'noop',true,'id_ajuste',v_id,
          'stockAntes',v_antes,'stockNuevo',v_antes,'delta',0);
      end if;
      update wh.stock set cantidad_disponible = v_despues, ultima_actualizacion = v_fecha
       where id_stock = v_fila;
    else
      v_antes := 0; v_delta := v_despues;
      if v_delta = 0 then
        return jsonb_build_object('ok',true,'dedup',false,'noop',true,'id_ajuste',v_id,
          'stockAntes',0,'stockNuevo',0,'delta',0);
      end if;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values (coalesce(v_id_stk, 'STK'||v_id), v_cod, v_despues, v_fecha);
    end if;
    v_tipo := case when v_delta > 0 then 'INC' else 'DEC' end;
    v_cant := abs(v_delta);
  else
    -- ── VÍA LEGACY (delta INC/DEC) — se conserva por la cola offline y llamadas viejas.
    v_delta := round(case when v_tipo='INC' then v_cant else -v_cant end, 3);
    update wh.stock set cantidad_disponible = round(cantidad_disponible + v_delta, 3),
                        ultima_actualizacion = v_fecha
     where id_stock = (select id_stock from wh.stock where cod_producto = v_cod order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then
      v_antes := round(v_despues - v_delta, 3);
    else
      v_antes := 0; v_despues := v_delta;
      insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
      values (coalesce(v_id_stk, 'STK'||v_id), v_cod, v_despues, v_fecha);
    end if;
    v_cant := abs(v_delta);
  end if;

  insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
  values (v_id, v_cod, v_tipo, v_cant, v_motivo, v_usuario, v_id_aud, v_fecha);

  if v_id_mov is not null then
    insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
    values (v_id_mov, v_fecha, v_cod, v_delta, v_antes, v_despues, 'AJUSTE_MANUAL', v_id, v_usuario)
    on conflict (id_mov) do nothing;
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'id_ajuste',v_id,
    'tipo',v_tipo,'cantidad',v_cant,'stockAntes',v_antes,'stockNuevo',v_despues,'delta',v_delta);
end;
$function$;

-- ── MOS/RIZ: ya hacía SET absoluto; se le agrega el MISMO redondeo a 3 decimales ──
create or replace function mos.almacen_crear_ajuste(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_cod     text := nullif(btrim(coalesce(p->>'codProducto', p->>'codigo_producto', p->>'codBarra', '')), '');
  v_conteo  numeric := nullif(btrim(coalesce(p->>'conteo','')), '')::numeric;
  v_user    text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'');
  v_id      text := nullif(btrim(coalesce(p->>'idAjuste', p->>'id_ajuste', p->>'localId', '')), '');
  v_motivo  text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''), 'Ajuste por conteo (RIZ Almacén)');
  v_zona    text := upper(btrim(coalesce(p->>'zona','')));
  v_fecha   timestamptz := now();
  v_id_stk  text;
  v_antes   numeric;
  v_despues numeric;
  v_delta   numeric;
  v_tipo    text;
  v_cant    numeric;
  v_id_mov  text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave='WH_CREAR_AJUSTE_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_AJUSTE_DIRECTO_OFF');
  end if;
  if v_cod is null or v_conteo is null then
    return jsonb_build_object('ok',false,'error','Requiere codProducto y conteo (numérico)');
  end if;
  if v_id is null then
    return jsonb_build_object('ok',false,'error','Requiere idAjuste (idempotencia)');
  end if;
  if v_conteo < 0 then return jsonb_build_object('ok',false,'error','CONTEO_NEGATIVO'); end if;

  v_cod := upper(v_cod);
  v_conteo := round(v_conteo, 3);   -- [613]

  if exists (select 1 from wh.ajustes a where a.id_ajuste = v_id) then
    select s.cantidad_disponible into v_despues
      from wh.stock s where upper(btrim(s.cod_producto)) = v_cod order by s.id_stock limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'id_ajuste',v_id,'stockNuevo',coalesce(v_despues,0));
  end if;

  select s.id_stock, s.cantidad_disponible into v_id_stk, v_antes
    from wh.stock s where upper(btrim(s.cod_producto)) = v_cod
    order by s.id_stock limit 1
    for update;

  if v_id_stk is not null then
    v_antes := round(coalesce(v_antes, 0), 3);   -- [613]
    v_delta := round(v_conteo - v_antes, 3);
    if v_delta = 0 then
      return jsonb_build_object('ok',true,'dedup',false,'noop',true,'id_ajuste',v_id,
        'stockAntes',v_antes,'stockNuevo',v_antes,'delta',0);
    end if;
    update wh.stock
       set cantidad_disponible = v_conteo, ultima_actualizacion = v_fecha
     where id_stock = v_id_stk;
    v_despues := v_conteo;
  else
    v_antes := 0; v_despues := v_conteo; v_delta := v_conteo;
    if v_delta = 0 then
      return jsonb_build_object('ok',true,'dedup',false,'noop',true,'id_ajuste',v_id,
        'stockAntes',0,'stockNuevo',0,'delta',0);
    end if;
    insert into wh.stock (id_stock, cod_producto, cantidad_disponible, ultima_actualizacion)
    values ('STK'||v_id, v_cod, v_despues, v_fecha);
  end if;

  v_tipo := case when v_delta > 0 then 'INC' else 'DEC' end;
  v_cant := abs(v_delta);

  insert into wh.ajustes (id_ajuste, cod_producto, tipo_ajuste, cantidad_ajuste, motivo, usuario, id_auditoria, fecha)
  values (v_id, v_cod, v_tipo, v_cant, v_motivo, v_user, nullif(v_zona,''), v_fecha);

  v_id_mov := 'MOV-'||v_id;
  insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
  values (v_id_mov, v_fecha, v_cod, v_delta, v_antes, v_despues, 'AJUSTE_MANUAL', coalesce(nullif(v_zona,''),'RIZ-ALMACEN'), v_user)
  on conflict (id_mov) do nothing;

  return jsonb_build_object('ok',true,'dedup',false,'id_ajuste',v_id,
    'tipo',v_tipo,'cantidad',v_cant,'stockAntes',v_antes,'stockNuevo',v_despues,'delta',v_delta);
end;
$function$;
