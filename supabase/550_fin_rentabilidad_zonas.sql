-- ════════════════════════════════════════════════════════════════════
-- 550 — Finanzas · Rentabilidad por zona EN VIVO (pedido del dueño tras
-- el reporte HTML de ZONA-02): una RPC que devuelve, para TODAS las
-- zonas, el diario (venta/costo/utilidad), el desglose de cobro por mes,
-- anuladas y top productos — el frontend arma la analítica interactiva.
-- Margen: costo real del catálogo; si el producto no tiene precio_costo,
-- fallback 15% sobre la venta (regla del dueño). Margen = utilidad/venta.
-- Ventas ANULADAS excluidas de todo y reportadas aparte.
-- ════════════════════════════════════════════════════════════════════
create or replace function mos.fin_rentabilidad_zonas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to ''
as $$
declare
  v_desde date := coalesce(nullif(btrim(coalesce(p->>'desde','')),'')::date, '2026-01-01');
  v_hasta date := coalesce(nullif(btrim(coalesce(p->>'hasta','')),'')::date, (now() at time zone 'America/Lima')::date);
  v_diario jsonb; v_met jsonb; v_anul jsonb; v_top jsonb;
begin
  -- líneas con costo (real o fallback 15%) — base de todo
  create temp table _rz_lin on commit drop as
    select coalesce(v.zona_id,'SIN_ZONA') zona,
           (v.fecha at time zone 'America/Lima')::date dia,
           v.id_venta, d.nombre, d.cod_barras,
           d.cantidad, (d.cantidad*d.precio) rev,
           case when coalesce(pr.precio_costo,0)>0 then d.cantidad*pr.precio_costo else d.cantidad*d.precio*0.85 end costo,
           (coalesce(pr.precio_costo,0)>0) con_costo
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    left join lateral (
      select p2.precio_costo from mos.productos p2
       where p2.codigo_barra = d.cod_barras or p2.id_producto = d.sku
          or p2.id_producto = (select e.sku_base from mos.equivalencias e
                                where e.codigo_barra = d.cod_barras and coalesce(e.activo,true) limit 1)
       order by (p2.codigo_barra = d.cod_barras) desc, (p2.id_producto = d.sku) desc limit 1
    ) pr on true
    where v.forma_pago <> 'ANULADO'
      and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hasta;

  select coalesce(jsonb_agg(x order by x->>'z', x->>'dia'),'[]'::jsonb) into v_diario from (
    select jsonb_build_object('z', zona, 'dia', dia, 'rev', round(sum(rev),2), 'costo', round(sum(costo),2),
      'rcr', round(sum(case when con_costo then rev else 0 end),2), 'n', count(distinct id_venta)) x
    from _rz_lin group by zona, dia) q;

  select coalesce(jsonb_agg(jsonb_build_object('z', z, 'mes', mes, 'fp', fp, 'tot', tot)),'[]'::jsonb) into v_met from (
    select coalesce(v.zona_id,'SIN_ZONA') z,
      to_char((v.fecha at time zone 'America/Lima')::date,'YYYY-MM') mes,
      case when v.forma_pago like 'MIXTO%' then 'MIXTO' else v.forma_pago end fp,
      round(sum(v.total),2) tot
    from me.ventas v
    where v.forma_pago <> 'ANULADO'
      and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hasta
    group by 1, 2, 3) q;

  select coalesce(jsonb_agg(jsonb_build_object('z', z, 'n', n, 'tot', tot)),'[]'::jsonb) into v_anul from (
    select coalesce(v.zona_id,'SIN_ZONA') z, count(*) n, round(sum(v.total),2) tot
    from me.ventas v
    where v.forma_pago = 'ANULADO'
      and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hasta
    group by 1) q;

  select coalesce(jsonb_agg(jsonb_build_object('z', z, 'nombre', nombre, 'und', und, 'rev', rev,
    'uti', uti, 'mpct', mpct, 'con_costo', con_costo)),'[]'::jsonb) into v_top from (
    select zona z, nombre, round(sum(cantidad)::numeric,1) und, round(sum(rev),2) rev,
      round(sum(rev-costo),2) uti, round((sum(rev-costo)/nullif(sum(rev),0)*100)::numeric,1) mpct,
      bool_or(con_costo) con_costo
    from _rz_lin
    group by zona, nombre
    order by sum(rev-costo) desc limit 60) q;

  return jsonb_build_object('ok', true, 'desde', v_desde, 'hasta', v_hasta,
    'diario', v_diario, 'metodos', v_met, 'anuladas', v_anul, 'top', v_top,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'));
end; $$;

alter function mos.fin_rentabilidad_zonas(jsonb) set statement_timeout = '25s';
grant execute on function mos.fin_rentabilidad_zonas(jsonb) to anon, authenticated, service_role;
