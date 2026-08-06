CREATE OR REPLACE FUNCTION mos.crear_producto(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_desc    text := nullif(btrim(coalesce(p->>'descripcion','')), '');
  v_pv      numeric := mos._numn(p->>'precioVenta');
  v_sin     boolean := coalesce((p->>'permitirSinPrecio') in ('1','true','t'), false);  -- [601] solo PN
  v_id      text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_sku     text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_cod     text := btrim(coalesce(p->>'codigoBarra',''));     -- texto SIEMPRE
  v_seq     bigint;
  v_pad     text;
  v_tipoigv text := coalesce(nullif(btrim(coalesce(p->>'Tipo_IGV','')),''),'1');
  v_igvpct  numeric;
  v_codtrib text;
  v_codsun  text;
  v_unidad  text;
  v_unidadm text;
  v_cpb     text := btrim(coalesce(p->>'codigoProductoBase',''));   -- texto SIEMPRE
  v_es_deriv boolean;
  v_es_pres  boolean;
  v_factor  numeric;
  v_fbase   numeric := mos._numn(p->>'factorConversionBase');
  v_tipo    mos.producto_tipo;
  v_modo    text := upper(coalesce(p->>'modoVenta',''));
  v_margen  numeric := mos._numn(p->>'margenPct');
  v_tope    numeric := mos._numn(p->>'precioTope');
  v_dup     record;
  v_inserted int;
  v_sku_in  text;
  v_id_in   text;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_desc is null then return jsonb_build_object('ok',false,'error','La descripción es requerida'); end if;
  -- [601] permitirSinPrecio: el PN puede nacer SIN precio (0 = sello/bloqueo en ME); el alta normal NO.
  if v_pv is null or v_pv <= 0 then
    if not v_sin then
      return jsonb_build_object('ok',false,'error','El precio de venta es requerido y debe ser mayor a 0');
    end if;
    v_pv := 0;
  end if;

  if v_id is not null and exists (select 1 from mos.productos where id_producto = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,
      'data', jsonb_build_object('idProducto', v_id, 'skuBase', coalesce(v_sku, (select sku_base from mos.productos where id_producto=v_id))));
  end if;

  if v_cod <> '' then
    select id_producto, descripcion into v_dup from mos.productos
      where btrim(coalesce(codigo_barra,'')) = v_cod limit 1;
    if found then
      return jsonb_build_object('ok',false,'error',
        'El código de barras '||v_cod||' ya existe en el producto '||v_dup.id_producto||' ('||coalesce(v_dup.descripcion,'sin descripción')||')');
    end if;
  end if;

  v_sku_in := v_sku; v_id_in := v_id;

  if v_id is null or v_sku is null then
    v_seq := nextval('mos.seq_producto');
    v_pad := lpad(v_seq::text, 7, '0');
    v_id  := coalesce(v_id,  'IDPRO'||v_pad);
    v_sku := coalesce(v_sku, 'LEV'||v_pad);
  end if;

  v_tipoigv := case lower(v_tipoigv) when 'gravado' then '1' when 'exonerado' then '2' when 'inafecto' then '3' else v_tipoigv end;
  if v_tipoigv not in ('1','2','3') then v_tipoigv := '1'; end if;
  v_igvpct  := coalesce(mos._numn(p->>'IGV_Porcentaje'), case when v_tipoigv='1' then 18 else 0 end);
  v_codtrib := coalesce(nullif(btrim(coalesce(p->>'Cod_Tributo','')),''),
                        case v_tipoigv when '1' then '1000' when '2' then '9997' when '3' then '9998' else '' end);
  v_codsun  := coalesce(nullif(btrim(coalesce(p->>'Cod_SUNAT','')),''),'10000000');
  v_unidad  := nullif(btrim(coalesce(p->>'unidad','')),'');
  v_unidadm := nullif(btrim(coalesce(p->>'Unidad_Medida','')),'');
  if v_unidad is not null and v_unidadm is not null and v_unidad <> v_unidadm then
    v_unidad := v_unidadm;
  end if;
  v_unidad  := coalesce(v_unidad, v_unidadm, 'NIU');
  v_unidadm := coalesce(v_unidadm, v_unidad, 'NIU');

  v_es_deriv := (v_cpb <> '');
  v_es_pres  := (v_sku_in is not null and v_sku_in <> coalesce(v_id_in, v_id));
  if v_es_pres then
    v_factor := coalesce(mos._numn(p->>'factorConversion'), 1);
  elsif v_es_deriv then
    v_factor := null;
  else
    v_factor := 1;
  end if;
  if v_cpb <> '' then
    v_tipo := 'DERIVADO';
  elsif v_factor is not null and v_factor > 0 and v_factor <> 1 then
    v_tipo := 'PRESENTACION';
  else
    v_tipo := 'CANONICO';
  end if;

  if v_modo not in ('MARGEN','FIJO','COMPETITIVO','LIBRE') then v_modo := null; end if;

  insert into mos.productos (
    id_producto, sku_base, codigo_barra, descripcion, marca, id_categoria, unidad,
    precio_venta, precio_costo, cod_tributo, igv_porcentaje, cod_sunat, tipo_igv, unidad_medida,
    estado, es_envasable, codigo_producto_base, factor_conversion, factor_conversion_base,
    merma_esperada_pct, stock_minimo, stock_maximo, zona, fecha_creacion, creado_por,
    modo_venta, margen_pct, precio_tope, tipo_producto, created_at, updated_at,
    envase_sku, es_insumo, precio_fijo
  ) values (
    v_id, v_sku, nullif(v_cod,''), v_desc,
    nullif(btrim(coalesce(p->>'marca','')),''),
    nullif(btrim(coalesce(p->>'idCategoria','')),''),
    v_unidad,
    v_pv, coalesce(mos._numn(p->>'precioCosto'),0), v_codtrib, v_igvpct, v_codsun, v_tipoigv::smallint, v_unidadm,
    true,
    coalesce((p->>'esEnvasable') in ('1','true','t'), false),
    nullif(v_cpb,''), v_factor, v_fbase,
    mos._numn(p->>'mermaEsperadaPct'),
    coalesce(mos._numn(p->>'stockMinimo'),0), coalesce(mos._numn(p->>'stockMaximo'),0),
    nullif(btrim(coalesce(p->>'zona','')),''),
    now(), nullif(btrim(coalesce(p->>'usuario','')),''),
    v_modo, v_margen, v_tope, v_tipo, now(), now(),
    nullif(btrim(coalesce(p->>'envaseSku','')),''),
    coalesce((p->>'esInsumo') in ('1','true','t'), false),
    coalesce((p->>'precioFijo') in ('1','true','t'), false)   -- [629] etiqueta del saco
  )
  on conflict (id_producto) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    return jsonb_build_object('ok',true,'dedup',true,
      'data', jsonb_build_object('idProducto', v_id, 'skuBase', v_sku));
  end if;

  -- [601] historial de precio inicial SOLO si nació CON precio (0 = SIN PRECIO, sin historial)
  if v_pv > 0 then
    insert into mos.historial_precios (id, sku_base, codigo_barra, descripcion, precio_anterior, precio_nuevo, usuario, motivo, app_origen, fecha)
    values ('HP'||replace(now()::text,' ','_')||substr(md5(random()::text),1,4),
            v_sku, nullif(v_cod,''), v_desc, 0, v_pv, nullif(btrim(coalesce(p->>'usuario','')),''), 'Precio inicial', 'MOS', now());
  end if;

  return jsonb_build_object('ok',true,'dedup',false,
    'data', jsonb_build_object('idProducto', v_id, 'skuBase', v_sku, 'tipo', v_tipo));
end;
$function$
