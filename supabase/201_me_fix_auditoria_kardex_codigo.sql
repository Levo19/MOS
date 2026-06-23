-- 201_me_fix_auditoria_kardex_codigo.sql — FIXES FLUJO AUDITORÍA→AJUSTE de ME (DINERO/INVENTARIO)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- Diagnóstico verificado en DB (2026-06-20):
--   · me.stock_zonas / mos.productos guardan el código TAL CUAL (mixed-case): existe 'Cts0002' literal en
--     mos.productos (id IDPRO0001250, sku LEV006). 0 pares fantasma (mismo upper, distinto case) hoy en stock_zonas.
--   · El kardex (me.stock_movimientos) está desfasado en 183 de 214 pares (cod,zona): saldo_despues ≠ stock_zonas.cantidad.
--
-- ── QUÉ ARREGLA ──────────────────────────────────────────────────────────────────────────────────────────────
--   FIX 🔴#1  me.zona_ajustar_stock ahora re-ancla el kardex con 'nuevoAbsoluto' (set-absoluto) en vez de 'delta'.
--             El kardex (me.zona_kardex_registrar) YA soporta nuevoAbsoluto (140 L137-140: delta = abs − saldo_actual,
--             saldo_despues = abs). Además marca tipo='AUDITORIA' cuando el origen es auditoría (distingue en historial).
--             Resultado: tras una auditoría, kardex.saldo_despues == stock_zonas.cantidad. NO toca stock_zonas (ya correcto).
--   FIX 🔴#2  Quitar upper() del matching de código. Los códigos son alfanuméricos mixed-case (Cts0002) → upper()
--             creaba fila fantasma CTS0002 en una auditoría. Se cambia a igualdad EXACTA (solo btrim) en:
--               · me.zona_ajustar_stock      (auditoría/ajuste set-absoluto)
--               · me.zona_descontar_venta     (descuento por cierre de caja — DINERO)
--               · me.zona_registrar_guia      (guías manuales — INVENTARIO)
--             Money-safe: como los datos NO están uppercased (solo 1/2368 tiene minúscula y es el caso real Cts0002),
--             quitar upper() NO descuadra ventas/guías existentes; al contrario, evita descuadres futuros.
--   RECONCILIACIÓN one-shot (sección 4): siembra un movimiento 'CUADRE' por cada par (cod,zona) desfasado, que
--             re-ancla el kardex al saldo real de me.stock_zonas. Idempotente (ref_id 'CUADRE-KARDEX:<zona>:<cod>'
--             único por uq_me_kardex_ref) + reversible (todo logueado en la tabla). NO toca me.stock_zonas.
--
-- ── POR QUÉ ES SEGURO ────────────────────────────────────────────────────────────────────────────────────────
--   · La cadena ajuste→me.zona_ajuste_log→me.stock_zonas NO se toca (atómica, idempotente por localId, set-absoluto).
--   · El único cambio en stock es el SET ABSOLUTO ya existente; el delta del kardex pasa a derivarse del saldo del
--     propio kardex (re-ancla), nunca de (nuevo−antes_stock) que era el origen del desfase.
--   · La reconciliación solo INSERTA en el kardex (tabla de trazabilidad); jamás muta me.stock_zonas ni dinero.
--   · Quitar upper(): se valida en DB que no hay datos uppercased que dependan del upper() (ver diagnóstico arriba).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create schema if not exists mos;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- FIX 🔴#1 + 🔴#2 — me.zona_ajustar_stock: re-ancla kardex (nuevoAbsoluto/AUDITORIA) + igualdad EXACTA de código.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me.zona_ajustar_stock(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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
$fn$;
revoke all on function me.zona_ajustar_stock(jsonb) from public;
grant execute on function me.zona_ajustar_stock(jsonb) to service_role, authenticated;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
-- FIX 🔴#2 — me.zona_descontar_venta: igualdad EXACTA de código (sin upper). DINERO. Resto IDÉNTICO a 144.
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

  create temp table _venta_agg (cod_barra text primary key, cant numeric) on commit drop;
  for v_e in select * from jsonb_array_elements(v_items) loop
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', ''));  -- 🔴#2: SIN upper()
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;
    insert into _venta_agg(cod_barra, cant) values (v_cb, v_cant)
      on conflict (cod_barra) do update set cant = _venta_agg.cant + excluded.cant;
  end loop;

  for v_cb, v_cant in select cod_barra, cant from _venta_agg loop
    v_kres := me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'tipo', 'SALIDA_VENTA', 'delta', (-v_cant),
      'refTipo', 'VENTA', 'refId', 'VENTA-CAJA:'||v_caja||':'||v_cb, 'usuario', v_user, 'origen', v_origen));

    if coalesce((v_kres->>'dedup')::boolean, false) then
      v_dedup := v_dedup + 1;
    else
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
-- FIX 🔴#2 — me.zona_registrar_guia: igualdad EXACTA de código (sin upper). INVENTARIO. Resto IDÉNTICO a 144.
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
    v_cb   := btrim(coalesce(v_e->>'codBarra', v_e->>'cod_barras', v_e->>'cod_barra', ''));  -- 🔴#2: SIN upper()
    v_cant := coalesce((v_e->>'cantidad')::numeric, 0);
    if v_cb = '' or v_cant <= 0 then continue; end if;

    perform me.zona_kardex_registrar(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb,
      'tipo', case when v_signo<0 then (case when v_tipo='SALIDA_MOVIMIENTO' then 'TRASLADO_OUT' else 'SALIDA_JEFA' end)
                   else 'TRASLADO_IN' end,
      'delta', (v_signo * v_cant), 'refTipo', 'GUIA', 'refId', 'GUIA:'||v_id||':'||v_cb,
      'usuario', v_user, 'origen', v_origen));

    insert into me.stock_zonas (cod_barras, zona_id, cantidad, usuario, fecha_ultimo_registro)
      values (v_cb, v_zona, (v_signo * v_cant), v_user, now())
    on conflict (cod_barras, zona_id) do update
      set cantidad = coalesce(me.stock_zonas.cantidad,0) + (v_signo * v_cant),
          usuario = excluded.usuario, fecha_ultimo_registro = now();

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
-- 4) RECONCILIACIÓN ONE-SHOT — re-anclar el kardex de los 183 pares (cod,zona) desfasados al saldo REAL de
--    me.stock_zonas. Idempotente (ref_id 'CUADRE-KARDEX:<zona>:<cod>' único) + reversible (queda logueado en
--    la tabla; para revertir: delete where ref_tipo='CUADRE'). NO toca me.stock_zonas (la verdad operativa).
--    Inserta DIRECTO (no vía la RPC) para no depender del gate _claim_ok en la migración; replica la misma
--    fórmula de set-absoluto (delta = real − saldo_actual_kardex, saldo_despues = real).
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_n_antes int;
  v_sembrados int := 0;
begin
  -- contar desfasados ANTES (validación)
  with last_k as (
    select distinct on (cod_barra, zona_id) cod_barra, zona_id, saldo_despues
      from me.stock_movimientos where ambito='ZONA'
      order by cod_barra, zona_id, fecha desc, id desc
  )
  select count(*) into v_n_antes
    from last_k lk join me.stock_zonas sz on sz.cod_barras=lk.cod_barra and sz.zona_id=lk.zona_id
   where lk.saldo_despues is distinct from sz.cantidad;
  raise notice 'RECONCILIACIÓN: pares desfasados ANTES = %', v_n_antes;

  with last_k as (
    select distinct on (cod_barra, zona_id) cod_barra, zona_id, saldo_despues
      from me.stock_movimientos where ambito='ZONA'
      order by cod_barra, zona_id, fecha desc, id desc
  ),
  objetivo as (
    select lk.cod_barra, lk.zona_id, coalesce(lk.saldo_despues,0) as kardex_saldo, coalesce(sz.cantidad,0) as real_saldo
      from last_k lk join me.stock_zonas sz on sz.cod_barras=lk.cod_barra and sz.zona_id=lk.zona_id
     where lk.saldo_despues is distinct from sz.cantidad
  )
  insert into me.stock_movimientos
    (ambito, zona_id, cod_barra, tipo, delta, saldo_antes, saldo_despues,
     ref_tipo, ref_id, usuario, fecha, origen)
  select
    'ZONA', o.zona_id, o.cod_barra, 'CUADRE',
    (o.real_saldo - o.kardex_saldo), o.kardex_saldo, o.real_saldo,
    'CUADRE', 'CUADRE-KARDEX:'||o.zona_id||':'||o.cod_barra, 'SISTEMA', now(), 'MIGRACION-201'
  from objetivo o
  on conflict do nothing;   -- idempotente por uq_me_kardex_ref (ambito,zona,ref_id)
  get diagnostics v_sembrados = row_count;
  raise notice 'RECONCILIACIÓN: movimientos CUADRE sembrados = %', v_sembrados;
end $$;
