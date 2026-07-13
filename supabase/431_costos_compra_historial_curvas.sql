-- 431 · [v5 §10-§11] COSTOS DE COMPRA → catálogo + HISTORIAL + curvas precio/costo
-- Paso 1 del secuencial: los montos de la factura se vuelven costo del CANÓNICO
-- (unidad canónica: pack ÷ factor), con historial fechado (quién/qué guía/antes/después).
-- El guardado del detalle de la guía sigue siendo wh.actualizar_precios_detalle (383) —
-- esta RPC hace la parte que el cutover dejó pendiente: el CATÁLOGO y su historia.
-- GUARD del dueño: esto NO toca precios de venta (eso es Paso 2, con confirmación).
-- CERO GAS.

create or replace function mos.aplicar_costos_compra(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_usr  text := coalesce(p->>'usuario','');
  it jsonb; v_cb text; v_costo numeric;
  v_prod record; v_canon record;
  v_factor numeric; v_costo_canon numeric; v_prev numeric;
  v_out jsonb := '[]'::jsonb;
  v_hist jsonb;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(p->'items') <> 'array' then
    return jsonb_build_object('ok',false,'error','Requiere items[]');
  end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_cb    := upper(btrim(coalesce(it->>'codProducto', it->>'codigoBarra','')));
    v_costo := mos._numn(it->>'costoUnitario');
    if v_cb = '' or v_costo is null or v_costo <= 0 then continue; end if;

    -- producto comprado (por cb; equivalencias también resuelven)
    select pr.* into v_prod from mos.productos pr
     where upper(btrim(coalesce(pr.codigo_barra,''))) = v_cb limit 1;
    if v_prod.id_producto is null then
      select pr.* into v_prod from mos.productos pr
       join mos.equivalencias e on e.activo and upper(btrim(e.codigo_barra)) = v_cb
        and pr.sku_base = e.sku_base and coalesce(nullif(pr.factor_conversion,0),1) = 1
       limit 1;
    end if;
    if v_prod.id_producto is null then
      v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', false, 'error', 'NO_EN_CATALOGO');
      continue;
    end if;

    -- canónico del grupo + costo por UNIDAD CANÓNICA (pack comprado ÷ factor; derivado ÷ porción)
    select pr.* into v_canon from mos.productos pr
     where (pr.sku_base = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto)
            or pr.id_producto = coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto))
       and coalesce(nullif(pr.factor_conversion,0),1) = 1
       and coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = ''
     order by pr.codigo_barra limit 1;
    if v_canon.id_producto is null then v_canon := v_prod; end if;

    v_factor := case
      when coalesce(nullif(btrim(v_prod.codigo_producto_base),''),'') <> ''
           and coalesce(v_prod.factor_conversion_base,0) > 0 then v_prod.factor_conversion_base
      when coalesce(nullif(v_prod.factor_conversion,0),1) <> 1 then v_prod.factor_conversion
      else 1 end;
    v_costo_canon := round(v_costo / nullif(v_factor,0), 4);
    v_prev := v_canon.precio_costo;

    -- persistir costo del canónico + HISTORIAL (accion COSTO, cap 50 — patrón 170)
    v_hist := jsonb_build_object('ts', to_char(now() at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'),
      'accion','COSTO', 'usuario', v_usr, 'source','COMPRA', 'idGuia', coalesce(v_guia,''),
      'costoAnterior', v_prev, 'precioCosto', v_costo_canon,
      'compradoComo', v_prod.descripcion, 'factorAplicado', v_factor);
    update mos.productos
       set precio_costo = v_costo_canon,
           -- append + cap 50 conservando orden cronológico (patrón 170)
           historial_cambios = case
             when jsonb_array_length(coalesce(historial_cambios,'[]'::jsonb)) >= 50 then
               (select jsonb_agg(e order by ord)
                  from jsonb_array_elements(coalesce(historial_cambios,'[]'::jsonb) || v_hist)
                       with ordinality x(e, ord)
                 where ord > 1)
             else coalesce(historial_cambios,'[]'::jsonb) || v_hist
           end
     where id_producto = v_canon.id_producto;

    v_out := v_out || jsonb_build_object('codProducto', v_cb, 'ok', true,
      'idCanonico', v_canon.id_producto, 'skuBase', coalesce(nullif(btrim(v_canon.sku_base),''), v_canon.id_producto),
      'descripcion', v_canon.descripcion, 'costoAnterior', v_prev, 'costoNuevo', v_costo_canon);
  end loop;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object('items', v_out));
end; $fn$;

revoke all on function mos.aplicar_costos_compra(jsonb) from public, anon;
grant execute on function mos.aplicar_costos_compra(jsonb) to authenticated, service_role;

-- ── Curvas del modal §10: series de PRECIO y COSTO desde historial_cambios ──
-- precios: entradas con precioVenta (ya se escriben desde el path directo).
-- costos: entradas accion='COSTO' (nacen con esta 431) + punto actual como cierre.
create or replace function mos.historial_precio_costo(p jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_prod record;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select * into v_prod from mos.productos where id_producto = v_id limit 1;
  if v_prod.id_producto is null then return jsonb_build_object('ok',false,'error','PRODUCTO_NO_ENCONTRADO'); end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'precioActual', v_prod.precio_venta,
    'costoActual',  v_prod.precio_costo,
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object('ts', e->>'ts', 'valor', mos._numn(e->>'precioVenta'),
                                          'usuario', e->>'usuario', 'motivo', e->>'motivo') order by e->>'ts')
      from jsonb_array_elements(coalesce(v_prod.historial_cambios,'[]'::jsonb)) e
      where mos._numn(e->>'precioVenta') is not null), '[]'::jsonb),
    'costos', coalesce((
      select jsonb_agg(jsonb_build_object('ts', e->>'ts', 'valor', mos._numn(e->>'precioCosto'),
                                          'idGuia', e->>'idGuia', 'usuario', e->>'usuario') order by e->>'ts')
      from jsonb_array_elements(coalesce(v_prod.historial_cambios,'[]'::jsonb)) e
      where e->>'accion' = 'COSTO' and mos._numn(e->>'precioCosto') is not null), '[]'::jsonb)
  ));
end; $fn$;

revoke all on function mos.historial_precio_costo(jsonb) from public, anon;
grant execute on function mos.historial_precio_costo(jsonb) to authenticated, service_role;
