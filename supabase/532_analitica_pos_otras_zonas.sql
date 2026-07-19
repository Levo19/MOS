-- 532_analitica_pos_otras_zonas.sql — Cierre de la duda de credibilidad del dueño (caso Fanta):
-- la analítica es POR ZONA (diseño correcto: "ventas de TU zona"), pero un cero mudo cuando
-- OTRA zona sí vendió genera desconfianza. Se agrega 'otrasZonas' = unidades vendidas en las
-- demás zonas (misma ventana: 4 semanas previas + semana actual) + detalle por zona, para que
-- el card diga "tu zona 0 · ZONA-02 vendió 3". Redefinición = 531 + bloque [532].
create or replace function me.analitica_pos(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_cb    text := upper(btrim(coalesce(p->>'codigoBarra','')));
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_lun   date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date;
  v_prod  mos.productos%rowtype;
  v_canon mos.productos%rowtype;
  v_sku   text;
  v_data  jsonb;
begin
  if not (me._claim_zona_ok() or mos._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_cb = '' or v_zona = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere codigoBarra y zona');
  end if;
  v_desde := v_lun - 28;

  select * into v_prod from mos.productos where upper(codigo_barra) = v_cb limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'PRODUCTO_NO_ENCONTRADO');
  end if;
  v_sku := coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto);
  select * into v_canon from mos.productos
   where (nullif(btrim(sku_base),'') = v_sku or id_producto = v_sku)
     and coalesce(nullif(factor_conversion,0),1) = 1
     and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   order by (id_producto = v_sku) desc, id_producto limit 1;
  if v_canon.id_producto is null then v_canon := v_prod; end if;

  with grupo as (
    select upper(codigo_barra) as cb, coalesce(nullif(factor_conversion,0),1) as f
      from mos.productos
     where nullif(btrim(sku_base),'') = v_sku or id_producto = v_sku or upper(codigo_barra) = v_cb
    union
    select upper(e.codigo_barra), 1 from mos.equivalencias e
     where e.sku_base = v_sku and coalesce(e.activo, true)
  ),
  ventas_all as (
    -- [532] ventana completa, TODAS las zonas (se parte adentro)
    select upper(coalesce(v.zona_id,'')) as zona,
           (v.fecha at time zone 'America/Lima')::date as dia,
           sum(coalesce(vd.cantidad,0) * g.f) as u
      from me.ventas v
      join me.ventas_detalle vd on vd.id_venta = v.id_venta
      join grupo g on upper(coalesce(vd.cod_barras,'')) = g.cb
     where (v.fecha at time zone 'America/Lima')::date >= v_desde
       and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
     group by 1, 2
  ),
  ventas_dia as (
    select dia, sum(u) as u from ventas_all where zona = v_zona group by 1
  ),
  otras as (
    select zona, sum(u) as u from ventas_all where zona <> v_zona and zona <> '' group by 1
  ),
  hist as (
    select d::date as dia,
           extract(isodow from d)::int as dow,
           ((d::date - v_desde) / 7)::int as w,
           coalesce(vd.u, 0) as u
      from generate_series(v_desde, v_lun - 1, interval '1 day') d
      left join ventas_dia vd on vd.dia = d::date
  ),
  pron as (
    select dow, ceil(avg(u))::numeric as pron from hist group by dow
  ),
  sem as (
    select w, max(u) as pico, sum(u) as vol from hist group by w
  ),
  tend as (
    select case
             when coalesce(sum(vol),0) <= 0 then 'NULA'
             when avg(pico) > 0 and (case when var_pop(w) > 0 then regr_slope(pico, w) else 0 end) / avg(pico) >=  0.10 then 'CRECIENTE'
             when avg(pico) > 0 and (case when var_pop(w) > 0 then regr_slope(pico, w) else 0 end) / avg(pico) <= -0.10 then 'DECRECIENTE'
             else 'ESTABLE'
           end as tendencia,
           coalesce(sum(vol),0) as vol4
      from sem
  ),
  actual as (
    select d::date as dia, extract(isodow from d)::int as dow,
           case when d::date <= v_hoy then coalesce(vd.u, 0) else null end as u,
           coalesce(pr.pron, 0) as pron
      from generate_series(v_lun, v_lun + 6, interval '1 day') d
      left join ventas_dia vd on vd.dia = d::date
      left join pron pr on pr.dow = extract(isodow from d)::int
  ),
  stocks as (
    select
      (select coalesce(sum(s.cantidad_disponible),0) from wh.stock s
        where upper(coalesce(s.cod_producto,'')) in (select cb from grupo)) as alm,
      (select coalesce(sum(sz.cantidad),0) from me.stock_zonas sz
        where upper(btrim(sz.zona_id)) = v_zona
          and upper(coalesce(sz.cod_barras,'')) in (select cb from grupo)) as zon,
      (select to_char(min(zl.fecha_vencimiento) at time zone 'America/Lima','YYYY-MM-DD')
         from me.zona_lotes zl
        where zl.zona_id = v_zona and coalesce(zl.cant_restante,0) > 0
          and (zl.sku_base = v_sku or upper(coalesce(zl.cod_barras,'')) in (select cb from grupo))) as venc
  )
  select jsonb_build_object(
    'ok', true,
    'producto', jsonb_build_object(
      'nombre', v_canon.descripcion, 'codigoBarra', v_canon.codigo_barra,
      'skuBase', v_sku, 'foto', coalesce(v_canon.foto_url,''),
      'esPadreDe', case when upper(coalesce(v_canon.codigo_barra,'')) <> v_cb then v_prod.descripcion else '' end),
    'zona', v_zona,
    'hoy', to_char(v_hoy,'YYYY-MM-DD'),
    'tendencia', (select tendencia from tend),
    'volumen4sem', (select vol4 from tend),
    'historial', (select coalesce(jsonb_agg(jsonb_build_object(
        'fecha', to_char(dia,'YYYY-MM-DD'), 'dow', dow, 'sem', w + 1, 'u', u) order by dia), '[]'::jsonb) from hist),
    'semanaActual', (select coalesce(jsonb_agg(jsonb_build_object(
        'fecha', to_char(dia,'YYYY-MM-DD'), 'dow', dow, 'u', u, 'pron', pron,
        'esHoy', dia = v_hoy) order by dia), '[]'::jsonb) from actual),
    'pronSemana', (select coalesce(sum(pron),0) from actual),
    'vendidosSemana', (select coalesce(sum(u),0) from actual where u is not null),
    'stockAlmacen', (select alm from stocks),
    'stockZona', (select zon from stocks),
    'vencProxZona', coalesce((select venc from stocks),''),
    'otrasZonas', (select coalesce(sum(u),0) from otras),
    'otrasZonasDetalle', (select coalesce(jsonb_agg(jsonb_build_object('zona', zona, 'u', u) order by u desc), '[]'::jsonb) from otras)
  ) into v_data;

  return v_data;
end; $fn$;
grant execute on function me.analitica_pos(jsonb) to authenticated;
