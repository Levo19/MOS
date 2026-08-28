-- [966] zona_mov_detalle: una guía puede ser de ZONA (me.guias_cabecera) o de ALMACÉN (wh.guias, tabla
-- propia de Almacén). Antes solo miraba Zona → las guías de Almacén (ids locales G_L…/ENV_… reales)
-- daban "Guía no encontrada". Ahora: prueba Zona; si no está, prueba Almacén.
create or replace function mos.zona_mov_detalle(p jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_id  text := nullif(btrim(coalesce(p->>'id','')),'');
  v_fte text := lower(nullif(btrim(coalesce(p->>'fuente','')),''));
  v_codes text[];
  v_head jsonb; v_lin jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_fte is null then return jsonb_build_object('ok',false,'error','id + fuente requeridos'); end if;
  select coalesce(array_agg(upper(btrim(x))), array[]::text[]) into v_codes
    from jsonb_array_elements_text(coalesce(p->'codBarras','[]'::jsonb)) x where btrim(x) <> '';

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
    -- (a) guía de ZONA
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
    -- (b) guía de ALMACÉN (wh.guias — tabla propia de almacén)
    select to_jsonb(h) into v_head from (
      select g.id_guia, coalesce(g.tipo,'') tipo,
             to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI') fecha,
             coalesce(g.usuario,'') vendedor, coalesce(g.id_zona,'') zona,
             ''::text destino, coalesce(g.estado,'') estado, coalesce(g.comentario,'') obs
        from wh.guias g where g.id_guia = v_id) h;
    if v_head is null then return jsonb_build_object('ok',false,'error','Guía no encontrada'); end if;
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

select '966 zona_mov_detalle + almacén listo' as ok;
