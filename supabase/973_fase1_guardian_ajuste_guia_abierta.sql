-- [973] FASE 1 · Guardián: no permitir "Ajustar" un producto que está en una GUÍA ABIERTA (no aplicada).
--  Motivo: el ajuste hace SET ABSOLUTO y el cierre de la guía SUMA su delta encima → doble conteo. Regla:
--   · ALMACÉN (wh) → cualquier guía estado ≠ CERRADA/ANULADA bloquea.
--   · ZONA (me)    → guía NO-venta estado ≠ CERRADA/CONFIRMADO/ANULADA bloquea (las ventas se reconcilian, Fase 2).
--  Va en los RPC de ajuste (server-side) → aplica a MOS + ME + WH y a TODOS los roles. Off-switch:
--   mos.config AJUSTE_BLOQUEA_GUIA_ABIERTA='0'.
create or replace function mos._guia_abierta_de(p_cod text, p_ambito text)
returns text language sql stable security definer set search_path to '' as $function$
  select case when upper(coalesce(p_ambito,'')) = 'ZONA' then
    (select g.id_guia from me.guias_detalle d join me.guias_cabecera g on g.id_guia = d.id_guia
      where upper(btrim(d.cod_barras)) = upper(btrim(p_cod))
        and upper(coalesce(g.tipo,'')) not like 'SALIDA_VENTA%'
        and upper(coalesce(g.estado,'')) not in ('CERRADA','CONFIRMADO','ANULADA')
      order by g.fecha desc limit 1)
  else
    (select g.id_guia from wh.guia_detalle d join wh.guias g on g.id_guia = d.id_guia
      where upper(btrim(d.cod_producto)) = upper(btrim(p_cod))
        and upper(coalesce(g.estado,'')) not in ('CERRADA','ANULADA')
      order by g.fecha desc limit 1)
  end;
$function$;
grant execute on function mos._guia_abierta_de(text,text) to authenticated, anon, service_role;

CREATE OR REPLACE FUNCTION wh.crear_ajuste(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_gopen   text;
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

  -- [GUARDIÁN F1] No permitir ajustar un producto que está en una GUÍA ABIERTA (no aplicada): al cerrarla se
  --   SUMA su delta encima del conteo → doble conteo. Cierra la guía primero. (Off-switch: mos.config
  --   AJUSTE_BLOQUEA_GUIA_ABIERTA='0'.)
  if coalesce((select valor from mos.config where clave='AJUSTE_BLOQUEA_GUIA_ABIERTA' limit 1),'1') = '1' then
    v_gopen := mos._guia_abierta_de(v_cod, 'ALMACEN');
    if v_gopen is not null then
      return jsonb_build_object('ok',false,'error','PRODUCTO_EN_GUIA_ABIERTA','guia',v_gopen,
        'mensaje','No puedes ajustar: este producto está en una guía abierta ('||v_gopen||'). Ciérrala primero y vuelve a intentar.');
    end if;
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
$function$
;
CREATE OR REPLACE FUNCTION mos.almacen_crear_ajuste(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_gopen   text;
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

  -- [GUARDIÁN F1] No ajustar si el producto está en una guía ABIERTA (no aplicada): el cierre sumaría su
  --   delta encima del conteo → doble conteo. Cierra la guía primero.
  if coalesce((select valor from mos.config where clave='AJUSTE_BLOQUEA_GUIA_ABIERTA' limit 1),'1') = '1' then
    v_gopen := mos._guia_abierta_de(v_cod, 'ALMACEN');
    if v_gopen is not null then
      return jsonb_build_object('ok',false,'error','PRODUCTO_EN_GUIA_ABIERTA','guia',v_gopen,
        'mensaje','No puedes ajustar: este producto está en una guía abierta ('||v_gopen||'). Ciérrala primero y vuelve a intentar.');
    end if;
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
$function$
;
CREATE OR REPLACE FUNCTION me.zona_ajustar_stock(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));          -- zona SÍ es upper-case por convención (ZONA-02)
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_nuevo numeric := nullif(btrim(coalesce(p->>'nuevo','')), '')::numeric;
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_cb    text := nullif(btrim(coalesce(p->>'codBarra', p->>'codBarras', '')), '');  -- 🔴#2: SIN upper(), código TAL CUAL
  -- tipo de movimiento del kardex: AUDITORIA si el gesto viene de la pantalla de auditoría, AJUSTE si no.
  v_ktipo text := upper(coalesce(nullif(btrim(coalesce(p->>'tipoAjuste','')),''),
                                 case when upper(btrim(coalesce(p->>'origen','')))='AUDITORIA' then 'AUDITORIA' else 'AJUSTE' end));
  v_antes numeric;
  v_existe bigint;
  v_refk  text;
  v_gopen text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_nuevo is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y nuevo (numérico)');
  end if;
  if v_cb is null and v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere codBarra (o skuBase para resolver el canónico)');
  end if;
  if v_ktipo not in ('AJUSTE','AUDITORIA') then v_ktipo := 'AJUSTE'; end if;

  -- IDEMPOTENCIA por localId: si el gesto ya se aplicó → devolver lo persistido (dedup).
  if v_local is not null then
    select id into v_existe from me.zona_ajuste_log where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idLog', v_existe));
    end if;
  end if;

  -- resolver el código concreto (🔴#2: comparar TAL CUAL — btrim, sin upper).
  if v_cb is null then
    select btrim(pr.codigo_barra) into v_cb
    from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku
      and nullif(btrim(pr.codigo_barra),'') is not null
    order by (case when coalesce(pr.codigo_producto_base,'')='' and coalesce(pr.factor_conversion,1)=1 then 0 else 1 end), pr.id_producto
    limit 1;
  end if;
  if v_cb is null then
    return jsonb_build_object('ok',false,'error','No se encontró código de barra para el skuBase '||coalesce(v_sku,''));
  end if;

  if v_sku is null then
    select sk into v_sku from (
      select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) sk, 0 ord
        from mos.productos pr where btrim(pr.codigo_barra) = v_cb
      union all
      select e.sku_base, 1 from mos.equivalencias e where btrim(e.codigo_barra) = v_cb and coalesce(e.activo,true)
    ) t order by ord limit 1;
  end if;

  -- [GUARDIÁN F1] No ajustar si el producto está en una guía de ZONA no-venta ABIERTA (traslado/ingreso no
  --   aplicado): al cerrarla se sumaría su delta encima del conteo. Las VENTAS (caja abierta todo el día) NO
  --   bloquean — esas se reconcilian por hora al cerrar caja (Fase 2).
  if coalesce((select valor from mos.config where clave='AJUSTE_BLOQUEA_GUIA_ABIERTA' limit 1),'1') = '1' then
    v_gopen := mos._guia_abierta_de(v_cb, 'ZONA');
    if v_gopen is not null then
      return jsonb_build_object('ok',false,'error','PRODUCTO_EN_GUIA_ABIERTA','guia',v_gopen,
        'mensaje','No puedes ajustar: este producto está en una guía abierta ('||v_gopen||'). Ciérrala primero y vuelve a intentar.');
    end if;
  end if;

  -- stock antes (🔴#2: igualdad EXACTA del código; zona sigue case-insensible que es su convención).
  select coalesce(sum(cantidad),0) into v_antes from me.stock_zonas
   where btrim(cod_barras) = v_cb and upper(btrim(zona_id)) = v_zona;

  -- escribir el nuevo stock (upsert atómico sobre PK (cod_barras, zona_id)) — SET ABSOLUTO. (NO cambia.)
  insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
  values (v_cb, v_zona, v_nuevo, v_user, now())
  on conflict (cod_barras, zona_id) do update set
    cantidad = excluded.cantidad, usuario = excluded.usuario, fecha_ultimo_registro = now();

  -- log [D] (idempotente por local_id).
  insert into me.zona_ajuste_log (zona_id, sku_base, cod_barras, stock_antes, stock_despues, delta, usuario, local_id)
  values (v_zona, v_sku, v_cb, v_antes, v_nuevo, v_nuevo - v_antes, v_user, v_local)
  on conflict (local_id) where local_id is not null do nothing;

  -- KARDEX [🔴#1]: SET ABSOLUTO. Pasamos nuevoAbsoluto = v_nuevo → me.zona_kardex_registrar re-ancla
  --   saldo_despues := v_nuevo (delta = v_nuevo − saldo_actual_kardex). Esto elimina el desfase del kardex.
  --   tipo = AUDITORIA cuando el origen es la auditoría (para distinguir en el historial), AJUSTE en otro caso.
  --   Idempotente por refId (uq_me_kardex_ref): por localId si vino; si no, por (zona,cod,epoch-ms).
  v_refk := v_ktipo||':'||coalesce(v_local, v_zona||':'||v_cb||':'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
  perform me.zona_kardex_registrar(jsonb_build_object(
    'zona', v_zona, 'codBarra', v_cb, 'tipo', v_ktipo, 'nuevoAbsoluto', v_nuevo,
    'refTipo', v_ktipo, 'refId', v_refk, 'usuario', v_user, 'origen', v_origen, 'localId', v_local));

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona', v_zona, 'skuBase', v_sku, 'codBarra', v_cb, 'codBarras', v_cb,
    'stockAntes', v_antes, 'stockDespues', v_nuevo, 'delta', v_nuevo - v_antes));
end;
$function$
;
select '973 fase1 guardian listo' as ok;
