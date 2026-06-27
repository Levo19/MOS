-- 215b · crear_pickup_cierre_caja v2: reposición por canónico con regla peso/unidad (mos._venta_canonico).

create or replace function wh.crear_pickup_cierre_caja(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_caja text := nullif(btrim(coalesce(p->>'id_caja',p->>'idCaja','')),'');
  v_zona text; v_cajero text; v_idp text; v_items jsonb; v_n int; v_n2 int; v_now timestamptz:=now();
begin
  if v_caja is null then return jsonb_build_object('ok',false,'error','Requiere id_caja'); end if;
  select coalesce(nullif(btrim(zona_id),''),''), coalesce(vendedor,'') into v_zona,v_cajero from me.cajas where id_caja=v_caja;
  if not found then return jsonb_build_object('ok',false,'error','Caja no encontrada'); end if;
  v_idp := 'PCK-CC-'||v_caja;
  perform 1 from wh.pickups where id_pickup=v_idp;
  if found then return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_idp,'dedup',true)); end if;
  with src as (
    select vd.cod_barras cb, wh._num(vd.cantidad::text) cant, vd.unidad_medida um
    from me.ventas v join me.ventas_detalle vd on vd.id_venta=v.id_venta
    where v.id_caja=v_caja and upper(coalesce(v.forma_pago,''))<>'ANULADO'
  ),
  det as (select cv.sku_base sku, cv.cant from src cross join lateral mos._venta_canonico(src.cb, src.cant, src.um) cv where src.cant>0),
  agg as (select sku, sum(cant) sol from det where coalesce(sku,'')<>'' group by sku having sum(cant)>0)
  select coalesce(jsonb_agg(jsonb_build_object(
    'skuBase',a.sku,
    'nombre',coalesce((select pp.descripcion from mos.productos pp where pp.sku_base=a.sku order by (pp.codigo_producto_base is null) desc limit 1),a.sku),
    'solicitado',a.sol,'despachado',0,
    'codigosOriginales',coalesce((select jsonb_agg(distinct cod) from (
        select pp.codigo_barra cod from mos.productos pp where pp.sku_base=a.sku and coalesce(pp.codigo_barra,'')<>'' and coalesce(nullif(pp.factor_conversion,0),1)=1
        union select e.codigo_barra from mos.equivalencias e where e.sku_base=a.sku and e.activo and coalesce(e.codigo_barra,'')<>'') q),'[]'::jsonb)
  ) order by a.sku),'[]'::jsonb) into v_items from agg a;
  v_n := jsonb_array_length(coalesce(v_items,'[]'::jsonb));
  if v_n=0 then return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',null,'items',0,'vacio',true)); end if;
  insert into wh.pickups (id_pickup,fuente,estado,items,id_zona,notas,creado_por,fecha_creado,ultima_actividad)
  values (v_idp,'ME_CIERRE_CAJA','PENDIENTE',v_items,v_zona,'idCaja='||v_caja||' · cajero='||v_cajero,coalesce(nullif(v_cajero,''),'ME_AUTO'),v_now,v_now)
  on conflict (id_pickup) do nothing;
  get diagnostics v_n2 = row_count;
  if v_n2=0 then return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_idp,'dedup',true)); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_idp,'items',v_n,'zona',v_zona));
exception when others then return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;$fn$;
revoke all on function wh.crear_pickup_cierre_caja(jsonb) from public;
grant execute on function wh.crear_pickup_cierre_caja(jsonb) to authenticated, service_role;
