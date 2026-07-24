-- ════════════════════════════════════════════════════════════════════
-- 549 — FIX: mos.actualizar_producto_proveedor exigía la clave 'idPp'
-- (P minúscula) pero el frontend MOS manda 'idPP' → ok:false 'idPp
-- requerido' con HTTP 200 → el bulto/min/ref/notas JAMÁS se guardaba
-- por esta ruta (el dueño lo reportó 2 veces). Ahora acepta ambas.
-- ════════════════════════════════════════════════════════════════════
create or replace function mos.actualizar_producto_proveedor(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id text := coalesce(nullif(btrim(coalesce(p->>'idPp','')),''), nullif(btrim(coalesce(p->>'idPP','')),'')); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPp requerido'); end if;
  update mos.proveedores_productos set
    sku_base          = coalesce(p->>'skuBase', sku_base),
    codigo_barra      = coalesce(p->>'codigoBarra', codigo_barra),
    descripcion       = coalesce(p->>'descripcion', descripcion),
    precio_referencia = coalesce(nullif(btrim(coalesce(p->>'precioReferencia','')),'')::numeric, precio_referencia),
    minimo_compra     = coalesce(nullif(btrim(coalesce(p->>'minimoCompra','')),'')::numeric, minimo_compra),
    dias_entrega      = coalesce(nullif(btrim(coalesce(p->>'diasEntrega','')),'')::numeric, dias_entrega),
    notas             = coalesce(p->>'notas', notas),
    unidades_por_bulto= coalesce(nullif(btrim(coalesce(p->>'unidadesPorBulto','')),'')::numeric, unidades_por_bulto),
    ultima_actualizacion = now()
   where id_pp = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','no encontrado'); end if;
  return jsonb_build_object('ok',true);
end; $function$;
