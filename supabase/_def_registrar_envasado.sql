CREATE OR REPLACE FUNCTION wh.registrar_envasado(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idenv   text := nullif(btrim(coalesce(p->>'id_envasado','')), '');
  v_codbase text := nullif(btrim(coalesce(p->>'cod_producto_base','')), '');
  v_codder  text := nullif(btrim(coalesce(p->>'cod_producto_envasado','')), '');
  v_cantbase numeric := wh._num(p->>'cantidad_base');
  v_unidades numeric := wh._num(p->>'unidades_producidas');
  v_unidadbase text := coalesce(p->>'unidad_base','');
  v_fvenc   text := nullif(btrim(coalesce(p->>'fecha_vencimiento','')), '');
  v_usuario text := btrim(regexp_replace(coalesce(p->>'usuario','sistema'), '[[:space:]]+', ' ', 'g'));  -- [586] normaliza (trim+colapsa espacios; preserva mayúsculas)
  -- [418] 🤝 colaborador (nombre completo, mismo formato que usuario). '' = normal.
  -- Si el creador "colabora consigo mismo" (mismo nombre normalizado) → se ignora.
  v_colab   text := btrim(coalesce(p->>'colaborador',''));
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_gsal text; v_ging text; v_linea int;
  v_antes numeric; v_despues numeric;
begin
  if coalesce((select valor from mos.config where clave='WH_REGISTRAR_ENVASADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REGISTRAR_ENVASADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [586] No permitir el "operador fantasma": WH_CONFIG.usuario='operador' cuando se entra sin login
  -- personal → el envasado quedaba a un genérico (no paga a nadie, se ve aparte en MOS). Exigir nombre real.
  if v_usuario = '' or mos._norm_nom(v_usuario) = 'operador' then
    return jsonb_build_object('ok',false,'error','OPERADOR_REQUERIDO','detalle','Inicia sesión con tu nombre antes de envasar.');
  end if;
  if v_idenv is null or v_codbase is null or v_codder is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_unidades <= 0 or v_cantbase < 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_fvenc is not null then v_fvenc := left(v_fvenc,10); end if;
  if v_colab <> '' and mos._norm_nom(v_colab) = mos._norm_nom(v_usuario) then v_colab := ''; end if;
  -- [418 · review MED5/MED6] El colaborador debe resolver a EXACTAMENTE UN personal
  -- ACTIVO envasador/almacenero. Sin esto: un typo → nadie cobra la mitad (pérdida
  -- silenciosa) y un HOMÓNIMO → dos personas cobran la mitad (el negocio paga 1.5×).
  -- El recompute matchea por nombre normalizado; acá cerramos la puerta en el origen.
  if v_colab <> '' then
    declare v_ncolab int; v_colab_id text; v_colab_rol text; v_colab_nom text;
    begin
      -- [dueno 2026-07-14] incluir ADMIN/MASTER como colaboradores validos (ademas de ENVASADOR/ALMACENERO).
      select count(*) into v_ncolab
        from mos.personal
       where coalesce(estado,false) = true
         and upper(coalesce(rol,'')) in ('ENVASADOR','ALMACENERO','MASTER','ADMIN','ADMINISTRADOR')
         and mos._norm_nom(btrim(nombre||' '||coalesce(apellido,''))) = mos._norm_nom(v_colab);
      if v_ncolab = 0 then return jsonb_build_object('ok',false,'error','COLABORADOR_NO_ENCONTRADO','colaborador',v_colab); end if;
      if v_ncolab > 1 then return jsonb_build_object('ok',false,'error','COLABORADOR_AMBIGUO','colaborador',v_colab); end if;
      -- [dueno] asegurar la fila de liquidacion del colaborador para que cobre su mitad. ADMIN/MASTER no la
      -- tienen (no hacen jornal) -> se crea con base=0; ENV/ALM ya la tienen (ingreso) -> ON CONFLICT no-op.
      select id_personal, upper(coalesce(rol,'')), btrim(nombre||' '||coalesce(apellido,''))
        into v_colab_id, v_colab_rol, v_colab_nom
        from mos.personal
       where coalesce(estado,false) = true
         and upper(coalesce(rol,'')) in ('ENVASADOR','ALMACENERO','MASTER','ADMIN','ADMINISTRADOR')
         and mos._norm_nom(btrim(nombre||' '||coalesce(apellido,''))) = mos._norm_nom(v_colab)
       limit 1;
      insert into mos.liquidaciones_dia (id_dia, fecha, id_personal, nombre, rol, app_origen, virtual,
        monto_base, pago_envasado, bono_meta, bonificacion, sancion, bonificacion_motivo, sancion_motivo,
        total_dia, auditado, evaluaciones_count, score_final, tarifa_envasado, presente, estado, id_pago,
        es_temporal, zona, device_id, hora_ingreso, ultima_conexion, estado_sesion, minutos_activos,
        reconexiones, meta_auditorias, ts_creado, ts_actualizado)
      values (mos._liqdia_key(v_colab_id, to_char(v_hoy,'YYYY-MM-DD')), v_hoy, v_colab_id, v_colab_nom, v_colab_rol,
        'warehouseMos', false, 0, 0, 0, 0, 0, '', '', 0, false, 0, 0,
        coalesce(mos._numn((select valor from mos.config where clave='tarifa_envasado' limit 1)),0.10),
        true, 'PENDIENTE', '', false, '', '', now(), now(), 'ACTIVA', 0, 0, 0, now(), now())
      on conflict (id_dia) do nothing;
    end;
  end if;

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
  -- [418 · hallazgo del ESTRÉS, bug pre-existente del 60] max(linea)+1 sin lock era una
  -- CARRERA: dos envasados registrándose el mismo segundo leían el mismo max → misma
  -- línea → violación de guia_detalle_pkey → uno de los dos FALLABA. Advisory lock por
  -- guía (tx-scoped) serializa la asignación de línea; se libera solo al commit.
  perform pg_advisory_xact_lock(hashtext('wh.guia_detalle:'||v_gsal));
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
  -- [418 · estrés] misma serialización para la guía de INGRESO del día
  perform pg_advisory_xact_lock(hashtext('wh.guia_detalle:'||v_ging));
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
    unidades_esperadas,unidades_producidas,merma_real,eficiencia_pct,fecha,usuario,estado,id_guia_salida,id_guia_ingreso,observacion,colaborador)
  values (v_idenv,v_codbase,v_cantbase,v_unidadbase,v_codder,v_unidades,v_unidades,0,100,now(),v_usuario,'COMPLETADO',v_gsal,v_ging,'',v_colab);

  return jsonb_build_object('ok',true,'dedup',false,'id_envasado',v_idenv,'id_guia_salida',v_gsal,'id_guia_ingreso',v_ging,
    'cantidad_base',v_cantbase,'unidades',v_unidades,'colaborador',v_colab);
end;
$function$
