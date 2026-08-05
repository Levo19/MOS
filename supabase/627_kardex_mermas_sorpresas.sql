
create or replace function wh._kardex(p_cod text, p_delta numeric, p_tipo text, p_origen text, p_usuario text)
returns void language plpgsql security definer set search_path to '' as $$
declare v_desp numeric; v_id text;
begin
  if coalesce(btrim(p_cod),'') = '' or coalesce(p_delta,0) = 0 then return; end if;
  select cantidad_disponible into v_desp from wh.stock
   where upper(cod_producto) = upper(btrim(p_cod)) order by id_stock limit 1;
  if not found then return; end if;
  v_id := 'MOV-' || upper(btrim(p_tipo)) || '-' || md5(p_cod || coalesce(p_origen,'') || p_delta::text || clock_timestamp()::text);
  insert into wh.stock_movimientos (id_mov, fecha, cod_producto, delta, stock_antes, stock_despues, tipo_operacion, origen, usuario)
  values (v_id, now(), btrim(p_cod), p_delta, round(v_desp - p_delta, 3), v_desp,
          upper(btrim(p_tipo)), nullif(btrim(coalesce(p_origen,'')),''), nullif(btrim(coalesce(p_usuario,'')),''))
  on conflict (id_mov) do nothing;
exception when others then null;  -- el kardex jamás puede tumbar la operación
end; $$;

CREATE OR REPLACE FUNCTION wh.registrar_sorpresa(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_orig   numeric;
  v_id     text := nullif(btrim(coalesce(p->>'id_sorpresa','')), '');
  v_guia   text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_cod    text := nullif(btrim(coalesce(p->>'cod_producto','')), '');
  v_delta  numeric := wh._num(p->>'delta');
  v_clave  text := nullif(btrim(coalesce(p->>'clave_admin','')), '');
  v_auth   jsonb;
  v_g      record;
  v_d      record;
  v_ya     record;
  v_nueva  numeric;
  v_costo  numeric;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_guia is null or v_cod is null or v_delta = 0 then
    return jsonb_build_object('ok',false,'error','PARAMS_INVALIDOS'); end if;

  select * into v_ya from wh.sorpresas where id_sorpresa = v_id;
  if found then return jsonb_build_object('ok',true,'dedup',true,'estado',v_ya.estado); end if;

  v_auth := mos._validar_clave_admin_core(v_clave, 'SORPRESA', v_guia,
              coalesce(p->>'app','WH'), coalesce(p->>'device',''),
              'sorpresa ' || v_cod || ' Δ' || v_delta);
  if coalesce(v_auth->>'autorizado','false') <> 'true' then
    return jsonb_build_object('ok',false,'error','CLAVE_INVALIDA',
             'detalle', coalesce(v_auth->>'error','clave rechazada')); end if;

  select * into v_g from wh.guias where id_guia = v_guia;
  if not found or upper(coalesce(v_g.tipo,'')) <> 'SALIDA_ZONA' then
    return jsonb_build_object('ok',false,'error','GUIA_INVALIDA'); end if;
  -- [Dueño 2026-07-19] solo guías DE HOY: la sorpresa se arma en la ventana del despacho
  if (v_g.fecha at time zone 'America/Lima')::date <> (now() at time zone 'America/Lima')::date then
    return jsonb_build_object('ok',false,'error','GUIA_NO_ES_DE_HOY','detalle','solo despachos del día'); end if;
  if exists (select 1 from me.zona_traslado_verificacion where id_guia = 'WH:' || v_guia) then
    return jsonb_build_object('ok',false,'error','SORPRESA_TARDE','detalle','la zona ya cerró la recepción'); end if;

  select * into v_d from wh.guia_detalle
   where id_guia = v_guia and upper(cod_producto) = upper(v_cod)
   order by linea limit 1;
  if not found then
    return jsonb_build_object('ok',false,'error','PRODUCTO_NO_EN_GUIA'); end if;

  v_orig  := coalesce(v_d.cant_recibida,0);
  v_nueva := v_orig + v_delta;
  if v_nueva < 0 then
    return jsonb_build_object('ok',false,'error','DELTA_EXCEDE','detalle','la línea tiene ' || v_orig); end if;

  update wh.guia_detalle set cant_recibida = v_nueva
   where id_guia = v_guia and linea = v_d.linea;

  if upper(coalesce(v_g.estado,'')) = 'CERRADA' then
    update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_delta,
                        ultima_actualizacion = now()
     where upper(cod_producto) = upper(v_cod);
    -- [627] dejar rastro en el kardex (antes esto movía stock sin registrar el movimiento)
    perform wh._kardex(v_cod, -v_delta, 'SORPRESA', 'SORPRESA', 'sistema');
  end if;

  begin
    select coalesce(nullif(precio_unitario,0),0) into v_costo
      from wh.guia_detalle where id_guia = v_guia and linea = v_d.linea;
  exception when others then v_costo := 0; end;

  insert into wh.sorpresas(id_sorpresa,id_guia,id_zona,cod_producto,descripcion,delta,
                           cant_original,cant_corregida,admin_nombre,costo_unitario)
  values (v_id, v_guia, v_g.id_zona, v_cod, null, v_delta,
          v_orig, v_nueva,
          coalesce(v_auth->>'nombre', nullif(btrim(coalesce(p->>'admin','')),''), 'admin'),
          v_costo);

  return jsonb_build_object('ok',true,'id_sorpresa',v_id,
           'cant_original', v_orig, 'cant_corregida', v_nueva);
end; $function$


CREATE OR REPLACE FUNCTION wh.merma_alta_manual(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id   text := nullif(btrim(coalesce(p->>'id_merma','')), '');
  v_cod  text := nullif(btrim(coalesce(p->>'cod_producto','')), '');
  v_cant numeric := wh._num(p->>'cantidad');
  v_foto text := coalesce(p->>'foto','');
  v_usr  text := coalesce(p->>'usuario','');
  v_mot  text := coalesce(p->>'motivo','hallado dañado en almacén');
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_cant <= 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_foto = '' then return jsonb_build_object('ok',false,'error','FOTO_OBLIGATORIA'); end if;
  if exists (select 1 from wh.mermas where id_merma = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_merma',v_id); end if;

  update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_cant,
                      ultima_actualizacion = now()
   where upper(cod_producto) = upper(v_cod);
    -- [627] dejar rastro en el kardex (antes esto movía stock sin registrar el movimiento)
    perform wh._kardex(v_cod, -v_cant, 'MERMA_ALTA', v_id, 'sistema');

  insert into wh.mermas (id_merma, fecha_ingreso, origen, cod_producto, id_lote, cantidad_original,
    cantidad_pendiente, motivo, usuario, id_guia, estado, responsable, cantidad_reparada,
    cantidad_desechada, foto, culpa, costo_unitario, stock_descontado)
  values (v_id, now(), 'ALMACEN', v_cod, '', v_cant, v_cant, v_mot, v_usr, '', 'EN_PROCESO',
    'ALMACEN', 0, 0, v_foto, 'ALMACEN', wh._num(p->>'costo'), true);

  return jsonb_build_object('ok',true,'id_merma',v_id);
end; $function$


CREATE OR REPLACE FUNCTION wh.procesar_merma(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id    text := nullif(btrim(coalesce(p->>'id_merma','')), '');
  v_lid   text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_acc   text := upper(coalesce(p->>'accion',''));
  v_cant  numeric := wh._num(p->>'cantidad');
  v_cdst  text := nullif(btrim(coalesce(p->>'cod_destino','')), '');
  v_qdst  numeric := wh._num(p->>'cantidad_destino');
  v_usr   text := coalesce(p->>'usuario','');
  v_obs   text := coalesce(p->>'observacion','');
  m       record;
  v_gt    text; v_gs text; v_linea int;
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_dow   int  := extract(dow from v_hoy)::int;
  v_lunes date; v_domingo date;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_acc not in ('RECUPERAR','ELIMINAR') then
    return jsonb_build_object('ok',false,'error','PARAMS_INVALIDOS'); end if;
  if v_lid is not null and not wh._dedup_nuevo(v_lid, 'procesar_merma') then
    return jsonb_build_object('ok',true,'dedup',true); end if;

  select * into m from wh.mermas where id_merma = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','MERMA_NO_ENCONTRADA'); end if;
  if coalesce(m.cantidad_pendiente,0) <= 0 then
    return jsonb_build_object('ok',true,'yaResuelta',true,'id_merma',v_id); end if;

  if v_acc = 'RECUPERAR' then
    if v_cant <= 0 or v_cant > m.cantidad_pendiente then
      return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA','pendiente',m.cantidad_pendiente); end if;

    if v_cdst is not null then
      -- ── TRANSFORMACIÓN: guía documental CERRADA (no corre cerrar_guia → no doble stock) ──
      if v_qdst <= 0 then v_qdst := v_cant; end if;  -- default: misma cantidad (editable)
      v_gt := 'GTRANS_' || coalesce(v_lid, v_id || '_' || to_char(now(),'HH24MISS'));
      insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
      values (v_gt,'TRANSFORMACION',now(),coalesce(nullif(v_usr,''),'sistema'),
              'Transformación de merma '||v_id||': '||m.cod_producto||' '||v_cant||' → '||v_cdst||' '||v_qdst,
              0,'CERRADA','','','','','')
      on conflict (id_guia) do nothing;
      insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
      values (v_gt,1,m.cod_producto,v_cant,v_cant,0,'','TRANSFORMACION_SALIDA · merma '||v_id,'','TDET1_'||v_gt,null),
             (v_gt,2,v_cdst,v_qdst,v_qdst,0,'','TRANSFORMACION_INGRESO · merma '||v_id,'','TDET2_'||v_gt,null)
      on conflict do nothing;
      -- stock destino entra SIEMPRE; origen solo sale si la fila es VIEJA (aún contaba en stock)
      update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) + v_qdst,
                          ultima_actualizacion = now()
       where upper(cod_producto) = upper(v_cdst);
    -- [627] dejar rastro en el kardex (antes esto movía stock sin registrar el movimiento)
    perform wh._kardex(v_cdst, v_qdst, 'MERMA_TRANSFORMA_INGRESO', v_id, 'sistema');
      if not coalesce(m.stock_descontado,false) then
        update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_cant,
                            ultima_actualizacion = now()
         where upper(cod_producto) = upper(m.cod_producto);
    -- [627] dejar rastro en el kardex (antes esto movía stock sin registrar el movimiento)
    perform wh._kardex(m.cod_producto, -v_cant, 'MERMA_DESECHO', v_id, 'sistema');
      end if;
    else
      -- recuperación simple: vuelve al stock SOLO si salió al entrar (v2)
      if coalesce(m.stock_descontado,false) then
        update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) + v_cant,
                            ultima_actualizacion = now()
         where upper(cod_producto) = upper(m.cod_producto);
    -- [627] dejar rastro en el kardex (antes esto movía stock sin registrar el movimiento)
    perform wh._kardex(m.cod_producto, v_cant, 'MERMA_REPARADA', v_id, 'sistema');
      end if;
    end if;

    update wh.mermas set
      cantidad_reparada   = coalesce(cantidad_reparada,0) + v_cant,
      cantidad_pendiente  = cantidad_pendiente - v_cant,
      estado              = case when cantidad_pendiente - v_cant <= 0 then 'RESUELTA' else 'EN_PROCESO' end,
      fecha_resolucion    = case when cantidad_pendiente - v_cant <= 0 then now() else fecha_resolucion end,
      observacion_resolucion = case when v_obs <> '' then v_obs else observacion_resolucion end,
      id_guia_transformacion = coalesce(v_gt, id_guia_transformacion)
    where id_merma = v_id;

    return jsonb_build_object('ok',true,'id_merma',v_id,'recuperado',v_cant,
      'transformada', v_cdst is not null, 'id_guia_transformacion', coalesce(v_gt,''),
      'pendiente', greatest(m.cantidad_pendiente - v_cant, 0));
  end if;

  -- ── ELIMINAR el resto pendiente ──
  if coalesce(m.stock_descontado,false) then
    -- v2: documental CERRADA (el stock ya salió al entrar a la cesta)
    v_gs := 'GSMERMA_' || coalesce(v_lid, v_id || '_' || to_char(now(),'HH24MISS'));
    insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
    values (v_gs,'SALIDA_MERMA',now(),coalesce(nullif(v_usr,''),'sistema'),
            'Eliminación de merma '||v_id||' ('||m.cod_producto||' '||m.cantidad_pendiente||')',
            0,'CERRADA','','','','','')
    on conflict (id_guia) do nothing;
    insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
    values (v_gs,1,m.cod_producto,m.cantidad_pendiente,m.cantidad_pendiente,0,'','Merma '||v_id||' eliminada','','ELDET_'||v_gs,null)
    on conflict do nothing;
  else
    -- fila vieja: patrón 66 — guía semanal ABIERTA (descuenta stock al cerrar)
    v_lunes   := v_hoy - (case when v_dow = 0 then 6 else v_dow - 1 end);
    v_domingo := v_lunes + 7;
    select id_guia into v_gs from wh.guias
     where tipo = 'SALIDA_MERMA' and upper(coalesce(estado,'')) = 'ABIERTA'
       and (fecha at time zone 'America/Lima')::date >= v_lunes
       and (fecha at time zone 'America/Lima')::date <  v_domingo
     order by fecha asc limit 1;
    if v_gs is null then
      v_gs := 'GMERMA' || to_char(v_lunes,'YYYYMMDD');
      insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
      values (v_gs,'SALIDA_MERMA',now(),coalesce(nullif(v_usr,''),'sistema'),
              'Mermas semana '||to_char(v_lunes,'YYYY-MM-DD'),0,'ABIERTA','','','','','')
      on conflict (id_guia) do nothing;
      -- [FIX 100x S9] la determinista de la semana puede EXISTIR pero CERRADA (heredado del 66):
      -- agregarle líneas a una cerrada = unidades que jamás se descuentan + documento mutado.
      -- Si no quedó ABIERTA, crear una NUEVA con sufijo único (sigue agrupando dentro de la semana).
      if (select upper(coalesce(estado,'')) from wh.guias where id_guia = v_gs) <> 'ABIERTA' then
        v_gs := 'GMERMA' || to_char(v_lunes,'YYYYMMDD') || '_' || coalesce(v_lid, v_id);
        insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
        values (v_gs,'SALIDA_MERMA',now(),coalesce(nullif(v_usr,''),'sistema'),
                'Mermas semana '||to_char(v_lunes,'YYYY-MM-DD')||' (reapertura)',0,'ABIERTA','','','','','')
        on conflict (id_guia) do nothing;
      end if;
    end if;
    perform 1 from wh.guias where id_guia = v_gs for update;
    select linea into v_linea from wh.guia_detalle
     where id_guia = v_gs and upper(coalesce(cod_producto,'')) = upper(m.cod_producto)
       and upper(coalesce(observacion,'')) <> 'ANULADO' order by linea limit 1;
    if found then
      update wh.guia_detalle set cant_recibida = coalesce(cant_recibida,0) + m.cantidad_pendiente,
                                 cant_esperada = coalesce(cant_esperada,0) + m.cantidad_pendiente
       where id_guia = v_gs and linea = v_linea;
    else
      select coalesce(max(linea),0)+1 into v_linea from wh.guia_detalle where id_guia = v_gs;
      insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
      values (v_gs,v_linea,m.cod_producto,m.cantidad_pendiente,m.cantidad_pendiente,0,'',
              'Merma '||v_id,'','MRMDET_'||v_id,null);
    end if;
  end if;

  update wh.mermas set
    cantidad_desechada  = coalesce(cantidad_desechada,0) + cantidad_pendiente,
    cantidad_pendiente  = 0,
    estado              = case when coalesce(cantidad_reparada,0) > 0 then 'RESUELTA' else 'DESECHADA' end,
    fecha_resolucion    = now(),
    observacion_resolucion = case when v_obs <> '' then v_obs else observacion_resolucion end,
    id_guia_salida      = coalesce(v_gs, id_guia_salida)
  where id_merma = v_id;

  return jsonb_build_object('ok',true,'id_merma',v_id,'eliminado',m.cantidad_pendiente,'id_guia_salida',v_gs);
end; $function$


CREATE OR REPLACE FUNCTION wh.mermas_eliminar_batch(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ids   text[] := (select coalesce(array_agg(x), '{}') from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) x);
  v_lid   text := nullif(btrim(coalesce(p->>'local_id','')), '');
  v_usr   text := coalesce(p->>'usuario','');
  v_obs   text := coalesce(p->>'observacion','');
  v_guia  text;
  v_linea int := 0;
  v_n     int := 0;
  v_skip  int := 0;
  m       record;
  v_id    text;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if array_length(v_ids,1) is null then
    return jsonb_build_object('ok',false,'error','SIN_IDS'); end if;
  if v_lid is null then
    return jsonb_build_object('ok',false,'error','FALTA_LOCAL_ID'); end if;
  if not wh._dedup_nuevo(v_lid, 'mermas_eliminar_batch') then
    return jsonb_build_object('ok',true,'dedup',true); end if;

  v_guia := 'GSLOTE_' || v_lid;
  insert into wh.guias (id_guia,tipo,fecha,usuario,comentario,monto_total,estado,id_proveedor,id_zona,numero_documento,id_preingreso,foto)
  values (v_guia,'SALIDA_MERMA',now(),coalesce(nullif(v_usr,''),'sistema'),
          'Eliminación en LOTE de ' || array_length(v_ids,1) || ' merma(s)' ||
          case when v_obs <> '' then ' · ' || v_obs else '' end,
          0,'CERRADA','','','','','')
  on conflict (id_guia) do nothing;

  foreach v_id in array v_ids loop
    select * into m from wh.mermas where id_merma = v_id limit 1 for update;
    if not found or coalesce(m.cantidad_pendiente,0) <= 0 then
      v_skip := v_skip + 1; continue; end if;

    -- fila VIEJA: sus unidades seguían contadas en el stock → salen ahora (atómico)
    if not coalesce(m.stock_descontado,false) then
      update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - m.cantidad_pendiente,
                          ultima_actualizacion = now()
       where upper(cod_producto) = upper(m.cod_producto);
    -- [627] dejar rastro en el kardex (antes esto movía stock sin registrar el movimiento)
    perform wh._kardex(m.cod_producto, -m.cantidad_pendiente, 'MERMA_ELIMINADA', m.id_merma, 'sistema');
    end if;

    v_linea := v_linea + 1;
    insert into wh.guia_detalle (id_guia,linea,cod_producto,cant_esperada,cant_recibida,precio_unitario,id_lote,observacion,id_producto_nuevo,id_detalle,fecha_vencimiento)
    values (v_guia, v_linea, m.cod_producto, m.cantidad_pendiente, m.cantidad_pendiente,
            coalesce(m.costo_unitario,0), coalesce(m.id_lote,''),
            'Merma ' || m.id_merma || case when coalesce(m.culpa,'') <> '' then ' · culpa ' || m.culpa else '' end,
            '', 'LOTDET_' || m.id_merma, null)
    on conflict do nothing;

    update wh.mermas set
      cantidad_desechada  = coalesce(cantidad_desechada,0) + cantidad_pendiente,
      cantidad_pendiente  = 0,
      estado              = case when coalesce(cantidad_reparada,0) > 0 then 'RESUELTA' else 'DESECHADA' end,
      fecha_resolucion    = now(),
      observacion_resolucion = case when v_obs <> '' then v_obs else observacion_resolucion end,
      id_guia_salida      = v_guia
    where id_merma = v_id;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    -- nada eliminable: no dejar la guía vacía huérfana
    delete from wh.guias where id_guia = v_guia
      and not exists (select 1 from wh.guia_detalle d where d.id_guia = v_guia);
    return jsonb_build_object('ok',true,'eliminadas',0,'omitidas',v_skip,'id_guia_salida','');
  end if;

  return jsonb_build_object('ok',true,'id_guia_salida',v_guia,'eliminadas',v_n,'omitidas',v_skip);
end; $function$
