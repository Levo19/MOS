-- 385 · kill-GAS OCR/Jefa — aplicar las decisiones de precio de la jefa al catálogo. ⚠️ MONEY.
-- Valida clave admin server-side (mos.verificar_clave_admin) + reusa mos.publicar_precio POR ITEM (propaga
-- presentaciones + historial + idempotente). El ticket de confirmación lo imprime el cliente (Edge imprimir).
create or replace function mos.aplicar_respuesta_jefa(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_g     text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_clave text := coalesce(p->>'claveAdmin','');
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_verif jsonb; v_por text;
  v_it jsonb; v_sku text; v_vn numeric; v_mg numeric; v_cn numeric;
  v_costo numeric; v_venta numeric; v_res jsonb; rd jsonb;
  v_aplic int := 0; v_err jsonb := '[]'::jsonb; v_cambios jsonb := '[]'::jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if jsonb_typeof(v_items) <> 'array' then return jsonb_build_object('ok',false,'error','items debe ser array'); end if;

  -- auth tier-2 server-side (paridad con verificarClaveAdmin del GAS)
  v_verif := mos.verificar_clave_admin(v_clave, 'APLICAR_RESPUESTA_JEFA', coalesce(v_g,''), 'MOS', '', 'Respuesta jefa');
  if not coalesce((v_verif->>'autorizado')::boolean,false) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_verif->>'error','Clave incorrecta')));
  end if;
  v_por := coalesce(nullif(btrim(coalesce(v_verif->>'nombre','')),''),'admin');

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_sku := nullif(btrim(coalesce(v_it->>'skuBase','')),'');
    v_vn  := mos._numn(v_it->>'ventaNueva');
    v_mg  := mos._numn(v_it->>'margenNuevoPct');   -- fracción 0..1 (la OCR ya normaliza)
    v_cn  := mos._numn(v_it->>'costoNuevo');
    if v_sku is null then continue; end if;
    -- la jefa no decidió nada en este item → skip
    if v_vn is null and v_mg is null then continue; end if;

    -- costo de referencia: el nuevo si vino, si no el del catálogo (fila base del sku)
    if v_cn is not null and v_cn > 0 then v_costo := v_cn;
    else select precio_costo into v_costo from mos.productos
          where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku
          order by (coalesce(factor_conversion,1)=1 and btrim(coalesce(codigo_producto_base,''))='') desc limit 1;
    end if;
    v_costo := coalesce(v_costo,0);

    -- venta objetivo: la directa, o derivada del margen (venta = costo/(1-margen))
    if v_vn is not null and v_vn > 0 then
      v_venta := round(v_vn, 2);
    elsif v_mg is not null and v_mg > -0.5 and v_mg < 0.99 and v_costo > 0 then
      v_venta := round(v_costo / (1 - v_mg), 2);
    else
      v_err := v_err || jsonb_build_object('skuBase',v_sku,'error','datos insuficientes (venta/margen inválido o sin costo)');
      continue;
    end if;

    -- actualizar costo del catálogo si vino uno nuevo (fila base del sku)
    if v_cn is not null and v_cn > 0 then
      update mos.productos set precio_costo = v_cn, updated_at = now()
       where coalesce(nullif(btrim(sku_base),''), id_producto) = v_sku
         and coalesce(factor_conversion,1) = 1 and btrim(coalesce(codigo_producto_base,'')) = '';
    end if;

    -- aplicar la venta (reusa publicar_precio: propaga presentaciones + historial, idempotente)
    v_res := mos.publicar_precio(jsonb_build_object('skuBase', v_sku, 'precioNuevo', v_venta,
      'motivo', 'Respuesta jefa · guía '||coalesce(v_g,''), 'usuario', v_por));
    if coalesce((v_res->>'ok')::boolean,false) then
      rd := coalesce(v_res->'data','{}'::jsonb);
      v_aplic := v_aplic + 1;
      v_cambios := v_cambios || jsonb_build_object('skuBase', v_sku, 'descripcion', rd->>'descripcion',
        'ventaAnterior', rd->>'precioAnterior', 'ventaNueva', v_venta, 'costo', v_costo,
        'presentaciones', coalesce((rd->>'presentacionesActualizadas')::int,0));
    else
      v_err := v_err || jsonb_build_object('skuBase',v_sku,'error',coalesce(v_res->>'error','publicar_precio falló'));
    end if;
  end loop;

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'autorizado', true, 'aplicados', v_aplic, 'errores', v_err, 'cambios', v_cambios,
    'autorizadoPor', v_por, 'ticketImpreso', false));
end; $fn$;

revoke all on function mos.aplicar_respuesta_jefa(jsonb) from public, anon;
grant execute on function mos.aplicar_respuesta_jefa(jsonb) to authenticated, service_role;
