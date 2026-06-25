-- 146 · catalogo_pos_rls: (b) fix filtro estado BOOLEAN (apagados dejan de filtrarse a ME) +
-- (c) entrega segmentos_precio resuelto por sku_base en cada PRESENTACION (ME lo aplica via _meCalcPrecioGranel,
-- y el equivalente lo recibe al resolver su barcode -> sku_base -> grupo). Solo cambian: el WHERE de `act`
-- y los objetos PRODUCTO_BASE/PRESENTACION (+segmentos_precio). Resto identico.
create or replace function mos.catalogo_pos_rls()
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_pb jsonb := '[]'::jsonb; v_pr jsonb := '[]'::jsonb; v_eq jsonb; v_zc jsonb; v_cf jsonb; v_sz jsonb; g record;
  v_tramos_map jsonb;
begin
  -- [PERF] pre-cargar TODOS los tramos en un mapa sku_base->tramos UNA vez (evita N subqueries en el loop)
  select coalesce(jsonb_object_agg(sku_base, tramos), '{}'::jsonb) into v_tramos_map from mos.precio_tramos;

  for g in
    with act as (
      select coalesce(nullif(btrim(sku_base),''), id_producto) as sku,
             id_producto, codigo_barra, descripcion, precio_venta,
             coalesce(nullif(factor_conversion,0),1) as factor,
             (coalesce(btrim(es_envasable::text),'') <> '1') as vendible,
             coalesce(es_envasable::text,'') as es_env,
             tipo_igv, unidad, unidad_medida, cod_sunat
        from mos.productos
       where coalesce(estado, true) = true          -- [b FIX] estado es BOOLEAN: excluir apagados (false), no '0'
    )
    select sku, jsonb_agg(to_jsonb(act) order by factor asc) as members from act group by sku
  loop
    declare
      v_members jsonb := g.members; v_vend jsonb; v_base jsonb; v_f1 jsonb; v_nombre text; m jsonb;
      v_tramos jsonb;
    begin
      select coalesce(jsonb_agg(value order by (value->>'factor')::numeric asc),'[]'::jsonb)
        into v_vend from jsonb_array_elements(v_members) where (value->>'vendible')::boolean;
      if jsonb_array_length(v_vend) = 0 then continue; end if;

      -- [fix dinero] DESEMPATE KGM: en grupos unidad-mixta (KGM+NIU, ambos factor=1) el `limit 1` arbitrario
      -- podía elegir la fila NIU → PRODUCTO_BASE.Unidad_Medida='NIU' → en ME `_esGranelItem` (chequea KGM)
      -- falla → los tramos del granel se IGNORAN en silencio → precio cobrado sin ajuste. Preferir KGM.
      select value into v_f1 from jsonb_array_elements(v_members) where (value->>'factor')::numeric = 1
        order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1;
      select value into v_base from jsonb_array_elements(v_vend) where (value->>'factor')::numeric = 1
        order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1;
      if v_base is null then v_base := v_vend->0; end if;

      if v_f1 is not null and not (v_f1->>'vendible')::boolean
         and coalesce(v_f1->>'id_producto','') <> coalesce(v_base->>'id_producto','') then
        v_nombre := btrim(coalesce(nullif(btrim(v_f1->>'descripcion'),''),'') || ' ' || coalesce(v_base->>'descripcion',''));
      else
        v_nombre := btrim(coalesce(v_base->>'descripcion',''));
      end if;

      -- [c] tramos del GRUPO (por sku_base, desde el mapa pre-cargado) -> a cada presentacion; ME los aplica al canonico
      v_tramos := v_tramos_map -> g.sku;

      v_pb := v_pb || jsonb_build_array(jsonb_build_object(
        'SKU_Base', g.sku, 'Nombre', v_nombre,
        'Tipo_IGV', mos._conv_tipo_igv(v_base->>'tipo_igv'),
        'Unidad_Medida', mos._norm_unidad_medida(v_base->>'unidad', v_base->>'unidad_medida'),
        'Cod_SUNAT', coalesce(v_base->>'cod_sunat',''),
        'segmentos_precio', coalesce(v_tramos,'[]'::jsonb)));

      for m in select value from jsonb_array_elements(v_vend) loop
        v_pr := v_pr || jsonb_build_array(
          jsonb_build_object(
            'SKU_Base', g.sku, 'SKU', coalesce(m->>'id_producto',''),
            'Cod_Barras', coalesce(nullif(btrim(m->>'codigo_barra'),''), m->>'id_producto'),
            'Empaque', coalesce(m->>'descripcion',''),
            'Precio_Venta', coalesce((m->>'precio_venta')::numeric, 0),
            'Factor', coalesce((m->>'factor')::numeric, 1))
          -- [c] segmentos_precio SOLO en la canónica (Factor=1, lo único que ME lee) y solo si hay tramos
          --     → no infla las 2358 presentaciones (el append es O(n²) en la longitud del array).
          || case when (m->>'factor')::numeric = 1 and v_tramos is not null
                  then jsonb_build_object('segmentos_precio', v_tramos) else '{}'::jsonb end);
      end loop;
    end;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('Cod_Alias', codigo_barra, 'Cod_Barras_Real', sku_base)), '[]'::jsonb)
    into v_eq from mos.equivalencias where activo;
  with imp as (
    select id_estacion, max(printnode_id) as pn from mos.impresoras
     where activo and (coalesce(lower(app_origen),'') in ('','mosexpress')) and (coalesce(upper(tipo),'') in ('','TICKET')) group by id_estacion),
  ser as (
    select id_zona,
      max(serie) filter (where upper(replace(replace(tipo_documento,' ',''),'_','')) in ('NOTAVENTA','NV','NOTADEVENTA')) as nota,
      max(serie) filter (where upper(tipo_documento)='BOLETA') as boleta,
      max(serie) filter (where upper(tipo_documento)='FACTURA') as factura
    from mos.series_documentales where activo group by id_zona)
  select coalesce(jsonb_agg(jsonb_build_object(
           'Zona_ID', e.id_zona, 'Estacion_Nombre', e.nombre, 'idEstacion', e.id_estacion,
           'PrintNode_ID', coalesce(imp.pn,''), 'Serie_Nota', coalesce(ser.nota,''),
           'Serie_Boleta', coalesce(ser.boleta,''), 'Serie_Factura', coalesce(ser.factura,''),
           'Admin_PIN', coalesce(e.admin_pin,''))), '[]'::jsonb)
    into v_zc from mos.estaciones e
    left join imp on imp.id_estacion = e.id_estacion left join ser on ser.id_zona = e.id_zona
   where e.activo and coalesce(lower(e.app_origen),'') in ('','mosexpress') and coalesce(btrim(e.nombre),'') <> '';
  select coalesce(jsonb_agg(jsonb_build_object('Documento', documento, 'Nombre_RazonSocial', nombre, 'Direccion', coalesce(direccion,''))), '[]'::jsonb)
    into v_cf from me.clientes_frecuentes;
  select coalesce(jsonb_agg(jsonb_build_object('Cod_Barras', cod_barras, 'Zona_ID', zona_id, 'Cantidad', cantidad)), '[]'::jsonb)
    into v_sz from me.stock_zonas;

  return jsonb_build_object('status','success','data', jsonb_build_object(
    'PRODUCTO_BASE', v_pb, 'PRESENTACIONES', v_pr, 'EQUIVALENCIAS', v_eq,
    'ZONAS_CONFIG', v_zc, 'CLIENTES_FRECUENTES', v_cf, 'STOCK_ZONAS', v_sz, 'PROMOCIONES', '[]'::jsonb,
    '_meta', jsonb_build_object('fuente','SUPABASE','timestamp', (extract(epoch from now())*1000)::bigint)));
end;
$fn$;
