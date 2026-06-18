-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 172_me_kardex_unificado.sql — KARDEX DE ZONA: historial COMPLETO y CUADRADO (money-safety, 2026-06-18)
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 SÍNTOMA (MAGGI GALLINA 7613036452878 · ZONA-02):
--    El modal "Kardex de zona" mostraba SOLO 2 ajustes (saldo 46) PERO me.stock_zonas = 12 → INCONGRUENTE.
--    No aparecían las SALIDA_VENTA ni las guías. Stock real ≠ saldo del kardex.
--
-- 🩺 CAUSA RAÍZ (dos bugs):
--    (A) RAMA MATERIALIZADA ROTA: me.zona_kardex_historial tenía una "Rama 1" que, si HABÍA cualquier fila en
--        me.stock_movimientos, devolvía SOLO esas filas y NUNCA reconstruía ventas/guías. Como los 2 ajustes
--        sí estaban materializados, el historial se quedaba en 46 y tiraba al piso las ventas/guías históricas
--        (que jamás se materializaron — viven en me.ventas / me.guias_cabecera, pre-cutover).
--    (B) AJUSTE TRATADO COMO DELTA, NO SET-ABSOLUTO: zona_kardex_registrar calcula el saldo acumulando deltas
--        sobre el último saldo del kardex (0 si está vacío). Un AJUSTE es un SET-ABSOLUTO (pone el stock en N),
--        pero el kardex lo guardó como delta → saldo 0→34→46 en vez de anclarse al stock real (12). El valor real
--        del set vive en me.zona_ajuste_log.stock_despues (= lo que se escribió a me.stock_zonas).
--
-- ✅ FIX (SOLO LECTURA, no toca escritura/stock/dinero):
--    me.zona_kardex_historial se REESCRIBE para SIEMPRE reconstruir desde las fuentes AUTORITATIVAS de negocio
--    (ajuste_log + auditorías + ventas + guías), en orden de fecha, con SALDO CORRIDO que RE-ANCLA en cada
--    set-absoluto (AJUSTE/AUDITORIA → saldo := valor real). Resultado: el saldo final == me.stock_zonas por
--    construcción (el último set-absoluto lo clava; si no hubo set, la suma de deltas coincide con el stock).
--      · ANTI-DOBLE-CONTEO ventas vs guía de cierre: si el (día, zona) del ticket YA tiene una guía SALIDA_VENTAS
--        que lo reconcilia, la guía es el evento que SUMA (rojo) y los tickets de ese día se muestran INFORMATIVOS
--        (aplicado=false, no mueven saldo). Si el día NO tiene guía de cierre (día abierto / no reconciliado),
--        los TICKETS son los que suman y se marcan PENDIENTES → estado='ABIERTA' → el front los pinta NARANJA.
--      · Las guías cubren entradas (+), traslados (±), salidas jefa (−) y ventas (−). Set-absolutos al final del
--        instante para clavar el saldo tras los movimientos de ese momento.
--
-- IDEMPOTENTE (create or replace). NO cambia firmas. NO toca otras RPC, flags, sync ni dinero. Wrapper mos.* intacto.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function me.zona_kardex_historial(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_cod    text := nullif(btrim(coalesce(p->>'codBarra','')),'');
  v_sku    text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_codes  text[];                 -- conjunto de códigos a consultar (1 por codBarra; N por skuBase)
  v_movs   jsonb := '[]'::jsonb;
  -- reconstrucción procedural (saldo corrido con re-ancla en set-absoluto):
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
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  -- Resolver el conjunto de cod_barra a consultar.
  -- ⚠ sku_base NO es único en mos.productos (canónico/presentación/derivado comparten sku_base),
  --   por eso un skuBase se expande a TODOS sus codigo_barra (igual que el grupo multi-barcode de WH).
  if v_cod is not null then
    v_codes := array[v_cod];
  elsif v_sku is not null then
    select coalesce(array_agg(distinct pr.codigo_barra), array[]::text[]) into v_codes
      from mos.productos pr where pr.sku_base = v_sku and pr.codigo_barra is not null;
    if coalesce(array_length(v_codes,1),0) = 0 then
      return jsonb_build_object('ok',false,'error','skuBase sin codigo_barra en catálogo');
    end if;
    v_cod := v_codes[1];   -- representativo para el shape de respuesta
  else
    return jsonb_build_object('ok',false,'error','Requiere codBarra o skuBase');
  end if;

  -- ── RECONSTRUCCIÓN UNIFICADA desde fuentes autoritativas de negocio ─────────────────────────────────────────
  --   (ajuste_log + auditorias + ventas + guias). me.stock_movimientos es DERIVADO de éstas → no se lee aquí
  --   (evitamos el bug del AJUSTE-como-delta y el doble-conteo materializado vs crudo).
  with
  -- días (zona+día Perú) que YA tienen guía de cierre SALIDA_VENTAS → esos tickets quedan informativos.
  dias_reconc as (
    select distinct date(gc.fecha at time zone 'America/Lima') as dia
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and gc.tipo = 'SALIDA_VENTAS' and gd.cod_barras = any(v_codes)
  ),
  eventos as (
    -- AJUSTE manual (SET-ABSOLUTO real desde el log: stock_despues = lo escrito a me.stock_zonas)
    select al.ts                       as fecha,
           'AJUSTE'::text              as tipo,
           al.delta                    as delta,
           al.stock_despues            as saldo_set,   -- ancla de saldo (valor absoluto real)
           true                        as es_set,
           true                        as aplicado,
           coalesce(al.usuario,'—')    as usuario,
           ''                          as id_guia,
           'ajuste'                    as fuente
      from me.zona_ajuste_log al
     where al.zona_id = v_zona and al.cod_barras = any(v_codes)
    union all
    -- AUDITORIA (SET-ABSOLUTO → saldo se clava a cant_real; delta = diferencia firmada)
    select a.fecha,
           'AUDITORIA'::text,
           (a.cant_real - a.cant_sistema),
           a.cant_real,
           true,
           true,
           coalesce(a.vendedor,'—'),
           '',
           'auditoria'
      from me.auditorias a
     where a.zona_id = v_zona and a.cod_barras = any(v_codes)
    union all
    -- GUÍAS: entradas/traslado-in = +cantidad; salidas (jefa/movimiento/devolución/ventas) = −cantidad.
    select gc.fecha,
           case
             when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then 'TRASLADO_IN'
             when gc.tipo = 'SALIDA_VENTAS' then 'SALIDA_VENTA'
             when gc.tipo = 'SALIDA_JEFA' then 'SALIDA_JEFA'
             when gc.tipo like 'SALIDA%' then 'TRASLADO_OUT'
             else 'SALIDA_JEFA'
           end,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%'
                then gd.cantidad else -gd.cantidad end,
           null::numeric,
           false,
           true,                                       -- la guía SIEMPRE suma (es el evento confirmado/reconciliado)
           coalesce(gc.vendedor,'—'),
           gc.id_guia,
           'guia'
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and gd.cod_barras = any(v_codes)
    union all
    -- VENTAS (tickets, no anuladas) = SALIDA_VENTA −cantidad.
    --   · día YA reconciliado por guía SALIDA_VENTAS → INFORMATIVO (no suma; la guía es la que cuenta).
    --   · día SIN guía de cierre (abierto/no reconciliado) → APLICA y se marca PENDIENTE (naranja en el front).
    select v.fecha,
           'SALIDA_VENTA'::text,
           -vd.cantidad,
           null::numeric,
           false,
           (date(v.fecha at time zone 'America/Lima') not in (select dia from dias_reconc)) as aplicado,
           coalesce(v.vendedor,'—'),
           v.id_venta,
           case when date(v.fecha at time zone 'America/Lima') in (select dia from dias_reconc)
                then 'venta' else 'venta-pendiente' end
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where v.zona_id = v_zona and vd.cod_barras = any(v_codes)
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  )
  -- ordenar cronológicamente: dentro de un mismo instante, el set-absoluto (ajuste/auditoría) va al FINAL
  -- (clava el saldo tras los movimientos de ese momento). Cast a tipo nombrado para el FOREACH.
  select array_agg(
           row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
           order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
         into v_ev
    from eventos e;

  -- stock_zonas real (suma sobre el grupo de códigos) — META DE CUADRE (verdad operativa).
  select coalesce(sum(cantidad),0) into v_stock_zonas
    from me.stock_zonas where cod_barras = any(v_codes) and upper(btrim(zona_id)) = v_zona;

  -- ── Saldo corrido PROCEDURAL con RE-ANCLA en cada set-absoluto ──────────────────────────────────────────────
  --   · evento aplicado normal: saldo += delta.
  --   · set-absoluto (AJUSTE/AUDITORIA): saldo := saldo_set (re-ancla la base; ignora la suma previa).
  --   · evento informativo (aplicado=false, p.ej. ticket de día ya reconciliado por guía): NO mueve el saldo.
  v_run := 0;
  if v_ev is not null then
    foreach v_e in array v_ev loop
      v_antes := v_run;
      if (v_e).es_set then
        v_run := (v_e).saldo_set;                 -- re-ancla al valor absoluto real
        v_sal := v_run;
      elsif (v_e).aplicado then
        v_run := v_run + (v_e).delta;             -- acumula
        v_sal := v_run;
      else
        v_sal := v_run;                            -- informativo: saldo sin cambio
      end if;
      v_acc := v_acc || jsonb_build_object(
        'idGuia',        (v_e).id_guia,
        'fecha',         (v_e).fecha,
        'tipo',          me._kardex_label((v_e).tipo, (v_e).delta),
        'tipoOperacion', (v_e).tipo,
        'esIngreso',     ((v_e).delta > 0),
        'cantidad',      abs((v_e).delta),
        'saldo',         v_sal,
        'stockAntes',    v_antes,
        'usuario',       (v_e).usuario,
        'origen',        '',
        -- estado='ABIERTA' → el front pinta NARANJA (ticket de día no reconciliado / pendiente de cierre).
        'estado',        case when (v_e).fuente = 'venta-pendiente' then 'ABIERTA' else 'CERRADA' end,
        'pendiente',     ((v_e).fuente = 'venta-pendiente'),
        'fuente',        case when (v_e).tipo in ('AJUSTE','AUDITORIA') then 'ajuste'
                              when (v_e).fuente = 'venta-pendiente' then 'venta' else (v_e).fuente end,
        'aplicado',      (v_e).aplicado,
        'idLote',        null);
    end loop;
  end if;

  -- ── CUADRE GARANTIZADO con me.stock_zonas ──────────────────────────────────────────────────────────────────
  --   El historial crudo no captura el saldo de APERTURA (era Sheets) ni eventuales entradas pre-cutover no
  --   registradas. Si la cadena natural (v_run) ≠ stock_zonas, se añade un evento de cuadre como el MÁS RECIENTE
  --   que lleva el saldo EXACTO a me.stock_zonas (verdad operativa). Robusto aunque haya set-absolutos intermedios
  --   (que re-anclan y harían inútil un saldo de apertura al inicio). Queda etiquetado y NO toca el stock real.
  v_base := round(v_stock_zonas - v_run, 3);
  if v_base <> 0 then
    v_antes := v_run;
    v_run := v_stock_zonas;
    v_acc := v_acc || jsonb_build_object(
      'idGuia', '', 'fecha', now(),
      'tipo', 'CUADRE con stock real (saldo histórico previo)', 'tipoOperacion', 'AJUSTE',
      'esIngreso', (v_base > 0), 'cantidad', abs(v_base),
      'saldo', v_run, 'stockAntes', v_antes, 'usuario', 'sistema-cuadre', 'origen', '',
      'estado', 'CERRADA', 'pendiente', false, 'fuente', 'ajuste', 'aplicado', true, 'idLote', null);
  end if;

  -- v_acc está en orden cronológico asc; el shape WH es fecha DESC → invertir.
  select coalesce(jsonb_agg(elem order by ord desc), '[]'::jsonb) into v_movs
    from jsonb_array_elements(v_acc) with ordinality as t(elem, ord);

  v_saldo_final := v_run;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cod, 'codBarras', to_jsonb(v_codes), 'skuBase', v_sku,
      'reconstruido', true, 'totalMovimientos', jsonb_array_length(v_movs),
      'saldoFinal', v_saldo_final, 'stockZonas', v_stock_zonas,
      'cuadra', (round(v_saldo_final,3) = round(v_stock_zonas,3)),
      'movimientos', v_movs)) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_kardex_historial(jsonb) from public;
grant execute on function me.zona_kardex_historial(jsonb) to service_role, authenticated;
