-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 193_riz_kardex_por_codigo.sql — TANDA 2/2 · HISTORIAL POR CÓDIGO (pestañas) en el kardex de Zona/RIZ (MOS).
-- App de DINERO en PROD · SOLO LECTURA (no escribe stock/dinero/sync). Aditivo: no cambia el shape "Total".
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- QUÉ HACE
--   El kardex de un producto con >1 código (canónico + equivalentes) hoy devuelve un único historial COMBINADO
--   (suma del grupo, que cuadra con me.stock_zonas del grupo). El dueño quiere ver el comportamiento de CADA
--   código por separado, manteniendo el combinado como pestaña "Total".
--
--   me.zona_kardex_historial ahora:
--     · acepta un parámetro ADITIVO  p.cod  → filtra la reconstrucción a UN solo código (mismo shape "Total",
--       pero su saldo/cuadre se ancla al me.stock_zonas de ESE código). Ruta usada por el front al pedir una pestaña.
--     · cuando se consulta por skuBase (grupo) y el grupo tiene MÁS DE UN código, agrega  data.porCodigo : {
--         "<cod>": { codBarra, esEquivalente, descripcion, totalMovimientos, saldoFinal, stockZonas, cuadra,
--                    movimientos:[...] }, ... }
--       con un historial reconstruido INDEPENDIENTE por cada código del grupo (canónico + cada equivalente).
--       El front pinta una pestaña por entrada de porCodigo + la pestaña "Total" (el shape de raíz de siempre).
--     · 1 solo código en el grupo → NO se agrega porCodigo (el front muestra el historial directo, sin pestañas).
--
-- CUADRE
--   El "Total" sigue cuadrando EXACTAMENTE con me.stock_zonas del grupo (sin cambios). Cada pestaña por código
--   reconstruye su saldo con el MISMO algoritmo (ancla en set-absoluto ajuste/auditoría + movimientos de ESE código)
--   y cuadra contra el me.stock_zonas de ESE código. Σ(stockZonas por código) = stockZonas del Total por
--   construcción (la suma de las filas de stock_zonas del grupo = la suma del grupo).
--
-- ATRIBUCIÓN POR CÓDIGO — limpieza de fuentes
--   Cada fuente trae su propio código, así que la atribución es 1-a-1 y limpia:
--     · me.zona_ajuste_log.cod_barras   (AJUSTE set-absoluto)
--     · me.auditorias.cod_barras        (AUDITORIA set-absoluto)
--     · me.guias_detalle.cod_barras     (GUÍAS ± )
--     · me.ventas_detalle.cod_barras    (VENTAS − )
--   El ÚNICO evento sin código limpio es el "CUADRE con stock real (saldo histórico previo)": es un saldo de
--   apertura sintético a nivel de la unidad consultada (Total o el código de la pestaña). Por eso se calcula
--   DENTRO de cada reconstrucción contra el stock_zonas de esa misma unidad → queda correctamente atribuido a
--   la pestaña/Total que se está viendo, nunca "huérfano". (No hay movimientos de grupo sin código en estas
--   fuentes; si en el futuro lo hubiera, caería sólo en el Total y no en ninguna pestaña de código.)
--
-- IDEMPOTENTE (create or replace). No cambia firmas públicas, ni flags, ni sync, ni el wrapper mos.*.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

set search_path to '';

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ HELPER INTERNO · me._kardex_reconstruir(zona, codes[]) → reconstrucción COMPLETA para un conjunto de       ║
-- ║ códigos (1 = pestaña de un código · N = Total del grupo). Devuelve el mismo objeto data que la RPC pública  ║
-- ║ (movimientos/saldoFinal/stockZonas/cuadra) para que Total y cada pestaña usen EXACTAMENTE el mismo algoritmo.║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create or replace function me._kardex_reconstruir(v_zona text, v_codes text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_movs   jsonb := '[]'::jsonb;
  v_ev     me._kardex_evento[];
  v_e      me._kardex_evento;
  v_run    numeric(20,3);
  v_antes  numeric(20,3);
  v_sal    numeric(20,3);
  v_acc    jsonb := '[]'::jsonb;
  v_saldo_final numeric(20,3);
  v_stock_zonas numeric(20,3);
  v_base   numeric(20,3);
begin
  if v_codes is null or coalesce(array_length(v_codes,1),0) = 0 then
    return jsonb_build_object('totalMovimientos',0,'saldoFinal',0,'stockZonas',0,'cuadra',true,'movimientos','[]'::jsonb);
  end if;

  -- ── RECONSTRUCCIÓN UNIFICADA desde fuentes autoritativas (ajuste_log + auditorias + ventas + guias). ──────────
  with
  dias_reconc as (
    select distinct date(gc.fecha at time zone 'America/Lima') as dia
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and gc.tipo = 'SALIDA_VENTAS' and upper(btrim(gd.cod_barras)) = any(v_codes)
  ),
  eventos as (
    -- AJUSTE manual (SET-ABSOLUTO real: stock_despues = lo escrito a me.stock_zonas)
    select al.ts as fecha, 'AJUSTE'::text as tipo, al.delta as delta, al.stock_despues as saldo_set,
           true as es_set, true as aplicado, coalesce(al.usuario,'—') as usuario, '' as id_guia, 'ajuste' as fuente
      from me.zona_ajuste_log al
     where al.zona_id = v_zona and upper(btrim(al.cod_barras)) = any(v_codes)
    union all
    -- AUDITORIA (SET-ABSOLUTO → saldo := cant_real; delta = diferencia firmada)
    select a.fecha, 'AUDITORIA'::text, (a.cant_real - a.cant_sistema), a.cant_real,
           true, true, coalesce(a.vendedor,'—'), '', 'auditoria'
      from me.auditorias a
     where a.zona_id = v_zona and upper(btrim(a.cod_barras)) = any(v_codes)
    union all
    -- GUÍAS: entradas/traslado-in = +cantidad; salidas = −cantidad. La guía SIEMPRE suma (evento reconciliado).
    select gc.fecha,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then 'TRASLADO_IN'
                when gc.tipo = 'SALIDA_VENTAS' then 'SALIDA_VENTA'
                when gc.tipo = 'SALIDA_JEFA' then 'SALIDA_JEFA'
                when gc.tipo like 'SALIDA%' then 'TRASLADO_OUT'
                else 'SALIDA_JEFA' end,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then gd.cantidad else -gd.cantidad end,
           null::numeric, false, true, coalesce(gc.vendedor,'—'), gc.id_guia, 'guia'
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and upper(btrim(gd.cod_barras)) = any(v_codes)
    union all
    -- VENTAS (tickets, no anuladas) = SALIDA_VENTA −cantidad. Día con guía de cierre → informativo (no suma).
    select v.fecha, 'SALIDA_VENTA'::text, -vd.cantidad, null::numeric, false,
           (date(v.fecha at time zone 'America/Lima') not in (select dia from dias_reconc)) as aplicado,
           coalesce(v.vendedor,'—'), v.id_venta,
           case when date(v.fecha at time zone 'America/Lima') in (select dia from dias_reconc)
                then 'venta' else 'venta-pendiente' end
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where v.zona_id = v_zona and upper(btrim(vd.cod_barras)) = any(v_codes)
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  )
  select array_agg(
           row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
           order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
         into v_ev
    from eventos e;

  -- stock_zonas real de ESTA unidad (suma sobre el conjunto de códigos) — META DE CUADRE.
  select coalesce(sum(cantidad),0) into v_stock_zonas
    from me.stock_zonas where upper(btrim(cod_barras)) = any(v_codes) and upper(btrim(zona_id)) = v_zona;

  -- ── Saldo corrido con RE-ANCLA en cada set-absoluto ─────────────────────────────────────────────────────────
  v_run := 0;
  if v_ev is not null then
    foreach v_e in array v_ev loop
      v_antes := v_run;
      if (v_e).es_set then
        v_run := (v_e).saldo_set; v_sal := v_run;
      elsif (v_e).aplicado then
        v_run := v_run + (v_e).delta; v_sal := v_run;
      else
        v_sal := v_run;
      end if;
      v_acc := v_acc || jsonb_build_object(
        'idGuia',(v_e).id_guia,'fecha',(v_e).fecha,'tipo',me._kardex_label((v_e).tipo,(v_e).delta),
        'tipoOperacion',(v_e).tipo,'esIngreso',((v_e).delta > 0),'cantidad',abs((v_e).delta),
        'saldo',v_sal,'stockAntes',v_antes,'usuario',(v_e).usuario,'origen','',
        'estado',case when (v_e).fuente = 'venta-pendiente' then 'ABIERTA' else 'CERRADA' end,
        'pendiente',((v_e).fuente = 'venta-pendiente'),
        'fuente',case when (v_e).tipo in ('AJUSTE','AUDITORIA') then 'ajuste'
                      when (v_e).fuente = 'venta-pendiente' then 'venta' else (v_e).fuente end,
        'aplicado',(v_e).aplicado,'idLote',null);
    end loop;
  end if;

  -- ── CUADRE con me.stock_zonas de ESTA unidad (apertura sintética, etiquetada, no toca stock real) ───────────
  v_base := round(v_stock_zonas - v_run, 3);
  if v_base <> 0 then
    v_antes := v_run;
    v_run := v_stock_zonas;
    v_acc := v_acc || jsonb_build_object(
      'idGuia','','fecha',now(),
      'tipo','CUADRE con stock real (saldo histórico previo)','tipoOperacion','AJUSTE',
      'esIngreso',(v_base > 0),'cantidad',abs(v_base),
      'saldo',v_run,'stockAntes',v_antes,'usuario','sistema-cuadre','origen','',
      'estado','CERRADA','pendiente',false,'fuente','ajuste','aplicado',true,'idLote',null);
  end if;

  -- v_acc es asc; shape WH = fecha DESC → invertir.
  select coalesce(jsonb_agg(elem order by ord desc), '[]'::jsonb) into v_movs
    from jsonb_array_elements(v_acc) with ordinality as t(elem, ord);

  v_saldo_final := v_run;

  return jsonb_build_object(
    'totalMovimientos', jsonb_array_length(v_movs),
    'saldoFinal',       v_saldo_final,
    'stockZonas',       v_stock_zonas,
    'cuadra',           (round(v_saldo_final,3) = round(v_stock_zonas,3)),
    'movimientos',      v_movs);
end;
$fn$;
revoke all on function me._kardex_reconstruir(text, text[]) from public;
grant execute on function me._kardex_reconstruir(text, text[]) to service_role, authenticated;

-- ╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗
-- ║ me.zona_kardex_historial — usa el helper para el Total y, si el grupo tiene >1 código, agrega porCodigo.    ║
-- ║ Parámetro ADITIVO p.cod (alias p.codBarra) → reconstruye sólo ese código (pestaña). Shape Total intacto.    ║
-- ╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝
create or replace function me.zona_kardex_historial(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_cod    text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  -- [193] p.cod = filtrar a UN código del grupo (pestaña). Aditivo; si viene, manda sobre la expansión del sku.
  v_pestana text := nullif(btrim(coalesce(p->>'cod','')),'');
  v_codes  text[];
  v_total  jsonb;
  v_porcod jsonb := '{}'::jsonb;
  v_one    text;
  v_one_data jsonb;
  v_desc   text;
  v_es_eq  boolean;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- [193] Si llega p.cod, es una consulta de PESTAÑA: la unidad consultada es ese único código.
  if v_pestana is not null then
    v_codes := array[upper(btrim(v_pestana))];
    v_cod   := v_codes[1];
  elsif v_cod is not null then
    v_codes := array[upper(btrim(v_cod))];
    v_cod   := v_codes[1];
  elsif v_sku is not null then
    -- [192] grupo = canónico (mos.productos, EXCLUYE PRESENTACION) ∪ equivalentes activos (mos.equivalencias).
    select coalesce(array_agg(distinct cb), array[]::text[]) into v_codes
      from (
        select upper(btrim(pr.codigo_barra)) cb
          from mos.productos pr
         where pr.sku_base = v_sku
           and nullif(btrim(pr.codigo_barra),'') is not null
           and pr.tipo_producto::text is distinct from 'PRESENTACION'
        union
        select upper(btrim(e.codigo_barra))
          from mos.equivalencias e
         where e.sku_base = v_sku
           and coalesce(e.activo,true)
           and nullif(btrim(e.codigo_barra),'') is not null
      ) t;
    if coalesce(array_length(v_codes,1),0) = 0 then
      return jsonb_build_object('ok',false,'error','skuBase sin codigo_barra (canónico/equivalente) en catálogo');
    end if;
    v_cod := v_codes[1];
  else
    return jsonb_build_object('ok',false,'error','Requiere codBarra, cod o skuBase');
  end if;

  -- TOTAL (combinado del conjunto consultado: el grupo entero, o el único código si vino cod/codBarra/pestaña).
  v_total := me._kardex_reconstruir(v_zona, v_codes);

  -- [193] PESTAÑAS POR CÓDIGO — sólo cuando se consulta el grupo por skuBase y hay MÁS DE UN código.
  --   Cada código se reconstruye INDEPENDIENTE (su propio saldo/cuadre vs su stock_zonas). El front pinta una
  --   pestaña por cada entrada + la pestaña "Total" (la raíz de esta respuesta). 1 código → sin porCodigo.
  if v_pestana is null and v_cod is not null and coalesce(array_length(v_codes,1),0) > 1
     and v_sku is not null then
    foreach v_one in array v_codes loop
      v_one_data := me._kardex_reconstruir(v_zona, array[v_one]);
      -- descripción + esEquivalente del código (catálogo: equivalencia tiene prioridad de etiqueta de equiv).
      select e.es_eq, e.descripcion into v_es_eq, v_desc from (
        select true as es_eq, nullif(btrim(eq.descripcion),'') as descripcion, 1 as ord
          from mos.equivalencias eq
         where upper(btrim(eq.codigo_barra)) = v_one and coalesce(eq.activo,true)
        union all
        select false, nullif(btrim(pr.descripcion),''), 0
          from mos.productos pr
         where upper(btrim(pr.codigo_barra)) = v_one
        order by ord desc limit 1
      ) e;
      v_porcod := v_porcod || jsonb_build_object(
        v_one,
        jsonb_build_object(
          'codBarra',       v_one,
          'esEquivalente',  coalesce(v_es_eq,false),
          'descripcion',    coalesce(v_desc, v_one),
          'totalMovimientos', v_one_data->'totalMovimientos',
          'saldoFinal',     v_one_data->'saldoFinal',
          'stockZonas',     v_one_data->'stockZonas',
          'cuadra',         v_one_data->'cuadra',
          'movimientos',    v_one_data->'movimientos'));
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'cod', v_pestana,                              -- eco del filtro de pestaña (null si Total/grupo)
      'reconstruido', true,
      'totalMovimientos', v_total->'totalMovimientos',
      'saldoFinal',  v_total->'saldoFinal',
      'stockZonas',  v_total->'stockZonas',
      'cuadra',      v_total->'cuadra',
      'movimientos', v_total->'movimientos',
      'porCodigo',   case when v_porcod = '{}'::jsonb then null else v_porcod end))
    || mos._frescura_sombra();
end;
$function$;
revoke all on function me.zona_kardex_historial(jsonb) from public;
grant execute on function me.zona_kardex_historial(jsonb) to service_role, authenticated;
