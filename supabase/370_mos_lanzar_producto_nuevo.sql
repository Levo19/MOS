-- ════════════════════════════════════════════════════════════════════════════
-- 370 · NIVEL 1 corte-GAS (MOS, cross-app) — lanzar producto nuevo / crear PN manual.
-- Espejo de Conexiones.gs::lanzarProductoNuevo (NUEVO/EQUIVALENTE/CORREGIR_CODIGO)
-- + forwardWHAction registrarProductoNuevo. Reusa mos.crear_producto (78),
-- mos.crear_equivalencia (79), wh.marcar_producto_nuevo_aprobado (44),
-- wh.registrar_producto_nuevo (217). Las llamadas WH gatean wh._claim_ok()=
-- ('','warehouseMos') → se ELEVA el claim a 'warehouseMos' transaction-local.
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config(clave,valor) values ('WH_REGISTRAR_PN_DIRECTO','1')
on conflict (clave) do update set valor='1';

create or replace function mos.lanzar_producto_nuevo(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tipo text := upper(coalesce(p->>'tipo','NUEVO'));
  v_user text := coalesce(nullif(p->>'usuario',''), 'MOS');
  v_cod  text := nullif(btrim(coalesce(p->>'codigoFinal','')),'');
  v_unid text := coalesce(nullif(p->>'unidad',''), nullif(p->>'Unidad_Medida',''), 'NIU');
  v_res  jsonb; v_idnew text; v_idprod text; v_exist mos.productos%rowtype; v_used text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

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
    v_idprod := coalesce(v_res->'data'->>'idProducto', v_res->>'idProducto', '');
    -- Aprobar el PN en WH (cross-app) si vino su id → elevar claim a warehouseMos.
    v_idnew := nullif(btrim(coalesce(p->>'idProductoNuevo','')),'');
    if v_idnew is not null then
      perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);
      perform wh.marcar_producto_nuevo_aprobado(jsonb_build_object('id_producto_nuevo', v_idnew, 'aprobado_por', v_user, 'observacion', 'NUEVO'));
      perform set_config('request.jwt.claims', v_claims::text, true);
    end if;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','NUEVO','idProducto',v_idprod,'aprobadoEnWH',(v_idnew is not null)));

  elsif v_tipo = 'EQUIVALENTE' then
    if nullif(btrim(coalesce(p->>'skuBase','')),'') is null then return jsonb_build_object('ok',false,'error','skuBase requerido'); end if;
    if v_cod is null then return jsonb_build_object('ok',false,'error','codigoFinal requerido'); end if;
    v_res := mos.crear_equivalencia(jsonb_build_object(
      'skuBase', p->>'skuBase', 'codigoBarra', v_cod,
      'descripcion', coalesce(nullif(p->>'descripcionEquiv',''), p->>'descripcion', ''), 'usuario', v_user));
    if coalesce((v_res->>'ok'),'false') <> 'true' then return v_res; end if;
    -- Aprobar el PN en WH si vino su id.
    v_idnew := nullif(btrim(coalesce(p->>'idProductoNuevo','')),'');
    if v_idnew is not null then
      perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);
      perform wh.marcar_producto_nuevo_aprobado(jsonb_build_object('id_producto_nuevo', v_idnew, 'aprobado_por', v_user, 'observacion', 'EQUIVALENTE'));
      perform set_config('request.jwt.claims', v_claims::text, true);
    end if;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','EQUIVALENTE','idEquiv',v_res->'data'->>'idEquiv','aprobadoEnWH',(v_idnew is not null)));

  elsif v_tipo = 'CORREGIR_CODIGO' then
    if nullif(btrim(coalesce(p->>'idProductoExistente','')),'') is null then return jsonb_build_object('ok',false,'error','Requiere idProductoExistente'); end if;
    if v_cod is null then return jsonb_build_object('ok',false,'error','Requiere codigoFinal (código real)'); end if;
    select * into v_exist from mos.productos where id_producto = p->>'idProductoExistente' limit 1;
    if not found then return jsonb_build_object('ok',false,'error','Producto existente no encontrado: '||(p->>'idProductoExistente')); end if;
    if upper(btrim(coalesce(v_exist.codigo_barra,''))) = upper(v_cod) then return jsonb_build_object('ok',false,'error','El producto ya tiene el código '||v_cod); end if;
    select id_producto into v_used from mos.productos where upper(btrim(codigo_barra)) = upper(v_cod) and id_producto <> v_exist.id_producto limit 1;
    if v_used is not null then return jsonb_build_object('ok',false,'error','El código '||v_cod||' ya está en uso por el producto '||v_used); end if;
    -- Preservar el código viejo como equivalencia (si existía) + reemplazar por el real.
    if nullif(btrim(coalesce(v_exist.codigo_barra,'')),'') is not null then
      perform mos.crear_equivalencia(jsonb_build_object('skuBase', coalesce(nullif(v_exist.sku_base,''), v_exist.id_producto),
        'codigoBarra', v_exist.codigo_barra, 'descripcion', v_exist.descripcion, 'usuario', v_user));
    end if;
    update mos.productos set codigo_barra = v_cod, updated_at = now() where id_producto = v_exist.id_producto;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','CORREGIR_CODIGO','idProducto',v_exist.id_producto,'codigoNuevo',v_cod));
  end if;

  return jsonb_build_object('ok',false,'error','tipo desconocido: '||v_tipo);
end; $fn$;

-- crearPNManual: forward a wh.registrar_producto_nuevo (elevación de claim).
create or replace function mos.crear_pn_manual(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb); v_res jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);
  v_res := wh.registrar_producto_nuevo(jsonb_build_object(
    'codigoBarra', coalesce(p->>'codigoBarra', p->>'codigoFinal',''), 'idGuia', coalesce(p->>'idGuia',''),
    'cantidad', coalesce(p->>'cantidad','0'), 'descripcion', coalesce(p->>'descripcion',''),
    'fechaVencimiento', coalesce(p->>'fechaVencimiento',''), 'usuario', coalesce(p->>'usuario','MOS')));
  perform set_config('request.jwt.claims', v_claims::text, true);
  return v_res;
end; $fn$;

revoke all on function mos.lanzar_producto_nuevo(jsonb), mos.crear_pn_manual(jsonb) from public, anon;
grant execute on function mos.lanzar_producto_nuevo(jsonb), mos.crear_pn_manual(jsonb) to authenticated, service_role;
