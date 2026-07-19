-- 520_fix_guia_semanal_cerrada.sql — FIX revisión 100x (S9): la guía semanal GMERMA<lunes>
-- puede existir CERRADA (heredado del patrón 66) → procesar_merma le agregaba líneas a una
-- guía cerrada (unidades sin descontar + documento mutado). Ahora: si la determinista no está
-- ABIERTA, se crea una nueva con sufijo único. (El mismo bug queda LATENTE en 66/resolver_merma
-- legacy — la UI nueva ya no lo usa; documentado.) Redefine wh.procesar_merma completa.
create or replace function wh.procesar_merma(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
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
      if not coalesce(m.stock_descontado,false) then
        update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_cant,
                            ultima_actualizacion = now()
         where upper(cod_producto) = upper(m.cod_producto);
      end if;
    else
      -- recuperación simple: vuelve al stock SOLO si salió al entrar (v2)
      if coalesce(m.stock_descontado,false) then
        update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) + v_cant,
                            ultima_actualizacion = now()
         where upper(cod_producto) = upper(m.cod_producto);
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
end; $fn$;
