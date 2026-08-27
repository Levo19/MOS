-- 958_zona_por_activar.sql — [RIZ · 5º GRUPO: "POR ACTIVAR" (huecos de surtido)]
-- Productos del CATÁLOGO MAESTRO (mos.productos canónicos activos) que NO existen aún en una zona/almacén
-- (sin fila en stock_zonas / wh.stock, sin ventas, sin esperado) pero SÍ tienen relevancia (los maneja otra
-- zona o hay stock en almacén). Son invisibles a los 4 cuadrantes porque no tienen historial. Este 5º grupo
-- los saca a la luz para que cada admin (Almacén / Zona1 / Zona2) les ponga stock inicial.
--
-- DINÁMICO: el universo se recalcula en vivo (catálogo − lo que ya está en la zona). En cuanto se activa el
-- producto (ajuste / ingreso / venta) obtiene fila → entra al universo del panel → cae solo en uno de los 4
-- cuadrantes → SALE de "Por activar" automáticamente. Sin estado que mantener.
--
-- CURABLE: un producto que NUNCA se venderá en esa zona se puede DESCARTAR (me.zona_por_activar_descartado),
-- reversible, para que no ensucie la lista por siempre.
--
-- Patrón RIZ: security definer · search_path='' · gate mos._claim_ok() · shape {ok:true,data:...} · wrapper mos.*
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── Tabla de descartes (curación por zona) ─────────────────────────────────────────────────────────────────
create table if not exists me.zona_por_activar_descartado (
  zona_id       text        not null,
  sku_base      text        not null,
  usuario       text,
  descartado_ts timestamptz not null default now(),
  primary key (zona_id, sku_base)
);
grant select, insert, delete on me.zona_por_activar_descartado to service_role, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_por_activar(p jsonb { zona (req), limite? (def 400), incluirDescartados? })
--   Devuelve data.items[] = { skuBase, descripcion, codBarra, unidad, stockAlmacen, rotaOtras, enOtraZona,
--     enAlmacen, prioridad, descartado } ordenado por prioridad desc, rotaOtras desc, descripcion.
--   ZONA normal: candidatos = canónicos activos SIN presencia en esta zona (stock/ventas/esperado) pero CON
--     presencia en otra zona real o stock en almacén.
--   ALMACEN: candidatos = canónicos que alguna zona maneja (stock/ventas) pero SIN fila en wh.stock (hueco compra).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_por_activar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text    := upper(btrim(coalesce(p->>'zona','')));
  v_lim    int     := least(greatest(coalesce((p->>'limite')::int, 400), 1), 2000);
  v_incd   boolean := coalesce((p->>'incluirDescartados')::boolean, false);
  v_hoy    date    := (now() at time zone 'America/Lima')::date;
  v_desde  date    := ((now() at time zone 'America/Lima')::date - 28);
  v_es_alm boolean := (v_zona = 'ALMACEN');
  v_data   jsonb;
  v_ndesc  int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  select count(*) into v_ndesc from me.zona_por_activar_descartado where upper(btrim(zona_id)) = v_zona;

  with
  -- cb → skuBase (canónico factor=1 + equivalentes activos; SIN presentaciones) — igual que el panel.
  cb_sku as (
    select distinct on (cb) cb, sku from (
      select upper(btrim(p2.codigo_barra)) cb, coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, 0 ord
        from mos.productos p2
        where nullif(btrim(p2.codigo_barra),'') is not null
          and coalesce(p2.factor_conversion,1) = 1
          and coalesce(p2.tipo_producto::text,'CANONICO') <> 'PRESENTACION'
      union all
      select upper(btrim(e.codigo_barra)), e.sku_base, 1
        from mos.equivalencias e
        where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t order by cb, ord
  ),
  -- catálogo canónico activo: 1 fila representativa por skuBase (el canónico: sin base y factor 1).
  cat as (
    select distinct on (sku) sku, cb, descripcion, unidad from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku,
             upper(btrim(p2.codigo_barra)) cb,
             p2.descripcion,
             coalesce(nullif(btrim(p2.unidad),''),'') unidad,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord,
             p2.id_producto
        from mos.productos p2
        where coalesce(p2.estado,true) = true
          and coalesce(p2.factor_conversion,1) = 1
          and coalesce(p2.tipo_producto::text,'CANONICO') <> 'PRESENTACION'
          and nullif(btrim(p2.codigo_barra),'') is not null
    ) t order by sku, ord, id_producto
  ),
  -- presencia por skuBase en cada zona real (stock_zonas; excluye MOCK/FALLBACK).
  sz as (
    select cs.sku,
           bool_or(upper(btrim(z.zona_id)) = v_zona) as aqui,
           bool_or(upper(btrim(z.zona_id)) <> v_zona) as otra
    from me.stock_zonas z
    join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
    where upper(btrim(z.zona_id)) not like '%MOCK%' and upper(btrim(z.zona_id)) not like '%FALLBACK%'
    group by cs.sku
  ),
  -- ventas base 4 semanas por skuBase y zona.
  vb as (
    select b.sku_base sku,
           sum(b.unidades_base) filter (where upper(btrim(b.zona_id)) = v_zona)  as u_aqui,
           sum(b.unidades_base) filter (where upper(btrim(b.zona_id)) <> v_zona)  as u_otra,
           sum(b.unidades_base)                                                  as u_all
    from me._riz_ventas_base(v_desde, v_hoy) b
    group by b.sku_base
  ),
  -- esperado materializado por skuBase en esta zona.
  esp as (
    select distinct sku_base sku from me.zona_esperado where upper(btrim(zona_id)) = v_zona
  ),
  -- stock en almacén por skuBase (wh.stock).
  alm as (
    select cs.sku, sum(coalesce(s.cantidad_disponible,0)) qty, count(*) filas
    from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto))
    group by cs.sku
  ),
  -- descartes de esta zona.
  dz as (
    select sku_base sku from me.zona_por_activar_descartado where upper(btrim(zona_id)) = v_zona
  ),
  cand as (
    select
      cat.sku, cat.descripcion, cat.cb, cat.unidad,
      coalesce(alm.qty,0)   as stock_alm,
      coalesce(alm.filas,0) as alm_filas,
      coalesce(sz.aqui,false) as sz_aqui,
      coalesce(sz.otra,false) as sz_otra,
      coalesce(vb.u_aqui,0) as v_aqui,
      coalesce(vb.u_otra,0) as v_otra,
      coalesce(vb.u_all,0)  as v_all,
      (esp.sku is not null) as esp_aqui,
      (dz.sku is not null)  as descartado
    from cat
    left join sz  on sz.sku  = cat.sku
    left join vb  on vb.sku  = cat.sku
    left join esp on esp.sku = cat.sku
    left join alm on alm.sku = cat.sku
    left join dz  on dz.sku  = cat.sku
  ),
  filtrado as (
    select
      c.sku, c.descripcion, c.cb, c.unidad,
      case when v_es_alm then 0 else c.stock_alm end as stock_almacen,
      case when v_es_alm then c.v_all else c.v_otra end as rota_otras,
      case when v_es_alm then false else c.sz_otra end  as en_otra_zona,
      case when v_es_alm then false else (c.stock_alm > 0) end as en_almacen,
      c.descartado,
      -- prioridad
      case
        when v_es_alm then (case when c.v_all > 0 then 2 else 1 end)
        when c.stock_alm > 0 and c.v_otra > 0 then 3    -- activable YA + demanda comprobada
        when c.stock_alm > 0 then 2                     -- activable YA
        else 1                                          -- solo existe en otra zona
      end as prioridad
    from cand c
    where (v_incd or not c.descartado)
      and (
        -- ── ZONA normal: sin presencia aquí, con relevancia en otra zona o almacén
        ( not v_es_alm
          and not c.sz_aqui and c.v_aqui = 0 and not c.esp_aqui
          and ( c.sz_otra or c.v_otra > 0 or c.stock_alm > 0 ) )
        or
        -- ── ALMACEN: lo maneja alguna zona (stock/ventas) pero sin fila en wh.stock
        ( v_es_alm
          and c.alm_filas = 0
          and ( c.sz_otra or c.sz_aqui or c.v_all > 0 ) )
      )
  )
  select jsonb_build_object(
    'zona', v_zona,
    'total', (select count(*) from filtrado),
    'nDescartados', v_ndesc,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'skuBase', f.sku, 'descripcion', f.descripcion, 'codBarra', f.cb, 'unidad', f.unidad,
        'stockAlmacen', f.stock_almacen, 'rotaOtras', f.rota_otras,
        'enOtraZona', f.en_otra_zona, 'enAlmacen', f.en_almacen,
        'prioridad', f.prioridad, 'descartado', f.descartado
      ) order by f.prioridad desc, f.rota_otras desc, f.descripcion)
      from (select * from filtrado order by prioridad desc, rota_otras desc, descripcion limit v_lim) f
    ), '[]'::jsonb)
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_por_activar(jsonb) from public;
grant execute on function me.zona_por_activar(jsonb) to service_role, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.zona_por_activar_descartar(p jsonb { zona (req), skuBase (req), usuario, revertir? })
--   Marca (o revierte con revertir=true) un producto como "no aplica en esta zona".
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_por_activar_descartar(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona text    := upper(btrim(coalesce(p->>'zona','')));
  v_sku  text    := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_user text    := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_rev  boolean := coalesce((p->>'revertir')::boolean, false);
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_sku is null then return jsonb_build_object('ok',false,'error','Requiere zona y skuBase'); end if;

  if v_rev then
    delete from me.zona_por_activar_descartado where upper(btrim(zona_id)) = v_zona and sku_base = v_sku;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('revertido', true, 'skuBase', v_sku));
  end if;

  insert into me.zona_por_activar_descartado (zona_id, sku_base, usuario)
  values (v_zona, v_sku, v_user)
  on conflict (zona_id, sku_base) do nothing;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('descartado', true, 'skuBase', v_sku));
end;
$fn$;
revoke all on function me.zona_por_activar_descartar(jsonb) from public;
grant execute on function me.zona_por_activar_descartar(jsonb) to service_role, authenticated;


-- ── Wrappers mos.* (pass-through con gate) ─────────────────────────────────────────────────────────────────
create or replace function mos.zona_por_activar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_por_activar(p);
end; $fn$;
revoke all on function mos.zona_por_activar(jsonb) from public;
grant execute on function mos.zona_por_activar(jsonb) to service_role, authenticated;

create or replace function mos.zona_por_activar_descartar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  return me.zona_por_activar_descartar(p);
end; $fn$;
revoke all on function mos.zona_por_activar_descartar(jsonb) from public;
grant execute on function mos.zona_por_activar_descartar(jsonb) to service_role, authenticated;

select 'zona_por_activar listo' ok;
