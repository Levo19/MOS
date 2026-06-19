-- 184_riz_ticket_dia_default_fecha_hoy.sql — [RIZ · FIX impresión "Ticket del día" vacío]
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- BUG (app de DINERO, pero este path es SOLO-LECTURA): el "Ticket del día" del módulo Zona/RIZ se imprimía
-- VACÍO ("(sin productos para hoy)"). CAUSA RAÍZ: la Edge supabase/functions/riz-print llama
-- rpcMos('zona_ticket_dia', { zona, ...(fecha?{fecha}:{}) }) — solo manda `fecha` si el caller la incluye, y el
-- flujo de impresión del frontend NO la setea. La RPC me.zona_ticket_dia EXIGÍA `fecha`: sin ella devolvía
-- {ok:false, error:'Requiere zona y fecha (YYYY-MM-DD)'} → la Edge no recibía data → imprimía vacío.
--
-- FIX (principal, robusto): cuando `p->>'fecha'` viene NULL/vacío, usar por DEFECTO HOY en zona horaria
-- America/Lima. Un "ticket del día" sin fecha = hoy. Se mantiene el error SOLO si falta `zona`. CON fecha
-- explícita el comportamiento es IDÉNTICO (no rompe el caso bueno). Resto del cuerpo SIN cambios.
--
-- Además, por simetría, me.zona_lista_compras recibe el MISMO criterio: si falta `semana`, default a la
-- semana ISO actual (IYYY-"W"IW en TZ Lima). Igual: con `semana` explícita el comportamiento es idéntico.
-- NOTA: zona_lista_compras NO es solo-lectura (hace upsert en me.zona_compra_externa), pero defaultear a la
-- semana actual es exactamente lo que el flujo de impresión espera (lista de compras de ESTA semana).
--
-- mos.zona_ticket_dia / mos.zona_lista_compras (wrappers, supabase/132) son pass-through puros (return me.<>(p))
-- → NO requieren cambios. La Edge riz-print tampoco requiere redeploy (ya llama sin fecha → ahora responde hoy).
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

-- ══ 1) me.zona_ticket_dia: fecha NULL/vacía → HOY (America/Lima) ══════════════════════════════════════════════
create or replace function me.zona_ticket_dia(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  -- ⭐ FIX: sin fecha (NULL/vacía) ⇒ HOY en TZ America/Lima. Un "ticket del día" sin fecha = hoy.
  v_fecha date := coalesce(nullif(btrim(coalesce(p->>'fecha','')), '')::date,
                           (now() at time zone 'America/Lima')::date);
  v_data  jsonb;
  v_mat    jsonb;
  v_es_almacen boolean;
  v_desde date;
  v_lunes date;    -- lunes ISO de la semana del p.fecha (ancla estable de la partición de 7 días)
  v_dow   int;     -- día de la semana del p.fecha en convención LUN=0 … DOM=6
  v_desde_obj date;   -- inicio ventana objetivo despacho (4 sem ISO cerradas) — anclado a v_lunes (igual que panel 179)
  v_hasta_obj date;   -- fin ventana objetivo despacho (domingo de la última sem cerrada)
  v_umbral numeric := 0.10;  -- mismo umbral de tendencia que 179/_riz_picos
  v_colchon numeric := 0.20; -- mismo colchón (×1.2) que 179/137/128
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- ⭐ FIX: solo exigimos `zona`. La fecha ya tiene default = hoy (TZ Lima) arriba.
  if v_zona = '' then
    return jsonb_build_object('ok',false,'error','Requiere zona');
  end if;

  -- ¿lote materializado por el cron (Capa 3)? Si lo hay, se devuelve tal cual (idempotente, respeta IMPRESO/REVISADO).
  select coalesce(jsonb_agg(jsonb_build_object(
           'loteDia', t.lote_dia, 'estado', t.estado, 'items', t.items) order by t.lote_dia), '[]'::jsonb)
    into v_mat
  from me.zona_ticket_dia t where upper(btrim(t.zona_id)) = v_zona and t.fecha = v_fecha;

  if v_mat is not null and jsonb_array_length(v_mat) > 0 then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'zona', v_zona, 'fecha', to_char(v_fecha,'YYYY-MM-DD'), 'origen', 'materializado', 'lotes', v_mat
    )) || mos._frescura_sombra();
  end if;

  -- ── ON-THE-FLY = la TANDA DE ROTACIÓN del día solicitado (misma definición que el cron 138) ─────────────────
  v_es_almacen := (v_zona = 'ALMACEN');
  v_lunes      := (date_trunc('week', v_fecha::timestamp)::date);  -- lunes ISO de la semana del p.fecha (ancla estable)
  v_desde      := v_lunes - 28;                                    -- ventana de rotación: 4 semanas (anclada al lunes)
  v_dow        := (extract(isodow from v_fecha)::int - 1);         -- isodow: LUN=1..DOM=7 → 0..6
  v_desde_obj  := v_lunes - 28;   -- 4 sem antes del lunes de la semana del p.fecha
  v_hasta_obj  := v_lunes - 1;    -- domingo de la última semana cerrada

  with
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
  sku_desc as (
    select distinct on (sku) sku, descripcion from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord, p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  rot_ventas as (
    select b.sku_base, sum(b.unidades_base) as rotacion
    from me._riz_ventas_base(v_desde, v_lunes) b
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
      and (g.fecha at time zone 'America/Lima')::date <= v_lunes
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
    having sum(rotacion) > 0   -- solo con rotación (excluye rotación-cero, igual que el cron)
  ),
  desp_base as (
    select cs.sku as sku_base,
           (g.fecha at time zone 'America/Lima')::date as dia,
           coalesce(d.cant_recibida,0) as u
    from wh.guia_detalle d
    join wh.guias g on g.id_guia = d.id_guia
    join cb_sku cs on cs.cb = upper(btrim(d.cod_producto))
    where v_es_almacen
      and g.tipo in ('SALIDA_ZONA','SALIDA_JEFATURA')
      and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
      and g.fecha is not null
      and upper(coalesce(d.observacion,'')) <> 'ANULADO'
      and coalesce(d.cant_recibida,0) > 0
      and (g.fecha at time zone 'America/Lima')::date >= v_desde_obj
      and (g.fecha at time zone 'America/Lima')::date <= v_hasta_obj
  ),
  desp_dia as (
    select sku_base, dia, sum(u) as u_dia
    from desp_base
    where dia >= v_desde_obj and dia <= v_hasta_obj
    group by sku_base, dia
  ),
  desp_sem as (
    select sku_base, to_char(dia,'IYYY"-W"IW') as sem, max(u_dia) as pico_sem, sum(u_dia) as vol_sem
    from desp_dia group by sku_base, to_char(dia,'IYYY"-W"IW')
  ),
  desp_semanas as (
    select w, to_char((v_desde_obj + (w*7))::date,'IYYY"-W"IW') as lbl
    from generate_series(0,3) as w
  ),
  desp_skus as (select distinct sku_base from desp_sem),
  desp_serie as (
    select s.sku_base, sl.w, coalesce(ds.pico_sem,0) as pico
    from desp_skus s
    cross join desp_semanas sl
    left join desp_sem ds on ds.sku_base = s.sku_base and ds.sem = sl.lbl
  ),
  desp_agg as (
    select se.sku_base,
           array_agg(se.pico order by se.w) as picos,
           (array_agg(se.pico order by se.w))[4] as pico_ultima,
           avg(se.pico) as media_pico,
           case when var_pop(se.w) > 0 then regr_slope(se.pico, se.w) else 0 end as pendiente
    from desp_serie se group by se.sku_base
  ),
  desp_vol as (
    select sku_base, sum(vol_sem) as volumen from desp_sem group by sku_base
  ),
  desp_med as (
    select percentile_cont(0.5) within group (order by volumen) as mediana from desp_vol where volumen > 0
  ),
  desp_obj as (
    select a.sku_base,
           coalesce(a.picos, '{}') as picos,
           coalesce(a.pico_ultima,0) as pico_ultima,
           coalesce(v.volumen,0) as volumen,
           ceil(coalesce(a.pico_ultima,0) * (1 + v_colchon))::numeric as esperado,
           case
             when coalesce(v.volumen,0) <= 0 then 'NULA'
             when a.media_pico > 0 and (a.pendiente / a.media_pico) >=  v_umbral then 'CRECIENTE'
             when a.media_pico > 0 and (a.pendiente / a.media_pico) <= -v_umbral then 'DECRECIENTE'
             else 'ESTABLE'
           end as tendencia
    from desp_agg a
    left join desp_vol v on v.sku_base = a.sku_base
  ),
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.picos
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  stock_zona as (
    select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) cant
    from me.stock_zonas z join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
    where upper(btrim(z.zona_id)) = v_zona group by cs.sku
  ),
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) cant
    from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto)) group by cs.sku
  ),
  filas as (
    select r.sku_base,
           coalesce(sd.descripcion, r.sku_base) as nombre,
           r.rotacion,
           coalesce(sz.cant,0) as stock_zona,
           (case when v_es_almacen then coalesce(dob.esperado,0) else coalesce(e.esperado,0) end) as esperada,
           greatest(0,
             (case when v_es_almacen then coalesce(dob.esperado,0) else coalesce(e.esperado,0) end)
             - greatest((case when v_es_almacen then coalesce(sa.cant,0) else coalesce(sz.cant,0) end), 0)) as faltan,
           coalesce(sa.cant,0) as stock_almacen,
           (case when v_es_almacen then coalesce(dob.tendencia,'NULA') else coalesce(e.tendencia,'NULA') end) as tendencia,
           (case when v_es_almacen then coalesce(to_jsonb(dob.picos),'[]'::jsonb) else coalesce(e.picos,'[]'::jsonb) end) as picos
    from rot r
    left join sku_desc   sd on sd.sku = r.sku_base
    left join esp        e  on e.sku_base = r.sku_base
    left join desp_obj   dob on dob.sku_base = r.sku_base
    left join stock_zona sz on sz.sku_base = r.sku_base
    left join stock_alm  sa on sa.sku_base = r.sku_base
  ),
  tot as ( select count(*)::int as n from filas ),
  enum as (
    select f.*,
           (row_number() over (order by f.rotacion desc, f.sku_base) - 1) as idx
    from filas f
  ),
  asignado as (
    select e.*,
           least((e.idx / greatest(ceil((select n from tot)::numeric / 7)::int, 1))::int, 6) as dia
    from enum e
  ),
  tanda as ( select * from asignado where dia = v_dow )
  select jsonb_build_object(
    'zona', v_zona, 'fecha', to_char(v_fecha,'YYYY-MM-DD'), 'origen', 'on_the_fly',
    'lotes', jsonb_build_array(jsonb_build_object('loteDia', 1, 'estado', 'PENDIENTE',
      'items', coalesce(jsonb_agg(jsonb_build_object(
        'skuBase', t.sku_base,
        'nombre', t.nombre,
        'stockZona', t.stock_zona,
        'esperada', t.esperada,
        'faltan', t.faltan,
        'stockAlmacen', t.stock_almacen,
        'tendencia', t.tendencia,
        'picos', t.picos,
        'rotacion', t.rotacion
      ) order by t.rotacion desc, t.faltan desc), '[]'::jsonb)))
  ) into v_data from tanda t;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$;


-- ══ 2) me.zona_lista_compras: semana NULL/vacía → semana ISO actual (TZ Lima) ════════════════════════════════
create or replace function me.zona_lista_compras(p jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_zona       text := upper(btrim(coalesce(p->>'zona','')));
  -- ⭐ FIX: sin semana (NULL/vacía) ⇒ semana ISO actual en TZ America/Lima (IYYY-"W"IW, == to_char Postgres).
  v_semana     text := coalesce(nullif(btrim(coalesce(p->>'semana','')), ''),
                                 to_char((now() at time zone 'America/Lima')::date, 'IYYY"-W"IW'));
  v_hoy        date := (now() at time zone 'America/Lima')::date;
  v_desde      date := ((now() at time zone 'America/Lima')::date - 28);   -- periodo de rotación: 4 semanas (28 días)
  v_es_almacen boolean := (v_zona = 'ALMACEN');
  v_data       jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- ⭐ FIX: solo exigimos `zona`. La semana ya tiene default = semana ISO actual (TZ Lima) arriba.
  if v_zona = '' then
    return jsonb_build_object('ok',false,'error','Requiere zona');
  end if;

  with
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
  sku_meta as (
    select distinct on (sku) sku, descripcion, unidad from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
             coalesce(nullif(btrim(p2.unidad),''),'') as unidad,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord, p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
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
  stock_zona as (
    select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) cant
    from me.stock_zonas z join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
    where upper(btrim(z.zona_id)) = v_zona group by cs.sku
  ),
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) cant
    from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto)) group by cs.sku
  ),
  esp as (
    select e.sku_base, e.esperado, e.tendencia from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
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
  externos as (
    select c.*,
           case c.tendencia
             when 'CRECIENTE'   then 0
             when 'ESTABLE'     then 1
             when 'DECRECIENTE' then 2
             else 3
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
    where ce.estado = 'PENDIENTE'
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
$function$;
