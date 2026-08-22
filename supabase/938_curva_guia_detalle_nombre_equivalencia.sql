-- [938] curva_guia_detalle: nombre de líneas con código-equivalencia (no en mos.productos)
-- resuelto por sku_base → descripción del canónico. Antes caía al código crudo (7750477080090).
CREATE OR REPLACE FUNCTION mos.curva_guia_detalle(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_guia text := nullif(btrim(coalesce(p->>'idGuia','')),'');
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')),'');
  v_idp  text := nullif(btrim(coalesce(p->>'idProducto','')),'');
  v_g    record;
  v_pv   numeric := 0;
  v_pc   numeric := 0;
  v_items jsonb;
  v_costo jsonb;
  v_desc  jsonb;
  v_elim  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_guia is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;

  if v_sku is null and v_idp is not null then
    select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) into v_sku
      from mos.productos pr where pr.id_producto = v_idp limit 1;
  end if;

  select * into v_g from wh.guias where id_guia = v_guia limit 1;
  if not found then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;

  select coalesce(pr.precio_venta,0), coalesce(pr.precio_costo,0) into v_pv, v_pc
    from mos.productos pr
   where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = coalesce(v_sku,'~')
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
   order by pr.codigo_barra limit 1;

  with codigos as (
    select upper(btrim(pr.codigo_barra)) cb from mos.productos pr
     where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = coalesce(v_sku,'~')
       and nullif(btrim(pr.codigo_barra),'') is not null
    union
    select upper(btrim(eq.codigo_barra)) from mos.equivalencias eq
     where eq.sku_base = coalesce(v_sku,'~') and coalesce(eq.activo, true)
       and nullif(btrim(eq.codigo_barra),'') is not null
  ),
  lineas as (
    select d.linea, d.cod_producto,
           coalesce(d.cant_recibida, d.cantidad_aplicada, d.cant_esperada, 0) cant,
           -- sku del producto de ESTA línea: por código propio o por equivalencia
           coalesce(
             (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr
               where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) limit 1),
             (select eq.sku_base from mos.equivalencias eq
               where upper(btrim(eq.codigo_barra)) = upper(btrim(d.cod_producto))
                 and coalesce(eq.activo,true) limit 1)
           ) sku_linea,
           (select pr.descripcion from mos.productos pr
             where upper(btrim(pr.codigo_barra)) = upper(btrim(d.cod_producto)) limit 1) nom
      from wh.guia_detalle d where d.id_guia = v_guia
  )
  select coalesce(jsonb_agg(x.obj order by x.linea), '[]'::jsonb) into v_items
    from (
      select l.linea, jsonb_build_object(
               'linea', l.linea,
               'codigo', coalesce(l.cod_producto,''),
               'nombre', coalesce(l.nom,
                 -- [938] código-equivalencia (no vive en mos.productos): resolver el nombre por sku_base → descripción del canónico
                 (select pr.descripcion from mos.productos pr
                   where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = l.sku_linea
                     and coalesce(nullif(pr.factor_conversion,0),1) = 1
                   order by pr.codigo_barra limit 1),
                 l.cod_producto),
               'cantidad', l.cant,
               -- [810] el costo que ESTA guía dejó aplicado a ESTE producto (null si ninguno)
               'costoAplicado', (
                 select round(h.valor, 4)
                   from mos.historial_precio_costo h
                   join lateral (
                     select coalesce(pr2.precio_venta,0) pv, coalesce(pr2.precio_costo,0) pc
                       from mos.productos pr2
                      where coalesce(nullif(btrim(pr2.sku_base),''), pr2.id_producto) = l.sku_linea
                        and coalesce(nullif(pr2.factor_conversion,0),1) = 1
                      order by pr2.codigo_barra limit 1
                   ) c2 on true
                  where h.tipo = 'COSTO' and h.id_guia = v_guia and h.sku_base = l.sku_linea
                    and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, c2.pv, c2.pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)) is null
                  order by h.ts desc, h.id desc limit 1),
               'esEste', (upper(btrim(coalesce(l.cod_producto,''))) in (select cb from codigos))
             ) obj
        from lineas l
    ) x;

  if v_sku is not null then
    select jsonb_build_object(
             'valor', round(h.valor,4), 'usuario', h.usuario, 'source', coalesce(h.source,''),
             'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI:SS'))
      into v_costo
      from mos.historial_precio_costo h
     where h.tipo='COSTO' and h.sku_base = v_sku and h.id_guia = v_guia
       and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)) is null
     order by h.ts desc, h.id desc limit 1;

    select coalesce(jsonb_agg(y.obj order by y.valor desc), '[]'::jsonb) into v_desc
      from (
        select h.valor,
               jsonb_build_object(
                 'valor',   round(h.valor,4),
                 'usuario', (array_agg(h.usuario order by h.id))[1],
                 'ts',      to_char(min(h.ts) at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
                 'motivo',  (array_agg(mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)) order by h.id))[1],
                 'veces',   count(*)) obj
          from mos.historial_precio_costo h
         where h.tipo='COSTO' and h.sku_base = v_sku and h.id_guia = v_guia
           and upper(coalesce(h.source,'')) <> 'COMPRA_REVERSA'
           and mos._costo_anulacion(h.sku_base, h.id_guia, h.valor, h.ts, h.source, v_pv, v_pc, coalesce(wh._ts_safe(h.meta->>'registradoEl'), h.ts)) is not null
         group by h.valor, h.sku_base, h.id_guia, h.ts, h.source
      ) y;

    select jsonb_build_object(
             'usuario', coalesce(nullif(btrim(h.usuario),''),'—'),
             'ts', to_char(h.ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'))
      into v_elim
      from mos.historial_precio_costo h
     where h.tipo='COSTO' and h.sku_base = v_sku and h.id_guia = v_guia
       and upper(coalesce(h.source,'')) = 'COMPRA_REVERSA'
     order by h.ts desc, h.id desc limit 1;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia', v_g.id_guia,
    'fecha',  to_char(v_g.fecha at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
    'tipo',   coalesce(v_g.tipo,''),
    'estado', coalesce(v_g.estado,''),
    'usuario', coalesce(v_g.usuario,''),
    'zona',   coalesce(v_g.id_zona,''),
    'comentario', coalesce(v_g.comentario,''),
    'proveedor', coalesce(
                   (select pv.nombre from mos.proveedores pv where pv.id_proveedor = v_g.id_proveedor
                     and coalesce(nullif(btrim(pv.nombre),''),'') <> '' limit 1),
                   nullif(btrim(v_g.ocr_razon_social),''),
                   nullif(btrim(v_g.id_proveedor),''), '—'),
    'documento', coalesce(nullif(btrim(v_g.numero_documento),''),''),
    'monto',  nullif(v_g.monto_total, 0),
    'foto',   coalesce(nullif(btrim(v_g.foto),''), ''),
    'fotoRot', coalesce(v_g.foto_rot, 0),
    'nItems', jsonb_array_length(v_items),
    'items',  v_items,
    'costo',  v_costo,
    'costosDescartados', coalesce(v_desc,'[]'::jsonb),
    'eliminadoPor', v_elim
  ));
end;
$function$
;
