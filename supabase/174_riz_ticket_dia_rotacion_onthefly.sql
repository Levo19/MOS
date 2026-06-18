-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 174_riz_ticket_dia_rotacion_onthefly.sql — TICKET DEL DÍA RIZ: el día SIN materializar trae su TANDA de rotación
-- ────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- 🔴 SÍNTOMA: el "Ticket del día" salía VACÍO / "sin productos para hoy, verificar stock real…".
--    En prod (2026-06-18, jueves): el cron `riz-recompute-semanal` ya materializó la cola de la semana ENTRANTE
--    (2026-06-22..28, ~31/día), pero HOY (06-18) NO está en esa ventana. me.zona_ticket_dia caía al fallback
--    on_the_fly, que devolvía SOLO el top-10 por brecha del esperado materializado → el admin veía ~10 (o, si la
--    UI exige tanda completa, lo leía como "vacío"). El dueño quiere ~40-50 productos REALES para el CONTEO FÍSICO.
--
-- 🩺 CAUSA: dos definiciones distintas de "ticket del día":
--    · cron (138): cola = TODOS los skus CON ROTACIÓN (28d) de la zona, repartidos en 7 días LUN..DOM
--      (lote = ceil(total/7) ≈ 33/día para ZONA-02 con 231 skus). Es la tanda que toca CONTAR ese día.
--    · on_the_fly (RPC vieja): top-10 por brecha. Universo y tamaño totalmente distintos → vacío/escaso.
--
-- ✅ FIX (SOLO LECTURA — no toca escritura/stock/dinero/sync/flags): me.zona_ticket_dia se REESCRIBE para que el
--    fallback on_the_fly use la MISMA definición que el cron, pero calculada PARA EL DÍA SOLICITADO:
--      (1) Universo = skus con rotación>0 (28d) de la zona (ventas para zonas; despacho SALIDA_ZONA para ALMACEN),
--          idéntico a 138 (mismo cb_sku, misma fuente, misma exclusión de rotación-cero).
--      (2) Se ordena por rotación desc (más movido primero), lote_sz = ceil(total/7), día = idx/lote_sz (0..6).
--      (3) Se devuelve la TANDA cuyo día == weekday del p.fecha solicitado (LUN=0 … DOM=6).
--    Resultado: cualquier día (incluido hoy, sin esperar al cron) trae su bloque de ~33 productos a contar.
--    La rama "materializado" (cron) NO cambia: si hay lote materializado para esa fecha, manda ese (idempotente).
--    El esperado materializado solo ENRIQUECE (esperada/brecha/tendencia/picos via LEFT JOIN) — la ROTACIÓN manda,
--    así que aunque me.zona_esperado esté vacío el ticket igual lista los productos a contar.
--
-- IDEMPOTENTE (create or replace). NO cambia firma. Wrapper mos.zona_ticket_dia(jsonb) intacto (delega aquí).
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
  v_fecha date := nullif(btrim(coalesce(p->>'fecha','')), '')::date;
  v_data  jsonb;
  v_mat    jsonb;
  v_es_almacen boolean;
  v_desde date;
  v_dow   int;     -- día de la semana del p.fecha en convención LUN=0 … DOM=6
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' or v_fecha is null then
    return jsonb_build_object('ok',false,'error','Requiere zona y fecha (YYYY-MM-DD)');
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
  v_desde      := v_fecha - 28;                                    -- ventana de rotación: 4 semanas
  v_dow        := (extract(isodow from v_fecha)::int - 1);         -- isodow: LUN=1..DOM=7 → 0..6

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
  -- ROTACIÓN del periodo (28d) por skuBase, según la zona.
  rot_ventas as (
    select b.sku_base, sum(b.unidades_base) as rotacion
    from me._riz_ventas_base(v_desde, v_fecha) b
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
      and (g.fecha at time zone 'America/Lima')::date <= v_fecha
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
  tot as ( select count(*)::int as n from filas ),
  enum as (
    select f.*,
           (row_number() over (order by f.rotacion desc, f.faltan desc, f.sku_base) - 1) as idx
    from filas f
  ),
  -- día asignado a cada sku = idx / lote_sz (capado a 6). Nos quedamos con los del weekday solicitado.
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
