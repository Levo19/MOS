-- 628 aplicado vía 628_mosgo_catalogo_real.mjs
CREATE OR REPLACE FUNCTION mos.catalogo_pos_rls()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pb jsonb := '[]'::jsonb; v_pr jsonb := '[]'::jsonb; v_eq jsonb; v_zc jsonb; v_cf jsonb; v_sz jsonb; g record;
  v_tramos_map jsonb;
begin
  -- [PERF] pre-cargar TODOS los tramos en un mapa sku_base->tramos UNA vez (evita N subqueries en el loop)
  select coalesce(jsonb_object_agg(sku_base, tramos), '{}'::jsonb) into v_tramos_map from mos.precio_tramos;

  for g in
    with act as (
      select coalesce(nullif(btrim(sku_base),''), id_producto) as sku,
             id_producto, codigo_barra, descripcion, precio_venta,
             coalesce(precio_fijo, false) as precio_fijo,   -- [628] presentación de granel con precio de etiqueta
             coalesce(nullif(factor_conversion,0),1) as factor,
             (coalesce(btrim(es_envasable::text),'') <> '1') as vendible,
             coalesce(es_envasable::text,'') as es_env,
             tipo_igv, unidad, unidad_medida, cod_sunat
        from mos.productos
       where coalesce(estado, true) = true          -- [b FIX] estado es BOOLEAN: excluir apagados (false), no '0'
    )
    select sku, jsonb_agg(to_jsonb(act) order by factor asc) as members from act group by sku
  loop
    declare
      v_members jsonb := g.members; v_vend jsonb; v_base jsonb; v_f1 jsonb; v_nombre text; m jsonb;
      v_tramos jsonb;
    begin
      select coalesce(jsonb_agg(value order by (value->>'factor')::numeric asc),'[]'::jsonb)
        into v_vend from jsonb_array_elements(v_members) where (value->>'vendible')::boolean;
      if jsonb_array_length(v_vend) = 0 then continue; end if;

      -- [fix dinero] DESEMPATE KGM: en grupos unidad-mixta (KGM+NIU, ambos factor=1) el `limit 1` arbitrario
      -- podía elegir la fila NIU → PRODUCTO_BASE.Unidad_Medida='NIU' → en ME `_esGranelItem` (chequea KGM)
      -- falla → los tramos del granel se IGNORAN en silencio → precio cobrado sin ajuste. Preferir KGM.
      select value into v_f1 from jsonb_array_elements(v_members) where (value->>'factor')::numeric = 1
        order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1;
      select value into v_base from jsonb_array_elements(v_vend) where (value->>'factor')::numeric = 1
        order by (upper(coalesce(value->>'unidad_medida', value->>'unidad','')) = 'KGM') desc limit 1;
      if v_base is null then v_base := v_vend->0; end if;

      if v_f1 is not null and not (v_f1->>'vendible')::boolean
         and coalesce(v_f1->>'id_producto','') <> coalesce(v_base->>'id_producto','') then
        v_nombre := btrim(coalesce(nullif(btrim(v_f1->>'descripcion'),''),'') || ' ' || coalesce(v_base->>'descripcion',''));
      else
        v_nombre := btrim(coalesce(v_base->>'descripcion',''));
      end if;

      -- [c] tramos del GRUPO (por sku_base, desde el mapa pre-cargado) -> a cada presentacion; ME los aplica al canonico
      v_tramos := v_tramos_map -> g.sku;

      v_pb := v_pb || jsonb_build_array(jsonb_build_object(
        'SKU_Base', g.sku, 'Nombre', v_nombre,
        'Tipo_IGV', mos._conv_tipo_igv(v_base->>'tipo_igv'),
        'Unidad_Medida', mos._norm_unidad_medida(v_base->>'unidad', v_base->>'unidad_medida'),
        'Cod_SUNAT', coalesce(v_base->>'cod_sunat',''),
        'segmentos_precio', coalesce(v_tramos,'[]'::jsonb)));

      for m in select value from jsonb_array_elements(v_vend) loop
        v_pr := v_pr || jsonb_build_array(
          jsonb_build_object(
            'SKU_Base', g.sku, 'SKU', coalesce(m->>'id_producto',''),
            'Cod_Barras', coalesce(nullif(btrim(m->>'codigo_barra'),''), m->>'id_producto'),
            'Empaque', coalesce(m->>'descripcion',''),
            'Precio_Venta', coalesce((m->>'precio_venta')::numeric, 0),
            'Factor', coalesce((m->>'factor')::numeric, 1),
            'Precio_Fijo', coalesce((m->>'precio_fijo')::boolean, false))
          -- [c] segmentos_precio SOLO en la canónica (Factor=1, lo único que ME lee) y solo si hay tramos
          --     → no infla las 2358 presentaciones (el append es O(n²) en la longitud del array).
          || case when (m->>'factor')::numeric = 1 and v_tramos is not null
                  then jsonb_build_object('segmentos_precio', v_tramos) else '{}'::jsonb end);
      end loop;
    end;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('Cod_Alias', codigo_barra, 'Cod_Barras_Real', sku_base)), '[]'::jsonb)
    into v_eq from mos.equivalencias where activo;
  with imp as (
    select id_estacion, max(printnode_id) as pn from mos.impresoras
     where activo and (coalesce(lower(app_origen),'') in ('','mosexpress')) and (coalesce(upper(tipo),'') in ('','TICKET')) group by id_estacion),
  ser as (
    select id_zona,
      max(serie) filter (where upper(replace(replace(tipo_documento,' ',''),'_','')) in ('NOTAVENTA','NV','NOTADEVENTA')) as nota,
      max(serie) filter (where upper(tipo_documento)='BOLETA') as boleta,
      max(serie) filter (where upper(tipo_documento)='FACTURA') as factura
    from mos.series_documentales where activo group by id_zona)
  select coalesce(jsonb_agg(jsonb_build_object(
           'Zona_ID', e.id_zona, 'Estacion_Nombre', e.nombre, 'idEstacion', e.id_estacion,
           'PrintNode_ID', coalesce(imp.pn,''), 'Serie_Nota', coalesce(ser.nota,''),
           'Serie_Boleta', coalesce(ser.boleta,''), 'Serie_Factura', coalesce(ser.factura,''),
           'Admin_PIN', coalesce(e.admin_pin,''))), '[]'::jsonb)
    into v_zc from mos.estaciones e
    left join imp on imp.id_estacion = e.id_estacion left join ser on ser.id_zona = e.id_zona
   where e.activo and coalesce(lower(e.app_origen),'') in ('','mosexpress') and coalesce(btrim(e.nombre),'') <> '';
  select coalesce(jsonb_agg(jsonb_build_object('Documento', documento, 'Nombre_RazonSocial', nombre, 'Direccion', coalesce(direccion,''))), '[]'::jsonb)
    into v_cf from me.clientes_frecuentes;
  select coalesce(jsonb_agg(jsonb_build_object('Cod_Barras', cod_barras, 'Zona_ID', zona_id, 'Cantidad', cantidad)), '[]'::jsonb)
    into v_sz from me.stock_zonas;

  return jsonb_build_object('status','success','data', jsonb_build_object(
    'PRODUCTO_BASE', v_pb, 'PRESENTACIONES', v_pr, 'EQUIVALENCIAS', v_eq,
    'ZONAS_CONFIG', v_zc, 'CLIENTES_FRECUENTES', v_cf, 'STOCK_ZONAS', v_sz, 'PROMOCIONES', '[]'::jsonb,
    '_meta', jsonb_build_object('fuente','SUPABASE','timestamp', (extract(epoch from now())*1000)::bigint)));
end;
$function$


create or replace function mos.ruta_boot(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_fam jsonb; v_clis jsonb; v_pct numeric;
begin
  -- [628] FAMILIAS: una por producto base (canónico o derivado). La escalera de una
  -- familia = su unidad base (si tiene 🛵) + sus presentaciones con 🛵. Los precios
  -- salen SIEMPRE del catálogo; el stock del almacén (base: kg o unidades).
  with go as (
    select * from mos.productos
     where coalesce(estado, true) = true and canal_mayoreo = true
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
           (coalesce(pr.canal_mayoreo,false) and coalesce(pr.estado,true)) as base_mosgo,
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
end; $fn$;

create or replace function mos.ruta_pedido_crear(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
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
       and coalesce(estado, true) = true and canal_mayoreo = true
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
end; $fn$;

create or replace function mos.catalogo_toggle_mosgo(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
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
  else
    -- Apagar 🛵 apaga AMBOS (decisión 3 del dueño: cascada en un solo gesto).
    update mos.productos set canal_mayoreo = false, estado = false where codigo_barra = v_cod;
  end if;

  select estado, canal_mayoreo into v_row from mos.productos where codigo_barra = v_cod;
  return jsonb_build_object('ok', true, 'codigoBarra', v_cod,
    'estado', v_row.estado, 'canalMayoreo', v_row.canal_mayoreo);
end; $fn$;