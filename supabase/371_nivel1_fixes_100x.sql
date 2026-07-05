-- ════════════════════════════════════════════════════════════════════════════
-- 371 · FIXES de la revisión 100x sobre 368/369/370.
--   368 D1: join podía DUPLICAR líneas (OR match + catálogo sucio) → monto ×N.
--        → join lateral limit 1 con match priorizado. D3: cant_recibida real-0
--        mostraba la esperada → coalesce(cant_recibida, cant_esperada).
--   369 D5: GRUPO+TOTAL sin cantMin>0 grababa el total como unitario (mal precio)
--        → validar cantMin para GRUPO.
--   370 D10/D11: WH_MARCAR..._DIRECTO estaba OFF y no se chequeaba el ok → mentía
--        aprobadoEnWH. → prender flag + reportar aprobadoEnWH REAL. D12: CORREGIR
--        perdía el código viejo si la equivalencia fallaba en silencio → chequear ok.
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config(clave,valor) values ('WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO','1')
on conflict (clave) do update set valor='1';

-- ── 368 fix: sin duplicados + cant real-0 ─────────────────────────────────────
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
      'idDetalle', coalesce(d.id_detalle,''), 'codigoProducto', d.cod_producto,
      'descripcion', coalesce(pr.descripcion, '⚠ '||d.cod_producto||' (no en catálogo)'),
      'esEquivalencia', (pr.id_producto is not null and coalesce(pr.codigo_barra,'') <> d.cod_producto and pr.id_producto <> d.cod_producto),
      'cantidad', coalesce(d.cant_recibida, d.cant_esperada, 0),
      'precioUnitario', coalesce(d.precio_unitario,0),
      'subtotal', coalesce(d.cant_recibida, d.cant_esperada, 0) * coalesce(d.precio_unitario,0),
      'fechaVencimiento', coalesce(d.fecha_vencimiento::text,''),
      'precioVentaActual', coalesce(pr.precio_venta,0), 'precioCostoActual', coalesce(pr.precio_costo,0),
      'categoria', coalesce(pr.id_categoria,'')
    ) order by d.linea), '[]'::jsonb) into v_lin
    from wh.guia_detalle d
    left join lateral (
      select * from mos.productos x
      where upper(btrim(x.codigo_barra)) = upper(btrim(d.cod_producto)) or x.id_producto = d.cod_producto
      order by (case when x.id_producto = d.cod_producto then 0 when upper(btrim(x.codigo_barra)) = upper(btrim(d.cod_producto)) then 1 else 2 end)
      limit 1) pr on true
    where d.id_guia = v_idg;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('fuente','WH','idGuia',v_idg,'lineas',v_lin));

  elsif v_fuente = 'ME' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'codigoBarra', d.cod_barras,
      'descripcion', coalesce(pr.descripcion, '⚠ '||d.cod_barras||' (no en catálogo)'),
      'esEquivalencia', (pr.id_producto is not null and coalesce(pr.codigo_barra,'') <> d.cod_barras),
      'cantidad', coalesce(d.cantidad,0), 'precioUnitario', coalesce(pr.precio_venta,0),
      'subtotal', coalesce(d.cantidad,0) * coalesce(pr.precio_venta,0)
    ) order by d.linea), '[]'::jsonb) into v_lin
    from me.guias_detalle d
    left join lateral (
      select * from mos.productos x where upper(btrim(x.codigo_barra)) = upper(btrim(d.cod_barras)) limit 1) pr on true
    where d.id_guia = v_idg;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('fuente','ME','idGuia',v_idg,'lineas',v_lin));
  end if;
  return jsonb_build_object('ok',false,'error','Fuente desconocida: '||v_fuente);
end; $fn$;

-- ── 369 fix: GRUPO+TOTAL exige cantMin>0 ──────────────────────────────────────
create or replace function mos.crear_promocion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_tipo text := upper(coalesce(p->>'tipo',''));
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_modo text := upper(coalesce(p->>'valorModo','UNITARIO'));
  v_valor numeric := coalesce(nullif(btrim(coalesce(p->>'valorPromo','')),'')::numeric, 0);
  v_cmin  numeric := coalesce(nullif(btrim(coalesce(p->>'cantMin','')),'')::numeric, 0);
  v_id text := nullif(btrim(coalesce(p->>'idPromo','')),'');
  v_items jsonb := p->'items';
  v_exist text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_tipo not in ('GRUPO','PORCENTAJE','COMBO') then return jsonb_build_object('ok',false,'error','tipo debe ser GRUPO, PORCENTAJE o COMBO'); end if;
  if v_tipo = 'COMBO' then
    if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
      return jsonb_build_object('ok',false,'error','COMBO requiere lista de items'); end if;
  else
    if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;
  end if;
  -- [fix D5] GRUPO en modo TOTAL sin cantMin>0 no se puede unitarizar → rechazar (evita precio ×cantMin errado).
  if v_tipo = 'GRUPO' and v_modo = 'TOTAL' and coalesce(v_cmin,0) <= 0 then
    return jsonb_build_object('ok',false,'error','GRUPO en modo TOTAL requiere cantMin > 0');
  end if;
  if v_tipo = 'GRUPO' and v_modo = 'TOTAL' and v_valor > 0 then v_valor := v_valor / v_cmin; end if;

  if v_tipo <> 'COMBO' then
    select id_promo into v_exist from mos.promociones where sku_base = v_sku limit 1;
    if v_exist is not null then v_id := v_exist; end if;
  end if;
  if v_id is null then v_id := 'PROMO' || (extract(epoch from clock_timestamp())*1000)::bigint; end if;

  insert into mos.promociones (id_promo, sku_base, tipo_promo, cant_min, valor_promo, valor_modo,
    descripcion, vigencia_desde, vigencia_hasta, activa, notas, items_json, updated_at)
  values (v_id, case when v_tipo='COMBO' then null else v_sku end, v_tipo, v_cmin, v_valor, v_modo,
    coalesce(p->>'descripcion',''), coalesce(p->>'vigenciaDesde',''), coalesce(p->>'vigenciaHasta',''),
    not (coalesce(p->>'activa','true') = 'false'), coalesce(p->>'notas',''),
    case when v_tipo='COMBO' then coalesce(v_items,'[]'::jsonb) else null end, now())
  on conflict (id_promo) do update set sku_base=excluded.sku_base, tipo_promo=excluded.tipo_promo,
    cant_min=excluded.cant_min, valor_promo=excluded.valor_promo, valor_modo=excluded.valor_modo,
    descripcion=excluded.descripcion, vigencia_desde=excluded.vigencia_desde, vigencia_hasta=excluded.vigencia_hasta,
    activa=excluded.activa, notas=excluded.notas, items_json=excluded.items_json, updated_at=now();
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPromo',v_id,'skuBase',v_sku,'tipo',v_tipo));
end; $fn$;

-- ── 370 fix: aprobadoEnWH REAL + CORREGIR preserva código (chequea ok) ─────────
create or replace function mos.lanzar_producto_nuevo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tipo text := upper(coalesce(p->>'tipo','NUEVO'));
  v_user text := coalesce(nullif(p->>'usuario',''), 'MOS');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoFinal','')),'');
  v_unid text := coalesce(nullif(p->>'unidad',''), nullif(p->>'Unidad_Medida',''), 'NIU');
  v_res jsonb; v_mres jsonb; v_eq jsonb; v_idnew text; v_idprod text; v_apr boolean := false;
  v_exist mos.productos%rowtype; v_used text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_idnew := nullif(btrim(coalesce(p->>'idProductoNuevo','')),'');

  if v_tipo = 'NUEVO' then
    if nullif(btrim(coalesce(p->>'descripcion','')),'') is null then return jsonb_build_object('ok',false,'error','La descripción es requerida'); end if;
    if coalesce(mos._numn(p->>'precioVenta'),0) <= 0 then return jsonb_build_object('ok',false,'error','El precio de venta es requerido y debe ser mayor a 0'); end if;
    v_res := mos.crear_producto(jsonb_build_object(
      'codigoBarra', coalesce(v_cod,''), 'descripcion', p->>'descripcion', 'marca', coalesce(p->>'marca',''),
      'idCategoria', coalesce(p->>'idCategoria',''), 'unidad', v_unid, 'Unidad_Medida', v_unid,
      'Tipo_IGV', coalesce(p->>'Tipo_IGV','1'), 'precioVenta', p->>'precioVenta', 'precioCosto', coalesce(p->>'precioCosto','0'),
      'stockMinimo', coalesce(p->>'stockMinimo','0'), 'stockMaximo', coalesce(p->>'stockMaximo','0'),
      'esEnvasable', coalesce(p->>'esEnvasable','0'), 'codigoProductoBase', coalesce(p->>'codigoProductoBase',''),
      'factorConversion', coalesce(p->>'factorConversion',''), 'mermaEsperadaPct', coalesce(p->>'mermaEsperadaPct',''),
      'zona', coalesce(p->>'zona',''), 'usuario', v_user));
    if coalesce((v_res->>'ok'),'false') <> 'true' then return v_res; end if;
    v_idprod := coalesce(v_res->'data'->>'idProducto','');
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
    -- [fix D12] preservar el código viejo como equivalencia; si FALLA, NO reescribir (no perder el código).
    if nullif(btrim(coalesce(v_exist.codigo_barra,'')),'') is not null then
      v_eq := mos.crear_equivalencia(jsonb_build_object('skuBase', coalesce(nullif(v_exist.sku_base,''), v_exist.id_producto),
        'codigoBarra', v_exist.codigo_barra, 'descripcion', v_exist.descripcion, 'usuario', v_user));
      if coalesce((v_eq->>'ok'),'false') <> 'true' then
        return jsonb_build_object('ok',false,'error','No se pudo preservar el código viejo como equivalencia: '||coalesce(v_eq->>'error','?'));
      end if;
    end if;
    update mos.productos set codigo_barra = v_cod, updated_at = now() where id_producto = v_exist.id_producto;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','CORREGIR_CODIGO','idProducto',v_exist.id_producto,'codigoNuevo',v_cod));
  else
    return jsonb_build_object('ok',false,'error','tipo desconocido: '||v_tipo);
  end if;

  -- [fix D10/D11] Aprobar el PN en WH (cross-app) si vino su id → elevar claim y REPORTAR el resultado real.
  if v_idnew is not null then
    perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);
    v_mres := wh.marcar_producto_nuevo_aprobado(jsonb_build_object('id_producto_nuevo', v_idnew, 'aprobado_por', v_user, 'observacion', v_tipo));
    perform set_config('request.jwt.claims', v_claims::text, true);
    v_apr := coalesce((v_mres->>'ok'),'false') = 'true';
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'tipo', v_tipo, 'idProducto', coalesce(v_idprod,''), 'idEquiv', coalesce(v_res->'data'->>'idEquiv',''),
    'aprobadoEnWH', v_apr, 'whError', case when v_idnew is not null and not v_apr then coalesce(v_mres->>'error','') else '' end));
end; $fn$;
