-- 138_riz_cola_7dias.sql — [RIZ · CAPA 3 · COLA DIARIA = TODA LA ROTACIÓN, 7 DÍAS SIN DESCANSO] — backward-compatible
-- Módulo de Reposición Inteligente por Zona (RIZ). RE-DEFINE me.cron_riz_recompute_semanal (última versión = 130).
--
-- ⚠️ INERTE igual que 130: el job corre (active=true) pero su efecto es inerte para el negocio (solo materializa
--    me.zona_esperado / me.zona_ticket_dia, que HOY nadie lee — el módulo RIZ del frontend está gated OFF). Este
--    archivo NO toca flags/sync/frontend/GAS/version/sw/api.js/app.js ni ninguna RPC de dinero. Solo CREATE OR
--    REPLACE de la función del cron. Patrón intacto: security definer · search_path='' · grants service_role.
--
-- ═══ EL CAMBIO PEDIDO POR EL DUEÑO ═══════════════════════════════════════════════════════════════════════════════
--   ANTES (130): la cola diaria repartía SOLO los productos "relevantes" (brecha>0 O tendencia accionable) del
--   esperado materializado, en lotes de ~10/día sobre LUN..SÁB (6 días, domingo descansa) → ~60 productos/semana,
--   ordenados por brecha.
--
--   AHORA: la cola diaria = TODOS los productos CON ROTACIÓN de la zona (los que VENDIERON o se DESPACHARON en las
--   4 semanas), EXCLUYENDO los rotación-cero (stock muerto: esos NO entran al ticket diario). Idea del dueño: "que
--   en toda la semana el admin prepare/ajuste/verifique TODOS los productos que se venden o se vendieron en las 4
--   semanas". Se reparte en 7 DÍAS (LUN..DOM, sin descanso). tamaño de lote = ceil(total_rotacion / 7) (~31/día
--   para ZONA-02 con 213 → 7×31=217 ≥ 213). El ÚLTIMO día lleva los que falten (puede ser uno menos).
--
--   FUENTE DE ROTACIÓN (idéntica a me.zona_panel 136/137 — una sola definición de "rota"):
--     · ZONA normal (ZONA-01, ZONA-02…): me._riz_ventas_base(28d) de ESA zona. unidades_base>0 ⇒ rota.
--     · ALMACEN (id_zona='ALMACEN'):    despacho SALIDA_ZONA (wh.guia_detalle de guías CERRADA/AUTOCERRADA,
--       líneas no ANULADO, cant_recibida>0) mapeado a skuBase vía el set base+equivalentes (sin presentaciones).
--   Verificado en prod (2026-06-17): ZONA-02 → 213 skus con rotación (28d). El ticket recorre TODO el catálogo
--   vivo de la zona en una semana.
--
-- ═══ IDEMPOTENCIA (diseño 4.1, igual que 130) ════════════════════════════════════════════════════════════════════
--   upsert por (zona_id, fecha, lote_dia) en me.zona_ticket_dia. Re-correr el mismo domingo regenera los mismos
--   lotes de los mismos días (LUN..DOM de la semana entrante) sin duplicar. Solo pisa filas en estado 'PENDIENTE'
--   (NO toca un ticket ya 'IMPRESO'/'REVISADO' por el admin). lote_dia=1 por día (un solo lote por día: el día ES
--   el lote — cada día trae su bloque de ~31 productos).
--
--   me.cron_riz_lista_compras() NO se toca aquí (sigue en 130, idempotente, apunta a me.zona_lista_compras de 139).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create extension if not exists pg_cron;
create table if not exists mos.cron_log (
  id        bigint generated always as identity primary key,
  ts        timestamptz not null default now(),
  job       text        not null,
  ok        boolean,
  resultado jsonb
);


-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- me.cron_riz_recompute_semanal()
--   (1) Recompute del esperado de TODAS las zonas → me.zona_esperado_recompute('{}') (128).
--   (2) Materializa la COLA diaria: TODOS los skus con ROTACIÓN de cada zona activa, repartidos en 7 días LUN..DOM
--       de la semana ENTRANTE, lote = ceil(total/7), el último día lleva el resto. Upsert en me.zona_ticket_dia.
--   Sin args. SECURITY DEFINER + search_path='' (corre como owner; me.jwt_app()=NULL → mos._claim_ok() pasa service_role).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.cron_riz_recompute_semanal()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_hoy        date := (now() at time zone 'America/Lima')::date;
  v_desde      date := ((now() at time zone 'America/Lima')::date - 28);   -- periodo de rotación: 4 semanas (28 días)
  -- lunes de la semana ENTRANTE (date_trunc('week') = lunes ISO de la semana en curso; + 7 = próximo lunes).
  v_lunes_next date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) + 7;
  v_rec        jsonb;
  v_total_cola int  := 0;
  r_z          record;
  v_es_almacen boolean;
  v_n_rota     int;
  v_lote_sz    int;
  v_filas      int;
begin
  -- (1) RECOMPUTE del esperado de todas las zonas (idempotente; solo escribe me.zona_esperado).
  v_rec := me.zona_esperado_recompute('{}'::jsonb);

  -- (2) COLA diaria por zona — 7 días LUN..DOM de la semana entrante; lote = ceil(total_rotacion / 7).
  for r_z in
    select upper(btrim(z.id_zona)) as zona
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado,true) = true
    order by 1
  loop
    v_es_almacen := (r_z.zona = 'ALMACEN');

    -- Universo de la zona = skus CON ROTACIÓN (los rotación-cero NO entran al ticket diario). Mismo set y misma
    -- definición de "rota" que me.zona_panel (136/137). Se enumera ordenado por rotación desc (lo más movido
    -- primero), se calcula el tamaño de lote = ceil(total/7), y se asigna día = idx/lote (0..6) → LUN..DOM.
    with
    -- mapa cod_barra → skuBase para el despacho de ALMACEN (base+equivalentes, SIN presentaciones — regla WH).
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
    -- descripción canónica por skuBase (para el item del ticket).
    sku_desc as (
      select distinct on (sku) sku, descripcion from (
        select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
               case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord, p2.id_producto
        from mos.productos p2
      ) t order by sku, ord, id_producto
    ),
    -- ROTACIÓN del periodo (28d) por skuBase, según la zona (ventas para zonas; despacho SALIDA_ZONA para almacén).
    rot_ventas as (
      select b.sku_base, sum(b.unidades_base) as rotacion
      from me._riz_ventas_base(v_desde, v_hoy) b
      where not v_es_almacen and b.zona_id = r_z.zona
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
      having sum(rotacion) > 0   -- ⭐ SOLO con rotación; excluye rotación-cero (no entran al ticket diario)
    ),
    -- esperado materializado (para enriquecer el item: esperada/brecha/tendencia/picos). LEFT JOIN: rotación manda.
    esp as (
      select e.sku_base, e.esperado, e.tendencia, e.picos
      from me.zona_esperado e where upper(btrim(e.zona_id)) = r_z.zona
    ),
    -- stock de zona por skuBase (para mostrar stockZona/faltan en el ticket).
    stock_zona as (
      select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) cant
      from me.stock_zonas z join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
      where upper(btrim(z.zona_id)) = r_z.zona group by cs.sku
    ),
    -- stock de almacén por skuBase (para el ticket — "pedir a almacén" si cubre).
    stock_alm as (
      select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) cant
      from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto)) group by cs.sku
    ),
    filas as (
      select r.sku_base,
             coalesce(sd.descripcion, r.sku_base) as nombre,
             r.rotacion,
             coalesce(sz.cant,0) as stock_zona,
             coalesce(e.esperado,0) as esperada,
             greatest(0, coalesce(e.esperado,0) - greatest(coalesce(sz.cant,0),0)) as faltan,
             coalesce(sa.cant,0) as stock_almacen,
             coalesce(e.tendencia,'NULA') as tendencia,
             coalesce(e.picos,'[]'::jsonb) as picos
      from rot r
      left join sku_desc   sd on sd.sku = r.sku_base
      left join esp        e  on e.sku_base = r.sku_base
      left join stock_zona sz on sz.sku_base = r.sku_base
      left join stock_alm  sa on sa.sku_base = r.sku_base
    ),
    -- total de skus con rotación y tamaño de lote = ceil(total/7) (mínimo 1). Día = idx/lote (0..6) → LUN..DOM.
    tot as ( select count(*)::int as n from filas ),
    enum as (
      select f.*,
             (row_number() over (order by f.rotacion desc, f.faltan desc, f.sku_base) - 1) as idx
      from filas f
    ),
    asignado as (
      select e.*,
             greatest(ceil((select n from tot)::numeric / 7)::int, 1) as lote_sz,
             v_lunes_next + least((e.idx / greatest(ceil((select n from tot)::numeric / 7)::int, 1))::int, 6) as fecha
      from enum e
    ),
    agrupado as (
      select a.fecha, 1 as lote_dia,
             jsonb_agg(jsonb_build_object(
               'skuBase', a.sku_base, 'nombre', a.nombre,
               'stockZona', a.stock_zona, 'esperada', a.esperada, 'faltan', a.faltan,
               'tendencia', a.tendencia, 'picos', a.picos, 'stockAlmacen', a.stock_almacen,
               'rotacion', a.rotacion
             ) order by a.rotacion desc, a.faltan desc) as items,
             count(*) as n
      from asignado a
      group by a.fecha
    ),
    up as (
      insert into me.zona_ticket_dia as t (zona_id, fecha, lote_dia, items, estado, creado_ts)
      select r_z.zona, g.fecha, g.lote_dia, g.items, 'PENDIENTE', now()
      from agrupado g
      on conflict (zona_id, fecha, lote_dia) do update set
        items     = excluded.items,
        creado_ts = now()
      where t.estado = 'PENDIENTE'   -- NO pisar tickets ya impresos/revisados por el admin
      returning 1
    )
    select coalesce(sum(1),0) into v_filas from up;
    v_total_cola := v_total_cola + coalesce(v_filas,0);
  end loop;

  insert into mos.cron_log(job, ok, resultado)
  values ('riz_recompute_semanal', coalesce((v_rec->>'ok')::boolean,false),
          jsonb_build_object('lunesEntrante', to_char(v_lunes_next,'YYYY-MM-DD'),
                             'recompute', v_rec, 'colaFilas', v_total_cola, 'modo', 'rotacion_7dias'));

  return jsonb_build_object('ok', true, 'recompute', v_rec, 'colaFilas', v_total_cola,
                            'lunesEntrante', to_char(v_lunes_next,'YYYY-MM-DD'), 'modo', 'rotacion_7dias');
exception when others then
  insert into mos.cron_log(job, ok, resultado)
  values ('riz_recompute_semanal', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok', false, 'error', 'excepcion', 'detalle', SQLERRM);
end;
$fn$;
revoke all on function me.cron_riz_recompute_semanal() from public, anon, authenticated;
grant execute on function me.cron_riz_recompute_semanal() to service_role;
