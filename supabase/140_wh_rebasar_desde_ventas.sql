-- 140 · rebasar_acumulada v3: pedido desde me.ventas (helper canónico), despacho desde guías [pickup:].

create or replace function wh.rebasar_acumulada(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_zona text:=coalesce(nullif(btrim(coalesce(p->>'zona',p->>'id_zona','')),''),'');
  v_bucket date:=wh._bucket_dom((now() at time zone 'America/Lima')::date); v_acum_id text; v_items jsonb;
begin
  if v_zona='' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;
  v_acum_id:='PCK-ACU-'||v_zona||'-'||to_char(v_bucket,'YYYY-MM-DD');
  with ped as (  -- pedido = Σ ventas del bucket (por cierre de caja de la zona) resuelto al canónico
    select cv.sku_base sku, sum(cv.cant) sol
    from me.cajas cj join me.ventas v on v.id_caja=cj.id_caja
    join me.ventas_detalle vd on vd.id_venta=v.id_venta
    cross join lateral mos._venta_canonico(vd.cod_barras, vd.cantidad::numeric, vd.unidad_medida) cv
    where coalesce(cj.zona_id,'')=v_zona and upper(coalesce(v.forma_pago,''))<>'ANULADO'
      and wh._bucket_dom((coalesce(cj.fecha_cierre,cj.fecha_apertura) at time zone 'America/Lima')::date)=v_bucket
      and coalesce(cv.sku_base,'')<>''
    group by cv.sku_base having sum(cv.cant)>0
  ),
  desp as (  -- despacho = Σ guías SALIDA_ZONA DESDE pickup ([pickup:]) resuelto al canónico
    select coalesce(
        (select pr.sku_base from mos.productos pr where pr.codigo_barra=gd.cod_producto limit 1),
        (select e.sku_base from mos.equivalencias e where e.codigo_barra=gd.cod_producto and e.activo limit 1),
        gd.cod_producto) sku,
      sum(coalesce(gd.cant_recibida,gd.cantidad_aplicada,0)) d
    from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
    where g.tipo='SALIDA_ZONA' and g.comentario like '%[pickup:%' and coalesce(g.id_zona,'')=v_zona
      and wh._bucket_dom((g.fecha at time zone 'America/Lima')::date)=v_bucket group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('skuBase',ped.sku,
    'nombre',coalesce((select pp.descripcion from mos.productos pp where pp.sku_base=ped.sku order by (pp.codigo_producto_base is null) desc limit 1),ped.sku),
    'solicitado',ped.sol,'despachado',least(ped.sol,coalesce(desp.d,0)),
    'codigosOriginales',coalesce((select jsonb_agg(distinct cod) from (
       select pp.codigo_barra cod from mos.productos pp where pp.sku_base=ped.sku and coalesce(pp.codigo_barra,'')<>'' and coalesce(nullif(pp.factor_conversion,0),1)=1
       union select e.codigo_barra from mos.equivalencias e where e.sku_base=ped.sku and e.activo and coalesce(e.codigo_barra,'')<>'') q),'[]'::jsonb)
  ) order by ped.sku),'[]'::jsonb) into v_items from ped left join desp on desp.sku=ped.sku;
  update wh.pickups set items=v_items, ultima_actividad=now() where id_pickup=v_acum_id;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('acum',v_acum_id,'items',jsonb_array_length(v_items)));
end;$fn$;