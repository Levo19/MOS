-- [999] Versionar foto_url para caché segura de imágenes (piloto egress MOS).
--  El SW cacheará las fotos cache-first para no re-descargarlas en cada sesión (baja el Cached Egress).
--  Para que NUNCA muestre una foto vieja, la URL lleva ?v=<ts>: al reemplazar la foto, set_foto_producto
--  actualiza mos.productos (dispara el trigger tg_bump_catversion_productos → el catálogo propaga la URL nueva)
--  y la nueva ?v hace cache-miss en el SW → baja la foto nueva. Nada parsea foto_url (solo se usa como src),
--  así que appendear el query param es seguro.

-- 1) Backfill: versionar las foto_url existentes con su updated_at (una sola vez; solo las que no tengan ?v).
update mos.productos
   set foto_url = foto_url || '?v=' || (extract(epoch from coalesce(updated_at, now()))::bigint)::text
 where coalesce(foto_url,'') <> '' and foto_url not like '%?v=%';

-- 2) set_foto_producto: versiona la URL al guardar (split_part quita cualquier ?... previo → sin apilar).
create or replace function mos.set_foto_producto(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_id   text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_url  text := nullif(btrim(coalesce(p->>'fotoUrl','')), '');
  v_n    int;
begin
  if coalesce((select valor from mos.config where clave='MOS_CATALOGO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_CATALOGO_DIRECTO_OFF');
  end if;
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_url is null then return jsonb_build_object('ok',false,'error','fotoUrl requerido'); end if;

  -- [egress] versionar la URL: una foto reemplazada = URL nueva = cache-miss del SW → nunca foto vieja.
  v_url := split_part(v_url, '?', 1) || '?v=' || (extract(epoch from now())::bigint)::text;

  if v_id is not null then
    update mos.productos set foto_url = v_url, updated_at = now() where id_producto = v_id;
  else
    if v_sku is null then return jsonb_build_object('ok',false,'error','skuBase o idProducto requerido'); end if;
    -- [646c] legacy por sku: SOLO el canónico (jamás pinta a la familia)
    update mos.productos set foto_url = v_url, updated_at = now()
     where sku_base = v_sku and tipo_producto::text = 'CANONICO';
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('skuBase', v_sku, 'idProducto', v_id,
    'fotoUrl', v_url, 'actualizados', coalesce(v_n,0)));
end; $function$;

select '999 foto_url versionada listo' as ok,
       (select count(*) from mos.productos where foto_url like '%?v=%') as fotos_versionadas;
