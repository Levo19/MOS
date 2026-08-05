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
    -- [633] INDEPENDIENTE: encender GO solo enciende el canal MosGo. El estado (ME)
    -- tiene su propio toggle y no se tocan entre sí ("así no combinamos" — el dueño).
    update mos.productos set canal_mayoreo = true where codigo_barra = v_cod;
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


CREATE OR REPLACE FUNCTION mos.ruta_boot(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_fam jsonb; v_clis jsonb; v_pct numeric;
begin
  -- [628] FAMILIAS: una por producto base (canónico o derivado). La escalera de una
  -- familia = su unidad base (si tiene 🛵) + sus presentaciones con 🛵. Los precios
  -- salen SIEMPRE del catálogo; el stock del almacén (base: kg o unidades).
  with go as (
    select * from mos.productos
     where canal_mayoreo = true   -- [633] GO manda solo aquí; estado gobierna ME, no MosGo
  ),
  fam_keys as (
    select distinct coalesce(nullif(btrim(sku_base),''), id_producto) as fsku
      from go where tipo_producto::text <> 'PRESENTACION'
    union
    select distinct nullif(btrim(sku_base),'')
      from go where tipo_producto::text = 'PRESENTACION' and nullif(btrim(sku_base),'') is not null
  ),
  basep as (
    select k.fsku, pr.codigo_barra, pr.descripcion, pr.precio_venta,
           upper(coalesce(nullif(btrim(pr.unidad_medida),''), pr.unidad, 'NIU')) as um,
           coalesce(pr.canal_mayoreo, false) as base_mosgo,   -- [633] independiente de estado
           coalesce(s.cantidad_disponible, 0) as stock
      from fam_keys k
      join lateral (
        select * from mos.productos p
         where coalesce(nullif(btrim(p.sku_base),''), p.id_producto) = k.fsku
           and p.tipo_producto::text <> 'PRESENTACION'
           and coalesce(nullif(p.factor_conversion,0),1) = 1
         order by (upper(coalesce(nullif(btrim(p.unidad_medida),''), p.unidad,'')) = 'KGM') desc, p.id_producto
         limit 1) pr on true
      left join wh.stock s on upper(btrim(s.cod_producto)) = upper(btrim(pr.codigo_barra))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'fsku',       b.fsku,
           'baseCod',    b.codigo_barra,
           'baseNombre', b.descripcion,
           'baseUnidad', b.um,
           'basePrecio', coalesce(b.precio_venta, 0),
           'baseMosgo',  b.base_mosgo,
           'stockBase',  b.stock,
           'escalones',  coalesce((
              select jsonb_agg(jsonb_build_object(
                       'cod',    e.codigo_barra,
                       'nombre', e.descripcion,
                       'factor', coalesce(nullif(e.factor_conversion,0),1),
                       'precio', coalesce(e.precio_venta,0),
                       'fijo',   coalesce(e.precio_fijo,false)
                     ) order by coalesce(nullif(e.factor_conversion,0),1))
                from go e
               where e.tipo_producto::text = 'PRESENTACION'
                 and nullif(btrim(e.sku_base),'') = b.fsku), '[]'::jsonb)
         ) order by b.descripcion), '[]'::jsonb)
    into v_fam from basep b;

  select coalesce(jsonb_agg(jsonb_build_object(
    'documento', cf.documento, 'nombre', cf.nombre, 'tipo_doc', cf.tipo_doc,
    'direccion', coalesce(cf.direccion,''),
    'tipo_negocio', coalesce(ce.tipo_negocio,''), 'direccion_entrega', coalesce(ce.direccion_entrega,''),
    'telefono_wsp', coalesce(ce.telefono_wsp,''), 'dia_visita', coalesce(ce.dia_visita,''),
    'notas', coalesce(ce.notas,'')
  ) order by cf.nombre), '[]'::jsonb) into v_clis
  from me.clientes_frecuentes cf
  left join ruta.clientes_ext ce on ce.documento = cf.documento;

  select (v)::text::numeric into v_pct from ruta.config where k = 'comision_pct';
  -- 'productos' [] mantiene vivo al frontend viejo hasta que se actualice (mostrará vacío).
  return jsonb_build_object('ok', true, 'familias', v_fam, 'productos', '[]'::jsonb,
    'clientes', v_clis, 'comision_pct', coalesce(v_pct, 3));
end; $function$


CREATE OR REPLACE FUNCTION mos.ruta_pedido_crear(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_local text := btrim(coalesce(p->>'local_id',''));
  v_vend  text := btrim(coalesce(p->>'vendedor',''));
  v_items jsonb := coalesce(p->'items','[]'::jsonb);
  v_it jsonb; v_total numeric := 0; v_ahorro numeric := 0; v_ajustados int := 0;
  v_cant numeric; v_pu numeric; v_pu_cli numeric; v_sub numeric;
  v_prod record; v_base_precio numeric; v_factor numeric;
  v_clean jsonb := '[]'::jsonb; v_id text; v_ex ruta.pedidos%rowtype;
begin
  if v_local = '' or v_vend = '' then return jsonb_build_object('ok', false, 'error', 'local_id y vendedor requeridos'); end if;
  if jsonb_array_length(v_items) = 0 then return jsonb_build_object('ok', false, 'error', 'pedido vacío'); end if;

  select * into v_ex from ruta.pedidos where local_id = v_local;
  if found then
    return jsonb_build_object('ok', true, 'id_pedido', v_ex.id_pedido, 'estado', v_ex.estado,
      'total', v_ex.total, 'dedup', true);
  end if;

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_cant := coalesce((v_it->>'cant')::numeric, 0);
    if v_cant <= 0 then return jsonb_build_object('ok', false, 'error', 'cantidad inválida: ' || coalesce(v_it->>'codigo_barra','?')); end if;

    -- [628] EL PRECIO ES DEL CATÁLOGO, no del celular. Antes se aceptaba precio_unit
    -- del cliente sin validar: un request manipulado podía comprar a S/ 0.01.
    select codigo_barra, descripcion, precio_venta, sku_base,
           tipo_producto::text as tipo, coalesce(nullif(factor_conversion,0),1) as factor
      into v_prod
      from mos.productos
     where codigo_barra = v_it->>'codigo_barra'
       and canal_mayoreo = true   -- [633] GO manda solo; estado es el toggle de ME
     limit 1;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ITEM_NO_MOSGO: ' || coalesce(v_it->>'codigo_barra','?'));
    end if;
    v_pu := round(coalesce(v_prod.precio_venta, 0), 2);
    if v_pu <= 0 then return jsonb_build_object('ok', false, 'error', 'SIN_PRECIO: ' || v_prod.codigo_barra); end if;
    v_pu_cli := coalesce((v_it->>'precio_unit')::numeric, v_pu);
    if abs(v_pu_cli - v_pu) > 0.009 then v_ajustados := v_ajustados + 1; end if;

    v_sub := round(v_cant * v_pu, 2);
    v_total := round(v_total + v_sub, 2);

    -- ahorro vs comprar suelto: solo presentaciones (factor>1) contra su unidad base
    if v_prod.tipo = 'PRESENTACION' and v_prod.factor > 1 then
      select precio_venta into v_base_precio from mos.productos
       where coalesce(nullif(btrim(sku_base),''), id_producto) = nullif(btrim(v_prod.sku_base),'')
         and tipo_producto::text <> 'PRESENTACION'
         and coalesce(nullif(factor_conversion,0),1) = 1
       limit 1;
      if v_base_precio is not null then
        v_ahorro := round(v_ahorro + greatest(0, round(v_cant * (v_prod.factor * v_base_precio - v_pu), 2)), 2);
      end if;
    end if;

    v_clean := v_clean || jsonb_build_object(
      'codigo_barra', v_prod.codigo_barra, 'descripcion', coalesce(v_prod.descripcion,''),
      'cant', v_cant, 'precio_unit', v_pu, 'subtotal', v_sub,
      'tramo', coalesce(v_it->>'tramo',''));
  end loop;

  v_id := 'R-' || lpad(nextval('ruta.seq_pedido')::text, 4, '0');
  insert into ruta.pedidos (id_pedido, local_id, documento_cliente, nombre_cliente, vendedor, id_vendedor,
    items, total, ahorro_total, fecha_entrega, nota)
  values (v_id, v_local, coalesce(p->>'documento_cliente',''), coalesce(p->>'nombre_cliente',''),
    v_vend, nullif(p->>'id_vendedor',''), v_clean, v_total, v_ahorro,
    nullif(p->>'fecha_entrega','')::date, coalesce(p->>'nota',''))
  on conflict (local_id) do nothing;
  return jsonb_build_object('ok', true, 'id_pedido', v_id, 'estado', 'CONFIRMADO',
    'total', v_total, 'ahorro', v_ahorro, 'ajustados', v_ajustados, 'items', v_clean);
end; $function$
