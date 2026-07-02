-- ============================================================================
-- 319_pickup_parity_lock.sql — 500x R2: cierra el race cross-txn del cross-guard +
-- alinea el set de items de AMBAS funciones de pickup del cierre.
-- ----------------------------------------------------------------------------
-- Hallazgos 500x (revisión adversarial):
--  HIGH (race): el cross-guard de 318 hace un `perform 1 ... where id_pickup=<otro>` que bajo
--    READ COMMITTED NO ve la fila del otro pickup si aún no commiteó. El mirror GAS
--    (crear_pickup_cierre_caja) corría SIN advisory lock → podía crear PCK-CC mientras la RPC
--    aún no commiteaba su PK-VENTAS → doble pickup. FIX: AMBAS toman pg_advisory_xact_lock(
--    'cerrarcaja:'||caja) al entrar. Re-entrante en la RPC (que ya lo tiene); en el mirror BLOQUEA
--    hasta que la RPC commitee/libere → el cross-guard ya ve la fila commiteada. Cierra el race.
--  MEDIUM (items parity): PK-VENTAS (crear_pickup_desde_ventas) resolvía `cant * factor_conversion`
--    (crudo), mientras el DESCUENTO de stock (me.zona_descontar_venta) y PCK-CC usan
--    mos._venta_canonico (regla granel KGM/NIU). Para granel divergían → la reposición sugerida no
--    cuadraba con lo descontado. FIX: crear_pickup_desde_ventas ahora lee me.ventas_detalle por
--    idCaja con mos._venta_canonico, IDÉNTICO a crear_pickup_cierre_caja (misma cantidad canónica).
--  ANULADO: PCK-CC usaba `<> 'ANULADO'` (exacto → incluía ANULADO_CONVERSION en la reposición).
--    FIX: ambas usan `not like 'ANULADO%'` (excluye toda anulación).
-- Resultado: los dos caminos producen EXACTAMENTE el mismo set de items; imposible doble pickup.
-- Idempotente por caja (self-dedup id + cross-guard). Sin cambio de firma.
-- ============================================================================

-- ── RPC (cierre directo): PK-VENTAS ──────────────────────────────────────────
create or replace function wh.crear_pickup_desde_ventas(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcaja text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_zona   text := coalesce(p->>'idZona','');
  v_cajero text := coalesce(p->>'cajero','');
  v_pk     text; v_built jsonb; v_n int;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idcaja is null then return jsonb_build_object('ok',false,'error','idCaja requerido'); end if;
  -- [319] serializa con el mirror (PCK-CC) y con el cierre → cross-guard sin race.
  perform pg_advisory_xact_lock(hashtext('cerrarcaja:'||v_idcaja));
  v_pk := 'PK-VENTAS-' || v_idcaja;
  if exists (select 1 from wh.pickups where id_pickup = v_pk) then
    return jsonb_build_object('ok',true,'dedup',true,'data',jsonb_build_object('idPickup',v_pk));
  end if;
  -- [319 cross-guard recíproco] si el mirror ya creó su PCK-CC, no duplicar.
  if exists (select 1 from wh.pickups where id_pickup = 'PCK-CC-'||v_idcaja) then
    return jsonb_build_object('ok',true,'dedup',true,'crossGuard',true,'data',jsonb_build_object('idPickup','PCK-CC-'||v_idcaja));
  end if;

  -- items canónicos desde ventas_detalle (IDÉNTICO a crear_pickup_cierre_caja / al descuento de stock)
  with src as (
    select vd.cod_barras cb, wh._num(vd.cantidad::text) cant, vd.unidad_medida um
    from me.ventas v join me.ventas_detalle vd on vd.id_venta=v.id_venta
    where v.id_caja=v_idcaja and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
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
  ) order by a.sku),'[]'::jsonb) into v_built from agg a;

  v_n := jsonb_array_length(coalesce(v_built,'[]'::jsonb));
  if v_n = 0 then
    return jsonb_build_object('ok',true,'vacio',true,'data',jsonb_build_object('idPickup',v_pk,'items',0));
  end if;
  insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
  values (v_pk, 'ME_CIERRE_CAJA', 'PENDIENTE', v_built, v_zona, 'Auto cierre de caja · '||v_idcaja, coalesce(nullif(v_cajero,''),'ME_AUTO'), now(), now())
  on conflict (id_pickup) do nothing;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_pk,'items',v_n));
end;
$fn$;
revoke all on function wh.crear_pickup_desde_ventas(jsonb) from public;
grant execute on function wh.crear_pickup_desde_ventas(jsonb) to authenticated;

-- ── Mirror GAS: PCK-CC (+ advisory lock que cierra el race + ANULADO prefijo) ────────────────
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
  -- [319] MISMO lock que la RPC → si la RPC aún no commiteó su PK-VENTAS, BLOQUEA aquí hasta que
  -- lo haga; luego el cross-guard de abajo lo ve commiteado y no duplica. Cierra el race cross-txn.
  perform pg_advisory_xact_lock(hashtext('cerrarcaja:'||v_caja));
  select coalesce(nullif(btrim(zona_id),''),''), coalesce(vendedor,'') into v_zona,v_cajero from me.cajas where id_caja=v_caja;
  if not found then return jsonb_build_object('ok',false,'error','Caja no encontrada'); end if;
  v_idp := 'PCK-CC-'||v_caja;
  perform 1 from wh.pickups where id_pickup=v_idp;
  if found then return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_idp,'dedup',true)); end if;
  -- [318/319 cross-guard] el cierre directo (RPC) ya creó su PK-VENTAS-<caja> → NO duplicar.
  perform 1 from wh.pickups where id_pickup='PK-VENTAS-'||v_caja;
  if found then return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup','PK-VENTAS-'||v_caja,'dedup',true,'crossGuard',true)); end if;
  with src as (
    select vd.cod_barras cb, wh._num(vd.cantidad::text) cant, vd.unidad_medida um
    from me.ventas v join me.ventas_detalle vd on vd.id_venta=v.id_venta
    where v.id_caja=v_caja and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'   -- [319] prefijo (excluye ANULADO_CONVERSION)
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
revoke all on function wh.crear_pickup_cierre_caja(jsonb) from public;
grant execute on function wh.crear_pickup_cierre_caja(jsonb) to authenticated, service_role;
