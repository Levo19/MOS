-- 602_pn_foto_a_catalogo.sql — [PN · LA FOTO DEL PN LLEGA AL CATÁLOGO]
-- Reclamo del dueño (2026-08-01): "la foto no se jaló al catálogo". Diagnóstico:
-- WH sí sube la foto del PN a Storage (wh-fotos/producto_nuevo/...) y la linkea en
-- wh.producto_nuevo.foto — pero mos.lanzar_producto_nuevo JAMÁS la copiaba a
-- mos.productos.foto_url al aprobar (las aguas San Mateo de hoy: PN con foto,
-- producto sin foto). Fix: al aprobar (NUEVO o CORREGIR_CODIGO) se copia la foto
-- del PN al producto SI el producto no tiene foto propia (best-effort: la foto
-- jamás rompe una aprobación). + Backfill de los APROBADOS con foto Storage cuyo
-- producto quedó sin foto (hoy: 2 — las aguas). El Nescafé 14g NO tiene foto ni
-- en el PN (registro de junio, sin foto): esa hay que subirla a mano en MOS.

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
    -- [601] PRECIO OPCIONAL (registro rápido) · COSTO jamás desde PN (forzado '0').
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
    -- [601] procedencia del PRECIO: source=REGISTRO_PN (best-effort).
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

  -- [602] FOTO del PN → catálogo: si el PN traía foto y el producto quedó sin foto propia,
  -- copiarla a foto_url. Best-effort: una foto JAMÁS rompe la aprobación.
  if v_idnew is not null and coalesce(v_idprod,'') <> '' then
    begin
      update mos.productos pr
         set foto_url = pn.foto, updated_at = now()
        from wh.producto_nuevo pn
       where pn.id_producto_nuevo = v_idnew
         and coalesce(pn.foto,'') <> ''
         and pr.id_producto = v_idprod
         and coalesce(pr.foto_url,'') = '';
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'tipo', v_tipo, 'idProducto', coalesce(v_idprod,''), 'idEquiv', coalesce(v_res->'data'->>'idEquiv',''),
    'conservoViejo', (v_tipo='CORREGIR_CODIGO' and coalesce((p->>'conservarCodigoViejo')::boolean,false)),
    'aprobadoEnWH', v_apr, 'whError', case when v_idnew is not null and not v_apr then coalesce(v_mres->>'error','') else '' end));
end; $function$;

-- ── BACKFILL: PN APROBADOS con foto de Storage cuyo producto quedó sin foto (hoy: las 2 aguas) ──
update mos.productos p
   set foto_url = pn.foto, updated_at = now()
  from wh.producto_nuevo pn
 where upper(coalesce(pn.estado,'')) = 'APROBADO'
   and coalesce(pn.foto,'') like '%supabase.co/storage%'
   and btrim(coalesce(p.codigo_barra,'')) = btrim(coalesce(pn.codigo_barra,''))
   and coalesce(p.foto_url,'') = '';
