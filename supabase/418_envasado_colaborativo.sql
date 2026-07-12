-- ════════════════════════════════════════════════════════════════════════════
-- 418 · ENVASADO 🤝 COLABORATIVO (diseño DISENO_envasado_colab_y_credito_personal.md)
-- ════════════════════════════════════════════════════════════════════════════
-- Regla del dueño (2026-07-11): un registro de envasado puede marcarse
-- COLABORATIVO con UN compañero → el pago (unidades × tarifa_envasado) se
-- divide MITAD Y MITAD. El registro es EXACTAMENTE el mismo (guías SALIDA/
-- INGRESO_ENVASADO, stock, kardex, lotes, adhesivos: CERO cambios) — solo se
-- agrega "con quién". El colaborador NO confirma (el creador lo elige, queda
-- auditado en la fila).
--
-- DINERO (money-safe, el negocio paga LO MISMO):
--   · normal:        creador  = round(unid × tarifa, 2)
--   · colaborativo:  invitado = round(unid × tarifa / 2, 2)
--                    creador  = round(unid × tarifa, 2) − invitado
--     (por REGISTRO → la suma de ambos SIEMPRE cuadra con el total; el creador
--      absorbe el céntimo impar si lo hay)
--   · liquidaciones_dia.pago_envasado sigue siendo el TOTAL de la persona
--     (propios + sus mitades) → total_dia y TODO el downstream intactos.
--     Detalle informativo en columnas nuevas: envasados_colab (unidades en
--     registros 🤝 donde participó) + pago_envasado_colab (S/ de esas mitades).
--     productos_envasados conserva su significado actual (unidades PROPIAS).
--
-- Piezas (todas verbatim de la versión viva + cambio quirúrgico):
--   1. wh.envasados + colaborador text
--   2. mos.liquidaciones_dia + envasados_colab + pago_envasado_colab
--   3. wh.registrar_envasado: acepta colaborador (ignora si = usuario)
--   4. mos.recomputar_dia: fórmula con mitades por registro
--   5. mos._tg_recompute_envasado: recomputa a AMBOS (y al colaborador viejo
--      si un UPDATE lo cambió) — sin esto el invitado no cobraría hasta otro
--      evento suyo del día.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) columna en el registro ─────────────────────────────────────────────────
alter table wh.envasados add column if not exists colaborador text not null default '';

-- ── 2) columnas informativas en la liquidación ───────────────────────────────
alter table mos.liquidaciones_dia add column if not exists envasados_colab     numeric not null default 0;
alter table mos.liquidaciones_dia add column if not exists pago_envasado_colab numeric not null default 0;

-- ── 3) wh.registrar_envasado — + colaborador ─────────────────────────────────
create or replace function wh.registrar_envasado(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_idenv   text := nullif(btrim(coalesce(p->>'id_envasado','')), '');
  v_codbase text := nullif(btrim(coalesce(p->>'cod_producto_base','')), '');
  v_codder  text := nullif(btrim(coalesce(p->>'cod_producto_envasado','')), '');
  v_cantbase numeric := wh._num(p->>'cantidad_base');
  v_unidades numeric := wh._num(p->>'unidades_producidas');
  v_unidadbase text := coalesce(p->>'unidad_base','');
  v_fvenc   text := nullif(btrim(coalesce(p->>'fecha_vencimiento','')), '');
  v_usuario text := coalesce(p->>'usuario','sistema');
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
  if v_idenv is null or v_codbase is null or v_codder is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_unidades <= 0 or v_cantbase < 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_fvenc is not null then v_fvenc := left(v_fvenc,10); end if;
  if v_colab <> '' and mos._norm_nom(v_colab) = mos._norm_nom(v_usuario) then v_colab := ''; end if;

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
    unidades_esperadas,unidades_producidas,merma_real,eficiencia_pct,fecha,usuario,estado,id_guia_salida,id_guia_ingreso,observacion,colaborador)
  values (v_idenv,v_codbase,v_cantbase,v_unidadbase,v_codder,v_unidades,v_unidades,0,100,now(),v_usuario,'COMPLETADO',v_gsal,v_ging,'',v_colab);

  return jsonb_build_object('ok',true,'dedup',false,'id_envasado',v_idenv,'id_guia_salida',v_gsal,'id_guia_ingreso',v_ging,
    'cantidad_base',v_cantbase,'unidades',v_unidades,'colaborador',v_colab);
end;
$function$;

revoke all on function wh.registrar_envasado(jsonb) from public;
grant execute on function wh.registrar_envasado(jsonb) to authenticated, service_role;

-- ── 4) mos.recomputar_dia — mitades por registro ──────────────────────────────
create or replace function mos.recomputar_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_id_dia  text;
  v_dia     date;
  r         mos.liquidaciones_dia%rowtype;
  v_rol     text;
  v_nomfull text;
  v_zona    text;
  v_fijo    numeric;
  v_tarifa  numeric;
  v_prod    numeric := 0;
  v_pagoenv numeric := 0;
  -- [418] 🤝 colaborativo
  v_unid_cr numeric := 0;  v_pago_cr numeric := 0;   -- registros donde SOY creador con colaborador
  v_unid_in numeric := 0;  v_pago_in numeric := 0;   -- registros donde SOY el colaborador invitado
  v_envcolab  numeric := 0;
  v_pagocolab numeric := 0;
  v_vcob    numeric := 0;
  v_vzona   numeric := 0;
  v_meta    numeric := 0;
  v_pct     numeric := 0;
  v_pool    numeric := 0;
  v_bono    numeric := 0;
  v_prog    numeric := 0;
  v_aud     numeric := 0;
  v_metaaud numeric;
  v_total   numeric;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ACCESOS_DIRECTO_OFF');
  end if;
  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  begin v_dia := v_fecha_s::date; exception when others then v_dia := (now() at time zone 'America/Lima')::date; end;

  select * into r from mos.liquidaciones_dia where id_dia = v_id_dia for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_EXISTE','skipped',true); end if;

  -- [500x C1] NO recomputar el dinero de una fila PAGADA o VETADA: el monto está SELLADO
  -- (pagado o retenido). Sin esto, una venta tardía disparaba el trigger → reescribía
  -- total_dia/bono_meta de una fila ya pagada/vetada (el número se movía bajo el sello).
  if upper(coalesce(r.estado,'PENDIENTE')) in ('PAGADA','VETADA') then
    return jsonb_build_object('ok',true,'skipped','ESTADO_'||upper(coalesce(r.estado,'')));
  end if;

  v_rol := upper(coalesce(r.rol,''));
  if v_rol in ('MASTER','ADMIN','ADMINISTRADOR') then
    return jsonb_build_object('ok',true,'skipped','ROL_BLOQUEADO');
  end if;

  v_zona    := coalesce(r.zona,'');
  v_fijo    := mos._fijo_personal(v_idp, v_rol);
  v_tarifa  := coalesce(mos._numn((select valor from mos.config where clave='tarifa_envasado' limit 1)),0.10);
  v_metaaud := coalesce(mos._numn((select valor from mos.config where clave='evalMetaAuditorias' limit 1)),0);
  -- nombre canónico: persona real (nombre+apellido) o el nombre de la fila (temporal ME)
  v_nomfull := coalesce((select btrim(nombre||' '||coalesce(apellido,'')) from mos.personal where id_personal = v_idp limit 1),
                        r.nombre);

  if v_rol in ('ENVASADOR','ALMACENERO') then
    -- pago por envasado PROPIO: unidades producidas (no anuladas, SIN colaborador) × tarifa
    select coalesce(sum(unidades_producidas),0) into v_prod
      from wh.envasados
     where (fecha at time zone 'America/Lima')::date = v_dia
       and upper(coalesce(estado,'')) <> 'ANULADO'
       and mos._norm_nom(usuario) = mos._norm_nom(v_nomfull)
       and btrim(coalesce(colaborador,'')) = '';
    -- [418] 🤝 como CREADOR: cobro total − mitad_redondeada del invitado (por registro,
    -- el creador absorbe el céntimo impar → la suma de ambos SIEMPRE = unid × tarifa)
    select coalesce(sum(round(unidades_producidas * v_tarifa, 2) - round(unidades_producidas * v_tarifa / 2, 2)),0),
           coalesce(sum(unidades_producidas),0)
      into v_pago_cr, v_unid_cr
      from wh.envasados
     where (fecha at time zone 'America/Lima')::date = v_dia
       and upper(coalesce(estado,'')) <> 'ANULADO'
       and mos._norm_nom(usuario) = mos._norm_nom(v_nomfull)
       and btrim(coalesce(colaborador,'')) <> '';
    -- [418] 🤝 como INVITADO: mitad redondeada por registro
    select coalesce(sum(round(unidades_producidas * v_tarifa / 2, 2)),0),
           coalesce(sum(unidades_producidas),0)
      into v_pago_in, v_unid_in
      from wh.envasados
     where (fecha at time zone 'America/Lima')::date = v_dia
       and upper(coalesce(estado,'')) <> 'ANULADO'
       and btrim(coalesce(colaborador,'')) <> ''
       and mos._norm_nom(colaborador) = mos._norm_nom(v_nomfull);
    v_envcolab  := coalesce(v_unid_cr,0) + coalesce(v_unid_in,0);
    v_pagocolab := round(coalesce(v_pago_cr,0) + coalesce(v_pago_in,0), 2);
    v_pagoenv := round(coalesce(v_prod,0) * v_tarifa, 2) + v_pagocolab;
    v_bono := 0;
    -- auditorías ejecutadas en almacén
    select count(*) into v_aud from wh.auditorias
     where (coalesce(fecha_ejecucion, fecha_asignacion) at time zone 'America/Lima')::date = v_dia
       and upper(coalesce(estado,'')) in ('EJECUTADA','COMPLETADA','OK')
       and mos._norm_nom(usuario) = mos._norm_nom(v_nomfull);

  elsif v_rol in ('CAJERO','VENDEDOR') then
    -- [ext · identidad NOMBRE|ZONA] La fila YA ES por zona (Sergio|ZONA-01 vs Sergio|ZONA-02)
    -- → se usa r.zona directo, cada fila cobra su zona. FALLBACK (filas viejas MEX:nombre sin
    -- zona o pulso vacío): derivar la zona dominante de me.ventas (con tiebreaker H1).
    v_zona := nullif(btrim(coalesce(r.zona,'')), '');
    if v_zona is null then
      select v.zona_id into v_zona
        from me.ventas v
       where (v.fecha at time zone 'America/Lima')::date = v_dia
         and mos._norm_nom(v.vendedor) = mos._norm_nom(v_nomfull)
         and v.forma_pago ~* '^(efectivo|virtual|mixto)'
         and coalesce(v.zona_id,'') <> ''
       group by v.zona_id order by sum(v.total) desc, v.zona_id asc limit 1;
    end if;
    v_zona := coalesce(v_zona, '');
    -- comisión 5% del excedente de zona, proporcional a lo cobrado por la persona
    v_vcob  := mos._venta_cobrada_persona(v_nomfull, v_zona, v_dia);
    v_vzona := mos._venta_cobrada_zona(v_zona, v_dia);
    v_meta  := mos._meta_zona(v_zona);
    v_pct   := mos._comision_pct(v_zona);
    v_pool  := round(greatest(0::numeric, v_vzona - v_meta) * v_pct / 100.0, 2);
    v_bono  := case when v_vzona > 0 then round(v_pool * (v_vcob / v_vzona), 2) else 0 end;
    v_prog  := case when v_meta > 0 then round(v_vcob / v_meta * 100, 1) else 0 end;
    v_pagoenv := 0; v_prod := 0;
    -- auditorías de ventas (ME) ejecutadas
    select count(*) into v_aud from me.auditorias
     where (fecha at time zone 'America/Lima')::date = v_dia
       and mos._norm_nom(vendedor) = mos._norm_nom(v_nomfull);
  else
    v_pagoenv := 0; v_bono := 0;
  end if;

  -- total preservando lo manual (bonificacion/sancion ya en la fila)
  v_total := mos._liqdia_total(v_fijo, v_pagoenv, v_bono, coalesce(r.bonificacion,0), coalesce(r.sancion,0));

  update mos.liquidaciones_dia set
      monto_base          = v_fijo,
      pago_envasado       = v_pagoenv,
      bono_meta           = v_bono,
      tarifa_envasado     = v_tarifa,
      productos_envasados = coalesce(v_prod,0),
      envasados_colab     = coalesce(v_envcolab,0),
      pago_envasado_colab = coalesce(v_pagocolab,0),
      venta_cobrada       = coalesce(v_vcob,0),
      venta_zona          = coalesce(v_vzona,0),
      meta_zona           = coalesce(v_meta,0),
      progreso_venta_pct  = coalesce(v_prog,0),
      auditorias_hechas   = coalesce(v_aud,0),
      meta_auditorias     = case when v_metaaud > 0 then v_metaaud else meta_auditorias end,
      cumplio_auditorias  = (coalesce(v_aud,0) >= case when v_metaaud>0 then v_metaaud else coalesce(meta_auditorias,0) end),
      -- persiste la zona derivada (cajero/vendedor); no blanquea una zona existente
      zona                = coalesce(nullif(btrim(coalesce(v_zona,'')), ''), zona),
      total_dia           = v_total,
      ts_actualizado      = now()
    where id_dia = v_id_dia;

  return jsonb_build_object('ok',true,'idDia',v_id_dia,'rol',v_rol,
    'montoBase',v_fijo,'pagoEnvasado',v_pagoenv,'bonoMeta',v_bono,
    'envasadosColab',v_envcolab,'pagoEnvasadoColab',v_pagocolab,
    'ventaCobrada',v_vcob,'ventaZona',v_vzona,'auditorias',v_aud,'totalDia',v_total);
end;
$function$;

revoke all on function mos.recomputar_dia(jsonb) from public;
grant execute on function mos.recomputar_dia(jsonb) to authenticated, service_role;

-- ── 5) trigger: recomputa a AMBOS participantes ───────────────────────────────
create or replace function mos._tg_recompute_envasado()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare r record := coalesce(NEW, OLD); v_dia date;
begin
  if coalesce((select valor from mos.config where clave='MOS_ACCESOS_DIRECTO' limit 1),'0') = '1' then
    v_dia := (r.fecha at time zone 'America/Lima')::date;
    begin
      perform mos._recompute_envasado_usuario(r.usuario, v_dia);
    exception when others then null;  -- nunca romper el registro de envasado
    end;
    -- [418] 🤝 el colaborador también cobra/deja de cobrar con este registro
    begin
      if btrim(coalesce(r.colaborador,'')) <> '' then
        perform mos._recompute_envasado_usuario(r.colaborador, v_dia);
      end if;
    exception when others then null;
    end;
    -- [418] UPDATE que CAMBIÓ el colaborador → el viejo pierde su mitad: recomputarlo
    begin
      if TG_OP = 'UPDATE' and btrim(coalesce(OLD.colaborador,'')) <> ''
         and mos._norm_nom(OLD.colaborador) is distinct from mos._norm_nom(coalesce(NEW.colaborador,'')) then
        perform mos._recompute_envasado_usuario(OLD.colaborador, (OLD.fecha at time zone 'America/Lima')::date);
      end if;
    exception when others then null;
    end;
  end if;
  return null;
end;
$function$;

notify pgrst, 'reload schema';
