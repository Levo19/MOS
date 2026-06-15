-- 60_wh_registrar_envasado.sql — [PASO 5 · B4] Orquestador ATÓMICO de envasado (la pieza más compleja, hallazgo #4).
-- Consume BASE (granel) y produce DERIVADO (unidades) en UNA SOLA TRANSACCIÓN. Replica _registrarEnvasadoImpl (GAS):
--   guía SALIDA_ENVASADO del día + detalle base + stock_base -= cant_base
--   guía INGRESO_ENVASADO del día + detalle derivado + stock_derivado += unidades + lote (si fecha_venc)
--   fila en wh.envasados. El CLIENTE resuelve el catálogo (cod_base, factor, cant_base) del cache y los pasa.
-- Idempotente por id_envasado. UPDATE atómico de stock (cantidad += delta). Gate _claim_ok. INERTE (flag).

insert into mos.config (clave, valor, descripcion) values
  ('WH_REGISTRAR_ENVASADO_DIRECTO','0','WH: registrar envasado directo (orquestador atomico base/derivado).')
on conflict (clave) do nothing;

create or replace function wh.registrar_envasado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idenv   text := nullif(btrim(coalesce(p->>'id_envasado','')), '');
  v_codbase text := nullif(btrim(coalesce(p->>'cod_producto_base','')), '');
  v_codder  text := nullif(btrim(coalesce(p->>'cod_producto_envasado','')), '');
  v_cantbase numeric := wh._num(p->>'cantidad_base');
  v_unidades numeric := wh._num(p->>'unidades_producidas');
  v_unidadbase text := coalesce(p->>'unidad_base','');
  v_fvenc   text := nullif(btrim(coalesce(p->>'fecha_vencimiento','')), '');
  v_usuario text := coalesce(p->>'usuario','sistema');
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_gsal text; v_ging text; v_linea int;
  v_antes numeric; v_despues numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_REGISTRAR_ENVASADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REGISTRAR_ENVASADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idenv is null or v_codbase is null or v_codder is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_unidades <= 0 or v_cantbase < 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_fvenc is not null then v_fvenc := left(v_fvenc,10); end if;

  -- idempotencia ATÓMICA por id_envasado (dedup vía sync_directo: insert-on-conflict toma el lock de la PK y serializa
  -- reintentos concurrentes — evita doble-consumo de base / doble-producción de derivado). HALLAZGO 40x #1.
  if not wh._dedup_nuevo(v_idenv, 'registrar_envasado') then
    return jsonb_build_object('ok',true,'dedup',true,'id_envasado',v_idenv);
  end if;

  -- ── SALIDA del BASE ──────────────────────────────────────────────
  select id_guia into v_gsal from wh.guias
   where tipo='SALIDA_ENVASADO' and (fecha at time zone 'America/Lima')::date = v_hoy order by fecha desc limit 1;
  if v_gsal is null then
    v_gsal := 'GSE'||v_idenv;
    insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
    values (v_gsal,'SALIDA_ENVASADO',now(),v_usuario,'Envasados '||to_char(v_hoy,'YYYY-MM-DD'),0,'CERRADA','','','','','');
  end if;
  select coalesce(max(linea),0)+1 into v_linea from wh.guia_detalle where id_guia=v_gsal;
  insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
  values (v_gsal,v_linea,v_codbase,v_cantbase,v_cantbase,0,'','Envasado','','ENVDET_S'||v_idenv,null);
  if v_cantbase > 0 then
    update wh.stock set cantidad_disponible = cantidad_disponible - v_cantbase, ultima_actualizacion=now()
     where id_stock=(select id_stock from wh.stock where cod_producto=v_codbase order by id_stock limit 1)
     returning cantidad_disponible into v_despues;
    if found then v_antes := v_despues + v_cantbase;
    else v_antes:=0; v_despues:=-v_cantbase;
      insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('STKSE'||v_idenv,v_codbase,v_despues,now());
    end if;
    insert into wh.stock_movimientos(id_mov,fecha,cod_producto,delta,stock_antes,stock_despues,tipo_operacion,origen,usuario)
    values('MOVSE'||v_idenv,now(),v_codbase,-v_cantbase,v_antes,v_despues,'ENVASADO_SALIDA',v_idenv,v_usuario) on conflict(id_mov) do nothing;
  end if;

  -- ── INGRESO del DERIVADO ─────────────────────────────────────────
  select id_guia into v_ging from wh.guias
   where tipo='INGRESO_ENVASADO' and (fecha at time zone 'America/Lima')::date = v_hoy order by fecha desc limit 1;
  if v_ging is null then
    v_ging := 'GIE'||v_idenv;
    insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
    values (v_ging,'INGRESO_ENVASADO',now(),v_usuario,'Envasados '||to_char(v_hoy,'YYYY-MM-DD'),0,'CERRADA','','','','','');
  end if;
  select coalesce(max(linea),0)+1 into v_linea from wh.guia_detalle where id_guia=v_ging;
  insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
  values (v_ging,v_linea,v_codder,v_unidades,v_unidades,0,case when v_fvenc is not null then 'LOTE'||v_idenv else '' end,'Envasado','','ENVDET_I'||v_idenv,case when v_fvenc is not null then v_fvenc::date else null end);
  update wh.stock set cantidad_disponible = cantidad_disponible + v_unidades, ultima_actualizacion=now()
   where id_stock=(select id_stock from wh.stock where cod_producto=v_codder order by id_stock limit 1)
   returning cantidad_disponible into v_despues;
  if found then v_antes := v_despues - v_unidades;
  else v_antes:=0; v_despues:=v_unidades;
    insert into wh.stock(id_stock,cod_producto,cantidad_disponible,ultima_actualizacion) values('STKIE'||v_idenv,v_codder,v_despues,now());
  end if;
  insert into wh.stock_movimientos(id_mov,fecha,cod_producto,delta,stock_antes,stock_despues,tipo_operacion,origen,usuario)
  values('MOVIE'||v_idenv,now(),v_codder,v_unidades,v_antes,v_despues,'ENVASADO_INGRESO',v_idenv,v_usuario) on conflict(id_mov) do nothing;
  -- lote del derivado producido
  if v_fvenc is not null then
    insert into wh.lotes_vencimiento (id_lote,cod_producto,fecha_vencimiento,cantidad_inicial,cantidad_actual,id_guia,estado,fecha_creacion)
    values ('LOTE'||v_idenv,v_codder,v_fvenc::date,v_unidades,v_unidades,v_ging,'ACTIVO',now()) on conflict (id_lote) do nothing;
  end if;

  -- ── ENVASADO ─────────────────────────────────────────────────────
  insert into wh.envasados (id_envasado,cod_producto_base,cantidad_base,unidad_base,cod_producto_envasado,
    unidades_esperadas,unidades_producidas,merma_real,eficiencia_pct,fecha,usuario,estado,id_guia_salida,id_guia_ingreso,observacion)
  values (v_idenv,v_codbase,v_cantbase,v_unidadbase,v_codder,v_unidades,v_unidades,0,100,now(),v_usuario,'COMPLETADO',v_gsal,v_ging,'');

  return jsonb_build_object('ok',true,'dedup',false,'id_envasado',v_idenv,'id_guia_salida',v_gsal,'id_guia_ingreso',v_ging,
    'cantidad_base',v_cantbase,'unidades',v_unidades);
end;
$fn$;

revoke all on function wh.registrar_envasado(jsonb) from public;
grant execute on function wh.registrar_envasado(jsonb) to service_role, authenticated;
