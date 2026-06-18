-- 144_me_activar_stock_zona.sql — CUTOVER NÚCLEO DE STOCK ME → SUPABASE (escritura directa) — PASO 1
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- VENTANA LIMPIA confirmada por el dueño (nadie opera las apps → sin escrituras concurrentes). App de DINERO/inventario.
-- Construye SOBRE la fundación 140 (kardex me.stock_movimientos) + 141 (traslado verificado) + me.zona_ajustar_stock.
--
-- ── QUÉ HACE (PASO 1) ────────────────────────────────────────────────────────────────────────────────────────
--   1) me.zona_traslado_cerrar  → DESBLOQUEA el gate: v_aplicar_stock := TRUE. Lo ESCANEADO se aplica a
--      me.stock_zonas con UPDATE ATÓMICO (cantidad = coalesce(cantidad,0) + delta) — NUNCA read-modify-write.
--      El kardex (TRASLADO_IN) ya se escribía; ahora ADEMÁS muta el saldo operativo. Idempotente por id_guia.
--   2) me.zona_ajustar_stock     → set-absoluto en me.stock_zonas (ya existía) + AHORA TAMBIÉN escribe el
--      KARDEX (movimiento AJUSTE, delta = nuevo − antes) vía me.zona_kardex_registrar. Sigue idempotente por localId
--      (el log me.zona_ajuste_log y el kardex comparten la misma clave de negocio → no se duplica al reintentar).
--   3) me.zona_descontar_venta (NUEVA) → descuento de stock por CIERRE DE CAJA. UPDATE ATÓMICO (resta delta) por
--      código + kardex SALIDA_VENTA. IDEMPOTENTE por id_caja: la clave de kardex 'VENTA-CAJA:<idCaja>:<cod>' tiene
--      índice único → re-descontar la MISMA caja no vuelve a restar (la 2da pasada es no-op total). Reemplaza el
--      READ-MODIFY-WRITE de generarGuiaSalidaVentas (doble-conteo confirmado en la Hoja).
--
-- ── POR QUÉ ES SEGURO ────────────────────────────────────────────────────────────────────────────────────────
--   · me.stock_zonas tiene PK (cod_barras, zona_id) → el UPSERT atómico (on conflict do update set cantidad =
--     stock_zonas.cantidad + excluded.cantidad) es libre de lost-update aun con concurrencia (lección WH).
--   · El descuento de venta NO se ata a la frescura de me.ventas en Supabase: recibe los totales ya calculados por
--     GAS (mismos que arma la guía). La idempotencia vive en el kardex (uq_me_kardex_ref), no en una tabla de ventas.
--   · NO toca catálogo (mos.productos), flags MOS_*, sync, ni RPCs de dinero. NO sanea negativos (conteo del dueño).
--   · Todas las mutaciones se enrutan por security definer + mos._claim_ok() (igual que el resto de me.*).
--
-- ── CÓMO REVERTIR ────────────────────────────────────────────────────────────────────────────────────────────
--   Las RPCs se quedan; el cutover real lo gobierna el flag GAS ME_ESCRITURA_STOCK_DIRECTA (default OFF → idéntico a
--   hoy). Para revertir: poner el flag OFF + re-encender el sync (borrar ME_SYNC_OFF_TABLAS). Si se quisiera dejar el
--   traslado INERTE de nuevo: volver a `v_aplicar_stock := false` en me.zona_traslado_cerrar y re-aplicar.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) me.zona_traslado_cerrar — DESBLOQUEAR el gate (v_aplicar_stock := true). Idéntico a 141 salvo esa línea.
--    Lo ESCANEADO entra a me.stock_zonas con UPDATE atómico (suma delta). El kardex TRASLADO_IN ya se escribía.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_traslado_cerrar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := btrim(coalesce(p->>'idGuia',''));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'MOS-PWA');
  v_cab    me.guias_cabecera%rowtype;
  v_zona   text;
  v_exist  me.zona_traslado_verificacion%rowtype;
  v_esc    jsonb := coalesce(p->'escaneados', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_linea  int;
  v_enviado_tot   numeric(20,3) := 0;
  v_escaneado_tot numeric(20,3) := 0;
  v_dif_tot       numeric(20,3) := 0;
  v_ok_n   int := 0;
  v_dif_n  int := 0;
  v_estado text;
  v_detalle jsonb := '[]'::jsonb;
  v_aplicar_stock boolean := true;   -- ✅ [GATE-STOCK] ACTIVADO (cutover 144): aplica lo escaneado a me.stock_zonas.
  v_row     me.zona_traslado_verificacion%rowtype;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  select * into v_exist from me.zona_traslado_verificacion where id_guia = v_id;
  if found then return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_exist)); end if;

  select * into v_cab from me.guias_cabecera where id_guia = v_id;
  if not found then return jsonb_build_object('ok',false,'error','Guía no encontrada: '||v_id); end if;
  v_zona := upper(btrim(coalesce(v_cab.zona_id,'')));
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Guía sin zona'); end if;

  -- A) Agregar los escaneados por código.
  create temp table _esc_agg (cod_barra text primary key, cant numeric) on commit drop;
  for v_e in select * from jsonb_array_elements(v_esc) loop
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barra', ''));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _esc_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _esc_agg.cant + excluded.cant;
  end loop;

  -- B) Detalle enviado (guía) vs escaneado (real).
  with envi as (
      select d.cod_barras as cod_barra, min(d.linea) as linea, sum(d.cantidad) as enviado
        from me.guias_detalle d where d.id_guia = v_id group by d.cod_barras
  ),
  uni as (
      select coalesce(en.cod_barra, es.cod_barra) as cod_barra, en.linea as linea,
             coalesce(en.enviado, 0) as enviado, coalesce(es.cant, 0) as escaneado
        from envi en full join _esc_agg es on es.cod_barra = en.cod_barra
  )
  select
      coalesce(sum(enviado),0), coalesce(sum(escaneado),0), coalesce(sum(enviado - escaneado),0),
      coalesce(sum(case when enviado = escaneado then 1 else 0 end),0),
      coalesce(sum(case when enviado <> escaneado then 1 else 0 end),0),
      coalesce(jsonb_agg(jsonb_build_object(
          'codBarra', u.cod_barra, 'descripcion', coalesce(pr.descripcion, u.cod_barra),
          'enviado', u.enviado, 'escaneado', u.escaneado, 'dif', (u.enviado - u.escaneado),
          'estado', case when u.enviado = u.escaneado then 'OK' when u.escaneado < u.enviado then 'FALTA' else 'SOBRA' end
        ) order by (u.enviado - u.escaneado) desc, u.cod_barra), '[]'::jsonb)
  into v_enviado_tot, v_escaneado_tot, v_dif_tot, v_ok_n, v_dif_n, v_detalle
  from uni u
  left join lateral (select descripcion from mos.productos pr where pr.codigo_barra = u.cod_barra limit 1) pr on true;

  v_estado := case when v_dif_n = 0 then 'COMPLETO' else 'INCOMPLETO' end;

  -- C) KARDEX: cada escaneado como TRASLADO_IN (idempotente por ref de línea/código).
  for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
    select min(d.linea) into v_linea from me.guias_detalle d where d.id_guia = v_id and d.cod_barras = v_cb;
    perform me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN', 'delta', v_cant,
      'refTipo', 'TRASLADO', 'refId', 'TRASLADO:'||v_id||':'||coalesce(v_linea::text, 'X-'||v_cb),
      'usuario', v_user, 'origen', v_origen));
  end loop;

  -- ┌─ [GATE-STOCK · ACTIVO] ────────────────────────────────────────────────────────────────────────────────┐
  -- │ Aplica lo ESCANEADO al saldo operativo (me.stock_zonas). UPDATE ATÓMICO (suma delta), nunca RMW.         │
  if v_aplicar_stock then
    for v_cb, v_cant in select cod_barra, cant from _esc_agg loop
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) + excluded.cantidad,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
    end loop;
  end if;
  -- └─ /GATE-STOCK ─────────────────────────────────────────────────────────────────────────────────────────┘

  -- D) Persistir verificación (idempotente por id_guia).
  insert into me.zona_traslado_verificacion
    (id_guia, zona_id, tipo_guia, estado, total_enviado, total_escaneado, total_dif,
     lineas_ok, lineas_dif, detalle, stock_aplicado, usuario, verificado_ts, fecha_guia)
  values
    (v_id, v_zona, v_cab.tipo, v_estado, v_enviado_tot, v_escaneado_tot, v_dif_tot,
     v_ok_n, v_dif_n, v_detalle, v_aplicar_stock, v_user, now(), v_cab.fecha)
  on conflict (id_guia) do nothing
  returning * into v_row;

  if v_row.id_guia is null then
    select * into v_row from me.zona_traslado_verificacion where id_guia = v_id;
    return jsonb_build_object('ok',true,'dedup',true,'data',to_jsonb(v_row));
  end if;

  return jsonb_build_object('ok', true, 'dedup', false, 'stockAplicado', v_aplicar_stock, 'data', to_jsonb(v_row));
end;
$fn$;
revoke all on function me.zona_traslado_cerrar(jsonb) from public;
grant execute on function me.zona_traslado_cerrar(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 2) me.zona_ajustar_stock — set-absoluto (ya existía) + AHORA escribe el KARDEX (AJUSTE, delta=nuevo−antes).
--    Idempotencia: el log me.zona_ajuste_log sigue por localId; el kardex por refId 'AJUSTE:<localId|zona:cod:ts>'.
--    Si no vino localId, el kardex usa una ref por (zona,cod,timestamp ms) para no colisionar entre ajustes legítimos.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_ajustar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_nuevo numeric := nullif(btrim(coalesce(p->>'nuevo','')), '')::numeric;
  v_user  text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_cb    text := upper(nullif(btrim(coalesce(p->>'codBarra', p->>'codBarras', '')), ''));
  v_antes numeric;
  v_existe bigint;
  v_refk  text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_nuevo is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y nuevo (numérico)');
  end if;
  if v_cb is null and v_sku is null then
    return jsonb_build_object('ok',false,'error','Requiere codBarra (o skuBase para resolver el canónico)');
  end if;

  -- IDEMPOTENCIA por localId: si el gesto ya se aplicó → devolver lo persistido (dedup).
  if v_local is not null then
    select id into v_existe from me.zona_ajuste_log where local_id = v_local limit 1;
    if found then
      return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idLog', v_existe));
    end if;
  end if;

  -- resolver el código concreto.
  if v_cb is null then
    select upper(btrim(pr.codigo_barra)) into v_cb
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
        from mos.productos pr where upper(btrim(pr.codigo_barra)) = v_cb
      union all
      select e.sku_base, 1 from mos.equivalencias e where upper(btrim(e.codigo_barra)) = v_cb and coalesce(e.activo,true)
    ) t order by ord limit 1;
  end if;

  -- stock antes.
  select coalesce(sum(cantidad),0) into v_antes from me.stock_zonas
   where upper(btrim(cod_barras)) = v_cb and upper(btrim(zona_id)) = v_zona;

  -- escribir el nuevo stock (upsert atómico sobre PK (cod_barras, zona_id)) — SET ABSOLUTO.
  insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
  values (v_cb, v_zona, v_nuevo, v_user, now())
  on conflict (cod_barras, zona_id) do update set
    cantidad = excluded.cantidad, usuario = excluded.usuario, fecha_ultimo_registro = now();

  -- log [D] (idempotente por local_id).
  insert into me.zona_ajuste_log (zona_id, sku_base, cod_barras, stock_antes, stock_despues, delta, usuario, local_id)
  values (v_zona, v_sku, v_cb, v_antes, v_nuevo, v_nuevo - v_antes, v_user, v_local)
  on conflict (local_id) where local_id is not null do nothing;

  -- KARDEX [nuevo 144]: movimiento AJUSTE con delta = nuevo − antes. Idempotente por refId (uq_me_kardex_ref).
  --   ref estable: por localId si vino; si no, por (zona,cod,epoch-ms) para no colisionar entre ajustes distintos.
  v_refk := 'AJUSTE:'||coalesce(v_local, v_zona||':'||v_cb||':'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
  perform me.zona_kardex_registrar(jsonb_build_object(
    'zona', v_zona, 'codBarra', v_cb, 'tipo', 'AJUSTE', 'delta', (v_nuevo - v_antes),
    'refTipo', 'AJUSTE', 'refId', v_refk, 'usuario', v_user, 'origen', v_origen, 'localId', v_local));

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona', v_zona, 'skuBase', v_sku, 'codBarra', v_cb, 'codBarras', v_cb,
    'stockAntes', v_antes, 'stockDespues', v_nuevo, 'delta', v_nuevo - v_antes));
end;
$fn$;
revoke all on function me.zona_ajustar_stock(jsonb) from public;
grant execute on function me.zona_ajustar_stock(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 3) me.zona_descontar_venta(p {idCaja, zona, items:[{codBarra,cantidad}], usuario?, origen?}) — DESCUENTO VENTA.
--    Reemplaza el read-modify-write de generarGuiaSalidaVentas (doble-conteo). Por cada código:
--      · KARDEX SALIDA_VENTA con delta = −cantidad, refId 'VENTA-CAJA:<idCaja>:<cod>' (uq_me_kardex_ref = idempotente).
--      · UPDATE ATÓMICO de me.stock_zonas (resta), SOLO si ese movimiento de kardex NO existía aún (anti-doble-resta).
--    IDEMPOTENCIA POR id_caja: el ref de kardex lleva el idCaja. Re-correr la MISMA caja → el kardex deduplica y
--    NO se vuelve a restar. items con cantidad<=0 se ignoran. NO sanea negativos (puede dejar saldo < 0; es real).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_descontar_venta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_caja   text := btrim(coalesce(p->>'idCaja',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_kres   jsonb;
  v_aplicados int := 0;
  v_dedup     int := 0;
  v_resultado jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_caja = '' then return jsonb_build_object('ok',false,'error','Requiere idCaja'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- Agregar por código (defensa: sumar si el array trae el mismo código en varias líneas).
  create temp table _venta_agg (cod_barra text primary key, cant numeric) on commit drop;
  for v_e in select * from jsonb_array_elements(v_items) loop
    v_cb   := upper(btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', '')));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _venta_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _venta_agg.cant + excluded.cant;
  end loop;

  for v_cb, v_cant in select cod_barra, cant from _venta_agg loop
    -- KARDEX primero (es el guardián de idempotencia por id_caja). dedup=true → ya se descontó esta caja.
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'SALIDA_VENTA', 'delta', (-v_cant),
      'refTipo', 'VENTA', 'refId', 'VENTA-CAJA:'||v_caja||':'||v_cb, 'usuario', v_user, 'origen', v_origen));

    if coalesce((v_kres->>'dedup')::boolean, false) then
      v_dedup := v_dedup + 1;   -- esta caja+código YA se descontó → NO restar otra vez.
    else
      -- UPDATE ATÓMICO (resta). Insert si no existe la fila (saldo arranca en −cant; conteo físico lo corrige).
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zona, -v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) - v_cant,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
      v_aplicados := v_aplicados + 1;
    end if;
    v_resultado := v_resultado || jsonb_build_object('codBarra', v_cb, 'cantidad', v_cant,
      'aplicado', not coalesce((v_kres->>'dedup')::boolean,false));
  end loop;

  return jsonb_build_object('ok', true, 'idCaja', v_caja, 'zona', v_zona,
    'aplicados', v_aplicados, 'dedup', v_dedup, 'detalle', v_resultado);
end;
$fn$;
revoke all on function me.zona_descontar_venta(jsonb) from public;
grant execute on function me.zona_descontar_venta(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 4) me.zona_registrar_guia(p {idGuia, zona, tipo, items:[{codBarra,cantidad}], usuario?, origen?,
--                              idGuiaEntrada?, zonaDestino?}) — GUÍA MANUAL (SALIDA_JEFA/MOVIMIENTO/ENTRADA_*).
--    Aplica el delta firmado por TIPO (SALIDA* = −, ENTRADA* = +) con UPDATE ATÓMICO + kardex. Idempotente por
--    refId 'GUIA:<idGuia>:<cod>'. Para SALIDA_MOVIMIENTO con zonaDestino: además suma en la zona destino
--    (refId 'GUIA:<idGuiaEntrada|idGuia-IN>:<cod>'). NO escribe me.guias_* (eso lo hace GAS en la Hoja + sync;
--    aquí solo mutamos el SALDO operativo y el kardex). NO sanea negativos.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_registrar_guia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := btrim(coalesce(p->>'idGuia',''));
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_tipo   text := upper(btrim(coalesce(p->>'tipo','')));
  v_user   text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_origen text := coalesce(nullif(btrim(coalesce(p->>'origen','')),''),'GAS');
  v_idEnt  text := nullif(btrim(coalesce(p->>'idGuiaEntrada','')),'');
  v_zdest  text := upper(nullif(btrim(coalesce(p->>'zonaDestino','')),''));
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_e      jsonb;
  v_cb     text;
  v_cant   numeric(20,3);
  v_signo  int;
  v_n      int := 0;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' or v_zona = '' or v_tipo = '' then
    return jsonb_build_object('ok',false,'error','Requiere idGuia, zona y tipo');
  end if;
  v_signo := case when v_tipo like 'SALIDA%' then -1 else 1 end;

  for v_e in select * from jsonb_array_elements(v_items) loop
    v_cb   := upper(btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', '')));
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;

    -- KARDEX origen (idempotente por refId de guía+código).
    perform me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb,
      'tipo', case when v_signo<0 then (case when v_tipo='SALIDA_MOVIMIENTO' then 'TRASLADO_OUT' else 'SALIDA_JEFA' end)
                   else 'TRASLADO_IN' end,
      'delta', (v_signo * v_cant), 'refTipo', 'GUIA', 'refId', 'GUIA:'||v_id||':'||v_cb,
      'usuario', v_user, 'origen', v_origen));

    -- SALDO atómico origen.
    insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
      values (v_cb, v_zona, (v_signo * v_cant), v_user, now())
    on conflict (cod_barras, zona_id) do update
      set cantidad = coalesce(me.stock_zonas.cantidad,0) + (v_signo * v_cant),
          usuario = excluded.usuario, fecha_ultimo_registro = now();

    -- SALIDA_MOVIMIENTO con destino → entrada espejo en la zona destino.
    if v_tipo = 'SALIDA_MOVIMIENTO' and v_zdest is not null then
      perform me.zona_kardex_registrar(jsonb_build_object(
        'zona', v_zdest, 'codBarra', v_cb, 'tipo', 'TRASLADO_IN', 'delta', v_cant,
        'refTipo', 'GUIA', 'refId', 'GUIA:'||coalesce(v_idEnt, v_id||'-IN')||':'||v_cb,
        'usuario', v_user, 'origen', v_origen));
      insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
        values (v_cb, v_zdest, v_cant, v_user, now())
      on conflict (cod_barras, zona_id) do update
        set cantidad = coalesce(me.stock_zonas.cantidad,0) + v_cant,
            usuario = excluded.usuario, fecha_ultimo_registro = now();
    end if;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'zona', v_zona, 'tipo', v_tipo, 'lineas', v_n);
end;
$fn$;
revoke all on function me.zona_registrar_guia(jsonb) from public;
grant execute on function me.zona_registrar_guia(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 5) WRAPPERS mos.* (profile 'mos') — pass-through con gate. mos.zona_ajustar_stock / mos.zona_traslado_cerrar
--    ya existen (re-CREATE OR REPLACE para refrescar). Agregar wrappers de las RPCs nuevas.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function mos.zona_descontar_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_descontar_venta(p);
end; $fn$;
revoke all on function mos.zona_descontar_venta(jsonb) from public;
grant execute on function mos.zona_descontar_venta(jsonb) to service_role, authenticated;

create or replace function mos.zona_registrar_guia(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_registrar_guia(p);
end; $fn$;
revoke all on function mos.zona_registrar_guia(jsonb) from public;
grant execute on function mos.zona_registrar_guia(jsonb) to service_role, authenticated;
