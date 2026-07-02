-- ============================================================================
-- 318_pickup_cross_guard.sql — cross-guard anti doble-pickup en el cierre de caja
-- ----------------------------------------------------------------------------
-- CONTEXTO (cero-GAS P4): el cierre directo `me.cerrar_caja` ahora corre efectos
-- server-side y crea su pickup con id `PK-VENTAS-<caja>` (wh.crear_pickup_desde_ventas).
-- El mirror GAS `CIERRE_CAJA` crea el suyo con id `PCK-CC-<caja>` (wh.crear_pickup_cierre_caja).
-- Claves DISTINTAS → el `on conflict (id_pickup)` NO dedupea entre sí → si ambos corren
-- para la misma caja, el almacén ve DOS pickups de reposición (doble pedido).
--
-- FIX: cross-guard en el lado del mirror (que corre SEGUNDO, en background tras el éxito
-- de la RPC). Si el pickup de la RPC (`PK-VENTAS-<caja>`) ya existe, NO crear el `PCK-CC`.
-- Cierra la ventana durante el rollout del frontend (quitar el mirror) y queda como defensa
-- permanente (p. ej. el auto-cierre de arranque que también dispara CIERRE_CAJA).
-- Idempotente, sin cambios de firma. Solo agrega el guard; el resto es idéntico a la versión viva.
-- ============================================================================

create or replace function wh.crear_pickup_cierre_caja(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_caja text := nullif(btrim(coalesce(p->>'id_caja',p->>'idCaja','')),'');
  v_zona text; v_cajero text; v_idp text; v_items jsonb; v_n int; v_n2 int; v_now timestamptz:=now();
begin
  if me.jwt_app() not in ('','MOS','mosExpress','warehouseMos') then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_caja is null then return jsonb_build_object('ok',false,'error','Requiere id_caja'); end if;
  select coalesce(nullif(btrim(zona_id),''),''), coalesce(vendedor,'') into v_zona,v_cajero from me.cajas where id_caja=v_caja;
  if not found then return jsonb_build_object('ok',false,'error','Caja no encontrada'); end if;
  v_idp := 'PCK-CC-'||v_caja;
  perform 1 from wh.pickups where id_pickup=v_idp;
  if found then return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_idp,'dedup',true)); end if;
  -- [318 cross-guard] el cierre directo (RPC) ya creó su pickup PK-VENTAS-<caja> → NO duplicar.
  perform 1 from wh.pickups where id_pickup='PK-VENTAS-'||v_caja;
  if found then return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup','PK-VENTAS-'||v_caja,'dedup',true,'crossGuard',true)); end if;
  with src as (
    select vd.cod_barras cb, wh._num(vd.cantidad::text) cant, vd.unidad_medida um
    from me.ventas v join me.ventas_detalle vd on vd.id_venta=v.id_venta
    where v.id_caja=v_caja and upper(coalesce(v.forma_pago,''))<>'ANULADO'
  ),
  det as (select cv.sku_base sku, cv.cant from src cross join lateral mos._venta_canonico(src.cb, src.cant, src.um) cv where src.cant>0),
  agg as (select sku, sum(cant) sol from det where coalesce(sku,'')<>'' group by sku having sum(cant)>0)
  select coalesce(jsonb_agg(jsonb_build_object(
    'skuBase',a.sku,
    'nombre',coalesce(
       (select pp.descripcion from mos.productos pp
         where pp.sku_base=a.sku and coalesce(nullif(pp.factor_conversion,0),1)=1 and pp.estado is not false
         order by (pp.codigo_producto_base is null) desc, length(pp.descripcion) desc limit 1),
       (select pp.descripcion from mos.productos pp where pp.sku_base=a.sku order by (pp.codigo_producto_base is null) desc limit 1),
       a.sku),
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
end;$function$;
