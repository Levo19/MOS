CREATE OR REPLACE FUNCTION mos.actualizar_producto(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id       text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_codmatch text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_row      record;
  v_pv_new   numeric;
  v_pv_old   numeric;
  v_cambio_precio boolean := false;
  v_pres_upd int := 0;
  v_unidad   text := nullif(btrim(coalesce(p->>'unidad','')),'');
  v_unidadm  text := nullif(btrim(coalesce(p->>'Unidad_Medida','')),'');
  v_es_canon boolean;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- localizar la fila (match por idProducto cuando viene, si no por codigoBarra) — paridad GAS
  if v_id is not null then
    select * into v_row from mos.productos where id_producto = v_id limit 1;
  elsif v_codmatch is not null then
    select * into v_row from mos.productos where btrim(coalesce(codigo_barra,'')) = v_codmatch limit 1;
  else
    return jsonb_build_object('ok',false,'error','Requiere idProducto o codigoBarra');
  end if;
  if not found then return jsonb_build_object('ok',false,'error','Producto no encontrado'); end if;

  -- validación de precioVenta si viene (no 0 ni vacío) — paridad GAS
  if (p ? 'precioVenta') and nullif(btrim(coalesce(p->>'precioVenta','')),'') is not null then
    v_pv_new := mos._numn(p->>'precioVenta');
    if v_pv_new is null or v_pv_new <= 0 then
      return jsonb_build_object('ok',false,'error','El precio de venta no puede ser 0 ni vacío');
    end if;
  end if;

  -- sincronizar unidad/Unidad_Medida (paridad GAS: si solo uno, copiar; si ambos distintos, prima Unidad_Medida)
  if v_unidad is not null and v_unidadm is null then v_unidadm := v_unidad;
  elsif v_unidadm is not null and v_unidad is null then v_unidad := v_unidadm;
  elsif v_unidad is not null and v_unidadm is not null and v_unidad <> v_unidadm then v_unidad := v_unidadm;
  end if;

  v_pv_old := v_row.precio_venta;

  update mos.productos t set
    sku_base               = case when nullif(btrim(coalesce(p->>'skuBase','')),'') is not null then btrim(p->>'skuBase') else t.sku_base end,
    codigo_barra           = case when nullif(btrim(coalesce(p->>'codigoBarra','')),'') is not null then btrim(p->>'codigoBarra') else t.codigo_barra end,
    descripcion            = case when nullif(btrim(coalesce(p->>'descripcion','')),'') is not null then btrim(p->>'descripcion') else t.descripcion end,
    id_categoria           = case when nullif(btrim(coalesce(p->>'idCategoria','')),'') is not null then btrim(p->>'idCategoria') else t.id_categoria end,
    unidad                 = coalesce(v_unidad, t.unidad),
    unidad_medida          = coalesce(v_unidadm, t.unidad_medida),
    codigo_producto_base   = case when nullif(btrim(coalesce(p->>'codigoProductoBase','')),'') is not null then btrim(p->>'codigoProductoBase') else t.codigo_producto_base end,
    factor_conversion      = case when nullif(btrim(coalesce(p->>'factorConversion','')),'') is not null then mos._numn(p->>'factorConversion') else t.factor_conversion end,
    factor_conversion_base = case when nullif(btrim(coalesce(p->>'factorConversionBase','')),'') is not null then mos._numn(p->>'factorConversionBase') else t.factor_conversion_base end,
    marca                  = case when p ? 'marca'          then nullif(btrim(coalesce(p->>'marca','')),'')      else t.marca end,
    precio_venta           = case when v_pv_new is not null then v_pv_new                                         else t.precio_venta end,
    precio_costo           = case when p ? 'precioCosto'    then mos._numn(p->>'precioCosto')                     else t.precio_costo end,
    cod_tributo            = case when p ? 'Cod_Tributo'    then nullif(btrim(coalesce(p->>'Cod_Tributo','')),'') else t.cod_tributo end,
    igv_porcentaje         = case when p ? 'IGV_Porcentaje' then mos._numn(p->>'IGV_Porcentaje')                  else t.igv_porcentaje end,
    cod_sunat              = case when p ? 'Cod_SUNAT'      then nullif(btrim(coalesce(p->>'Cod_SUNAT','')),'')   else t.cod_sunat end,
    tipo_igv               = case when nullif(btrim(coalesce(p->>'Tipo_IGV','')),'') is not null
                                  and (p->>'Tipo_IGV') in ('1','2','3') then (p->>'Tipo_IGV')::smallint else t.tipo_igv end,
    estado                 = case when p ? 'estado'      then ((p->>'estado')      in ('1','true','t')) else t.estado end,
    es_envasable           = case when p ? 'esEnvasable' then ((p->>'esEnvasable') in ('1','true','t')) else t.es_envasable end,
    -- [597] envase del derivado (VACIABLE: clave presente y vacía → null = "falta elegir") + toggle insumo
    envase_sku             = case when p ? 'envaseSku'   then nullif(btrim(coalesce(p->>'envaseSku','')),'') else t.envase_sku end,
    es_insumo              = case when p ? 'esInsumo'    then ((p->>'esInsumo') in ('1','true','t')) else t.es_insumo end,
    merma_esperada_pct     = case when p ? 'mermaEsperadaPct' then mos._numn(p->>'mermaEsperadaPct') else t.merma_esperada_pct end,
    stock_minimo           = case when p ? 'stockMinimo' then mos._numn(p->>'stockMinimo') else t.stock_minimo end,
    stock_maximo           = case when p ? 'stockMaximo' then mos._numn(p->>'stockMaximo') else t.stock_maximo end,
    zona                   = case when p ? 'zona'        then nullif(btrim(coalesce(p->>'zona','')),'') else t.zona end,
    modo_venta             = case when p ? 'modoVenta'
                                  then (case when upper(coalesce(p->>'modoVenta','')) in ('MARGEN','FIJO','COMPETITIVO','LIBRE')
                                             then upper(p->>'modoVenta') else null end)
                                  else t.modo_venta end,
    margen_pct             = case when p ? 'margenPct'  then mos._numn(p->>'margenPct')  else t.margen_pct end,
    precio_tope            = case when p ? 'precioTope' then mos._numn(p->>'precioTope') else t.precio_tope end,
    updated_at             = now()
  where id_producto = v_row.id_producto;

  -- Normalizar: si tras el update es CANÓNICO (sin base) y factor quedó NULL → setear 1 (modelo normalizado, paridad GAS)
  update mos.productos set factor_conversion = 1
   where id_producto = v_row.id_producto
     and coalesce(btrim(codigo_producto_base),'') = ''
     and factor_conversion is null;

  -- Recalcular tipo_producto (la sombra DEBE quedar consistente; backfill post() rule)
  update mos.productos set tipo_producto =
    case when coalesce(btrim(codigo_producto_base),'') <> '' then 'DERIVADO'::mos.producto_tipo
         when factor_conversion is not null and factor_conversion > 0 and factor_conversion <> 1 then 'PRESENTACION'::mos.producto_tipo
         else 'CANONICO'::mos.producto_tipo end
   where id_producto = v_row.id_producto;

  -- ¿cambió el precio? (tolerancia 0.001 como _valoresIguales de GAS)
  v_cambio_precio := (v_pv_new is not null) and (v_pv_old is null or abs(v_pv_new - v_pv_old) >= 0.001);

  if v_cambio_precio then
    insert into mos.historial_precios (id, sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, motivo, app_origen, fecha)
    select 'HP'||replace(now()::text,' ','_')||substr(md5(random()::text),1,4),
           t.sku_base, t.codigo_barra, t.descripcion, v_pv_old, v_pv_new,
           nullif(btrim(coalesce(p->>'usuario','')),''),
           coalesce(nullif(btrim(coalesce(p->>'motivoPrecio','')),''),'Actualización'), 'MOS', now()
      from mos.productos t where t.id_producto = v_row.id_producto;

    select (coalesce(btrim(codigo_producto_base),'') = ''
            and (factor_conversion is null or factor_conversion = 1)) into v_es_canon
      from mos.productos where id_producto = v_row.id_producto;
    if v_es_canon and not coalesce((p->>'_noPropagar')::boolean, false) then
      v_pres_upd := mos._propagar_precio(v_row.sku_base, v_row.id_producto, v_pv_new,
                                         nullif(btrim(coalesce(p->>'usuario','')),''),
                                         nullif(btrim(coalesce(p->>'motivoPrecio','')),''));
    end if;
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('presentacionesActualizadas', v_pres_upd));
end;
$function$
