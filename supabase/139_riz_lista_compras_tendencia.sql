-- 139_riz_lista_compras_tendencia.sql — [RIZ · CAPA 2 · LISTA DE COMPRAS: orden por TENDENCIA DE SUBIDA + shape PRO]
-- Módulo de Reposición Inteligente por Zona (RIZ). RE-DEFINE me.zona_lista_compras (última versión = 129) + wrapper mos.*.
--
-- ⚠️ INERTE igual que 129: la RPC tiene grant pero el módulo RIZ del frontend está gated OFF (flag mos_zona_modulo).
--    Este archivo NO toca flags/sync/frontend/GAS/version/sw/api.js/app.js. Solo CREATE OR REPLACE de la función
--    me.zona_lista_compras + el wrapper mos.zona_lista_compras. Patrón intacto: security definer · search_path='' ·
--    gate mos._claim_ok() · grants revoke public + service_role,authenticated · lectura concatena || mos._frescura_sombra().
--
-- ═══ EL CAMBIO PEDIDO POR EL DUEÑO ═══════════════════════════════════════════════════════════════════════════════
--   ANTES (129): externos con brecha>0 que almacén NO cubre, cantidad = ceil(brecha − stockAlmacen), ordenado por
--   cantidad desc. shape item = {skuBase, descripcion, cantidad}.
--
--   AHORA:
--     · Solo productos CON ROTACIÓN de la zona (los que vendieron/despacharon en 28d — NO los rotación-cero). Misma
--       definición de "rota" que me.zona_panel (136/137): ventas para zonas, despacho SALIDA_ZONA para almacén.
--     · ORDEN: primero los de tendencia CRECIENTE (subida — lo que realmente importa al dueño); luego ESTABLE; al
--       final DECRECIENTE (y NULA al fondo). Dentro de cada grupo, por `comprar` desc.
--     · `comprar` = ceil(max(0, esperado − stockZona − stockAlmacen)) — lo que falta DESPUÉS de usar el stock de la
--       zona Y el del almacén. Ejemplo del dueño: esperado 21, almacén 11, zona 0 → comprar 10. ✔
--     · shape item = {skuBase, descripcion, comprar, esperado, stockAlmacen, tendencia, unidad}.
--   Se MANTIENE el envoltorio {ok, data:{zona, semana, items, totalItems, unidades}} || _frescura. Sigue
--   materializando me.zona_compra_externa (idempotente por zona+semana+sku; cantidad = comprar). NO construye costo
--   (DECISIÓN CERRADA #5: el costo lo registra la guía de ingreso ME, no RIZ).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_lista_compras(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona       text := upper(btrim(coalesce(p->>'zona','')));
  v_semana     text := nullif(btrim(coalesce(p->>'semana','')), '');
  v_hoy        date := (now() at time zone 'America/Lima')::date;
  v_desde      date := ((now() at time zone 'America/Lima')::date - 28);   -- periodo de rotación: 4 semanas (28 días)
  v_es_almacen boolean := (v_zona = 'ALMACEN');
  v_data       jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_semana is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y semana (IYYY-Www)');
  end if;

  with
  -- mapa cod_barra → skuBase (base+equivalentes, SIN presentaciones — regla en piedra de WH). Igual a 136/137.
  cb_sku as (
    select distinct on (cb) cb, sku from (
      select upper(btrim(p2.codigo_barra)) cb, coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, 0 ord
        from mos.productos p2
        where nullif(btrim(p2.codigo_barra),'') is not null
          and coalesce(p2.factor_conversion,1) = 1
          and coalesce(p2.tipo_producto::text, 'CANONICO') <> 'PRESENTACION'
      union all
      select upper(btrim(ev.codigo_barra)), ev.sku_base, 1
        from mos.equivalencias ev
        where coalesce(ev.activo,true) and nullif(btrim(ev.codigo_barra),'') is not null and nullif(btrim(ev.sku_base),'') is not null
    ) t order by cb, ord
  ),
  -- descripción + unidad del canónico por skuBase.
  sku_meta as (
    select distinct on (sku) sku, descripcion, unidad from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
             coalesce(nullif(btrim(p2.unidad),''),'') as unidad,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord, p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  -- ROTACIÓN del periodo (28d) por skuBase, según la zona (ventas para zonas; despacho SALIDA_ZONA para almacén).
  rot_ventas as (
    select b.sku_base, sum(b.unidades_base) as rotacion
    from me._riz_ventas_base(v_desde, v_hoy) b
    where not v_es_almacen and b.zona_id = v_zona
    group by b.sku_base
  ),
  rot_desp as (
    select cs.sku as sku_base, sum(coalesce(d.cant_recibida,0)) as rotacion
    from wh.guia_detalle d
    join wh.guias g on g.id_guia = d.id_guia
    join cb_sku cs on cs.cb = upper(btrim(d.cod_producto))
    where v_es_almacen
      and g.tipo = 'SALIDA_ZONA'
      and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
      and g.fecha is not null
      and (g.fecha at time zone 'America/Lima')::date >= v_desde
      and (g.fecha at time zone 'America/Lima')::date <= v_hoy
      and upper(coalesce(d.observacion,'')) <> 'ANULADO'
      and coalesce(d.cant_recibida,0) > 0
    group by cs.sku
  ),
  rot as (
    select sku_base, sum(rotacion) as rotacion
    from (select sku_base, rotacion from rot_ventas
          union all
          select sku_base, rotacion from rot_desp) u
    group by sku_base
    having sum(rotacion) > 0   -- ⭐ SOLO con rotación (excluye rotación-cero)
  ),
  -- stock de la zona por skuBase (base+equivalentes en me.stock_zonas).
  stock_zona as (
    select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) cant
    from me.stock_zonas z join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
    where upper(btrim(z.zona_id)) = v_zona group by cs.sku
  ),
  -- stock de almacén por skuBase (base+equivalentes en wh.stock).
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) cant
    from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto)) group by cs.sku
  ),
  -- esperado/tendencia materializados de la zona.
  esp as (
    select e.sku_base, e.esperado, e.tendencia from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  -- comprar = ceil(max(0, esperado − stockZona − stockAlmacen)). Solo se compra lo que falta tras usar zona Y almacén.
  -- El stock negativo de zona se trata como 0 (no infla la compra ni la reduce hacia abajo): greatest(stock,0).
  candidatos as (
    select r.sku_base,
           coalesce(sm.descripcion, r.sku_base) as descripcion,
           coalesce(sm.unidad, '') as unidad,
           coalesce(e.esperado, 0) as esperado,
           coalesce(sz.cant, 0) as stock_zona,
           coalesce(sa.cant, 0) as stock_almacen,
           coalesce(e.tendencia, 'NULA') as tendencia,
           ceil(greatest(0, coalesce(e.esperado,0)
                            - greatest(coalesce(sz.cant,0),0)
                            - greatest(coalesce(sa.cant,0),0)))::numeric as comprar
    from rot r
    left join sku_meta   sm on sm.sku = r.sku_base
    left join esp        e  on e.sku_base = r.sku_base
    left join stock_zona sz on sz.sku_base = r.sku_base
    left join stock_alm  sa on sa.sku_base = r.sku_base
  ),
  -- solo lo que hay que comprar (>0). Orden: tendencia (CRECIENTE→ESTABLE→DECRECIENTE→NULA), luego comprar desc.
  externos as (
    select c.*,
           case c.tendencia
             when 'CRECIENTE'   then 0
             when 'ESTABLE'     then 1
             when 'DECRECIENTE' then 2
             else 3                                    -- NULA / cualquier otra → al fondo
           end as orden_tend
    from candidatos c
    where c.comprar > 0
  ),
  up as (
    insert into me.zona_compra_externa as ce (zona_id, semana, sku_base, descripcion, cantidad, estado, creado_ts)
    select v_zona, v_semana, x.sku_base, x.descripcion, x.comprar, 'PENDIENTE', now()
    from externos x
    on conflict (zona_id, semana, sku_base) do update set
      descripcion = excluded.descripcion,
      cantidad    = excluded.cantidad
    where ce.estado = 'PENDIENTE'                       -- no pisar compras ya resueltas
    returning sku_base
  )
  select jsonb_build_object(
    'zona', v_zona, 'semana', v_semana,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'skuBase',      x.sku_base,
        'descripcion',  x.descripcion,
        'comprar',      x.comprar,
        'esperado',     x.esperado,
        'stockAlmacen', x.stock_almacen,
        'tendencia',    x.tendencia,
        'unidad',       x.unidad
      ) order by x.orden_tend, x.comprar desc, x.sku_base)
      from externos x), '[]'::jsonb),
    'totalItems', (select count(*) from externos),
    'unidades',   coalesce((select sum(comprar) from externos), 0),
    'upserted',   (select count(*) from up)
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_lista_compras(jsonb) from public;
grant execute on function me.zona_lista_compras(jsonb) to service_role, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- WRAPPER mos.zona_lista_compras — la firma jsonb NO cambia (pass-through puro). Reafirmado idempotente para que un
-- deploy de SOLO este archivo deje el wrapper apuntando a la versión nueva.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.zona_lista_compras(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  return me.zona_lista_compras(p);
end;
$fn$;
revoke all on function mos.zona_lista_compras(jsonb) from public;
grant execute on function mos.zona_lista_compras(jsonb) to service_role, authenticated;
