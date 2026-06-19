-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 188_riz_ticket_dia_ventana_4iso_unificada.sql
-- 🎯 UNIFICACIÓN VENTANA · me.zona_ticket_dia → "4 semanas ISO CERRADAS" (lunes_actual-28 .. lunes_actual-1),
--    IDÉNTICA a me._riz_picos / me.zona_panel / el gráfico "¿Por qué Esperado?". App de DINERO · SOLO LECTURA.
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 PROBLEMA (verificado en prod, 2026-06-19, ZONA-02):
--    El ticket usaba una ventana de rotación/universo "rolling-28 anclada al LUNES" que llegaba HASTA el lunes
--    inclusive (v_desde = v_lunes-28 .. <= v_lunes). Eso son 29 días e INCLUYE el lunes de la semana en curso →
--    el universo del ticket (193 skus) NO coincidía con el ROTADO del panel (177 skus, que sale de
--    me.zona_esperado.volumen_4sem, computado por me._riz_picos sobre la ventana 4-ISO-CERRADA lunes-28..lunes-1).
--    Resultado: el filtro "Día" (que consume este RPC) mostraba la INTERSECCIÓN con el panel, no un calce exacto.
--
-- ✅ FIX (additivo, no rompe shape ni firma; wrapper mos.zona_ticket_dia pass-through intacto):
--    (1) VENTANA DE ROTACIÓN/UNIVERSO → 4-ISO-CERRADA: el límite superior pasa de `v_lunes` a `v_lunes - 1`
--        (= v_hasta_obj). Ahora la rotación cubre EXACTAMENTE lunes-28 .. lunes-1 = los mismos 28 días / 4 semanas
--        ISO cerradas que me._riz_picos. Esto vale para ZONA (rot_ventas) y para ALMACEN (rot_desp).
--    (2) ZONA · MISMA FUENTE que el panel: el universo de ZONA ya no se deriva de _riz_ventas_base al vuelo, sino
--        de me.zona_esperado (volumen_4sem > 0) — EXACTAMENTE el mismo set y la misma columna que define "ROTADO"
--        en me.zona_panel. Así el universo del ticket == ROTADO del panel sku-por-sku (no solo por ventana, también
--        por FUENTE), y queda inmune a que el snapshot esté a medio recomputar. La `rotacion` informativa del item
--        (orden de presentación) sigue saliendo de volumen_4sem (proxy de volumen de ventas 4-ISO), que es la misma
--        magnitud que ordena el panel. ALMACEN NO cambia de fuente (sigue wh.guia_detalle SALIDA_ZONA), solo recorta
--        la ventana a 4-ISO; su esperada/tendencia/picos siguen replicando 179 vía desp_obj.
--    (3) La PARTICIÓN diaria NO cambia: sigue anclada al lunes, idx/ceil(total/7), día = isodow-1, orden determinista
--        (rotacion desc, sku_base). Solo cambia QUÉ universo se reparte. Coincide con el cron de materialización.
--
-- NOTA money-safe: SOLO LECTURA. No toca stock, escritura, dinero, sync ni flags. IDEMPOTENTE (create or replace).
--   Cuando p.fecha cae en la semana en curso (caso normal del ticket de hoy), v_lunes == lunes-actual → la ventana
--   del ticket == la ventana del panel/_riz_picos → universo idéntico. Para fechas de semanas pasadas, v_lunes se
--   ancla al lunes de esa semana (estable lun-dom).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

create or replace function me.zona_ticket_dia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  -- ⭐ sin fecha (NULL/vacía) ⇒ HOY en TZ America/Lima. Un "ticket del día" sin fecha = hoy.
  v_fecha date := coalesce(nullif(btrim(coalesce(p->>'fecha','')), '')::date,
                           (now() at time zone 'America/Lima')::date);
  v_data  jsonb;
  v_mat    jsonb;
  v_es_almacen boolean;
  v_lunes date;       -- lunes ISO de la semana del p.fecha (ancla estable de la partición de 7 días)
  v_dow   int;        -- día de la semana del p.fecha en convención LUN=0 … DOM=6
  v_desde_obj date;   -- inicio ventana 4-ISO-CERRADA — anclada a v_lunes (idéntica a me._riz_picos / panel 179)
  v_hasta_obj date;   -- fin ventana 4-ISO-CERRADA (domingo de la última semana cerrada) = v_lunes - 1
  v_umbral numeric := 0.10;  -- mismo umbral de tendencia que 179/_riz_picos
  v_colchon numeric := 0.20; -- mismo colchón (×1.2) que 179/137/128
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
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

  -- ── ON-THE-FLY = la TANDA DE ROTACIÓN del día solicitado ─────────────────────────────────────────────────────
  --   ⭐ VENTANA UNIFICADA 4-ISO-CERRADA: la rotación/universo cubre v_lunes-28 .. v_lunes-1 (NO incluye la semana
  --      en curso) — la MISMA ventana que me._riz_picos / me.zona_panel. La partición (7 días anclados al lunes)
  --      reparte exactamente ese universo → cada día es disjunto y ∪días == universo == ROTADO del panel.
  v_es_almacen := (v_zona = 'ALMACEN');
  v_lunes      := (date_trunc('week', v_fecha::timestamp)::date);  -- lunes ISO de la semana del p.fecha (ancla estable)
  v_dow        := (extract(isodow from v_fecha)::int - 1);         -- isodow: LUN=1..DOM=7 → 0..6
  v_desde_obj  := v_lunes - 28;   -- 4 sem antes del lunes de la semana del p.fecha
  v_hasta_obj  := v_lunes - 1;    -- domingo de la última semana cerrada (límite SUPERIOR de la rotación)

  with
  -- mapa cod_barra → skuBase (base + equivalentes activos, SIN presentaciones — regla WH), igual que 138.
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
  -- ── ROTACIÓN / UNIVERSO por skuBase (ventana 4-ISO-CERRADA: v_desde_obj .. v_hasta_obj) ──────────────────────
  --   ZONA  : MISMA FUENTE que el ROTADO del panel → me.zona_esperado.volumen_4sem (>0). Mismo set, misma columna.
  --   ALMACEN: despacho SALIDA_ZONA en la ventana 4-ISO (igual técnica que el cron, solo recorta la semana en curso).
  rot_ventas as (
    select e.sku_base, coalesce(e.volumen_4sem,0) as rotacion
    from me.zona_esperado e
    where not v_es_almacen and upper(btrim(e.zona_id)) = v_zona and coalesce(e.volumen_4sem,0) > 0
  ),
  -- ⭐ tipos de guía = SALIDA_ZONA + SALIDA_JEFATURA, IDÉNTICO al objetivo del panel (desp_obj de 179/189). Antes el
  --   ticket usaba solo SALIDA_ZONA → 5 skus que rotaron solo por SALIDA_JEFATURA salían como ROTADO en el panel pero
  --   NO en el universo del ticket. Igualar el set de tipos hace que ticket-universo == panel-ROTADO exacto en ALMACEN.
  rot_desp as (
    select cs.sku as sku_base, sum(coalesce(d.cant_recibida,0)) as rotacion
    from wh.guia_detalle d
    join wh.guias g on g.id_guia = d.id_guia
    join cb_sku cs on cs.cb = upper(btrim(d.cod_producto))
    where v_es_almacen
      and g.tipo in ('SALIDA_ZONA','SALIDA_JEFATURA')
      and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
      and g.fecha is not null
      and (g.fecha at time zone 'America/Lima')::date >= v_desde_obj
      and (g.fecha at time zone 'America/Lima')::date <= v_hasta_obj
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
  -- ── OBJETIVO DE DESPACHO para ALMACEN (RÉPLICA EXACTA de 179, anclada a v_lunes) ───────────────────────────
  --    Solo se materializa cuando v_es_almacen. Para zonas estas CTEs quedan vacías y los CASE no las usan.
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
           -- esperada: ALMACEN ⇒ objetivo de despacho (igual que panel 179) ; zonas ⇒ esperado materializado (ventas).
           (case when v_es_almacen then coalesce(dob.esperado,0) else coalesce(e.esperado,0) end) as esperada,
           -- faltan: ALMACEN ⇒ esperada − stockAlmacen(wh.stock) ; zonas ⇒ esperada − stockZona(me.stock_zonas).
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
  -- enumeración para la PARTICIÓN del día: orden DETERMINISTA e independiente del stock (rotacion desc, sku_base).
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
$fn$;
revoke all on function me.zona_ticket_dia(jsonb) from public;
grant execute on function me.zona_ticket_dia(jsonb) to service_role, authenticated;
