-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 190_riz_cron_ventana_4iso_y_diario.sql
-- 🎯 (A) Unifica la ventana de ROTACIÓN del cron de materialización a "4 semanas ISO CERRADAS" de la SEMANA ENTRANTE
--        (v_lunes_next-28 .. v_lunes_next-1) → coherente con el on-the-fly del ticket (188) para esas mismas fechas.
--    (B) Programa un RECOMPUTE DIARIO del snapshot me.zona_esperado (02:07 Lima) para que NUNCA quede viejo a media
--        semana: si el cron del lunes falla, el diario lo pone al día. Idempotente (la ventana 4-ISO es estable
--        lun-dom; solo cambia el lunes). SOLO LECTURA / diagnóstico (escribe únicamente snapshot + cola de tickets).
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 ANTES: el cron materializaba la cola de la semana entrante usando una ventana de rotación rolling-28 anclada a
--    HOY (v_desde = hoy-28 .. v_hoy). Como el cron corre lunes 04:00 UTC = domingo 23:00 Lima (semana vieja aún),
--    "hoy" era el domingo de la semana que terminaba → universo NO 4-ISO-cerrado y distinto del on-the-fly de las
--    fechas materializadas (que usan v_lunes(fecha)-28 .. v_lunes(fecha)-1).
-- ✅ AHORA: rotación = v_lunes_next-28 .. v_lunes_next-1 (las 4 semanas ISO cerradas relativas a la semana entrante).
--    Igual técnica que me._riz_picos / panel 189 / ticket 188. La PARTICIÓN (7 días desde v_lunes_next, ceil(total/7))
--    NO cambia. ALMACEN sigue por despacho SALIDA_ZONA; ZONA sigue por _riz_ventas_base (live) — solo cambia la ventana.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION me.cron_riz_recompute_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  -- lunes de la semana ENTRANTE (date_trunc('week') = lunes ISO de la semana en curso; + 7 = próximo lunes).
  v_lunes_next date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) + 7;
  -- ⭐ ventana de ROTACIÓN = 4 semanas ISO CERRADAS de la SEMANA ENTRANTE (coincide con el on-the-fly del ticket 188
  --   para las fechas que aquí se materializan): v_lunes_next-28 .. v_lunes_next-1.
  v_desde      date := v_lunes_next - 28;   -- inicio 4-ISO-cerrada (entrante)
  v_hasta      date := v_lunes_next - 1;    -- fin 4-ISO-cerrada (entrante)
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
      from me._riz_ventas_base(v_desde, v_hasta) b
      where not v_es_almacen and b.zona_id = r_z.zona
      group by b.sku_base
    ),
    -- ⭐ tipos = SALIDA_ZONA + SALIDA_JEFATURA, idéntico al objetivo del panel (desp_obj) y al on-the-fly del ticket
    --   (188) → universo materializado == panel ROTADO == ticket on-the-fly en ALMACEN.
    rot_desp as (
      select cs.sku as sku_base, sum(coalesce(d.cant_recibida,0)) as rotacion
      from wh.guia_detalle d
      join wh.guias g on g.id_guia = d.id_guia
      join cb_sku cs on cs.cb = upper(btrim(d.cod_producto))
      where v_es_almacen
        and g.tipo in ('SALIDA_ZONA','SALIDA_JEFATURA')
        and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
        and g.fecha is not null
        and (g.fecha at time zone 'America/Lima')::date >= v_desde
        and (g.fecha at time zone 'America/Lima')::date <= v_hasta
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
    -- enumeración para la PARTICIÓN: orden DETERMINISTA e independiente del stock (rotacion desc, sku_base).
    -- 'faltan' NO entra aquí (stock-volátil) → debe coincidir con el on_the_fly (174) para que un día materializado
    -- y uno calculado al vuelo asignen el MISMO día a cada sku. 'faltan' solo prioriza la presentación dentro del día.
    enum as (
      select f.*,
             (row_number() over (order by f.rotacion desc, f.sku_base) - 1) as idx
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
$function$;

-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- (B) GUARDIA DE FRESCURA: recompute DIARIO del snapshot me.zona_esperado.
--     La ventana 4-ISO es estable lun-dom (idempotente; solo avanza el lunes). Recomputar a diario garantiza que
--     si el cron del lunes falla, el snapshot se ponga al día el mismo día y NUNCA quede viejo a media semana.
--     Solo escribe me.zona_esperado (filas 'auto'; NO pisa overrides manuales). No toca stock/dinero/sync.
--     pg_cron corre en GMT (UTC). 02:07 Lima (UTC-5) = 07:07 UTC. Minuto :07 (no :00) para no chocar con la franja.
--     Idempotente: unschedule por nombre antes de schedule (no duplica si se reaplica la migración).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- limpiar job previo por nombre (si existe) para idempotencia
    perform cron.unschedule(jobid) from cron.job where jobname = 'riz-recompute-diario';
    -- programar diario 07:07 UTC = 02:07 America/Lima
    perform cron.schedule('riz-recompute-diario', '7 7 * * *', 'select me.zona_esperado_recompute(''{}''::jsonb);');
  end if;
end;
$cron$;
