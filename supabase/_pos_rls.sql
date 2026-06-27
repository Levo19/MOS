CREATE OR REPLACE FUNCTION mos.catalogo_pos_rls()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pb   jsonb := '[]'::jsonb;   -- PRODUCTO_BASE
  v_pr   jsonb := '[]'::jsonb;   -- PRESENTACIONES
  v_eq   jsonb;                  -- EQUIVALENCIAS
  v_zc   jsonb;                  -- ZONAS_CONFIG
  v_cf   jsonb;                  -- CLIENTES_FRECUENTES
  v_sz   jsonb;                  -- STOCK_ZONAS
  g      record;
begin
  -- ── PRODUCTO_BASE + PRESENTACIONES: agrupado por skuBase (espejo del GAS) ──
  for g in
    with act as (
      select coalesce(nullif(btrim(sku_base),''), id_producto) as sku,
             id_producto, codigo_barra, descripcion, precio_venta,
             coalesce(nullif(factor_conversion,0),1) as factor,
             (coalesce(btrim(es_envasable::text),'') <> '1') as vendible,
             coalesce(es_envasable::text,'') as es_env,
             tipo_igv, unidad, unidad_medida, cod_sunat
        from mos.productos
       where coalesce(estado::text,'') <> '0'
    )
    select sku,
           jsonb_agg(to_jsonb(act) order by factor asc) as members
      from act
     group by sku
  loop
    declare
      v_members jsonb := g.members;
      v_vend    jsonb;
      v_base    jsonb;
      v_f1      jsonb;
      v_nombre  text;
      m         jsonb;
    begin
      -- vendibles (esEnvasable<>1)
      select coalesce(jsonb_agg(value order by (value->>'factor')::numeric asc),'[]'::jsonb)
        into v_vend from jsonb_array_elements(v_members) where (value->>'vendible')::boolean;
      if jsonb_array_length(v_vend) = 0 then continue; end if;  -- todo envasable → oculto

      -- miembro factor=1 (cualquiera) y base (vendible factor=1, si no el primer vendible)
      select value into v_f1 from jsonb_array_elements(v_members)
        where (value->>'factor')::numeric = 1 limit 1;
      select value into v_base from jsonb_array_elements(v_vend)
        where (value->>'factor')::numeric = 1 limit 1;
      if v_base is null then v_base := v_vend->0; end if;

      -- nombre: base nominal envasable + presentación huérfana → concatenar
      if v_f1 is not null and not (v_f1->>'vendible')::boolean
         and coalesce(v_f1->>'id_producto','') <> coalesce(v_base->>'id_producto','') then
        v_nombre := btrim(coalesce(nullif(btrim(v_f1->>'descripcion'),''),'')
                    || ' ' || coalesce(v_base->>'descripcion',''));
      else
        v_nombre := btrim(coalesce(v_base->>'descripcion',''));
      end if;

      v_pb := v_pb || jsonb_build_array(jsonb_build_object(
        'SKU_Base', g.sku,
        'Nombre', v_nombre,
        'Tipo_IGV', mos._conv_tipo_igv(v_base->>'tipo_igv'),
        'Unidad_Medida', mos._norm_unidad_medida(v_base->>'unidad', v_base->>'unidad_medida'),
        'Cod_SUNAT', coalesce(v_base->>'cod_sunat','')));

      -- PRESENTACIONES: solo vendibles
      for m in select value from jsonb_array_elements(v_vend) loop
        v_pr := v_pr || jsonb_build_array(jsonb_build_object(
          'SKU_Base', g.sku,
          'SKU', coalesce(m->>'id_producto',''),
          'Cod_Barras', coalesce(nullif(btrim(m->>'codigo_barra'),''), m->>'id_producto'),
          'Empaque', coalesce(m->>'descripcion',''),
          'Precio_Venta', coalesce((m->>'precio_venta')::numeric, 0),
          'Factor', coalesce((m->>'factor')::numeric, 1)));
      end loop;
    end;
  end loop;

  -- ── EQUIVALENCIAS ──
  select coalesce(jsonb_agg(jsonb_build_object('Cod_Alias', codigo_barra, 'Cod_Barras_Real', sku_base)), '[]'::jsonb)
    into v_eq from mos.equivalencias where activo;

  -- ── ZONAS_CONFIG (estaciones + impresoras TICKET + series, app mosexpress) ──
  with imp as (
    select id_estacion, max(printnode_id) as pn from mos.impresoras
     where activo and (coalesce(lower(app_origen),'') in ('','mosexpress'))
       and (coalesce(upper(tipo),'') in ('','TICKET'))
     group by id_estacion
  ),
  ser as (
    select id_zona,
      max(serie) filter (where upper(replace(replace(tipo_documento,' ',''),'_','')) in ('NOTAVENTA','NV','NOTADEVENTA')) as nota,
      max(serie) filter (where upper(tipo_documento)='BOLETA')  as boleta,
      max(serie) filter (where upper(tipo_documento)='FACTURA') as factura
    from mos.series_documentales where activo group by id_zona
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'Zona_ID', e.id_zona, 'Estacion_Nombre', e.nombre, 'idEstacion', e.id_estacion,
           'PrintNode_ID', coalesce(imp.pn,''),
           'Serie_Nota', coalesce(ser.nota,''), 'Serie_Boleta', coalesce(ser.boleta,''),
           'Serie_Factura', coalesce(ser.factura,''), 'Admin_PIN', coalesce(e.admin_pin,''))), '[]'::jsonb)
    into v_zc
    from mos.estaciones e
    left join imp on imp.id_estacion = e.id_estacion
    left join ser on ser.id_zona = e.id_zona
   where e.activo and coalesce(lower(e.app_origen),'') in ('','mosexpress')
     and coalesce(btrim(e.nombre),'') <> '';

  -- ── CLIENTES_FRECUENTES + STOCK_ZONAS ──
  select coalesce(jsonb_agg(jsonb_build_object('Documento', documento, 'Nombre_RazonSocial', nombre, 'Direccion', coalesce(direccion,''))), '[]'::jsonb)
    into v_cf from me.clientes_frecuentes;
  select coalesce(jsonb_agg(jsonb_build_object('Cod_Barras', cod_barras, 'Zona_ID', zona_id, 'Cantidad', cantidad)), '[]'::jsonb)
    into v_sz from me.stock_zonas;

  return jsonb_build_object('status','success','data', jsonb_build_object(
    'PRODUCTO_BASE', v_pb, 'PRESENTACIONES', v_pr, 'EQUIVALENCIAS', v_eq,
    'ZONAS_CONFIG', v_zc, 'CLIENTES_FRECUENTES', v_cf, 'STOCK_ZONAS', v_sz,
    'PROMOCIONES', '[]'::jsonb,
    '_meta', jsonb_build_object('fuente','SUPABASE','timestamp', (extract(epoch from now())*1000)::bigint)));
end;
$function$
