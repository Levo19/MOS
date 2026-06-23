-- 231_wh_pickup_desde_ventas.sql — Pickup ME→WH al cierre de caja, 100% Supabase (erradica el enviarPickupAWH de
-- GAS). Mapea cada cod vendido → skuBase CANÓNICO × factor (regla WH en piedra: WH solo canónicos factor=1; una
-- venta de presentación factor F → F unidades del canónico) usando mos.productos + mos.equivalencias, agrupa, y
-- crea un wh.pickups (fuente='ME_CIERRE_CAJA', estado='PENDIENTE'). Idempotente por id_caja (re-cierre NO duplica).
-- Réplica fiel de gas/Guias.gs:enviarPickupAWH (codAFila/canonicoPorSku/equivalentesPorSku + factor).
create or replace function wh.crear_pickup_desde_ventas(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_idcaja text := nullif(btrim(coalesce(p->>'idCaja','')),'');
  v_zona   text := coalesce(p->>'idZona','');
  v_cajero text := coalesce(p->>'cajero','');
  v_items  jsonb := case when jsonb_typeof(p->'items')='array' then p->'items' else '[]'::jsonb end;
  v_pk     text; v_built jsonb;
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idcaja is null then return jsonb_build_object('ok',false,'error','idCaja requerido'); end if;
  v_pk := 'PK-VENTAS-' || v_idcaja;                          -- idempotente por caja
  if exists (select 1 from wh.pickups where id_pickup = v_pk) then
    return jsonb_build_object('ok',true,'dedup',true,'data',jsonb_build_object('idPickup',v_pk));
  end if;

  with entrada as (
    select btrim(coalesce(e->>'codBarra', e->>'cod_barras','')) cod,
           coalesce(mos._numn(e->>'cantidad'),0) cant
    from jsonb_array_elements(v_items) e
  ),
  ent2 as (select cod, cant from entrada where cod <> '' and cant > 0),
  resuelto as (   -- cod → (sku, factor): productos(codigo_barra) → productos(id_producto) → equivalencias → fallback
    select en.cod, en.cant,
      coalesce(pr.sku_base, pi.sku_base, eq.sku_base, en.cod) as sku,
      coalesce(pr.factor_conversion, pi.factor_conversion, 1)::numeric as factor
    from ent2 en
    left join lateral (select sku_base, factor_conversion from mos.productos
        where codigo_barra = en.cod and coalesce(estado::text,'1') <> '0' order by factor_conversion limit 1) pr on true
    left join lateral (select sku_base, factor_conversion from mos.productos
        where id_producto = en.cod limit 1) pi on true
    left join lateral (select sku_base from mos.equivalencias
        where codigo_barra = en.cod and coalesce(activo,true) limit 1) eq on true
  ),
  agrupado as (
    select sku, sum(cant * coalesce(factor,1)) as solicitado from resuelto group by sku
  ),
  items as (
    select coalesce(jsonb_agg(jsonb_build_object(
        'skuBase', a.sku,
        'nombre', coalesce(nullif(can.descripcion,''), a.sku),
        'solicitado', a.solicitado,
        'despachado', 0,
        'codigosOriginales', (
          select coalesce(jsonb_agg(distinct z.cod), '[]'::jsonb) from (
            select can.codigo_barra cod where coalesce(can.codigo_barra,'') <> ''
            union
            select codigo_barra from mos.equivalencias where sku_base = a.sku and coalesce(activo,true) and coalesce(codigo_barra,'') <> ''
          ) z
        )
      ) order by a.sku), '[]'::jsonb) as arr
    from agrupado a
    left join lateral (select codigo_barra, descripcion from mos.productos
        where sku_base = a.sku and factor_conversion = 1 and coalesce(estado::text,'1') <> '0'
        order by length(coalesce(descripcion,'')) desc limit 1) can on true
    where a.solicitado > 0
  )
  select arr into v_built from items;

  if v_built is null or jsonb_array_length(v_built) = 0 then
    return jsonb_build_object('ok',true,'vacio',true,'data',jsonb_build_object('idPickup',v_pk,'items',0));
  end if;

  insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
  values (v_pk, 'ME_CIERRE_CAJA', 'PENDIENTE', v_built, v_zona, 'Auto cierre de caja · '||v_idcaja, v_cajero, now(), now())
  on conflict (id_pickup) do nothing;

  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPickup',v_pk,'items',jsonb_array_length(v_built)));
end;
$fn$;

revoke all on function wh.crear_pickup_desde_ventas(jsonb) from public;
grant execute on function wh.crear_pickup_desde_ventas(jsonb) to authenticated;
