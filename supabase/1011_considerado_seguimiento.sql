-- ============================================================================
-- 1011_considerado_seguimiento.sql — Drill-down de un considerado (pedido del dueño 02-sep)
-- ----------------------------------------------------------------------------
-- En 🎯 Considerados, "ZONA-02 debía 11" no decía CUÁNDO: el Master quiere clic → qué
-- SEMANA se pidió/despachó, y otro clic → los DÍAS con hora y monto (🛒 pidió +N /
-- 🏭 despachó −N), para dar seguimiento igual que el desglose del pickup.
--
-- wh.considerado_seguimiento({skuBase, zona, semanas?=10}) → {ok, semanas:[
--   {lun:'YYYY-MM-DD', pedido, despachado, pendiente, dias:[
--     {dia:'YYYY-MM-DD', evs:[{hm:'HH:MI', tipo:'pedido'|'despacho', fuente, cant}]}]}]}
--
-- Fuentes (las MISMAS del historial del pickup, wh.zona_pickup_detalle):
--   · pedidos  = wh.pickups de la zona (fuente ≠ ACUMULADO_SEMANAL: cierres de caja,
--                lista sombra, RIZ), items con ese skuBase.
--   · despachos = guías SALIDA% a la zona con ese sku (por código→sku, líneas no anuladas).
-- Semana = lunes de calendario (date_trunc week, TZ Lima) — etiqueta de SEGUIMIENTO,
-- independiente de los buckets internos del acumulador (_bucket_venta/_despacho).
-- Solo lectura. Mismos grants que considerados_listar.
-- ============================================================================
create or replace function wh.considerado_seguimiento(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_sku   text := nullif(btrim(coalesce(p->>'skuBase', p->>'sku','')),'');
  v_zona  text := nullif(btrim(coalesce(p->>'zona','')),'');
  v_sem   int  := greatest(1, least(26, coalesce((p->>'semanas')::int, 10)));
  v_desde timestamptz := (date_trunc('week', (now() at time zone 'America/Lima')::date::timestamp) - make_interval(weeks => v_sem - 1)) at time zone 'America/Lima';
  v_out   jsonb;
begin
  if v_sku is null or v_zona is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere skuBase y zona');
  end if;

  with pedidos as (
    select pk.fecha_creado as ts, coalesce(pk.fuente,'') as fuente,
           sum(wh._num(coalesce(it->>'solicitado','0'))) as cant
      from wh.pickups pk
      cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
     where coalesce(pk.id_zona,'') = v_zona
       and coalesce(pk.fuente,'') <> 'ACUMULADO_SEMANAL'
       and pk.fecha_creado >= v_desde
       and coalesce(it->>'skuBase','') = v_sku
       and wh._num(coalesce(it->>'solicitado','0')) > 0
     group by 1, 2
  ),
  despachos as (
    select coalesce(gd.created_at, g.fecha) as ts, 'GUIA_SALIDA'::text as fuente,
           sum(coalesce(gd.cant_recibida, gd.cantidad_aplicada, 0)) as cant
      from wh.guias g
      join wh.guia_detalle gd on gd.id_guia = g.id_guia
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
     where coalesce(g.id_zona,'') = v_zona
       and g.tipo like 'SALIDA%'
       and coalesce(gd.created_at, g.fecha) >= v_desde
       and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
       and coalesce(pr.sku_base, eq.sku_base) = v_sku
     group by 1, 2
  ),
  eventos as (
    select ts, 'pedido'::text tipo, fuente, cant from pedidos where cant > 0
    union all
    select ts, 'despacho'::text, fuente, cant from despachos where cant > 0
  ),
  ev2 as (
    select date_trunc('week', (ts at time zone 'America/Lima')::date::timestamp)::date as lun,
           (ts at time zone 'America/Lima')::date as dia,
           to_char(ts at time zone 'America/Lima','HH24:MI') as hm,
           ts, tipo, fuente, cant
      from eventos
  ),
  dias as (
    select lun, dia,
           jsonb_agg(jsonb_build_object('hm', hm, 'tipo', tipo, 'fuente', fuente,
                                        'cant', round(cant::numeric, 2)) order by ts) as evs
      from ev2 group by lun, dia
  ),
  semanas as (
    select e.lun,
           round(sum(case when e.tipo = 'pedido'   then e.cant else 0 end)::numeric, 2) as pedido,
           round(sum(case when e.tipo = 'despacho' then e.cant else 0 end)::numeric, 2) as despachado
      from ev2 e group by e.lun
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'lun', to_char(s.lun, 'YYYY-MM-DD'),
           'pedido', s.pedido, 'despachado', s.despachado,
           'pendiente', greatest(0, s.pedido - s.despachado),
           'dias', (select coalesce(jsonb_agg(jsonb_build_object(
                       'dia', to_char(d.dia,'YYYY-MM-DD'), 'evs', d.evs) order by d.dia), '[]'::jsonb)
                      from dias d where d.lun = s.lun)
         ) order by s.lun desc), '[]'::jsonb)
    into v_out from semanas s;

  return jsonb_build_object('ok', true, 'skuBase', v_sku, 'zona', v_zona,
                            'desde', to_char(v_desde at time zone 'America/Lima','YYYY-MM-DD'),
                            'semanas', coalesce(v_out, '[]'::jsonb));
end $function$;
grant execute on function wh.considerado_seguimiento(jsonb) to authenticated, anon, service_role;
