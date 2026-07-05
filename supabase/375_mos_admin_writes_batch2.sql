-- 375 · NIVEL 4/kill-GAS (MOS) — completar CRUD admin que caía al fall-through GAS de _postMOS.
-- Gate mos._claim_ok(). Espejo de actualizarCategoria / eliminarPersonalMaster / actualizarImpresora /
-- eliminarProductoProveedor / eliminarPromocion / guardarTarjetaWA.

create or replace function mos.actualizar_categoria(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idCategoria','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idCategoria requerido'); end if;
  update mos.categorias set
    nombre      = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    modo_venta  = coalesce(nullif(upper(btrim(coalesce(p->>'modoVenta',''))),''), modo_venta),
    margen_pct  = coalesce(nullif(btrim(coalesce(p->>'margenPct','')),'')::numeric, margen_pct),
    precio_tope = coalesce(nullif(btrim(coalesce(p->>'precioTope','')),'')::numeric, precio_tope),
    descripcion = coalesce(p->>'descripcion', descripcion),
    estado      = coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, estado)
   where id_categoria = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','categoría no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.eliminar_personal(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPersonal','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  -- soft delete (estado=false), paridad con el ecosistema (no borra histórico).
  update mos.personal set estado = false where id_personal = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','personal no encontrado'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.actualizar_impresora(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idImpresora','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idImpresora requerido'); end if;
  update mos.impresoras set
    nombre      = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    printnode_id= coalesce(nullif(btrim(coalesce(p->>'printnodeId', p->>'printNodeId','')),''), printnode_id),
    tipo        = coalesce(nullif(btrim(coalesce(p->>'tipo','')),''), tipo),
    id_estacion = coalesce(p->>'idEstacion', id_estacion),
    id_zona     = coalesce(p->>'idZona', id_zona),
    activo      = coalesce(nullif(btrim(coalesce(p->>'activo','')),'')::boolean, activo),
    descripcion = coalesce(p->>'descripcion', descripcion)
   where id_impresora = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','impresora no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.eliminar_proveedor_producto(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPp', p->>'id_pp','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPp requerido'); end if;
  update mos.proveedores_productos set activa = false where id_pp = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','no encontrado'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.eliminar_promocion(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idPromo','')),''); v_sku text := nullif(btrim(coalesce(p->>'skuBase','')),''); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null and v_sku is null then return jsonb_build_object('ok',false,'error','idPromo o skuBase requerido'); end if;
  delete from mos.promociones where (v_id is not null and id_promo = v_id) or (v_id is null and sku_base = v_sku);
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','Promoción no encontrada'); end if;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.guardar_tarjeta_wa(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_com text := regexp_replace(coalesce(p->>'comercial',''),'\D','','g');
        v_cmp text := regexp_replace(coalesce(p->>'compras',''),'\D','','g');
        v_mar text := coalesce(nullif(btrim(coalesce(p->>'marca','')),''),'INVERSION MOS');
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  insert into mos.config(clave,valor) values
    ('TARJETA_WA_COMERCIAL', v_com), ('TARJETA_WA_COMPRAS', v_cmp), ('TARJETA_MARCA', v_mar)
  on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('comercial',v_com,'compras',v_cmp,'marca',v_mar));
end; $fn$;

revoke all on function mos.actualizar_categoria(jsonb), mos.eliminar_personal(jsonb), mos.actualizar_impresora(jsonb),
  mos.eliminar_proveedor_producto(jsonb), mos.eliminar_promocion(jsonb), mos.guardar_tarjeta_wa(jsonb) from public, anon;
grant execute on function mos.actualizar_categoria(jsonb), mos.eliminar_personal(jsonb), mos.actualizar_impresora(jsonb),
  mos.eliminar_proveedor_producto(jsonb), mos.eliminar_promocion(jsonb), mos.guardar_tarjeta_wa(jsonb) to authenticated, service_role;
