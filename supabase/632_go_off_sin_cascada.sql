CREATE OR REPLACE FUNCTION mos.catalogo_toggle_mosgo(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cod text := btrim(coalesce(p->>'codigoBarra',''));
  v_on boolean := coalesce((p->>'on')::boolean, false);
  v_usr text := btrim(coalesce(p->>'usuario',''));
  v_row record;
begin
  -- [628] Guard server-side: SOLO MASTER puede tocar el canal MosGo (decisión 5).
  if not exists (select 1 from mos.personal
                  where upper(btrim(nombre)) = upper(v_usr) and upper(coalesce(rol,'')) = 'MASTER') then
    return jsonb_build_object('ok', false, 'error', 'SOLO_MASTER');
  end if;
  if v_cod = '' then return jsonb_build_object('ok', false, 'error', 'Requiere codigoBarra'); end if;

  select codigo_barra, estado, canal_mayoreo into v_row from mos.productos where codigo_barra = v_cod;
  if not found then return jsonb_build_object('ok', false, 'error', 'NO_EXISTE'); end if;

  if v_on then
    -- Encender 🛵 enciende también el catálogo (todo lo de MosGo se vende en ME — decisión 1).
    update mos.productos set canal_mayoreo = true, estado = true where codigo_barra = v_cod;
    -- [631] presentación de un granel (base KGM) sin precio_fijo → se marca sola: en el
    -- canal GO todo escalón se cobra a etiqueta; sin la marca, MosGo la oculta y ME la
    -- cobraría por kg (precio mentiroso). Solo al ENCENDER, decisión explícita del MASTER.
    update mos.productos pr set precio_fijo = true
     where pr.codigo_barra = v_cod
       and pr.tipo_producto::text = 'PRESENTACION'
       and coalesce(pr.precio_fijo, false) = false
       and exists (select 1 from mos.productos b
                    where coalesce(nullif(btrim(b.sku_base),''), b.id_producto) = nullif(btrim(pr.sku_base),'')
                      and b.tipo_producto::text <> 'PRESENTACION'
                      and coalesce(nullif(b.factor_conversion,0),1) = 1
                      and upper(coalesce(nullif(btrim(b.unidad_medida),''), b.unidad,'')) = 'KGM');
  else
    -- [632] Apagar GO SOLO lo saca del canal MosGo — el producto SIGUE a la venta en ME.
    -- (La cascada original apagaba también el catálogo: el dueño la vio en acción —
    -- la familia entera "en mallas" y el granel fuera de la caja — y la descartó.)
    update mos.productos set canal_mayoreo = false where codigo_barra = v_cod;
  end if;

  select estado, canal_mayoreo, precio_fijo into v_row from mos.productos where codigo_barra = v_cod;
  return jsonb_build_object('ok', true, 'codigoBarra', v_cod,
    'estado', v_row.estado, 'canalMayoreo', v_row.canal_mayoreo, 'precioFijo', v_row.precio_fijo);
end; $function$


grant execute on function mos.catalogo_version(jsonb) to anon;