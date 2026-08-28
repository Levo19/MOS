-- 960_me_kardex_recepciones_visibles.sql — HISTORIAL: mostrar las recepciones por escaneo WH→ME
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBLEMA: me._kardex_reconstruir arma el historial desde 4 fuentes (ajuste_log + auditorías + guías + ventas)
-- y NO lee me.stock_movimientos. Las recepciones por escaneo (recibir_guia_wh_cerrar) escriben SOLO en
-- me.stock_movimientos (TRASLADO_IN, ref_id 'TRASLADO-WH:<idGuiaWH>:<linea>') y NO crean fila en me.guias →
-- eran INVISIBLES en el historial (25 de 30 recientes), tapadas por el evento sintético "CUADRE con stock real".
--
-- FIX: agregar una 5ª fuente al reconstruir = las recepciones 'TRASLADO-WH:' de me.stock_movimientos, DEDUP contra
-- las guías ENTRADA (mismo código + mismo día) para no duplicar las que ya salen por guía. El id_guia del evento
-- = el idGuiaWH (para poder abrir el documento después). El saldo final sigue anclado a stock_zonas (CUADRE),
-- así que esto NO cambia el número final — solo hace VISIBLE el ingreso que antes se escondía.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me._kardex_reconstruir(v_zona text, v_codes text[])
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
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

  with
  dias_reconc as (
    select distinct date(gc.fecha at time zone 'America/Lima') as dia
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and gc.tipo = 'SALIDA_VENTAS' and upper(btrim(gd.cod_barras)) = any(v_codes)
  ),
  eventos as (
    -- AJUSTE manual (SET-ABSOLUTO real)
    select al.ts as fecha, 'AJUSTE'::text as tipo, al.delta as delta, al.stock_despues as saldo_set,
           true as es_set, true as aplicado, coalesce(al.usuario,'—') as usuario, '' as id_guia, 'ajuste' as fuente
      from me.zona_ajuste_log al
     where al.zona_id = v_zona and upper(btrim(al.cod_barras)) = any(v_codes)
    union all
    -- AUDITORIA (SET-ABSOLUTO)
    select a.fecha, 'AUDITORIA'::text, (a.cant_real - a.cant_sistema), a.cant_real,
           true, true, coalesce(a.vendedor,'—'), '', 'auditoria'
      from me.auditorias a
     where a.zona_id = v_zona and upper(btrim(a.cod_barras)) = any(v_codes)
    union all
    -- GUÍAS (entradas +, salidas −)
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
    -- VENTAS (tickets, no anuladas)
    select v.fecha, 'SALIDA_VENTA'::text, -vd.cantidad, null::numeric, false,
           (date(v.fecha at time zone 'America/Lima') not in (select dia from dias_reconc)) as aplicado,
           coalesce(v.vendedor,'—'), v.id_venta,
           case when date(v.fecha at time zone 'America/Lima') in (select dia from dias_reconc)
                then 'venta' else 'venta-pendiente' end
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where v.zona_id = v_zona and upper(btrim(vd.cod_barras)) = any(v_codes)
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
    union all
    -- [960] RECEPCIONES por escaneo WH→ME (me.stock_movimientos 'TRASLADO-WH:'; NO crean me.guias).
    --   DEDUP: se excluye si ya hay una guía ENTRADA para el mismo código en el mismo día (para no duplicar
    --   las recepciones que sí generaron guía). id_guia del evento = idGuiaWH (split del ref_id) → abrible.
    select sm.fecha,
           case when sm.delta >= 0 then 'TRASLADO_IN' else 'TRASLADO_OUT' end,
           sm.delta, null::numeric, false, true,
           coalesce(sm.usuario,'—'), split_part(sm.ref_id, ':', 2), 'recepcion'
      from me.stock_movimientos sm
     where sm.ambito = 'ZONA' and upper(btrim(sm.zona_id)) = v_zona
       and upper(btrim(sm.cod_barra)) = any(v_codes)
       and sm.ref_id like 'TRASLADO-WH:%'
       and coalesce(sm.delta,0) <> 0
       and not exists (
         select 1 from me.guias_detalle gd2
           join me.guias_cabecera gc2 on gc2.id_guia = gd2.id_guia
          where gc2.zona_id = v_zona
            and upper(btrim(gd2.cod_barras)) = upper(btrim(sm.cod_barra))
            and (gc2.tipo like 'ENTRADA%' or gc2.tipo like 'TRASLADO_IN%')
            and date(gc2.fecha at time zone 'America/Lima') = date(sm.fecha at time zone 'America/Lima'))
  )
  select array_agg(
           row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
           order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
         into v_ev
    from eventos e;

  select coalesce(sum(cantidad),0) into v_stock_zonas
    from me.stock_zonas where upper(btrim(cod_barras)) = any(v_codes) and upper(btrim(zona_id)) = v_zona;

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
$function$;

select 'kardex recepciones visibles listo' ok;
