-- 517_wh_mermas_v2.sql — ♻️ TRATAMIENTO DE MERMAS v2 · FASE 1 backend (diseño DISENO_SORPRESAS_MERMAS.md)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ADITIVO sobre 31/66 (registrar_merma/resolver_merma quedan intactas para paridad GAS). Nuevo modelo
-- físico: la merma SALE del stock vendible al entrar a la cesta (stock_descontado=true) y VUELVE al
-- recuperarse; la eliminación es documental (guía CERRADA, sin doble descuento). Las mermas VIEJAS
-- (stock_descontado=false, entradas por el flujo 31: nunca salieron del stock) se procesan con la
-- semántica vieja (recupero sin crédito; desecho → guía semanal ABIERTA que descuenta al cerrar).
-- Decisiones dueño: SLA 3 días CORRIDOS · culpa = zona que devolvió o ALMACÉN (estadística) ·
-- transformación con cantidad destino editable (default = recuperado) · parcial ITERATIVO.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

alter table wh.mermas add column if not exists culpa                  text;
alter table wh.mermas add column if not exists id_guia_transformacion text;
alter table wh.mermas add column if not exists costo_unitario         numeric;
alter table wh.mermas add column if not exists stock_descontado       boolean default false;

-- ── Puerta A: merma desde línea de guía INGRESO_DEVOLUCION_ZONA ────────────────────────────────────
-- p: { id_merma(localId), id_guia, cod_producto, cantidad, culpa('ZONA'|'ALMACEN'), foto, usuario, motivo? }
-- culpa='ZONA' se traduce a la zona de la guía (id_zona). Guía debe estar CERRADA (el stock ya ingresó
-- completo) → acá la parte dañada SALE del stock vendible hacia la cesta.
create or replace function wh.merma_desde_guia(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'id_merma','')), '');
  v_guia  text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_cod   text := nullif(btrim(coalesce(p->>'cod_producto','')), '');
  v_cant  numeric := wh._num(p->>'cantidad');
  v_culpa text := upper(nullif(btrim(coalesce(p->>'culpa','')), ''));
  v_foto  text := coalesce(p->>'foto','');
  v_usr   text := coalesce(p->>'usuario','');
  v_mot   text := coalesce(p->>'motivo','devolución de zona en mal estado');
  v_g     record; v_d record;
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_guia is null or v_cod is null then
    return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_cant <= 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_foto = '' then return jsonb_build_object('ok',false,'error','FOTO_OBLIGATORIA'); end if;
  if v_culpa not in ('ZONA','ALMACEN') then
    return jsonb_build_object('ok',false,'error','CULPA_INVALIDA'); end if;

  if exists (select 1 from wh.mermas where id_merma = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_merma',v_id); end if;

  select * into v_g from wh.guias where id_guia = v_guia;
  if not found or upper(coalesce(v_g.tipo,'')) <> 'INGRESO_DEVOLUCION_ZONA' then
    return jsonb_build_object('ok',false,'error','GUIA_INVALIDA','detalle','solo guías de devolución de zona'); end if;
  if upper(coalesce(v_g.estado,'')) <> 'CERRADA' then
    return jsonb_build_object('ok',false,'error','GUIA_ABIERTA','detalle','cierra la guía primero (el stock debe haber ingresado)'); end if;

  select * into v_d from wh.guia_detalle
   where id_guia = v_guia and upper(cod_producto) = upper(v_cod)
     and upper(coalesce(observacion,'')) <> 'ANULADO'
   order by linea limit 1;
  if not found then return jsonb_build_object('ok',false,'error','PRODUCTO_NO_EN_GUIA'); end if;
  if v_cant > coalesce(v_d.cant_recibida,0) then
    return jsonb_build_object('ok',false,'error','CANTIDAD_EXCEDE','detalle','la línea recibió '||coalesce(v_d.cant_recibida,0)); end if;

  -- la parte dañada sale del stock vendible (atómico) — entra a la cesta
  update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_cant,
                      ultima_actualizacion = now()
   where upper(cod_producto) = upper(v_cod);

  insert into wh.mermas (id_merma, fecha_ingreso, origen, cod_producto, id_lote, cantidad_original,
    cantidad_pendiente, motivo, usuario, id_guia, estado, responsable, cantidad_reparada,
    cantidad_desechada, foto, culpa, costo_unitario, stock_descontado)
  values (v_id, now(), 'DEVOLUCION_ZONA', v_cod, coalesce(v_d.id_lote,''), v_cant, v_cant, v_mot, v_usr,
    v_guia, 'EN_PROCESO',
    case when v_culpa='ZONA' then coalesce(v_g.id_zona,'ZONA') else 'ALMACEN' end,
    0, 0, v_foto,
    case when v_culpa='ZONA' then coalesce(v_g.id_zona,'ZONA') else 'ALMACEN' end,
    coalesce(nullif(v_d.precio_unitario,0),0), true);

  return jsonb_build_object('ok',true,'id_merma',v_id,'culpa',
    case when v_culpa='ZONA' then coalesce(v_g.id_zona,'ZONA') else 'ALMACEN' end);
end; $fn$;
revoke all on function wh.merma_desde_guia(jsonb) from public, anon;
grant execute on function wh.merma_desde_guia(jsonb) to service_role, authenticated;

-- ── Puerta B: hallazgo en andamio (culpa ALMACÉN fija, sale del stock) ─────────────────────────────
-- p: { id_merma(localId), cod_producto, cantidad, foto, usuario, motivo?, costo? }
create or replace function wh.merma_alta_manual(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
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

  insert into wh.mermas (id_merma, fecha_ingreso, origen, cod_producto, id_lote, cantidad_original,
    cantidad_pendiente, motivo, usuario, id_guia, estado, responsable, cantidad_reparada,
    cantidad_desechada, foto, culpa, costo_unitario, stock_descontado)
  values (v_id, now(), 'ALMACEN', v_cod, '', v_cant, v_cant, v_mot, v_usr, '', 'EN_PROCESO',
    'ALMACEN', 0, 0, v_foto, 'ALMACEN', wh._num(p->>'costo'), true);

  return jsonb_build_object('ok',true,'id_merma',v_id);
end; $fn$;
revoke all on function wh.merma_alta_manual(jsonb) from public, anon;
grant execute on function wh.merma_alta_manual(jsonb) to service_role, authenticated;

-- ── Procesar (ITERATIVO): RECUPERAR N (± transformación) · ELIMINAR el resto ───────────────────────
-- p: { id_merma, local_id, accion:'RECUPERAR'|'ELIMINAR', cantidad?, cod_destino?, cantidad_destino?, usuario, observacion? }
-- RECUPERAR: pendiente-=N · reparada+=N · stock: si transformar → guía TRANSFORMACION CERRADA
--   (2 líneas documentales) + stock destino += cantidad_destino (origen ya está fuera si v2; si fila
--   VIEJA además origen -= N porque seguía contada); sin transformar → stock origen += N (solo v2).
-- ELIMINAR: desechada += pendiente · pendiente=0 · v2 → guía SALIDA_MERMA documental CERRADA (id
--   determinista del local_id, sin doble descuento) · fila VIEJA → línea en la guía semanal ABIERTA
--   (patrón 66: descuenta al cerrar). pendiente=0 ⇒ estado RESUELTA (o DESECHADA si nada se reparó).
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
revoke all on function wh.procesar_merma(jsonb) from public, anon;
grant execute on function wh.procesar_merma(jsonb) to service_role, authenticated;

-- ── Lectura: lista de mermas (WH acotada · MOS completa) con SLA computado ─────────────────────────
create or replace function wh.mermas_lista(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case when wh._claim_ok() or mos._claim_ok()
    then jsonb_build_object('ok', true, 'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idMerma', m.id_merma, 'fechaIngreso', m.fecha_ingreso, 'origen', m.origen,
        'codProducto', m.cod_producto, 'cantidadOriginal', m.cantidad_original,
        'cantidadPendiente', m.cantidad_pendiente, 'cantidadReparada', m.cantidad_reparada,
        'cantidadDesechada', m.cantidad_desechada, 'motivo', m.motivo, 'usuario', m.usuario,
        'idGuia', m.id_guia, 'estado', m.estado, 'culpa', coalesce(m.culpa, m.responsable),
        'foto', m.foto, 'fechaResolucion', m.fecha_resolucion,
        'observacionResolucion', m.observacion_resolucion,
        'idGuiaSalida', m.id_guia_salida, 'idGuiaTransformacion', m.id_guia_transformacion,
        'costoUnitario', coalesce(m.costo_unitario,0), 'stockDescontado', coalesce(m.stock_descontado,false),
        'diasPendiente', case when coalesce(m.cantidad_pendiente,0) > 0
                              then extract(day from now() - m.fecha_ingreso)::int else null end,
        'vencida', coalesce(m.cantidad_pendiente,0) > 0 and m.fecha_ingreso < now() - interval '3 days')
        order by (coalesce(m.cantidad_pendiente,0) > 0) desc, m.fecha_ingreso desc)
      from wh.mermas m
      where case when lower(coalesce(p->>'alcance','wh')) = 'mos'
              then m.fecha_ingreso >= now() - make_interval(days => least(greatest(coalesce((p->>'dias')::int, 365),1),1095))
              else (coalesce(m.cantidad_pendiente,0) > 0 or m.fecha_resolucion >= now() - interval '15 days') end
    ), '[]'::jsonb))
    else jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA') end;
$fn$;
revoke all on function wh.mermas_lista(jsonb) from public, anon;
grant execute on function wh.mermas_lista(jsonb) to service_role, authenticated;

-- ── Cron: alerta de vencidas (SLA 3 días corridos) · 1 push resumen, 8am Lima ─────────────────────
create or replace function wh.cron_mermas_vencidas()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_n int; v_txt text;
begin
  select count(*), string_agg(m.cod_producto || ' (' || m.cantidad_pendiente || ')', ' · ')
    into v_n, v_txt
  from wh.mermas m
  where coalesce(m.cantidad_pendiente,0) > 0 and m.fecha_ingreso < now() - interval '3 days';
  if coalesce(v_n,0) > 0 then
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMIN')),
        'titulo', '🧺🔴 ' || v_n || ' merma(s) vencida(s)',
        'cuerpo', 'Más de 3 días sin procesar: ' || coalesce(v_txt,'') || ' · WH → cesta de mermas',
        'data', jsonb_build_object('tipo','mermas_vencidas','n',v_n)));
    exception when others then null; end;
  end if;
  insert into mos.cron_log(job, ok, resultado)
  values ('mermas_vencidas', true, jsonb_build_object('vencidas', coalesce(v_n,0)));
  return jsonb_build_object('ok',true,'vencidas',coalesce(v_n,0));
end; $fn$;
revoke all on function wh.cron_mermas_vencidas() from public, anon;
grant execute on function wh.cron_mermas_vencidas() to service_role;
select cron.schedule('wh-mermas-vencidas', '0 13 * * *', $$ select wh.cron_mermas_vencidas(); $$);
