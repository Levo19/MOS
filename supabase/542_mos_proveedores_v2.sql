-- ════════════════════════════════════════════════════════════════════════════
-- 542 · Proveedores v2 — RPC enriquecida (familia+derivados, costos, competencia)
-- ════════════════════════════════════════════════════════════════════════════
-- Diseño aprobado por el dueño (mockup 2026-07-22, artifact f0e3b615). Reglas:
--  · FAMILIA = canónico + equivalentes + DERIVADOS (codigo_producto_base → padre,
--    convertidos por factor_conversion_base). El derivado cuenta stock Y rotación
--    hacia el padre ("si vendo 500gr envaso → compro el padre para envasar").
--  · Σ familia SIN negativos (un stock <0 se reporta pero no suma: seguro no hay).
--  · Costos: precio_referencia está en 0 en toda la BD → el costo REAL se
--    auto-aprende de wh.guia_detalle.precio_unitario (últimos 3).
--  · Competencia: otros proveedores del MISMO sku con SU último costo real.
--  · Cobertura en SEMANAS reemplaza a las alertas min/max (el dueño no las usa).
--  · Sugerencia = base editable (cubrir 1 semana +20%), jamás fija.
-- v2 = WRAPPER que enriquece a mos.productos_proveedor_stock (109 queda intacta
-- y en paridad; cero riesgo sobre el módulo v1 mientras conviven).
-- ════════════════════════════════════════════════════════════════════════════

create or replace function mos.productos_proveedor_stock_v2(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_base  jsonb;
  v_items jsonb;
  v_out   jsonb := '[]'::jsonb;
  it      jsonb;
  v_sku   text;
  v_upb   numeric;
  v_barras text[];
  v_der   jsonb;
  v_der_stock_eq numeric;
  v_der_ven_dia  numeric;
  v_stock_pos numeric;
  v_tiene_neg boolean;
  v_rot_fam numeric;
  v_cob   numeric;
  v_sug_u numeric;
  v_sug_b numeric;
  v_costos jsonb;
  v_comp  jsonb;
  z       jsonb;
begin
  v_base := mos.productos_proveedor_stock(p);
  if coalesce((v_base->>'ok')::boolean, false) = false then return v_base; end if;
  v_items := coalesce(v_base->'data', '[]'::jsonb);

  for it in select * from jsonb_array_elements(v_items) loop
    v_sku := coalesce(it->>'skuBase','');
    v_upb := greatest(coalesce(nullif(it->>'unidadesPorBulto','')::numeric, 1), 1);

    -- barras de la familia canónica (master + equivalencias activas)
    select coalesce(array_agg(distinct cb), '{}') into v_barras from (
      select nullif(btrim(pr.codigo_barra),'') as cb from mos.productos pr
        where coalesce(nullif(pr.sku_base,''), pr.id_producto) = v_sku
      union
      select nullif(btrim(e.codigo_barra),'') from mos.equivalencias e
        where e.sku_base = v_sku and coalesce(e.activo, true) = true
    ) b where cb is not null;

    -- ── DERIVADOS del padre: stock (+eq) y ventas 30d (+eq/día) ──────────────
    select coalesce(jsonb_agg(jsonb_build_object(
             'sku', d.sku, 'nombre', d.descripcion,
             'stock', d.stock, 'factorEq', d.factor,
             'stockPadreEq', round((greatest(d.stock,0) * d.factor)::numeric, 2),
             'ventas30', d.ventas30,
             'ventasPadreEqDia', round((d.ventas30 / 30.0 * d.factor)::numeric, 3)
           ) order by d.stock desc), '[]'::jsonb),
           coalesce(sum(greatest(d.stock,0) * d.factor), 0),
           coalesce(sum(d.ventas30 / 30.0 * d.factor), 0)
      into v_der, v_der_stock_eq, v_der_ven_dia
    from (
      select coalesce(nullif(dp.sku_base,''), dp.id_producto) as sku,
             dp.descripcion,
             greatest(coalesce(dp.factor_conversion_base, 0), 0) as factor,
             coalesce((select sum(s.cantidad_disponible) from wh.stock s
                        where s.cod_producto = dp.id_producto or s.cod_producto = nullif(btrim(dp.codigo_barra),'')), 0)
             + coalesce((select sum(z1.cantidad) from me.stock_zonas z1
                        where z1.cod_barras = nullif(btrim(dp.codigo_barra),'')), 0) as stock,
             coalesce((select sum(vd.cantidad) from me.ventas_detalle vd
                        join me.ventas ve on ve.id_venta = vd.id_venta
                        where (nullif(btrim(vd.sku),'') = dp.id_producto or nullif(btrim(vd.cod_barras),'') = nullif(btrim(dp.codigo_barra),''))
                          and ve.fecha > now() - interval '30 days'
                          and upper(coalesce(ve.estado_envio,'')) <> 'ANULADO'), 0) as ventas30
      from mos.productos dp
      where dp.tipo_producto = 'DERIVADO'
        and nullif(btrim(dp.codigo_producto_base),'') = v_sku
    ) d;

    -- ── Σ FAMILIA sin negativos + flag ───────────────────────────────────────
    v_stock_pos := greatest(coalesce(nullif(it->>'stockWh','')::numeric,0), 0);
    v_tiene_neg := coalesce(nullif(it->>'stockWh','')::numeric,0) < 0;
    for z in select * from jsonb_array_elements(coalesce(it->'zonas','[]'::jsonb)) loop
      v_stock_pos := v_stock_pos + greatest(coalesce(nullif(z->>'cantidad','')::numeric,0), 0);
      if coalesce(nullif(z->>'cantidad','')::numeric,0) < 0 then v_tiene_neg := true; end if;
    end loop;
    if it->'zonasHuerfanas' is not null and jsonb_typeof(it->'zonasHuerfanas') = 'object' then
      v_stock_pos := v_stock_pos + greatest(coalesce(nullif(it->'zonasHuerfanas'->>'cantidad','')::numeric,0), 0);
      if coalesce(nullif(it->'zonasHuerfanas'->>'cantidad','')::numeric,0) < 0 then v_tiene_neg := true; end if;
    end if;
    v_stock_pos := v_stock_pos + v_der_stock_eq;

    -- ── rotación familia (sku total ya = Σ zonas; + derivados convertidos) ───
    v_rot_fam := coalesce(nullif(it->>'rotacionDia','')::numeric,0) + v_der_ven_dia;
    v_cob := case when v_rot_fam > 0 then round((v_stock_pos / (v_rot_fam * 7))::numeric, 2) else null end;
    v_sug_u := greatest(0, ceil(v_rot_fam * 7 * 1.2 - v_stock_pos));
    v_sug_b := case when v_sug_u > 0 then greatest(1, ceil(v_sug_u / v_upb)) else 0 end;

    -- ── últimos 3 costos reales de ESTE proveedor (guia_detalle) ────────────
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha', to_char(c.fecha at time zone 'America/Lima', 'DD Mon'),
             'costo', round(c.precio::numeric, 2)) order by c.fecha desc), '[]'::jsonb)
      into v_costos
    from (
      select g.fecha, gd.precio_unitario as precio
      from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
      where g.id_proveedor = v_prov and g.tipo = 'INGRESO_PROVEEDOR'
        and gd.cod_producto = any(v_barras) and coalesce(gd.precio_unitario,0) > 0
      order by g.fecha desc limit 3
    ) c;

    -- ── competencia: otros proveedores del mismo sku + su último costo ──────
    select coalesce(jsonb_agg(jsonb_build_object(
             'idProveedor', q.idp, 'proveedor', q.nombre,
             'costo', q.costo, 'fecha', q.f) order by q.costo nulls last), '[]'::jsonb)
      into v_comp
    from (
      select pp2.id_proveedor as idp, pv.nombre,
             (select round(gd.precio_unitario::numeric,2)
                from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
               where g.id_proveedor = pp2.id_proveedor and g.tipo='INGRESO_PROVEEDOR'
                 and gd.cod_producto = any(v_barras) and coalesce(gd.precio_unitario,0) > 0
               order by g.fecha desc limit 1) as costo,
             (select to_char(max(g.fecha) at time zone 'America/Lima','DD Mon')
                from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
               where g.id_proveedor = pp2.id_proveedor and g.tipo='INGRESO_PROVEEDOR'
                 and gd.cod_producto = any(v_barras) and coalesce(gd.precio_unitario,0) > 0) as f
      from mos.proveedores_productos pp2
      join mos.proveedores pv on pv.id_proveedor = pp2.id_proveedor
      where pp2.sku_base = v_sku and coalesce(pp2.activa,false) = true
        and pp2.id_proveedor <> v_prov
      limit 2
    ) q;

    v_out := v_out || (it || jsonb_build_object(
      'familia', jsonb_build_object(
        'stockPos',       round(v_stock_pos::numeric, 2),
        'tieneNegativos', v_tiene_neg,
        'derivados',      v_der,
        'rotFamiliaDia',  round(v_rot_fam::numeric, 3),
        'coberturaSem',   v_cob
      ),
      'sugerenciaV2', jsonb_build_object(
        'bultos', v_sug_b, 'unidades', v_sug_u,
        'razon', case
          when v_rot_fam <= 0 then 'sin rotación registrada'
          when v_sug_b = 0 then 'la familia cubre ' || coalesce(v_cob::text,'∞') || ' semanas'
          else 'cubrir 1 semana (+20%) · familia tiene ' || round(v_stock_pos::numeric,1) || ' y rota ' || round((v_rot_fam*7)::numeric,1) || '/sem'
        end
      ),
      'ultimosCostos', v_costos,
      'competencia',   v_comp
    ));
  end loop;

  return (v_base - 'data') || jsonb_build_object('data', v_out, '_v2', true);
end;
$fn$;

-- ── Candidatos desde SUS guías (para ➕ con evidencia — nunca bulk) ──────────
create or replace function mos.prov_guia_candidatos(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_prov text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_prov is null then return jsonb_build_object('ok', false, 'error', 'idProveedor requerido'); end if;

  with det as (
    select gd.cod_producto as cod, g.fecha, gd.precio_unitario as precio, g.id_guia
    from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
    where g.id_proveedor = v_prov and g.tipo = 'INGRESO_PROVEEDOR'
  ),
  res as (
    select coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           max(pr.descripcion) as descripcion,
           max(d.cod)  as cb,
           count(distinct d.id_guia) as veces,
           max(d.fecha) as ult,
           (array_agg(d.precio order by d.fecha desc))[1] as ult_costo
    from det d
    join mos.productos pr on pr.codigo_barra = d.cod or pr.id_producto = d.cod
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'skuBase', r.sku, 'descripcion', r.descripcion, 'codigoBarra', r.cb,
           'veces', r.veces,
           'ultFecha', to_char(r.ult at time zone 'America/Lima','DD Mon'),
           'ultCosto', case when coalesce(r.ult_costo,0) > 0 then round(r.ult_costo::numeric,2) else null end,
           'pocaEvidencia', (r.veces < 2)
         ) order by r.ult desc), '[]'::jsonb)
    into v_data
  from res r
  where r.sku not in (
    select pp.sku_base from mos.proveedores_productos pp where pp.id_proveedor = v_prov
  );

  return jsonb_build_object('ok', true, 'data', coalesce(v_data,'[]'::jsonb));
end;
$fn$;

revoke all on function mos.productos_proveedor_stock_v2(jsonb), mos.prov_guia_candidatos(jsonb) from public;
grant execute on function mos.productos_proveedor_stock_v2(jsonb), mos.prov_guia_candidatos(jsonb) to authenticated, service_role;
