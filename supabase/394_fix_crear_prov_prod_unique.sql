-- 394 · FIX (2da revisión 500x): el índice único ux_mos_provprod_prov_sku (393) puede hacer que
-- crear_producto_proveedor lance unique_violation (500) si un admin crea un prov-prod cuyo (id_proveedor,
-- sku_base) ya existe (p.ej. auto-jalado). Ahora captura el conflicto y hace UPDATE de la fila existente.
create or replace function mos.crear_producto_proveedor(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPp','')),''); v_prov text := nullif(btrim(coalesce(p->>'idProveedor','')),''); v_sku text := btrim(coalesce(p->>'skuBase',''));
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_prov is null then return jsonb_build_object('ok',false,'error','idProveedor requerido'); end if;
  if v_id is null then v_id := 'PP' || (extract(epoch from clock_timestamp())*1000)::bigint; end if;
  begin
    insert into mos.proveedores_productos (id_pp, id_proveedor, sku_base, codigo_barra, descripcion,
      precio_referencia, minimo_compra, dias_entrega, activa, notas, unidades_por_bulto, ultima_actualizacion)
    values (v_id, v_prov, v_sku, coalesce(p->>'codigoBarra',''), coalesce(p->>'descripcion',''),
      nullif(btrim(coalesce(p->>'precioReferencia','')),'')::numeric, nullif(btrim(coalesce(p->>'minimoCompra','')),'')::numeric,
      nullif(btrim(coalesce(p->>'diasEntrega','')),'')::numeric, true, coalesce(p->>'notas',''),
      nullif(btrim(coalesce(p->>'unidadesPorBulto','')),'')::numeric, now())
    on conflict (id_pp) do update set sku_base=excluded.sku_base, codigo_barra=excluded.codigo_barra,
      descripcion=excluded.descripcion, precio_referencia=excluded.precio_referencia, minimo_compra=excluded.minimo_compra,
      dias_entrega=excluded.dias_entrega, notas=excluded.notas, unidades_por_bulto=excluded.unidades_por_bulto, ultima_actualizacion=now();
  exception when unique_violation then
    -- ya existe una fila con ese (id_proveedor, sku_base) → actualizarla (no duplicar)
    update mos.proveedores_productos set codigo_barra=coalesce(p->>'codigoBarra',codigo_barra),
      descripcion=coalesce(nullif(p->>'descripcion',''),descripcion),
      precio_referencia=coalesce(nullif(btrim(coalesce(p->>'precioReferencia','')),'')::numeric, precio_referencia),
      minimo_compra=coalesce(nullif(btrim(coalesce(p->>'minimoCompra','')),'')::numeric, minimo_compra),
      dias_entrega=coalesce(nullif(btrim(coalesce(p->>'diasEntrega','')),'')::numeric, dias_entrega),
      notas=coalesce(p->>'notas',notas), unidades_por_bulto=coalesce(nullif(btrim(coalesce(p->>'unidadesPorBulto','')),'')::numeric, unidades_por_bulto),
      ultima_actualizacion=now()
     where id_proveedor=v_prov and sku_base=v_sku
     returning id_pp into v_id;
  end;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPp',v_id));
end; $fn$;
