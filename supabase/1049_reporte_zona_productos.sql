-- 1049 · Reporte integral por zona (Finanzas → 📋 Reporte de zonas · página externa reporte-zonas.html)
-- SOLO LECTURA. Pedido de Luis 08-nov-2026:
--   a) qué productos vende cada zona, agrupados por PADRE (granel/canónico) con sus HIJOS
--      (derivados y presentaciones), cantidades, precio, costo y margen.
--      Costo del hijo = costo propio si tiene; si no, costo del PADRE × fracción (½ kg de un granel
--      de S/50 cuesta S/25); si el padre tampoco tiene costo → regla del dueño: margen 15%.
--   b) costo del personal asignado a la zona = mos.liquidaciones_dia.total_dia (BRUTO, sin VETADAS;
--      doctrina gasto-personal-bruto-vs-caja).
-- Ventana: últimos N días (1 · 7 · 28) INCLUYENDO HOY (hora Lima). Zona: ZONA-01 / ZONA-02 / TODAS.
-- OJO: PostgREST (pg_safeupdate) exige WHERE en todo UPDATE, incluso de temp tables → `where true`.
-- Venta = subtotal de la línea (lo cobrado). ANULADO% fuera (1046).
create or replace function mos.reporte_zona_productos(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
 set statement_timeout to '25s'
as $function$
declare
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_dias  int  := least(greatest(coalesce(nullif(p->>'dias','')::int, 1), 1), 62);
  v_desde date;
  v_zona  text := upper(coalesce(nullif(btrim(p->>'zona'),''), 'TODAS'));
  v_alm jsonb; v_res jsonb; v_diario jsonb; v_padres jsonb; v_pers jsonb; v_cajas jsonb;
begin
  if coalesce(me.jwt_app(), '') <> 'MOS' then
    return jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO');
  end if;
  v_desde := v_hoy - (v_dias - 1);
  drop table if exists _rzp;

  create temp table _rzp on commit drop as
  with lin as (
    select coalesce(v.zona_id,'SIN_ZONA') zona,
           (v.fecha at time zone 'America/Lima')::date dia,
           v.id_venta, d.nombre, d.cod_barras, d.sku, d.cantidad,
           coalesce(d.subtotal, d.cantidad*d.precio) rev,
           upper(coalesce(d.unidad_medida,'')) in ('KGM','KG','LTR','L','MTR','M','GR','GMS','G') peso
      from me.ventas v
      join me.ventas_detalle d on d.id_venta = v.id_venta
     where coalesce(v.forma_pago,'') not like 'ANULADO%'
       and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hoy
       and (v_zona = 'TODAS' or v.zona_id = v_zona)
       and coalesce(v.zona_id,'') <> 'ZONA_MOCK_FALLBACK'
  )
  select l.*, pr.codigo_barra pcod, pr.descripcion pdesc, pr.tipo_producto::text tipo,
         coalesce(pr.precio_costo,0) costo_propio,
         rt.root_sku, rt.f,
         ro.codigo_barra rcod, ro.descripcion rdesc, ro.unidad_medida rum, coalesce(ro.precio_costo,0) rcosto
    from lin l
    -- producto vendido: código de barras → sku → equivalencia (canónico de su grupo)
    left join lateral (
      select p2.* from mos.productos p2
       where p2.codigo_barra = l.cod_barras or p2.id_producto = l.sku
          or (p2.sku_base = (select e.sku_base from mos.equivalencias e
                              where e.codigo_barra = l.cod_barras and coalesce(e.activo,true) limit 1)
              and coalesce(nullif(p2.factor_conversion,0),1) = 1)
       order by (p2.codigo_barra = l.cod_barras) desc, (p2.id_producto = l.sku) desc,
                (p2.tipo_producto::text = 'CANONICO') desc
       limit 1
    ) pr on true
    -- miembro factor 1 del grupo (para presentaciones colgadas de un derivado)
    left join lateral (
      select g.* from mos.productos g
       where g.sku_base = pr.sku_base and coalesce(nullif(g.factor_conversion,0),1) = 1
       order by (g.tipo_producto::text = 'CANONICO') desc, g.codigo_barra limit 1
    ) gm on pr.tipo_producto::text = 'PRESENTACION'
    -- raíz (padre) + fracción del hijo respecto a la unidad del padre
    left join lateral (
      select case
               when pr.id_producto is null then null
               when pr.tipo_producto::text = 'DERIVADO' and nullif(btrim(pr.codigo_producto_base),'') is not null
                 then pr.codigo_producto_base
               when pr.tipo_producto::text = 'PRESENTACION' and gm.tipo_producto::text = 'DERIVADO'
                    and nullif(btrim(gm.codigo_producto_base),'') is not null
                 then gm.codigo_producto_base
               else pr.sku_base end root_sku,
             case
               when pr.id_producto is null then 1
               /* venta por peso: la cantidad ya está en kg/l del padre */
               when l.peso then 1
               when pr.tipo_producto::text = 'DERIVADO'
                 then coalesce(nullif(pr.factor_conversion_base,0),1)
               when pr.tipo_producto::text = 'PRESENTACION' and gm.tipo_producto::text = 'DERIVADO'
                 then coalesce(nullif(pr.factor_conversion,0),1) * coalesce(nullif(gm.factor_conversion_base,0),1)
               else coalesce(nullif(pr.factor_conversion,0),1) end f
    ) rt on true
    left join lateral (
      select r.* from mos.productos r
       where r.sku_base = rt.root_sku and coalesce(nullif(r.factor_conversion,0),1) = 1
       order by (r.tipo_producto::text = 'CANONICO') desc,
                (coalesce(nullif(btrim(r.codigo_producto_base),''),'') = '') desc, r.codigo_barra
       limit 1
    ) ro on true;

  alter table _rzp add column origen text, add column costo numeric;
  /* QA: un costo solo vale si es menor que el precio unitario de esa venta; si no, es dato dudoso
     del catálogo (costo de bulto, etc.) → se estima al 15% y se marca DUDOSO para corregirlo. */
  update _rzp set
    origen = case when costo_propio > 0 and not (peso and tipo = 'PRESENTACION')
                    then case when cantidad > 0 and costo_propio < rev / cantidad then 'REAL' else 'DUDOSO' end
                  when rcosto > 0
                    then case when cantidad > 0 and rcosto * f < rev / cantidad then 'PADRE' else 'DUDOSO' end
                  else 'EST' end
   where true;
  update _rzp set costo = case origen
    when 'REAL'  then cantidad * costo_propio
    when 'PADRE' then cantidad * f * rcosto
    else rev * 0.85 end
   where true;

  -- resumen
  select jsonb_build_object(
      'venta', round(coalesce(sum(rev),0),2),
      'costo', round(coalesce(sum(costo),0),2),
      'utilidad', round(coalesce(sum(rev-costo),0),2),
      'tickets', count(distinct id_venta),
      'ventaConCosto', round(coalesce(sum(rev) filter (where origen in ('REAL','PADRE')),0),2),
      'ventaDudosa', round(coalesce(sum(rev) filter (where origen = 'DUDOSO'),0),2))
    into v_res from _rzp;

  -- personal (bruto, sin vetadas) por persona
  select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]'::jsonb) into v_pers from (
    select jsonb_build_object('nombre', max(l.nombre), 'rol', max(l.rol), 'zona', l.zona,
             'dias', count(distinct (l.fecha at time zone 'America/Lima')::date),
             'base', round(sum(coalesce(l.monto_base,0)),2),
             'extras', round(sum(coalesce(l.total_dia,0) - coalesce(l.monto_base,0)),2),
             'total', round(sum(coalesce(l.total_dia,0)),2),
             'pendiente', bool_or(coalesce(l.estado,'') <> 'PAGADA')) x
      from mos.liquidaciones_dia l
     where (l.fecha at time zone 'America/Lima')::date between v_desde and v_hoy
       and coalesce(l.estado,'') <> 'VETADA'
       and l.zona like 'ZONA-%'
       and (v_zona = 'TODAS' or l.zona = v_zona)
     group by coalesce(nullif(l.id_personal,''), l.nombre), l.zona) q;

  /* QA: el personal sin zona (almacén) no se carga a ninguna zona; se informa aparte */
  select jsonb_build_object('total', round(coalesce(sum(coalesce(l.total_dia,0)),0),2),
           'personas', count(distinct coalesce(nullif(l.id_personal,''), l.nombre)))
    into v_alm
    from mos.liquidaciones_dia l
   where (l.fecha at time zone 'America/Lima')::date between v_desde and v_hoy
     and coalesce(l.estado,'') <> 'VETADA'
     and coalesce(l.zona,'') not like 'ZONA-%';

  -- serie diaria: venta, utilidad, personal
  select coalesce(jsonb_agg(x order by x->>'dia'), '[]'::jsonb) into v_diario from (
    select jsonb_build_object('dia', g.dia,
             'venta', round(coalesce(s.venta,0),2), 'utilidad', round(coalesce(s.uti,0),2),
             'personal', round(coalesce(pp.pers,0),2)) x
      from generate_series(v_desde, v_hoy, interval '1 day') gs(d)
      cross join lateral (select gs.d::date dia) g
      left join (select dia, sum(rev) venta, sum(rev-costo) uti from _rzp group by dia) s on s.dia = g.dia
      left join (select (l.fecha at time zone 'America/Lima')::date dia, sum(coalesce(l.total_dia,0)) pers
                   from mos.liquidaciones_dia l
                  where coalesce(l.estado,'') <> 'VETADA' and l.zona like 'ZONA-%'
                    and (v_zona = 'TODAS' or l.zona = v_zona)
                    and (l.fecha at time zone 'America/Lima')::date between v_desde and v_hoy
                  group by 1) pp on pp.dia = g.dia) q;

  -- padres con sus hijos (2 niveles: hijo → padre, una sola pasada)
  select coalesce(jsonb_agg(x order by (x->>'venta')::numeric desc), '[]'::jsonb) into v_padres from (
    select jsonb_build_object(
             'cod', pk, 'nombre', max(pnombre), 'um', max(pum), 'costoPadre', max(rcosto),
             'cantBase', round(sum(cant_base)::numeric,3),
             'venta', round(sum(venta),2), 'costo', round(sum(costo),2), 'utilidad', round(sum(venta-costo),2),
             'origen', case when bool_or(origen='DUDOSO') then 'DUDOSO'
                            when bool_and(origen='EST') then 'EST' when bool_or(origen='EST') then 'MIXTO' else 'REAL' end,
             'hijos', jsonb_agg(jsonb_build_object('cod', hcod, 'nombre', hnombre, 'tipo', tipo,
                       'fraccion', f, 'cant', round(cant::numeric,3),
                       'precio', round(venta/nullif(cant,0),2), 'costoUnit', round(costo/nullif(cant,0),2),
                       'venta', round(venta,2), 'costo', round(costo,2), 'utilidad', round(venta-costo,2),
                       'origen', origen, 'peso', peso) order by venta desc)) x
      from (
        select coalesce(rcod, pcod, cod_barras, nombre) pk,
               max(coalesce(rdesc, pdesc, nombre)) pnombre, max(coalesce(rum,'NIU')) pum, max(rcosto) rcosto,
               coalesce(pcod, cod_barras, nombre) hcod, max(coalesce(pdesc, nombre)) hnombre, max(tipo) tipo,
               max(f) f, sum(cantidad) cant, sum(cantidad*f) cant_base, sum(rev) venta, sum(costo) costo,
               case when bool_or(origen='DUDOSO') then 'DUDOSO'
                    when bool_and(origen='EST') then 'EST' when bool_or(origen='EST') then 'MIXTO'
                    when bool_or(origen='PADRE') then 'PADRE' else 'REAL' end origen,
               bool_or(peso) peso
          from _rzp group by 1, 5) h
     group by pk) q;

  -- cajas del período (cerradas / abiertas) para el aviso "hoy en vivo"
  select jsonb_build_object(
           'cerradas', count(*) filter (where upper(coalesce(c.estado,'')) like 'CERRAD%'),
           'abiertas', count(*) filter (where upper(coalesce(c.estado,'')) not like 'CERRAD%'))
    into v_cajas
    from me.cajas c
   where (c.fecha_apertura at time zone 'America/Lima')::date between v_desde and v_hoy
     and (v_zona = 'TODAS' or c.zona_id = v_zona)
     and coalesce(c.zona_id,'') like 'ZONA-%';

  return jsonb_build_object('ok', true, 'zona', v_zona, 'dias', v_dias, 'desde', v_desde, 'hasta', v_hoy,
    'resumen', v_res || jsonb_build_object('personal',
        coalesce((select round(sum((x->>'total')::numeric),2) from jsonb_array_elements(v_pers) x),0)),
    'diario', v_diario, 'padres', v_padres, 'personal', v_pers, 'almacen', v_alm, 'cajas', v_cajas,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'));
end; $function$;

revoke all on function mos.reporte_zona_productos(jsonb) from public, anon;
grant execute on function mos.reporte_zona_productos(jsonb) to authenticated, service_role;
