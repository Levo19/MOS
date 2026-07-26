-- 568 · mos.operacion_detalle: resolver CÓDIGOS EQUIVALENTES.
-- Bug: el detalle de compra/costos enriquecía el nombre solo con mos.productos por
-- codigo_barra/id_producto. Un código equivalente (mos.equivalencias) NO matcheaba →
-- descripcion "(no en catálogo)" y sin precio/categoría. Ahora se resuelve el canónico
-- vía equivalencias.codigo_barra → sku_base → mos.productos (canónico primero).
create or replace function mos.operacion_detalle(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_fuente text := upper(btrim(coalesce(p->>'fuente','')));
  v_idg    text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_lin    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_fuente = '' or v_idg is null then return jsonb_build_object('ok',false,'error','Requiere fuente y idGuia'); end if;

  if v_fuente = 'WH' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'idDetalle',         coalesce(d.id_detalle,''),
      'codigoProducto',    d.cod_producto,
      'descripcion',       coalesce(pr.descripcion, eqp.descripcion, '⚠ '||d.cod_producto||' (no en catálogo)'),
      'esEquivalencia',    (pr.id_producto is null and eq.sku_base is not null),
      'cantidad',          coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0),
      'precioUnitario',    coalesce(d.precio_unitario,0),
      'subtotal',          coalesce(nullif(d.cant_recibida,0), d.cant_esperada, 0) * coalesce(d.precio_unitario,0),
      'fechaVencimiento',  coalesce(d.fecha_vencimiento::text,''),
      'precioVentaActual', coalesce(pr.precio_venta, eqp.precio_venta, 0),
      'precioCostoActual', coalesce(pr.precio_costo, eqp.precio_costo, 0),
      'categoria',         coalesce(nullif(pr.id_categoria,''), eqp.id_categoria, '')
    ) order by d.linea), '[]'::jsonb) into v_lin
    from wh.guia_detalle d
    left join mos.productos pr on (upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) or pr.id_producto = d.cod_producto)
    left join lateral (select e.sku_base from mos.equivalencias e
                        where upper(btrim(e.codigo_barra)) = upper(btrim(d.cod_producto)) and e.activo is true limit 1) eq on (pr.id_producto is null)
    left join lateral (select px.descripcion, px.precio_venta, px.precio_costo, px.id_categoria from mos.productos px
                        where px.sku_base = eq.sku_base order by (px.codigo_producto_base is null) desc, px.id_producto limit 1) eqp on true
    where d.id_guia = v_idg;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('fuente','WH','idGuia',v_idg,'lineas',v_lin));

  elsif v_fuente = 'ME' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'codigoBarra',    d.cod_barras,
      'descripcion',    coalesce(pr.descripcion, eqp.descripcion, '⚠ '||d.cod_barras||' (no en catálogo)'),
      'esEquivalencia', (pr.id_producto is null and eq.sku_base is not null),
      'cantidad',       coalesce(d.cantidad,0),
      'precioUnitario', coalesce(pr.precio_venta, eqp.precio_venta, 0),
      'subtotal',       coalesce(d.cantidad,0) * coalesce(pr.precio_venta, eqp.precio_venta, 0)
    ) order by d.linea), '[]'::jsonb) into v_lin
    from me.guias_detalle d
    left join mos.productos pr on upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_barras))
    left join lateral (select e.sku_base from mos.equivalencias e
                        where upper(btrim(e.codigo_barra)) = upper(btrim(d.cod_barras)) and e.activo is true limit 1) eq on (pr.id_producto is null)
    left join lateral (select px.descripcion, px.precio_venta, px.precio_costo, px.id_categoria from mos.productos px
                        where px.sku_base = eq.sku_base order by (px.codigo_producto_base is null) desc, px.id_producto limit 1) eqp on true
    where d.id_guia = v_idg;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('fuente','ME','idGuia',v_idg,'lineas',v_lin));
  end if;

  return jsonb_build_object('ok',false,'error','Fuente desconocida: '||v_fuente);
end; $fn$;
revoke all on function mos.operacion_detalle(jsonb) from public, anon;
grant execute on function mos.operacion_detalle(jsonb) to authenticated, service_role;
