-- ════════════════════════════════════════════════════════════════════
-- 553 — FIX "Corregir código" del flujo Producto Nuevo (lanzar_producto_nuevo).
--
-- DOS bugs reportados por el dueño (caso Mostaza Alpesa 2kg 7750243057240):
--
-- BUG 1 (dos códigos): al corregir, el código anterior SIEMPRE se conservaba como
--   equivalencia (diseño para "código falso corto que empieza con 0"). Pero cuando
--   el anterior es un EAN-13 real, el producto queda con DOS códigos y el usuario
--   esperaba un REEMPLAZO limpio. Fix: nuevo flag `conservarCodigoViejo` (default
--   FALSE = reemplazo puro). Solo si es TRUE se preserva el viejo como equivalente.
--
-- BUG 2 (el PN seguía "por registrar"): el branch CORREGIR_CODIGO hacía un `return`
--   TEMPRANO, ANTES del bloque que aprueba el PN en WH (wh.marcar_producto_nuevo_
--   aprobado). Resultado: cada corrección dejaba el PN en estado PENDIENTE → seguía
--   apareciendo en el banner como si nunca se hubiera registrado. Fix: quitar el
--   return temprano; setear v_idprod y CAER al bloque común de aprobación + return.
-- ════════════════════════════════════════════════════════════════════

create or replace function mos.lanzar_producto_nuevo(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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
    -- [BUG1 · fix] SOLO conservar el código viejo como equivalencia si el usuario lo pidió
    -- explícitamente (conservarCodigoViejo=true). Default = REEMPLAZO limpio (no crea 2º código).
    -- Si se conserva y FALLA, NO reescribir (no perder el código real entrante).
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
    -- [BUG2 · fix] NO retornar aquí: caer al bloque común para APROBAR el PN en WH.
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
    'conservoViejo', (v_tipo='CORREGIR_CODIGO' and coalesce((p->>'conservarCodigoViejo')::boolean,false)),
    'aprobadoEnWH', v_apr, 'whError', case when v_idnew is not null and not v_apr then coalesce(v_mres->>'error','') else '' end));
end; $function$;

grant execute on function mos.lanzar_producto_nuevo(jsonb) to anon, authenticated, service_role;
