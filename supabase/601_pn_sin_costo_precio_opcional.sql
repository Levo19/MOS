-- 601_pn_sin_costo_precio_opcional.sql — [PN · REGISTRO RÁPIDO SIN COSTO + PRECIO OPCIONAL CON PROCEDENCIA]
-- Pedido del dueño (2026-08-01), tras el caso de las aguas San Mateo:
-- (1) El COSTO ya NO entra por la aprobación de PN (era un costo "fantasma": quedaba en el producto
--     sin fila en mos.historial_precio_costo → el gráfico lo marcaba sin poder decir de dónde salió).
--     El costo entra SOLO por compras (llenar costos desde guía, con procedencia). La RPC lo fuerza a 0
--     aunque el caller mande algo (defensa aunque el front viejo siga cacheado).
-- (2) El PRECIO DE VENTA en PN es OPCIONAL (registro rápido): si viene > 0 se loguea en
--     mos.historial_precio_costo con source='REGISTRO_PN' (fecha/hora/usuario → el overlay del gráfico
--     dirá "Registro de PN"); si viene vacío el producto nace precio_venta=0 = "SIN PRECIO":
--     se mueve en stock normal, pero ME lo muestra con sello y BLOQUEA la venta hasta que
--     el admin le ponga precio (decisión del dueño: cero riesgo de vender a S/0).
-- (3) mos.crear_producto acepta flag permitirSinPrecio ('1') SOLO para este flujo; el alta normal
--     del catálogo sigue exigiendo precio > 0. Sin precio → NO se escribe historial de precio.

-- ── (3) crear_producto + permitirSinPrecio ──
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
    envase_sku, es_insumo
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
    coalesce((p->>'esInsumo') in ('1','true','t'), false)
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
$function$;

-- ── (1)(2) lanzar_producto_nuevo: costo forzado 0 · precio opcional · log REGISTRO_PN ──
CREATE OR REPLACE FUNCTION mos.lanzar_producto_nuevo(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tipo text := upper(coalesce(p->>'tipo','NUEVO'));
  v_user text := coalesce(nullif(p->>'usuario',''), 'MOS');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoFinal','')),'');
  v_unid text := coalesce(nullif(p->>'unidad',''), nullif(p->>'Unidad_Medida',''), 'NIU');
  v_res jsonb; v_mres jsonb; v_eq jsonb; v_idnew text; v_idprod text; v_apr boolean := false;
  v_exist mos.productos%rowtype; v_used text;
  v_pv numeric;   -- [601]
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_idnew := nullif(btrim(coalesce(p->>'idProductoNuevo','')),'');

  if v_tipo = 'NUEVO' then
    if nullif(btrim(coalesce(p->>'descripcion','')),'') is null then return jsonb_build_object('ok',false,'error','La descripción es requerida'); end if;
    -- [601] PRECIO OPCIONAL (registro rápido): vacío/0 → nace SIN PRECIO (ME lo sella y bloquea).
    -- COSTO: JAMÁS desde PN (entra por compras con procedencia) → forzado '0' ignore lo que mande el caller.
    v_pv := coalesce(mos._numn(p->>'precioVenta'), 0);
    if v_pv < 0 then v_pv := 0; end if;
    v_res := mos.crear_producto(jsonb_build_object(
      'codigoBarra', coalesce(v_cod,''), 'descripcion', p->>'descripcion', 'marca', coalesce(p->>'marca',''),
      'idCategoria', coalesce(p->>'idCategoria',''), 'unidad', v_unid, 'Unidad_Medida', v_unid,
      'Tipo_IGV', coalesce(p->>'Tipo_IGV','1'), 'precioVenta', v_pv::text, 'precioCosto', '0',
      'permitirSinPrecio', '1',
      'stockMinimo', coalesce(p->>'stockMinimo','0'), 'stockMaximo', coalesce(p->>'stockMaximo','0'),
      'esEnvasable', coalesce(p->>'esEnvasable','0'), 'codigoProductoBase', coalesce(p->>'codigoProductoBase',''),
      'factorConversion', coalesce(p->>'factorConversion',''), 'mermaEsperadaPct', coalesce(p->>'mermaEsperadaPct',''),
      'zona', coalesce(p->>'zona',''), 'usuario', v_user));
    if coalesce((v_res->>'ok'),'false') <> 'true' then return v_res; end if;
    v_idprod := coalesce(v_res->'data'->>'idProducto','');
    -- [601] procedencia del PRECIO en el gráfico: source=REGISTRO_PN (quién/cuándo/desde qué PN).
    -- Best-effort: un log JAMÁS rompe la aprobación.
    if v_pv > 0 and v_idprod <> '' then
      begin
        insert into mos.historial_precio_costo (id_producto, sku_base, tipo, valor, valor_anterior, usuario, source, app_origen, ts, meta)
        values (v_idprod, coalesce(nullif(v_res->'data'->>'skuBase',''), v_idprod), 'PRECIO', v_pv, null,
                v_user, 'REGISTRO_PN', 'MOS', now(), jsonb_build_object('idProductoNuevo', coalesce(v_idnew,'')));
      exception when others then null;
      end;
    end if;
  elsif v_tipo = 'EQUIVALENTE' then
    if nullif(btrim(coalesce(p->>'skuBase','')),'') is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;
    if v_cod is null then return jsonb_build_object('ok',false,'error','codigoFinal requerido'); end if;
    v_res := mos.crear_equivalencia(jsonb_build_object('skuBase', p->>'skuBase', 'codigoBarra', v_cod,
      'descripcion', coalesce(nullif(p->>'descripcionEquiv',''), p->>'descripcion', ''), 'usuario', v_user));
    if coalesce((v_res->>'ok'),'false') <> 'true' then return v_res; end if;
  elsif v_tipo = 'CORREGIR_CODIGO' then
    if nullif(btrim(coalesce(p->>'idProductoExistente','')),'') is null then return jsonb_build_object('ok',false,'error','Requiere idProductoExistente'); end if;
    if v_cod is null then return jsonb_build_object('ok',false,'error','Requiere codigoFinal (código real)'); end if;
    select * into v_exist from mos.productos where id_producto = p->>'idProductoExistente' limit 1;
    if not found then return jsonb_build_object('ok',false,'error','Producto existente no encontrado: '||(p->>'idProductoExistente')); end if;
    if upper(btrim(coalesce(v_exist.codigo_barra,''))) = upper(v_cod) then return jsonb_build_object('ok',false,'error','El producto ya tiene el código '||v_cod); end if;
    select id_producto into v_used from mos.productos where upper(btrim(codigo_barra)) = upper(v_cod) and id_producto <> v_exist.id_producto limit 1;
    if v_used is not null then return jsonb_build_object('ok',false,'error','El código '||v_cod||' ya está en uso por el producto '||v_used); end if;
    if coalesce((p->>'conservarCodigoViejo')::boolean, false)
       and nullif(btrim(coalesce(v_exist.codigo_barra,'')),'') is not null then
      v_eq := mos.crear_equivalencia(jsonb_build_object('skuBase', coalesce(nullif(v_exist.sku_base,''), v_exist.id_producto),
        'codigoBarra', v_exist.codigo_barra, 'descripcion', v_exist.descripcion, 'usuario', v_user));
      if coalesce((v_eq->>'ok'),'false') <> 'true' then
        return jsonb_build_object('ok',false,'error','No se pudo preservar el código viejo como equivalencia: '||coalesce(v_eq->>'error','?'));
      end if;
    end if;
    update mos.productos set codigo_barra = v_cod, updated_at = now() where id_producto = v_exist.id_producto;
    v_idprod := v_exist.id_producto;
  else
    return jsonb_build_object('ok',false,'error','tipo desconocido: '||v_tipo);
  end if;

  if v_idnew is not null then
    perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);
    v_mres := wh.marcar_producto_nuevo_aprobado(jsonb_build_object('id_producto_nuevo', v_idnew, 'aprobado_por', v_user, 'observacion', v_tipo));
    perform set_config('request.jwt.claims', v_claims::text, true);
    v_apr := coalesce((v_mres->>'ok'),'false') = 'true';
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'tipo', v_tipo, 'idProducto', coalesce(v_idprod,''), 'idEquiv', coalesce(v_res->'data'->>'idEquiv',''),
    'conservoViejo', (v_tipo='CORREGIR_CODIGO' and coalesce((p->>'conservarCodigoViejo')::boolean,false)),
    'aprobadoEnWH', v_apr, 'whError', case when v_idnew is not null and not v_apr then coalesce(v_mres->>'error','') else '' end));
end; $function$;
