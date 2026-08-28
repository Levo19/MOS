-- [965] Zona · detalle de un MOVIMIENTO del historial (kardex). Para el overlay que abre cada fila:
--  · fuente 'venta' → ticket completo (me.ventas + me.ventas_detalle), marcando la línea del producto analizado.
--  · fuente 'guia'  → guía completa (me.guias_cabecera + me.guias_detalle), idem.
--  (ajuste/auditoría NO pasan por acá: el front los dibuja del propio movimiento — traen usuario/fecha/delta/saldo.)
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
  -- códigos del producto analizado (para marcar su línea)
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
    select to_jsonb(h) into v_head from (
      select g.id_guia, coalesce(g.tipo,'') tipo,
             to_char(g.fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI') fecha,
             coalesce(g.vendedor,'') vendedor, coalesce(g.zona_id,'') zona,
             coalesce(g.zona_destino,'') destino, coalesce(g.estado,'') estado, coalesce(g.observacion,'') obs
        from me.guias_cabecera g where g.id_guia = v_id) h;
    if v_head is null then return jsonb_build_object('ok',false,'error','Guía no encontrada'); end if;
    select coalesce(jsonb_agg(jsonb_build_object(
        'nombre', coalesce(cat.descripcion, d.cod_barras),
        'cod', coalesce(d.cod_barras,''), 'cantidad', d.cantidad,
        'aplicada', d.cantidad_aplicada,
        'match', (array_length(v_codes,1) is not null and upper(btrim(coalesce(d.cod_barras,''))) = any(v_codes))
      ) order by d.linea), '[]'::jsonb) into v_lin
      from me.guias_detalle d
      left join lateral (
        select pr.descripcion from mos.productos pr where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_barras)) limit 1
      ) cat on true
     where d.id_guia = v_id;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('tipo','guia','header',v_head,'lineas',v_lin));
  end if;

  return jsonb_build_object('ok',false,'error','fuente no soportada: '||v_fte);
end $function$;

grant execute on function mos.zona_mov_detalle(jsonb) to authenticated, anon, service_role;
select '965 zona_mov_detalle listo' as ok;
