-- [967] zona_mov_detalle + ENVASADO. Un movimiento de ALMACEN puede ser un ENVASADO (id ENV_...): NO es una
-- guia de wh.guias -- es una TRANSFORMACION registrada en wh.envasados (granel base + envase -> producto
-- envasado, con merma y eficiencia). Antes caia en "Guia no encontrada" y mostraba solo el resumen del mov.
-- Ahora fuente='envasado' (o id ENV_...) devuelve la transformacion completa, marcando el rol del producto
-- analizado (insumo/envase/producido).  Conserva las ramas venta + guia(zona/almacen) de [966].
create or replace function mos.zona_mov_detalle(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_id  text := nullif(btrim(coalesce(p->>'id','')),'');
  v_fte text := lower(nullif(btrim(coalesce(p->>'fuente','')),''));
  v_codes text[];
  v_head jsonb; v_lin jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','id requerido'); end if;
  select coalesce(array_agg(upper(btrim(x))), array[]::text[]) into v_codes
    from jsonb_array_elements_text(coalesce(p->'codBarras','[]'::jsonb)) x where btrim(x) <> '';

  -- === ENVASADO === (fuente explicita o id ENV_...): transformacion desde wh.envasados
  if v_fte = 'envasado' or v_id like 'ENV\_%' then
    select to_jsonb(h) into v_head from (
      select e.id_envasado id, coalesce(e.estado,'') estado,
             to_char(e.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI') fecha,
             coalesce(nullif(btrim(e.usuario),''),'—') usuario,
             coalesce(nullif(btrim(e.colaborador),''),'') colaborador,
             coalesce(e.observacion,'') obs,
             coalesce(e.eficiencia_pct,0) eficiencia, coalesce(e.merma_real,0) merma,
             coalesce(e.unidad_base,'') unidad_base
        from wh.envasados e where e.id_envasado = v_id) h;
    if v_head is null then return jsonb_build_object('ok',false,'error','Envasado no encontrado'); end if;
    select jsonb_agg(l order by l->>'ord') into v_lin from (
      select e.* from wh.envasados e where e.id_envasado = v_id
    ) e cross join lateral (
      -- (1) INSUMO: granel base consumido
      select jsonb_build_object('ord','1','rol','Insumo (granel)','dir','out',
               'cod', e.cod_producto_base,
               'nombre', coalesce((select pr.descripcion from mos.productos pr
                          where upper(btrim(pr.codigo_barra))=upper(btrim(e.cod_producto_base))
                             or upper(btrim(pr.sku_base))=upper(btrim(e.cod_producto_base)) limit 1), e.cod_producto_base),
               'cantidad', e.cantidad_base, 'unidad', coalesce(e.unidad_base,''),
               'match', (array_length(v_codes,1) is not null and upper(btrim(e.cod_producto_base)) = any(v_codes))) l
      union all
      -- (2) ENVASE: empaque consumido (si hubo)
      select jsonb_build_object('ord','2','rol','Envase','dir','out',
               'cod', e.envase_cod,
               'nombre', coalesce((select pr.descripcion from mos.productos pr
                          where upper(btrim(pr.codigo_barra))=upper(btrim(e.envase_cod))
                             or upper(btrim(pr.sku_base))=upper(btrim(e.envase_cod)) limit 1), e.envase_cod),
               'cantidad', e.envase_cant, 'unidad', '',
               'match', (array_length(v_codes,1) is not null and upper(btrim(coalesce(e.envase_cod,''))) = any(v_codes)))
      where coalesce(nullif(btrim(e.envase_cod),''),'') <> '' and coalesce(e.envase_cant,0) <> 0
      union all
      -- (3) PRODUCIDO: unidades envasadas obtenidas
      select jsonb_build_object('ord','3','rol','Producido','dir','in',
               'cod', e.cod_producto_envasado,
               'nombre', coalesce((select pr.descripcion from mos.productos pr
                          where upper(btrim(pr.codigo_barra))=upper(btrim(e.cod_producto_envasado))
                             or upper(btrim(pr.sku_base))=upper(btrim(e.cod_producto_envasado)) limit 1), e.cod_producto_envasado),
               'cantidad', coalesce(e.unidades_producidas, e.unidades_esperadas), 'unidad', 'und',
               'esperadas', e.unidades_esperadas,
               'match', (array_length(v_codes,1) is not null and upper(btrim(e.cod_producto_envasado)) = any(v_codes)))
    ) l(l);
    return jsonb_build_object('ok',true,'data',jsonb_build_object(
      'tipo','envasado','origen','almacen','header',v_head,'lineas',coalesce(v_lin,'[]'::jsonb)));
  end if;

  if v_fte is null then return jsonb_build_object('ok',false,'error','fuente requerida'); end if;

  if v_fte = 'venta' then
    select to_jsonb(h) into v_head from (
      select v.id_venta, coalesce(v.correlativo,'') correlativo,
             to_char(v.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI') fecha,
             coalesce(v.vendedor,'') vendedor, coalesce(v.cliente_nombre,'') cliente,
             coalesce(v.cliente_doc,'') doc, v.total, coalesce(v.forma_pago,'') forma_pago,
             coalesce(v.id_caja,'') caja, coalesce(v.zona_id,'') zona, coalesce(v.obs,'') obs
        from me.ventas v where v.id_venta = v_id) h;
    if v_head is null then return jsonb_build_object('ok',false,'error','Venta no encontrada'); end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'nombre', coalesce(nullif(btrim(d.nombre),''), d.cod_barras, d.sku),
        'cod', coalesce(d.cod_barras,''), 'cantidad', d.cantidad, 'precio', d.precio,
        'subtotal', d.subtotal, 'unidad', coalesce(d.unidad_medida,''),
        'match', (array_length(v_codes,1) is not null and upper(btrim(coalesce(d.cod_barras,''))) = any(v_codes))
      ) order by d.linea), '[]'::jsonb) into v_lin
      from me.ventas_detalle d where d.id_venta = v_id;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','venta','header',v_head,'lineas',v_lin));

  elsif v_fte = 'guia' then
    -- (a) guia de ZONA
    select to_jsonb(h) into v_head from (
      select g.id_guia, coalesce(g.tipo,'') tipo,
             to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI') fecha,
             coalesce(g.vendedor,'') vendedor, coalesce(g.zona_id,'') zona,
             coalesce(g.zona_destino,'') destino, coalesce(g.estado,'') estado, coalesce(g.observacion,'') obs
        from me.guias_cabecera g where g.id_guia = v_id) h;
    if v_head is not null then
      select coalesce(jsonb_agg(jsonb_build_object(
          'nombre', coalesce(cat.descripcion, d.cod_barras),
          'cod', coalesce(d.cod_barras,''), 'cantidad', d.cantidad, 'aplicada', d.cantidad_aplicada,
          'match', (array_length(v_codes,1) is not null and upper(btrim(coalesce(d.cod_barras,''))) = any(v_codes))
        ) order by d.linea), '[]'::jsonb) into v_lin
        from me.guias_detalle d
        left join lateral (select pr.descripcion from mos.productos pr where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_barras)) limit 1) cat on true
       where d.id_guia = v_id;
      return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','guia','header',v_head,'lineas',v_lin));
    end if;
    -- (b) guia de ALMACEN (wh.guias -- tabla propia de almacen)
    select to_jsonb(h) into v_head from (
      select g.id_guia, coalesce(g.tipo,'') tipo,
             to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI') fecha,
             coalesce(g.usuario,'') vendedor, coalesce(g.id_zona,'') zona,
             ''::text destino, coalesce(g.estado,'') estado, coalesce(g.comentario,'') obs
        from wh.guias g where g.id_guia = v_id) h;
    if v_head is null then return jsonb_build_object('ok',false,'error','Guia no encontrada'); end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'nombre', coalesce(cat.descripcion, d.cod_producto),
        'cod', coalesce(d.cod_producto,''),
        'cantidad', coalesce(d.cant_recibida, d.cant_esperada),
        'aplicada', d.cantidad_aplicada,
        'match', (array_length(v_codes,1) is not null and upper(btrim(coalesce(d.cod_producto,''))) = any(v_codes))
      ) order by d.linea), '[]'::jsonb) into v_lin
      from wh.guia_detalle d
      left join lateral (select pr.descripcion from mos.productos pr
                          where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto))
                             or upper(btrim(pr.sku_base)) = upper(btrim(d.cod_producto)) limit 1) cat on true
     where d.id_guia = v_id;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','guia','origen','almacen','header',v_head,'lineas',v_lin));
  end if;

  return jsonb_build_object('ok',false,'error','fuente no soportada: '||v_fte);
end $function$;

grant execute on function mos.zona_mov_detalle(jsonb) to authenticated, anon, service_role;
select '967 zona_mov_detalle + envasado listo' as ok;
