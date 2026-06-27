-- ============================================================
-- 265_review500_fix_anulado_prefix.sql
-- [FIX MONEY-CRÍTICO · C2 de la revisión 500x · DOUBLE-COUNTING en conversión NV→CPE]
-- ============================================================
--
-- ── EL BUG (C2, confirmado en vivo) ──────────────────────────────────────────────────────────────────
-- La conversión NV→CPE (GAS convertirNVaCPE → _dualWriteVentaPatchME) marca la Nota de Venta ORIGINAL
-- con forma_pago = 'ANULADO_CONVERSION' en la sombra me.ventas, y crea un CPE de reemplazo (BOLETA/FACTURA,
-- forma_pago real EFECTIVO/VIRTUAL/etc).
--
-- Las 3 RPC de lectura de DINERO que MOS consume DIRECTO de Supabase detectan "anulado" por IGUALDAD EXACTA:
--     · mos.cierres_caja      → estado := case when upper(forma_pago) in ('ANULADO','CREDITO') ...
--     · mos.finanzas_dia      → es_anulado := fp = 'ANULADO' ; es_cobrado := fp not in ('ANULADO',...)
--     · mos.finanzas_rango    → where upper(forma_pago) not in ('ANULADO','POR_COBRAR','CREDITO')
-- 'ANULADO_CONVERSION' NO matchea 'ANULADO' → la NV anulada se CUENTA como venta COBRADA/COMPLETADA →
-- DOBLE ingreso (NV vieja + CPE de reemplazo, ambas contadas) en arqueo (cierres_caja) y P&L (finanzas).
-- Sólo cerrar_caja_efectos ya usa el prefijo `not like 'ANULADO%'` (por eso el STOCK sí queda bien; el
-- DINERO no). Hoy hay 0 filas 'ANULADO_CONVERSION' (139 'ANULADO' planas) → aún no dispara, pero es CIERTO
-- en la primera conversión por GAS.
--
-- ── EL FIX ───────────────────────────────────────────────────────────────────────────────────────────
-- Unificar la detección de anulado a PREFIJO `upper(coalesce(forma_pago,'')) like 'ANULADO%'` en las 3 RPC,
-- exactamente como cerrar_caja_efectos. Así 'ANULADO_CONVERSION' (y cualquier 'ANULADO_*') queda EXCLUIDO
-- del ingreso/arqueo igual que 'ANULADO'. El CPE de reemplazo (forma_pago EFECTIVO/etc, tipo_doc BOLETA)
-- SIGUE contando — sólo cambia la clasificación de la NV anulada.
--
-- ── SEGURIDAD del cambio ─────────────────────────────────────────────────────────────────────────────
-- Verificado contra prod (2026-06-27): el ÚNICO valor de me.ventas.forma_pago que empieza con 'ANULADO'
-- es 'ANULADO' (139 filas). NINGÚN valor legítimo no-anulado empieza con 'ANULADO' (set válido:
-- EFECTIVO/VIRTUAL/CREDITO/POR_COBRAR/MIXTO (…)/ANULADO/ANULADO_CONVERSION). El prefijo NO captura falsos
-- positivos. CREDITO y POR_COBRAR se mantienen por igualdad EXACTA (no se tocan).
--
-- Cada función se redefine 1:1 contra su definición VIVA (pg_get_functiondef), cambiando ÚNICAMENTE los
-- puntos de clasificación de forma_pago a prefijo. Todo lo demás (CTEs, redondeos, TZ, gates, grants)
-- queda byte-por-byte idéntico.
--
-- ⚠️ NO APLICAR sin revisión. Migración independiente, idempotente (CREATE OR REPLACE).
--
-- Paridad GAS pendiente (NO incluida aquí — reportada aparte): MosExpress/gas/Finanzas.gs
--   _parseFormaPagoFin (~457) y _calcularIngresos (~484) deben usar prefijo de la misma forma.
-- ============================================================

create schema if not exists mos;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- (1) mos.cierres_caja — arqueo / cierres de caja.
--   CAMBIO: la derivación de `estado` (2 lugares: CTE `ventas` y recompute de kpisTickets) pasa el
--   branch ANULADO a prefijo y normaliza a 'ANULADO'. CREDITO/POR_COBRAR exactos sin cambio.
--     ANTES: when upper(forma_pago) in ('ANULADO','CREDITO') then upper(forma_pago)
--     AHORA: when upper(forma_pago) like 'ANULADO%' then 'ANULADO'
--            when upper(forma_pago) = 'CREDITO'     then 'CREDITO'
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.cierres_caja(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_tz        text := 'America/Lima';
  v_hoy       date := (now() at time zone v_tz)::date;
  v_limite    timestamptz := now() - interval '30 days';
  v_me_url    text;
  v_out       jsonb;
  v_kt        jsonb;
  v_kpis      jsonb;
  v_abiertas  jsonb;
  v_cerradas  jsonb;
  v_todos     jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  begin
    select valor into v_me_url from mos.config where clave = 'ME_GAS_URL' limit 1;
  exception when others then v_me_url := null;
  end;
  v_me_url := coalesce(v_me_url, '');

  with
  cajas_map as (
    select c.id_caja,
           coalesce(c.vendedor,'')                          as vendedor,
           coalesce(nullif(c.zona_id,''), coalesce(c.estacion,'')) as zona
    from me.cajas c
  ),
  ventas_raw as (
    select
      coalesce(v.id_caja,'')                                as id_caja,
      coalesce(v.forma_pago,'EFECTIVO')                     as forma_pago,
      coalesce(v.tipo_doc,'NOTA_DE_VENTA')                  as tipo_doc,
      coalesce(v.total,0)::numeric                          as total,
      v.fecha                                               as fecha_ts,
      v.id_venta, v.correlativo, v.cliente_doc, v.cliente_nombre, v.obs,
      v.created_at
    from me.ventas v
    where v.fecha is null or v.fecha >= v_limite
  ),
  ventas as (
    select vr.*,
      -- estado derivado de forma_pago (regla en piedra) — ANULADO por PREFIJO (C2)
      case
        when upper(vr.forma_pago) like 'ANULADO%' then 'ANULADO'
        when upper(vr.forma_pago) = 'CREDITO'     then 'CREDITO'
        when upper(vr.forma_pago) = 'POR_COBRAR'  then 'POR_COBRAR'
        else 'COMPLETADO'
      end                                                   as estado,
      case upper(vr.tipo_doc)
        when 'BOLETA'  then 'B'
        when 'FACTURA' then 'F'
        else 'NV'
      end                                                   as tipo,
      case when vr.fecha_ts is not null
           then to_char(vr.fecha_ts at time zone v_tz, 'YYYY-MM-DD') else '' end as fecha,
      case when vr.fecha_ts is not null
           then to_char(vr.fecha_ts at time zone v_tz, 'HH24:MI')    else '' end as hora
    from ventas_raw vr
  ),
  ventas_calc as (
    select vt.*,
      cm.vendedor as cm_vendedor,
      coalesce(cm.zona,'') as cm_zona,
      case
        when vt.estado <> 'COMPLETADO' then 0
        when upper(vt.forma_pago) = 'EFECTIVO' then vt.total
        when upper(vt.forma_pago) like 'MIXTO%' then
          coalesce((substring(vt.forma_pago from 'EFE:([0-9.]+)'))::numeric, 0)
        else 0
      end                                                   as efe,
      case
        when vt.estado <> 'COMPLETADO' then 0
        when upper(vt.forma_pago) = 'EFECTIVO' then 0
        when upper(vt.forma_pago) like 'MIXTO%' then
          coalesce(
            (substring(vt.forma_pago from 'VIR:([0-9.]+)'))::numeric,
            vt.total - coalesce((substring(vt.forma_pago from 'EFE:([0-9.]+)'))::numeric, 0)
          )
        else vt.total
      end                                                   as vir
    from ventas vt
    left join cajas_map cm on cm.id_caja = vt.id_caja
  ),
  vpc as (
    select id_caja,
      round(sum(case when estado='COMPLETADO' then total else 0 end), 2) as total,
      sum(case when estado in ('COMPLETADO','POR_COBRAR') then 1 else 0 end) as tickets,
      round(sum(efe), 2)                                                  as efectivo,
      round(sum(vir), 2)                                                  as otros,
      sum(case when estado='ANULADO'     then 1 else 0 end)               as anulados,
      sum(case when estado='POR_COBRAR'  then 1 else 0 end)               as sin_cobrar
    from ventas_calc
    where id_caja <> ''
    group by id_caja
  ),
  vpc_metodo as (
    select id_caja, jsonb_object_agg(forma_pago, t) as by_metodo
    from (
      select id_caja, forma_pago, round(sum(total),2) as t
      from ventas_calc where id_caja <> '' and estado='COMPLETADO'
      group by id_caja, forma_pago
    ) m group by id_caja
  ),
  vpc_doc as (
    select id_caja, jsonb_object_agg(tipo_doc, t) as by_doc
    from (
      select id_caja, tipo_doc, round(sum(total),2) as t
      from ventas_calc where id_caja <> '' and estado='COMPLETADO'
      group by id_caja, tipo_doc
    ) d group by id_caja
  ),
  tk as (
    select vc.id_caja, vc.fecha, vc.hora, vc.created_at, vc.id_venta,
      jsonb_build_object(
        'idVenta',     coalesce(vc.id_venta,''),
        'fecha',       vc.fecha,
        'hora',        vc.hora,
        'correlativo', coalesce(vc.correlativo,''),
        'clienteDoc',  coalesce(vc.cliente_doc,''),
        'clienteNom',  coalesce(vc.cliente_nombre,''),
        'total',       vc.total,
        'tipoDoc',     vc.tipo_doc,
        'tipo',        vc.tipo,
        'metodo',      vc.forma_pago,
        'estado',      vc.estado,
        'obs',         coalesce(vc.obs,''),
        'idCaja',      vc.id_caja,
        'vendedor',    coalesce(vc.cm_vendedor,''),
        'zona',        vc.cm_zona
      ) as obj
    from ventas_calc vc
  ),
  tlist as (
    select id_caja,
      coalesce(jsonb_agg(obj order by created_at desc nulls last, id_venta desc), '[]'::jsonb) as tickets_list
    from tk where id_caja <> ''
    group by id_caja
  ),
  todos as (
    select coalesce(jsonb_agg(obj order by (fecha||hora) desc, id_venta desc), '[]'::jsonb) as arr
    from tk
  ),
  ext_raw as (
    select coalesce(e.id_caja,'')        as id_caja,
           coalesce(e.tipo,'EGRESO')     as tipo,
           coalesce(e.monto,0)::numeric  as monto,
           coalesce(e.concepto,'')       as concepto,
           e.ts, e.id_extra, e.created_at
    from me.movimientos_extra e
    where coalesce(e.id_caja,'') <> ''
  ),
  epc as (
    select id_caja,
      sum(case when tipo='INGRESO' then monto else 0 end) as entradas,
      sum(case when tipo='EGRESO'  then monto else 0 end) as salidas
    from ext_raw group by id_caja
  ),
  elist as (
    select id_caja,
      coalesce(jsonb_agg(
        jsonb_build_object(
          'idExtra',  coalesce(id_extra,''),
          'tipo',     tipo,
          'monto',    monto,
          'concepto', concepto,
          'hora',     case when ts is not null then to_char(ts at time zone v_tz,'HH24:MI') else '' end
        ) order by created_at asc nulls last, id_extra asc
      ), '[]'::jsonb) as extras_list
    from ext_raw group by id_caja
  ),
  cajas_obj as (
    select
      c.id_caja,
      coalesce(c.estado,'')                                 as estado,
      c.fecha_apertura, c.fecha_cierre,
      coalesce(c.monto_inicial,0)::numeric                  as monto_inicial,
      coalesce(c.monto_final,0)::numeric                    as monto_final,
      coalesce(vpc.total,0)::numeric                        as v_total,
      coalesce(vpc.tickets,0)::int                          as v_tickets,
      coalesce(vpc.efectivo,0)::numeric                     as v_efectivo,
      coalesce(vpc.otros,0)::numeric                        as v_otros,
      coalesce(vpc.anulados,0)::int                         as v_anulados,
      coalesce(vpc.sin_cobrar,0)::int                       as v_sin_cobrar,
      coalesce(vm.by_metodo, '{}'::jsonb)                   as by_metodo,
      coalesce(vd.by_doc, '{}'::jsonb)                       as by_doc,
      coalesce(epc.entradas,0)::numeric                     as entradas,
      coalesce(epc.salidas,0)::numeric                      as salidas,
      coalesce(tl.tickets_list,'[]'::jsonb)                 as tickets_list,
      coalesce(el.extras_list,'[]'::jsonb)                  as extras_list,
      coalesce(c.vendedor,'')                               as vendedor,
      coalesce(c.estacion,'')                               as estacion,
      coalesce(c.zona_id,'')                                as zona
    from me.cajas c
    left join vpc        on vpc.id_caja = c.id_caja
    left join vpc_metodo vm on vm.id_caja = c.id_caja
    left join vpc_doc    vd on vd.id_caja = c.id_caja
    left join epc        on epc.id_caja = c.id_caja
    left join tlist      tl on tl.id_caja = c.id_caja
    left join elist      el on el.id_caja = c.id_caja
    where not (coalesce(c.estado,'')='CERRADA' and (c.fecha_cierre is null or c.fecha_cierre < v_limite))
  ),
  cajas_full as (
    select
      co.*,
      round(co.monto_inicial + co.v_efectivo + co.entradas - co.salidas, 2) as efectivo_esperado,
      case when co.estado='CERRADA'
           then round(co.monto_final - (co.monto_inicial + co.v_efectivo + co.entradas - co.salidas), 2)
           else null end                                                    as diferencia,
      case when co.fecha_apertura is not null
           then to_char(co.fecha_apertura at time zone v_tz,'YYYY-MM-DD HH24:MI') else '' end as f_apert,
      case when co.fecha_cierre is not null
           then to_char(co.fecha_cierre   at time zone v_tz,'YYYY-MM-DD HH24:MI') else '' end as f_cierr
    from cajas_obj co
  ),
  cajas_json as (
    select cf.*,
      jsonb_build_object(
        'idCaja',           cf.id_caja,
        'vendedor',         cf.vendedor,
        'estacion',         cf.estacion,
        'zona',             cf.zona,
        'estado',           cf.estado,
        'fechaApertura',    cf.f_apert,
        'fechaCierre',      cf.f_cierr,
        'montoInicial',     cf.monto_inicial,
        'montoFinal',       cf.monto_final,
        'totalVentas',      round(cf.v_total,2),
        'tickets',          cf.v_tickets,
        'efectivo',         round(cf.v_efectivo,2),
        'otros',            round(cf.v_otros,2),
        'anulados',         cf.v_anulados,
        'sinCobrar',        cf.v_sin_cobrar,
        'byMetodo',         cf.by_metodo,
        'byDoc',            cf.by_doc,
        'entradas',         cf.entradas,
        'salidas',          cf.salidas,
        'efectivoEsperado', cf.efectivo_esperado,
        'diferencia',       cf.diferencia,
        'ticketsList',      cf.tickets_list,
        'extrasList',       cf.extras_list,
        'urlReporte',       case when v_me_url <> ''
                                 then v_me_url || '?accion=ver_cierre&id_caja=' || mos._urlenc(cf.id_caja)
                                 else '' end
      ) as obj
    from cajas_full cf
  )
  select
    coalesce((select jsonb_agg(obj order by id_caja)
                from cajas_json where estado='ABIERTA'), '[]'::jsonb),
    coalesce((select jsonb_agg(obj order by fecha_apertura desc nulls last, id_caja desc)
                from cajas_json where estado<>'ABIERTA'), '[]'::jsonb),
    (select arr from todos)
  into v_abiertas, v_cerradas, v_todos;

  select jsonb_build_object(
    'hoy', jsonb_build_object(
      'total',    count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO'),
      'NV',       count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO' and tipo='NV'),
      'B',        count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO' and tipo='B'),
      'F',        count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado<>'ANULADO' and tipo='F'),
      'anulados', count(*) filter (where fecha = to_char(v_hoy,'YYYY-MM-DD') and estado='ANULADO')
    ),
    'mes', jsonb_build_object(
      'total',    count(*) filter (where estado<>'ANULADO'),
      'NV',       count(*) filter (where estado<>'ANULADO' and tipo='NV'),
      'B',        count(*) filter (where estado<>'ANULADO' and tipo='B'),
      'F',        count(*) filter (where estado<>'ANULADO' and tipo='F'),
      'anulados', count(*) filter (where estado='ANULADO')
    )
  ) into v_kt
  from (
    select
      -- estado recomputado (mismas reglas que arriba) — ANULADO por PREFIJO (C2)
      case
        when upper(coalesce(v.forma_pago,'EFECTIVO')) like 'ANULADO%' then 'ANULADO'
        when upper(coalesce(v.forma_pago,'EFECTIVO')) = 'CREDITO'     then 'CREDITO'
        when upper(coalesce(v.forma_pago,'EFECTIVO')) = 'POR_COBRAR'  then 'POR_COBRAR'
        else 'COMPLETADO'
      end as estado,
      case upper(coalesce(v.tipo_doc,'NOTA_DE_VENTA'))
        when 'BOLETA' then 'B' when 'FACTURA' then 'F' else 'NV' end as tipo,
      case when v.fecha is not null then to_char(v.fecha at time zone v_tz,'YYYY-MM-DD') else '' end as fecha
    from me.ventas v
    where v.fecha is null or v.fecha >= v_limite
  ) ktv;

  with caja_elem as (
    select e as obj, true as es_abierta from jsonb_array_elements(v_abiertas) e
    union all
    select e as obj, false from jsonb_array_elements(v_cerradas) e
  ),
  caja_hoy as (
    select obj from caja_elem
    where es_abierta
       or left(coalesce(obj->>'fechaApertura',''), 10) = to_char(v_hoy,'YYYY-MM-DD')
       or left(coalesce(obj->>'fechaCierre','') , 10) = to_char(v_hoy,'YYYY-MM-DD')
  )
  select jsonb_build_object(
    'cajasAbiertas', jsonb_array_length(v_abiertas),
    'cajasCerradas', jsonb_array_length(v_cerradas),
    'totalDia',      round(coalesce(sum((obj->>'totalVentas')::numeric),0), 2),
    'ticketsDia',    coalesce(sum((obj->>'tickets')::int), 0),
    'anuladosDia',   coalesce(sum((obj->>'anulados')::int), 0),
    'sinCobrarDia',  coalesce(sum((obj->>'sinCobrar')::int), 0)
  ) into v_kpis
  from caja_hoy;

  v_out := jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'kpis',         v_kpis,
      'kpisTickets',  v_kt,
      'abiertas',     v_abiertas,
      'cerradas',     v_cerradas,
      'todosTickets', v_todos,
      'generadoEn',   to_char(now() at time zone v_tz, 'YYYY-MM-DD HH24:MI:SS')
    )
  ) || mos._frescura_sombra();

  return v_out;
end;
$fn$;

revoke all on function mos.cierres_caja(jsonb)     from public;
grant execute on function mos.cierres_caja(jsonb)  to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- (2) mos.finanzas_dia — P&L de un día.
--   CAMBIOS (todos forma_pago-classification a prefijo):
--     · clasif: es_anulado/no_anulado/es_cobrado → `fp like 'ANULADO%'` (antes `fp = 'ANULADO'` / `not in (...)`)
--     · detalleTickets.estado → `when fp like 'ANULADO%' then 'ANULADO'` (antes `fp='ANULADO'`)
--     · vcobr (COGS sólo de cobrados) → `not like 'ANULADO%'` (antes `not in ('ANULADO',...)`)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.finanzas_dia(p_fecha text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_margen numeric := 20;
  v_d      date;
  v_data   jsonb;
  v_hb     timestamptz;
  v_ttl    int;
  v_fresh  boolean;

  v_ventas_brutas      numeric := 0;
  v_total_efectivo     numeric := 0;
  v_total_virtual      numeric := 0;
  v_total_mixto        numeric := 0;
  v_porcobrar_monto    numeric := 0;
  v_credito_monto      numeric := 0;
  v_ventas_netas       numeric := 0;
  v_tickets            int := 0;
  v_tickets_totales    int := 0;
  v_porcobrar_n        int := 0;
  v_creditos_n         int := 0;
  v_anulados_n         int := 0;
  v_ticket_promedio    numeric := 0;
  v_bydoc              jsonb := '{}'::jsonb;
  v_bymetodo           jsonb;
  v_detalle_tickets    jsonb := '[]'::jsonb;

  v_costo_total        numeric := 0;
  v_costo_real         numeric := 0;
  v_costo_estimado     numeric := 0;
  v_items              int := 0;
  v_unidades           numeric := 0;
  v_skus_distintos     int := 0;
  v_sin_costo          jsonb := '[]'::jsonb;
  v_cant_estimados     int := 0;
  v_margen_prom_pct    numeric := 0;
  v_detalle_productos  jsonb := '[]'::jsonb;

  v_gasto_personal     numeric := 0;
  v_personas           int := 0;
  v_personal_detalle   jsonb := '[]'::jsonb;

  v_gasto_otros        numeric := 0;
  v_gastos_fijos       numeric := 0;
  v_gastos_variables   numeric := 0;
  v_gastos_bycat       jsonb := '{}'::jsonb;
  v_gastos_detalle     jsonb := '[]'::jsonb;

  v_utilidad_bruta     numeric := 0;
  v_total_gastos       numeric := 0;
  v_utilidad_neta      numeric := 0;
  v_margen_bruto_pct   numeric := 0;
  v_margen_neto_pct    numeric := 0;
  v_costos_fijos       numeric := 0;
  v_margen_contrib     numeric := 0;
  v_break_even_ventas  numeric;
  v_break_even_pct     numeric := 0;
  v_supera_be          boolean := false;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  if p_fecha is null or btrim(p_fecha) = '' then
    v_d := (now() at time zone 'America/Lima')::date;
  else
    begin
      v_d := p_fecha::date;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'Fecha inválida (YYYY-MM-DD)');
    end;
  end if;

  select valor::numeric into v_margen
  from mos.config
  where clave = 'finMargenDefault' and valor ~ '^[0-9]+(\.[0-9]+)?$';
  if v_margen is null or v_margen < 0 or v_margen >= 100 then v_margen := 20; end if;

  with del_dia as (
    select v.id_venta,
           coalesce(v.total,0)::numeric as total,
           upper(coalesce(v.forma_pago,'')) as fp,
           v.forma_pago,
           coalesce(nullif(v.tipo_doc,''),'NOTA_DE_VENTA') as tipo_doc,
           coalesce(v.vendedor,'') as vendedor,
           coalesce(v.correlativo,'') as correlativo,
           coalesce(v.cliente_nombre,'') as cliente_nombre,
           coalesce(v.cliente_doc,'') as cliente_doc,
           v.fecha
    from me.ventas v
    where (v.fecha at time zone 'America/Lima')::date = v_d
  ),
  clasif as (
    select d.*,
           (d.fp like 'ANULADO%')                                    as es_anulado,   -- C2: prefijo
           (d.fp not like 'ANULADO%')                                as no_anulado,   -- C2: prefijo
           (d.fp not like 'ANULADO%' and d.fp not in ('POR_COBRAR','CREDITO')) as es_cobrado,  -- C2: prefijo
           (d.fp = 'POR_COBRAR')                                     as es_porcobrar,
           (d.fp = 'CREDITO')                                        as es_credito
    from del_dia d
  ),
  cob as (
    select
      sum( case
             when fp='EFECTIVO' then total
             when fp='VIRTUAL'  then 0
             when fp like 'MIXTO%' then
               coalesce( (substring(upper(forma_pago) from 'EFE:([0-9.]+)'))::numeric,
                         round(total - coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0), 2) )
             else 0 end ) as tot_efe,
      sum( case
             when fp='EFECTIVO' then 0
             when fp='VIRTUAL'  then total
             when fp like 'MIXTO%' then coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0)
             else total end ) as tot_vir,
      sum( case when fp like 'MIXTO%' then total else 0 end ) as tot_mixto,
      count(*) as n_cobrados
    from clasif where es_cobrado
  )
  select
    coalesce((select mos._r2(sum(total)) from clasif where no_anulado), 0),
    coalesce((select tot_efe   from cob), 0),
    coalesce((select tot_vir   from cob), 0),
    coalesce((select tot_mixto from cob), 0),
    coalesce((select mos._r2(sum(total)) from clasif where es_porcobrar), 0),
    coalesce((select mos._r2(sum(total)) from clasif where es_credito), 0),
    coalesce((select n_cobrados from cob), 0),
    coalesce((select count(*)::int from clasif where no_anulado), 0),
    coalesce((select count(*)::int from clasif where es_porcobrar), 0),
    coalesce((select count(*)::int from clasif where es_credito), 0),
    coalesce((select count(*)::int from clasif where es_anulado), 0),
    coalesce((select jsonb_object_agg(tipo_doc, monto)
              from (select tipo_doc, mos._r2(sum(total)) as monto
                    from clasif where no_anulado group by tipo_doc) q), '{}'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'idVenta',     id_venta,
               'total',       total,
               'tipoDoc',     tipo_doc,
               'formaPago',   case when coalesce(forma_pago,'')='' then 'EFECTIVO' else forma_pago end,
               'estado',      case when fp like 'ANULADO%' then 'ANULADO'    -- C2: prefijo
                                   when fp='POR_COBRAR' then 'POR_COBRAR'
                                   when fp='CREDITO' then 'CREDITO'
                                   else 'COBRADO' end,
               'vendedor',    vendedor,
               'correlativo', correlativo,
               'cliente',     cliente_nombre,
               'clienteDoc',  cliente_doc,
               'hora',        to_char(fecha at time zone 'America/Lima', 'HH24:MI')
             ) order by to_char(fecha at time zone 'America/Lima', 'HH24:MI') desc)
      from clasif), '[]'::jsonb)
  into
    v_ventas_brutas, v_total_efectivo, v_total_virtual, v_total_mixto,
    v_porcobrar_monto, v_credito_monto,
    v_tickets, v_tickets_totales, v_porcobrar_n, v_creditos_n, v_anulados_n,
    v_bydoc, v_detalle_tickets;

  v_total_efectivo := mos._r2(v_total_efectivo);
  v_total_virtual  := mos._r2(v_total_virtual);
  v_total_mixto    := mos._r2(v_total_mixto);
  v_ventas_netas   := mos._r2(v_total_efectivo + v_total_virtual);
  v_ticket_promedio := case when v_tickets > 0 then mos._r2(v_ventas_netas / v_tickets) else 0 end;

  v_bymetodo := jsonb_build_object(
    'EFECTIVO',   v_total_efectivo,
    'VIRTUAL',    v_total_virtual,
    'MIXTO',      v_total_mixto,
    'POR_COBRAR', mos._r2(v_porcobrar_monto),
    'CREDITO',    mos._r2(v_credito_monto)
  );

  with vcobr as (
    select v.id_venta
    from me.ventas v
    where (v.fecha at time zone 'America/Lima')::date = v_d
      and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'           -- C2: prefijo
      and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
  ),
  det as (
    select upper(trim(d.sku)) as nsku_l,
           upper(trim(coalesce(d.cod_barras,''))) as ncod_l,
           coalesce(d.cantidad,0)::numeric as cantidad,
           coalesce(d.precio,0)::numeric as precio,
           d.sku as sku_raw, d.nombre as nombre_raw
    from me.ventas_detalle d
    join vcobr v on v.id_venta = d.id_venta
  ),
  m_id as (
    select distinct on (upper(trim(id_producto))) upper(trim(id_producto)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where id_producto is not null and trim(id_producto)<>''
    order by upper(trim(id_producto)), id_producto desc
  ),
  m_cod as (
    select distinct on (upper(trim(codigo_barra))) upper(trim(codigo_barra)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where codigo_barra is not null and trim(codigo_barra)<>''
    order by upper(trim(codigo_barra)), id_producto desc
  ),
  m_sku as (
    select distinct on (upper(trim(sku_base))) upper(trim(sku_base)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), id_producto asc
  ),
  canon as (
    select distinct on (upper(trim(sku_base)))
           upper(trim(sku_base)) nsku,
           coalesce(precio_costo,0)::numeric costo,
           coalesce(descripcion,'') descripcion,
           coalesce(codigo_barra,'') codigo_barra,
           coalesce(precio_venta,0)::numeric precio_venta
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), case when coalesce(factor_conversion,1)=1 then 0 else 1 end, id_producto
  ),
  det_res as (
    select dt.cantidad, dt.precio, dt.nombre_raw,
           coalesce(mi.factor, mc1.factor, mc2.factor, msk.factor, 1) as factor,
           coalesce(mi.nsku, mc1.nsku, mc2.nsku, msk.nsku) as nsku_match,
           coalesce(
             mi.nsku, mc1.nsku, mc2.nsku, msk.nsku,
             nullif(dt.nsku_l,''), nullif(dt.ncod_l,''),
             upper(left(trim(coalesce(dt.nombre_raw,'')),30))
           ) as grupo_sku
    from det dt
    left join m_id  mi  on mi.k  = dt.nsku_l
    left join m_cod mc1 on mc1.k = dt.nsku_l
    left join m_cod mc2 on mc2.k = dt.ncod_l
    left join m_sku msk on msk.k = dt.nsku_l
  ),
  lineas as (
    select dr.*,
           coalesce(cn.costo,0) as costo_canon_unit,
           (dr.cantidad * dr.factor) as unidades_base,
           (dr.precio * dr.cantidad) as ingreso_linea,
           coalesce(cn.descripcion,'') as canon_desc,
           coalesce(cn.codigo_barra,'') as canon_cod,
           coalesce(cn.precio_venta,0) as canon_precio,
           (cn.nsku is not null) as tiene_canon,
           case when coalesce(cn.costo,0) > 0
                then (dr.cantidad * dr.factor) * cn.costo
                else (dr.precio * dr.cantidad) * (1 - v_margen/100)
           end as costo_linea,
           (coalesce(cn.costo,0) <= 0) as es_estimado
    from det_res dr
    left join canon cn on cn.nsku = dr.nsku_match
  ),
  grp as (
    select grupo_sku,
           sum(unidades_base) as cantidad,
           sum(cantidad)      as cant_present,
           sum(ingreso_linea) as ingreso,
           bool_or(es_estimado) as es_estimado,
           (array_agg(costo_canon_unit) filter (where tiene_canon))[1] as costo_unit_canon,
           (array_agg(canon_desc)       filter (where tiene_canon))[1] as canon_desc,
           (array_agg(nombre_raw))[1] as nombre_fallback,
           (array_agg(canon_cod)        filter (where tiene_canon))[1] as canon_cod,
           (array_agg(canon_precio)     filter (where tiene_canon))[1] as canon_precio
    from lineas
    group by grupo_sku
  )
  select
    coalesce(mos._r2((select sum(costo_linea) from lineas)),0),
    coalesce(mos._r2((select sum(costo_linea) from lineas where not es_estimado)),0),
    coalesce(mos._r2((select sum(costo_linea) from lineas where es_estimado)),0),
    coalesce((select count(*)::int from det),0),
    coalesce((select round(sum(unidades_base))::numeric from lineas),0),
    coalesce((select count(*)::int from grp),0),
    coalesce((select jsonb_agg(grupo_sku) from grp where es_estimado), '[]'::jsonb),
    coalesce((select count(*)::int from grp where es_estimado),0),
    coalesce((
      select case when sum(ingreso_linea) > 0
        then round( ((sum(ingreso_linea)-sum(costo_linea))/sum(ingreso_linea)) * 1000 ) / 10.0
        else 0 end
      from lineas),0),
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku',            grupo_sku,
               'nombre',         coalesce(canon_desc, nombre_fallback),
               'cantidad',       round(cantidad*100)/100,
               'cantPresent',    round(cant_present*100)/100,
               'precio',         case when cantidad > 0 then mos._r2(ingreso/cantidad) else 0 end,
               'costoUnit',      mos._r2(coalesce(costo_unit_canon,0)),
               'costoTotal',     mos._r2(coalesce(costo_unit_canon,0) * cantidad),
               'esEstimado',     es_estimado,
               'sinCosto',       es_estimado,
               'codigoCanonico', coalesce(canon_cod,''),
               'precioCanonico', coalesce(canon_precio,0)
             ) order by cantidad desc)
      from grp), '[]'::jsonb)
  into
    v_costo_total, v_costo_real, v_costo_estimado, v_items, v_unidades,
    v_skus_distintos, v_sin_costo, v_cant_estimados, v_margen_prom_pct, v_detalle_productos;

  with liq as (
    select lower(trim(l.nombre)) as k,
           l.nombre,
           upper(coalesce(l.estado,'PENDIENTE')) as estado,
           case when coalesce(l.total_dia,0)>0 then l.total_dia::numeric else coalesce(l.monto_base,0)::numeric end as monto,
           coalesce(l.id_personal,'') as id_personal,
           coalesce(l.rol,'') as rol,
           coalesce(l.app_origen,'') as app_origen,
           l.id_dia
    from mos.liquidaciones_dia l
    where l.presente = true and l.nombre is not null and trim(l.nombre)<>''
      and (l.fecha at time zone 'America/Lima')::date = v_d
      and not exists (
        select 1 from mos.personal p
        where (
            ( (p.apellido is null or trim(p.apellido)='') and lower(trim(p.nombre)) = lower(trim(l.nombre)) )
            or ( p.apellido is not null and trim(p.apellido)<>'' and lower(trim(p.nombre)||' '||trim(p.apellido)) = lower(trim(l.nombre)) )
          )
          and ( upper(coalesce(p.app_origen,''))='MOS'
             or upper(coalesce(p.rol,'')) in ('MASTER','ADMINISTRADOR','ADMIN')
             or ( coalesce(p.rol,'')<>'' and upper(p.rol) not in ('ALMACENERO','ENVASADOR','OPERADOR','CAJERO','VENDEDOR') ) )
      )
  ),
  liq_dedup as (
    select *, row_number() over (partition by k order by id_dia) rn from liq
  ),
  liq1 as (
    select * from liq_dedup where rn = 1
  ),
  resuelto as (
    select l.*,
           coalesce(
             (select upper(p.rol) from mos.personal p
              where p.rol is not null and trim(p.rol)<>''
                and (
                  ( (p.apellido is null or trim(p.apellido)='') and lower(trim(p.nombre)) = l.k )
                  or ( p.apellido is not null and trim(p.apellido)<>'' and lower(trim(p.nombre)||' '||trim(p.apellido)) = l.k )
                )
              limit 1),
             upper(l.rol)
           ) as rol_final,
           (l.estado = 'VETADA') as vetada
    from liq1 l
  )
  select
    coalesce(mos._r2(sum(case when not vetada then monto else 0 end)),0),
    coalesce(count(*) filter (where not vetada)::int, 0),
    coalesce(jsonb_agg(jsonb_build_object(
        'idJornada',  '',
        'idPersonal', id_personal,
        'nombre',     nombre,
        'rol',        rol_final,
        'zona',       '',
        'appOrigen',  app_origen,
        'monto',      case when vetada then 0 else monto end,
        'fuente',     case when vetada then 'ELIMINADA' else 'AUTO_VENTA' end,
        'vetada',     vetada,
        'presente',   true,
        'liqEstado',  estado
      )), '[]'::jsonb)
  into v_gasto_personal, v_personas, v_personal_detalle
  from resuelto;

  with g as (
    select coalesce(g.monto,0)::numeric as monto,
           coalesce(nullif(g.categoria,''),'OTROS') as categoria,
           g.tipo,
           g.id_gasto, g.fecha, g.descripcion, g.comprobante, g.registrado_por
    from mos.gastos g
    where (g.fecha at time zone 'America/Lima')::date = v_d
  )
  select
    coalesce(mos._r2(sum(monto)),0),
    coalesce(mos._r2(sum(monto) filter (where tipo = 'FIJO')),0),
    coalesce((select jsonb_object_agg(categoria, m)
              from (select categoria, mos._r2(sum(monto)) m from g group by categoria) q), '{}'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
                'idGasto',       id_gasto,
                'fecha',         fecha,
                'categoria',     categoria,
                'tipo',          tipo,
                'descripcion',   descripcion,
                'monto',         monto,
                'comprobante',   comprobante,
                'registradoPor', registrado_por
              )) from g), '[]'::jsonb)
  into v_gasto_otros, v_gastos_fijos, v_gastos_bycat, v_gastos_detalle
  from g;

  v_gasto_otros      := mos._r2(v_gasto_otros);
  v_gastos_fijos     := mos._r2(v_gastos_fijos);
  v_gastos_variables := mos._r2(v_gasto_otros - v_gastos_fijos);

  v_utilidad_bruta := mos._r2(v_ventas_netas - v_costo_total);
  v_total_gastos   := mos._r2(v_gasto_personal + v_gasto_otros);
  v_utilidad_neta  := mos._r2(v_utilidad_bruta - v_total_gastos);
  v_margen_bruto_pct := case when v_ventas_netas > 0 then mos._r2(v_utilidad_bruta / v_ventas_netas * 100) else 0 end;
  v_margen_neto_pct  := case when v_ventas_netas > 0 then mos._r2(v_utilidad_neta  / v_ventas_netas * 100) else 0 end;

  v_costos_fijos  := mos._r2(v_gasto_personal + v_gastos_fijos);
  v_margen_contrib := case when v_ventas_netas > 0 then (v_ventas_netas - v_costo_total) / v_ventas_netas else 0 end;
  if v_margen_contrib > 0 then
    v_break_even_ventas := mos._r2(v_costos_fijos / v_margen_contrib);
  else
    v_break_even_ventas := null;
  end if;
  v_break_even_pct := case
    when v_break_even_ventas is not null and v_ventas_netas > 0
    then mos._r2(least(v_break_even_ventas / v_ventas_netas * 100, 100))
    else 0 end;
  v_supera_be := (v_break_even_ventas is not null) and (v_ventas_netas >= v_break_even_ventas);

  v_data := jsonb_build_object(
    'fecha',              to_char(v_d, 'YYYY-MM-DD'),
    'ventasBrutas',       v_ventas_brutas,
    'ventasNetas',        v_ventas_netas,
    'tickets',            v_tickets,
    'anulados',           v_anulados_n,
    'creditos',           v_creditos_n,
    'ticketPromedio',     v_ticket_promedio,
    'cobrado',            v_ventas_netas,
    'cobradoEfectivo',    v_total_efectivo,
    'cobradoVirtual',     v_total_virtual,
    'creditoOtorgado',    mos._r2(v_porcobrar_monto + v_credito_monto),
    'byDoc',              v_bydoc,
    'byMetodo',           v_bymetodo,
    'detalleTickets',     v_detalle_tickets,
    'costoVentas',        v_costo_total,
    'costoVentasReal',    v_costo_real,
    'costoVentasEstimado',v_costo_estimado,
    'itemsVendidos',      v_items,
    'unidadesVendidas',   v_unidades,
    'skusDistintos',      v_skus_distintos,
    'productosSinCosto',  v_sin_costo,
    'cantidadEstimados',  v_cant_estimados,
    'margenPromedioPct',  v_margen_prom_pct,
    'defaultMargenUsado', v_margen,
    'detalleProductos',   v_detalle_productos,
    'utilidadBruta',      v_utilidad_bruta,
    'margenBrutoPct',     v_margen_bruto_pct,
    'gastoPersonal',      v_gasto_personal,
    'personalDetalle',    v_personal_detalle,
    'personas',           v_personas,
    'gastoOtros',         v_gasto_otros,
    'gastosFijos',        v_gastos_fijos,
    'gastosVariables',    v_gastos_variables,
    'gastosByCategoria',  v_gastos_bycat,
    'gastosDetalle',      v_gastos_detalle,
    'totalGastos',        v_total_gastos,
    'utilidadNeta',       v_utilidad_neta,
    'margenNetoPct',      v_margen_neto_pct,
    'costosFijos',        v_costos_fijos,
    'margenContribPct',   mos._r2(v_margen_contrib * 100),
    'breakEvenVentas',    v_break_even_ventas,
    'breakEvenPct',       v_break_even_pct,
    'superaBreakEven',    v_supera_be
  );

  begin
    select (valor)::timestamptz into v_hb from mos.config where clave = 'MOS_SYNC_HEARTBEAT' limit 1;
  exception when others then v_hb := null;
  end;
  begin
    select (valor)::int into v_ttl from mos.config where clave = 'MOS_SYNC_TTL_MIN' limit 1;
  exception when others then v_ttl := null;
  end;
  v_ttl := coalesce(v_ttl, 30);
  if v_ttl < 15   then v_ttl := 15;   end if;
  if v_ttl > 1440 then v_ttl := 1440; end if;
  v_fresh := (v_hb is not null) and (now() - v_hb < make_interval(mins => v_ttl));

  return jsonb_build_object('ok', true, 'data', v_data)
         || jsonb_build_object('_fresh', v_fresh, '_heartbeat', v_hb, '_now', now(), '_ttl_min', v_ttl);
end;
$fn$;

revoke all on function mos.finanzas_dia(text)      from public;
grant execute on function mos.finanzas_dia(text)   to service_role, authenticated;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- (3) mos.finanzas_rango — P&L de un rango de días.
--   CAMBIO: el filtro de ventas COBRADAS pasa ANULADO a prefijo.
--     ANTES: where upper(coalesce(forma_pago,'')) not in ('ANULADO','POR_COBRAR','CREDITO')
--     AHORA: where upper(coalesce(forma_pago,'')) not like 'ANULADO%'
--              and upper(coalesce(forma_pago,'')) not in ('POR_COBRAR','CREDITO')
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.finanzas_rango(p_desde text, p_hasta text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_margen numeric := 20;
  v_data   jsonb;
begin
  select valor::numeric into v_margen
  from mos.config
  where clave = 'finMargenDefault' and valor ~ '^[0-9]+(\.[0-9]+)?$';
  if v_margen is null or v_margen < 0 or v_margen >= 100 then v_margen := 20; end if;

  with dias as (
    select to_char(d, 'YYYY-MM-DD') as dia
    from generate_series(p_desde::date, p_hasta::date, interval '1 day') as d
  ),
  vcobr as (
    select to_char(v.fecha at time zone 'America/Lima', 'YYYY-MM-DD') as dia,
           v.id_venta, coalesce(v.total,0)::numeric as total,
           upper(coalesce(v.forma_pago,'')) as fp, v.forma_pago
    from me.ventas v
    where upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'              -- C2: prefijo
      and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
      and (v.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
  ),
  neto as (
    select dia, mos._r2(sum(
      ( case
          when fp='EFECTIVO' then total
          when fp='VIRTUAL'  then 0
          when fp like 'MIXTO%' then
            coalesce( (substring(upper(forma_pago) from 'EFE:([0-9.]+)'))::numeric,
                      round(total - coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0), 2) )
          else 0 end )
      +
      ( case
          when fp='EFECTIVO' then 0
          when fp='VIRTUAL'  then total
          when fp like 'MIXTO%' then coalesce((substring(upper(forma_pago) from 'VIR:([0-9.]+)'))::numeric,0)
          else total end )
    )) as ventas_netas
    from vcobr group by dia
  ),
  det as (
    select v.dia, upper(trim(d.sku)) as nsku_l, upper(trim(coalesce(d.cod_barras,''))) as ncod_l,
           coalesce(d.cantidad,0)::numeric as cantidad, coalesce(d.precio,0)::numeric as precio
    from me.ventas_detalle d
    join vcobr v on v.id_venta = d.id_venta
  ),
  m_id as (
    select distinct on (upper(trim(id_producto))) upper(trim(id_producto)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where id_producto is not null and trim(id_producto)<>''
    order by upper(trim(id_producto)), id_producto desc
  ),
  m_cod as (
    select distinct on (upper(trim(codigo_barra))) upper(trim(codigo_barra)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where codigo_barra is not null and trim(codigo_barra)<>''
    order by upper(trim(codigo_barra)), id_producto desc
  ),
  m_sku as (
    select distinct on (upper(trim(sku_base))) upper(trim(sku_base)) k,
           upper(trim(sku_base)) nsku, coalesce(factor_conversion,1)::numeric factor
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), id_producto asc
  ),
  canon as (
    select distinct on (upper(trim(sku_base))) upper(trim(sku_base)) nsku,
           coalesce(precio_costo,0)::numeric costo
    from mos.productos where sku_base is not null and trim(sku_base)<>''
    order by upper(trim(sku_base)), case when coalesce(factor_conversion,1)=1 then 0 else 1 end, id_producto
  ),
  det_res as (
    select dt.dia, dt.cantidad, dt.precio,
           coalesce(mi.factor, mc1.factor, mc2.factor, msk.factor, 1) as factor,
           coalesce(mi.nsku, mc1.nsku, mc2.nsku, msk.nsku) as nsku
    from det dt
    left join m_id  mi  on mi.k  = dt.nsku_l
    left join m_cod mc1 on mc1.k = dt.nsku_l
    left join m_cod mc2 on mc2.k = dt.ncod_l
    left join m_sku msk on msk.k = dt.nsku_l
  ),
  cogs as (
    select dr.dia, mos._r2(sum(
      case when coalesce(cn.costo,0) > 0
           then (dr.cantidad * dr.factor) * cn.costo
           else (dr.precio * dr.cantidad) * (1 - v_margen/100)
      end
    )) as costo_ventas
    from det_res dr
    left join canon cn on cn.nsku = dr.nsku
    group by dr.dia
  ),
  liq as (
    select to_char(l.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
           lower(trim(l.nombre)) as k,
           upper(coalesce(l.estado,'PENDIENTE')) as estado,
           case when coalesce(l.total_dia,0)>0 then l.total_dia::numeric else coalesce(l.monto_base,0)::numeric end as monto,
           l.id_dia
    from mos.liquidaciones_dia l
    where l.presente = true and l.nombre is not null and trim(l.nombre)<>''
      and (l.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
      and not exists (
        select 1 from mos.personal p
        where (
            ( (p.apellido is null or trim(p.apellido)='') and lower(trim(p.nombre)) = lower(trim(l.nombre)) )
            or ( p.apellido is not null and trim(p.apellido)<>'' and lower(trim(p.nombre)||' '||trim(p.apellido)) = lower(trim(l.nombre)) )
          )
          and ( upper(coalesce(p.app_origen,''))='MOS'
             or upper(coalesce(p.rol,'')) in ('MASTER','ADMINISTRADOR','ADMIN')
             or ( coalesce(p.rol,'')<>'' and upper(p.rol) not in ('ALMACENERO','ENVASADOR','OPERADOR','CAJERO','VENDEDOR') ) )
      )
  ),
  liq_dedup as (
    select dia, k, estado, monto, row_number() over (partition by dia, k order by id_dia) rn
    from liq
  ),
  personal as (
    select dia, mos._r2(sum(case when estado<>'VETADA' then monto else 0 end)) total_personal
    from liq_dedup where rn=1 group by dia
  ),
  gastos as (
    select to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD') as dia,
           mos._r2(sum(coalesce(g.monto,0)::numeric)) total_gastos_otros
    from mos.gastos g
    where (g.fecha at time zone 'America/Lima')::date between p_desde::date and p_hasta::date
    group by dia
  ),
  pl as (
    select d.dia,
           coalesce(n.ventas_netas,0) ventas_netas, coalesce(c.costo_ventas,0) costo_ventas,
           coalesce(pe.total_personal,0) personal, coalesce(ga.total_gastos_otros,0) gastos_otros
    from dias d
    left join neto n on n.dia=d.dia
    left join cogs c on c.dia=d.dia
    left join personal pe on pe.dia=d.dia
    left join gastos ga on ga.dia=d.dia
  ),
  pl2 as (
    select dia, ventas_netas, costo_ventas,
           mos._r2(ventas_netas - costo_ventas) utilidad_bruta,
           mos._r2(personal + gastos_otros) total_gastos
    from pl
  ),
  pl3 as (
    select dia, ventas_netas, costo_ventas, utilidad_bruta, total_gastos,
           mos._r2(utilidad_bruta - total_gastos) utilidad_neta,
           case when ventas_netas>0 then mos._r2(utilidad_bruta/ventas_netas*100) else 0 end margen_bruto_pct
    from pl2
  )
  select jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'serie', coalesce((
        select jsonb_agg(jsonb_build_object(
          'fecha',dia,'utilidadNeta',utilidad_neta,'ventasNetas',ventas_netas,
          'costoVentas',costo_ventas,'totalGastos',total_gastos,
          'utilidadBruta',utilidad_bruta,'margenBrutoPct',margen_bruto_pct
        ) order by dia) from pl3), '[]'::jsonb),
      'totales', (
        select jsonb_build_object(
          'ventasNetas',sum(ventas_netas),'costoVentas',sum(costo_ventas),
          'utilidadBruta',sum(utilidad_bruta),'totalGastos',sum(total_gastos),'utilidadNeta',sum(utilidad_neta),
          'margenBrutoPct', case when sum(ventas_netas)>0 then mos._r2(sum(utilidad_bruta)/sum(ventas_netas)*100) else 0 end,
          'margenNetoPct',  case when sum(ventas_netas)>0 then mos._r2(sum(utilidad_neta)/sum(ventas_netas)*100) else 0 end
        ) from pl3),
      'desde', p_desde, 'hasta', p_hasta
    )
  ) into v_data;

  return v_data;
end;
$fn$;

revoke all on function mos.finanzas_rango(text,text) from public;
grant execute on function mos.finanzas_rango(text,text) to service_role;
