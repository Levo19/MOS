-- 128_riz_rpcs_analiticas.sql — [RIZ · CAPA 2 · RPCs ANALÍTICAS: tendencia / esperado / panel]
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md (Parte 1.2-1.3, 3.x).
--
-- ⚠️ INERTE: estas RPCs existen y tienen grant, pero NADIE las llama (no hay wiring en js/api.js ni cron). MOS
--    opera 100% por GAS. Este archivo NO toca flags/sync/frontend/GAS. Solo lee (tendencia/panel) y materializa
--    [A] (recompute). El recompute es idempotente (upsert) y solo escribe me.zona_esperado (tabla nueva, inerte).
--
-- ── PATRÓN (idéntico a las 56 RPCs en prod) ─────────────────────────────────────────────────────────────────
--   security definer · set search_path='' · gate mos._claim_ok() (app='MOS' o service_role/GAS) ·
--   shape { ok:true, data:... } camelCase · lecturas concatenan || mos._frescura_sombra() (señal _fresh).
--   FUENTE DE ROTACIÓN: me._riz_ventas_base (fundación 126), unidades BASE por factor. NO usa data de WH
--   (DECISIÓN RONDA 2 #7: la rotación es la de MI zona). De wh.* solo se toma STOCK (en zona_panel).
--
-- ── PARÁMETROS POR ZONA (mos.zonas.politica_json) ───────────────────────────────────────────────────────────
--   colchon_pct       (default 0.20) — colchón sobre el pico para la esperada.
--   semanas_tendencia (default 4)     — N semanas ISO cerradas para la serie de picos.
--   umbral_tendencia  (default 0.10)  — banda relativa (|pendiente|/pico_medio) para CRECIENTE/DECRECIENTE/ESTABLE.
--   Si politica_json no trae la clave → default. (R2/R3 del diseño: nada hardcodeado.)
--
-- ── SEMANAS ISO CERRADAS ────────────────────────────────────────────────────────────────────────────────────
--   "Cerrada" = semana ISO estrictamente anterior a la semana ISO actual (la semana en curso NO cuenta, está
--   incompleta). Ventana = las N semanas cerradas más recientes (lun..dom). Misma TÉCNICA de pivote ISO que
--   wh.rotacion_semanal (11_fase1d_wh_rotacion.sql) pero sobre la fundación de ventas ME por zona.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
-- HELPER interno: me._riz_picos(p_zona, p_semanas) → TABLA por skuBase con la serie de picos de las N semanas
-- ISO CERRADAS de UNA zona + agregados (volumen, pendiente, tendencia, bcg vs mediana de la zona).
-- Lo consumen tendencia_zona, zona_esperado_recompute y zona_panel (una sola definición de la matemática).
-- p_umbral / colchón se aplican fuera (cada RPC lee politica_json). Aquí solo la pendiente y etiqueta base.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function me._riz_picos(p_zona text, p_semanas int, p_umbral numeric)
returns table(
  sku_base text, picos numeric[], pico_ultima numeric, volumen numeric,
  pendiente numeric, tendencia text, bcg text
)
language sql
stable
security definer
set search_path = ''
as $fn$
  with
  params as (
    select upper(btrim(p_zona)) as zona,
           greatest(coalesce(p_semanas,4),1) as n,
           coalesce(p_umbral,0.10) as umbral,
           -- lunes 00:00 Lima de la semana ISO ACTUAL (la primera semana CERRADA es la anterior a este lunes)
           (date_trunc('week', (now() at time zone 'America/Lima'))::date) as lunes_actual
  ),
  ventana as (
    select p.*, (p.lunes_actual - (p.n * 7)) as desde, (p.lunes_actual - 1) as hasta from params p
  ),
  -- etiquetas de las N semanas cerradas (cronológicas, w=0 la más antigua .. n-1 la más reciente)
  semanas_lbl as (
    select w, to_char((v.desde + (w*7))::date, 'IYYY"-W"IW') as lbl
    from ventana v, generate_series(0, (select n-1 from ventana)) as w
  ),
  -- ventas base de la zona en la ventana, etiquetadas por semana ISO
  base as (
    select b.sku_base,
           to_char(b.dia, 'IYYY"-W"IW') as sem,
           b.dia,
           b.unidades_base
    from me._riz_ventas_base((select desde from ventana), (select hasta from ventana)) b
    where b.zona_id = (select zona from params)
  ),
  -- pico diario por (sku, semana) = MAX de unidades_base en los días de esa semana
  pico_sem as (
    select sku_base, sem, max(unidades_base) as pico
    from base group by sku_base, sem
  ),
  skus as (select distinct sku_base from base),
  -- serie densa: cada sku × cada semana de la ventana (faltantes → 0)
  serie as (
    select s.sku_base, sl.w, coalesce(ps.pico, 0) as pico
    from skus s
    cross join semanas_lbl sl
    left join pico_sem ps on ps.sku_base = s.sku_base and ps.sem = sl.lbl
  ),
  -- agregados por sku: array de picos ordenado, último pico, volumen total, pendiente (regresión lineal simple
  -- pico vs índice de semana), volumen total de la ventana.
  agg as (
    select
      se.sku_base,
      array_agg(se.pico order by se.w) as picos,
      (array_agg(se.pico order by se.w))[(select n from ventana)] as pico_ultima,
      sum(se.pico) as suma_picos,
      avg(se.pico) as media_pico,
      -- pendiente = covar_pop(pico, w) / var_pop(w) (regresión OLS). Si var(w)=0 (n=1) → 0.
      case when var_pop(se.w) > 0 then regr_slope(se.pico, se.w) else 0 end as pendiente
    from serie se group by se.sku_base
  ),
  -- volumen de la ventana por sku (suma de unidades base, NO de picos) = eje X de la BCG
  vol as (select sku_base, sum(unidades_base) as volumen from base group by sku_base),
  -- mediana del volumen de la zona (corte alto/bajo de la BCG, relativo a ESTA zona — RONDA 2 #9)
  med as (select percentile_cont(0.5) within group (order by volumen) as mediana from vol where volumen > 0)
  select
    a.sku_base,
    a.picos,
    coalesce(a.pico_ultima, 0) as pico_ultima,
    coalesce(v.volumen, 0) as volumen,
    round(a.pendiente::numeric, 4) as pendiente,
    -- TENDENCIA (árbol §1.3): NULA si volumen 0; si no, por pendiente normalizada vs umbral.
    case
      when coalesce(v.volumen,0) <= 0 then 'NULA'
      when a.media_pico > 0 and (a.pendiente / a.media_pico) >=  (select umbral from ventana) then 'CRECIENTE'
      when a.media_pico > 0 and (a.pendiente / a.media_pico) <= -(select umbral from ventana) then 'DECRECIENTE'
      else 'ESTABLE'
    end as tendencia,
    -- BCG (§3.10): Y = crecimiento (tendencia) · X = volumen vs MEDIANA de la zona.
    --   alto crecimiento (CRECIENTE) + alto volumen → ESTRELLA ; + bajo volumen → INTERROGANTE
    --   bajo  crecimiento (ESTABLE)  + alto volumen → VACA      ; + bajo volumen → PERRO
    --   DECRECIENTE / NULA → PERRO (caso "sacar/rematar"), independiente del volumen.
    case
      when coalesce(v.volumen,0) <= 0 then 'PERRO'
      else case
        when (a.media_pico > 0 and (a.pendiente / a.media_pico) >= (select umbral from ventana))
          then case when coalesce(v.volumen,0) >= coalesce((select mediana from med),0) then 'ESTRELLA' else 'INTERROGANTE' end
        when (a.media_pico > 0 and (a.pendiente / a.media_pico) <= -(select umbral from ventana))
          then 'PERRO'
        else case when coalesce(v.volumen,0) >= coalesce((select mediana from med),0) then 'VACA' else 'PERRO' end
      end
    end as bcg
  from agg a
  left join vol v on v.sku_base = a.sku_base;
$fn$;
revoke all on function me._riz_picos(text, int, numeric) from public;
grant execute on function me._riz_picos(text, int, numeric) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) me.tendencia_zona(p jsonb { zona (req), skuBase? (opc), semanas? (default politica/4) })
--    Por skuBase de la zona: serie de picos de las N semanas ISO cerradas + etiqueta de tendencia + BCG.
--    Shape data: { zona, semanas, umbral, items:[{skuBase, picos:[...], picoUltima, volumen, pendiente,
--                  tendencia, bcg}] }. Si skuBase viene → 1 item.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.tendencia_zona(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona text := upper(btrim(coalesce(p->>'zona','')));
  v_sku  text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_pol  jsonb;
  v_sem  int;
  v_umb  numeric;
  v_data jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  select z.politica_json into v_pol from mos.zonas z where upper(btrim(z.id_zona)) = v_zona limit 1;
  v_sem := coalesce(nullif(btrim(coalesce(p->>'semanas','')),'')::int, (v_pol->>'semanas_tendencia')::int, 4);
  if v_sem is null or v_sem < 1 then v_sem := 4; end if;
  if v_sem > 52 then v_sem := 52; end if;
  v_umb := coalesce((v_pol->>'umbral_tendencia')::numeric, 0.10);

  select jsonb_build_object(
    'zona', v_zona, 'semanas', v_sem, 'umbral', v_umb,
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'skuBase', t.sku_base,
      'picos', to_jsonb(t.picos),
      'picoUltima', t.pico_ultima,
      'volumen', t.volumen,
      'pendiente', t.pendiente,
      'tendencia', t.tendencia,
      'bcg', t.bcg
    ) order by t.volumen desc), '[]'::jsonb)
  ) into v_data
  from me._riz_picos(v_zona, v_sem, v_umb) t
  where v_sku is null or t.sku_base = v_sku;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.tendencia_zona(jsonb) from public;
grant execute on function me.tendencia_zona(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) me.zona_esperado_recompute(p jsonb { zona | null=all })
--    Materializa me.zona_esperado para cada (zona, skuBase) con ventas:
--      esperada = ceil( pico_ULTIMA_semana × (1 + colchon_zona) )   (DECISIÓN CERRADA #4: usa el pico de la
--      última semana, NO una proyección; la tendencia es solo etiqueta informativa).
--    Idempotente: upsert por (zona_id, sku_base). Solo reescribe filas de fuente='auto' (respeta overrides
--    manuales: si una fila quedó fuente='manual', NO se pisa).
--    Shape data: { zonas:[...], filas, porZona:{zona:n} }.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_esperado_recompute(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_zona_in text := nullif(upper(btrim(coalesce(p->>'zona',''))), '');
  v_zona    text;
  v_pol     jsonb;
  v_sem     int;
  v_umb     numeric;
  v_col     numeric;
  v_filas   int := 0;
  v_porzona jsonb := '{}'::jsonb;
  v_zonas   text[] := '{}';
  r_cnt     int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  for v_zona in
    select upper(btrim(z.id_zona)) from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado,true) = true
      and (v_zona_in is null or upper(btrim(z.id_zona)) = v_zona_in)
    order by 1
  loop
    select z.politica_json into v_pol from mos.zonas z where upper(btrim(z.id_zona)) = v_zona limit 1;
    v_sem := coalesce((v_pol->>'semanas_tendencia')::int, 4);
    if v_sem is null or v_sem < 1 then v_sem := 4; end if;
    v_umb := coalesce((v_pol->>'umbral_tendencia')::numeric, 0.10);
    v_col := coalesce((v_pol->>'colchon_pct')::numeric, 0.20);

    with calc as (
      select t.sku_base, t.picos, t.pico_ultima, t.volumen, t.tendencia, t.bcg,
             ceil(t.pico_ultima * (1 + v_col))::numeric as esperado
      from me._riz_picos(v_zona, v_sem, v_umb) t
    ),
    up as (
      insert into me.zona_esperado as e
        (zona_id, sku_base, esperado, pico_ultima, pico_proyectado, tendencia, bcg, picos, colchon_pct, volumen_4sem, fuente, actualizado_ts)
      select v_zona, c.sku_base, c.esperado, c.pico_ultima, c.pico_ultima, c.tendencia, c.bcg,
             to_jsonb(c.picos), v_col, c.volumen, 'auto', now()
      from calc c
      on conflict (zona_id, sku_base) do update set
        esperado        = excluded.esperado,
        pico_ultima     = excluded.pico_ultima,
        pico_proyectado = excluded.pico_proyectado,
        tendencia       = excluded.tendencia,
        bcg             = excluded.bcg,
        picos           = excluded.picos,
        colchon_pct     = excluded.colchon_pct,
        volumen_4sem    = excluded.volumen_4sem,
        actualizado_ts  = now()
      where e.fuente = 'auto'           -- NO pisar overrides manuales
      returning 1
    )
    select count(*) into r_cnt from up;
    v_filas := v_filas + r_cnt;
    v_porzona := v_porzona || jsonb_build_object(v_zona, r_cnt);
    v_zonas := array_append(v_zonas, v_zona);
  end loop;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zonas', to_jsonb(v_zonas), 'filas', v_filas, 'porZona', v_porzona));
end;
$fn$;
revoke all on function me.zona_esperado_recompute(jsonb) from public;
grant execute on function me.zona_esperado_recompute(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) me.zona_panel(p jsonb { zona (req), filtro? })  — los cards del módulo.
--    Por skuBase de la zona (universo = skus con esperado materializado ∪ skus con stock en la zona):
--      { skuBase, descripcion, stockZona, esperada, brecha=esperada−stockZona, stockAlmacen, tendencia,
--        picos[], bcg, vencimientoProximo:{fecha,dias}|null, countLotes }.
--    SOLO catálogo + ESTA zona + almacén (NUNCA stock de otras zonas — diseño Parte 0).
--    filtro (opc): 'BRECHA' (brecha>0) · 'SIN_ROTACION' (tendencia NULA) · 'CRECIENTE'/'DECRECIENTE'/'ESTABLE' ·
--                  'ESTRELLA'/'VACA'/'INTERROGANTE'/'PERRO'.
--    Perf <2s: JOINs (no subqueries correlacionadas); el cálculo pesado (picos) se LEE de me.zona_esperado ya
--    materializado por el recompute (no recalcula la tendencia en cada panel). stockZona/stockAlmacen sí se
--    agregan en vivo (baratos).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.zona_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_zona   text := upper(btrim(coalesce(p->>'zona','')));
  v_filtro text := upper(btrim(coalesce(p->>'filtro','')));
  v_hoy    date := (now() at time zone 'America/Lima')::date;
  v_data   jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;

  with
  -- resolver de zona inverso: ¿qué raw-zonas (incl id estación/nombre) mapean a esta zona canónica? Para que
  -- me.stock_zonas (que guarda zona_id ya canónico en prod) y cualquier alias caigan a v_zona.
  zona_aliases as (
    select v_zona as alias
    union select upper(btrim(es.id_zona)) from mos.estaciones es where upper(btrim(es.id_zona)) = v_zona
  ),
  -- mapa cod_barra → skuBase (presentaciones propias + equivalentes), para sumar stock por skuBase.
  cb_sku as (
    select distinct on (cb) cb, sku from (
      select upper(btrim(p2.codigo_barra)) cb, coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, 0 ord
        from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)), e.sku_base, 1
        from mos.equivalencias e where coalesce(e.activo,true) and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t order by cb, ord
  ),
  -- descripción canónica por skuBase (el producto base = factor 1 / sin base; si no, cualquiera estable).
  sku_desc as (
    select distinct on (sku) sku, descripcion from (
      select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
             case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord,
             p2.id_producto
      from mos.productos p2
    ) t order by sku, ord, id_producto
  ),
  -- stock de ESTA zona por skuBase (suma de todas sus barras en me.stock_zonas para zona_id = v_zona).
  stock_zona as (
    select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) as cant
    from me.stock_zonas z
    join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
    where upper(btrim(z.zona_id)) in (select alias from zona_aliases)
    group by cs.sku
  ),
  -- stock de ALMACÉN por skuBase (wh.stock por cualquier cod_producto que sea barra del canónico+equivalentes).
  stock_alm as (
    select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) as cant
    from wh.stock s
    join cb_sku cs on cs.cb = upper(btrim(s.cod_producto))
    group by cs.sku
  ),
  -- lotes de la zona por skuBase: vencimiento más próximo + conteo de lotes activos.
  lotes as (
    select l.sku_base, min(l.fecha_vencimiento) as venc_prox, count(*) as n
    from me.zona_lotes l
    where upper(btrim(l.zona_id)) = v_zona and coalesce(l.cant_restante,0) > 0
    group by l.sku_base
  ),
  -- esperado materializado (la matemática vive en me.zona_esperado; aquí solo se LEE).
  esp as (
    select e.sku_base, e.esperado, e.tendencia, e.bcg, e.picos
    from me.zona_esperado e where upper(btrim(e.zona_id)) = v_zona
  ),
  -- universo = skus con esperado ∪ skus con stock en la zona.
  universo as (
    select sku_base from esp union select sku_base from stock_zona
  ),
  filas as (
    select
      u.sku_base,
      coalesce(sd.descripcion, u.sku_base) as descripcion,
      coalesce(sz.cant, 0) as stock_zona,
      coalesce(es.esperado, 0) as esperada,
      coalesce(es.esperado, 0) - coalesce(sz.cant, 0) as brecha,
      coalesce(sa.cant, 0) as stock_almacen,
      coalesce(es.tendencia, 'NULA') as tendencia,
      coalesce(es.bcg, 'PERRO') as bcg,
      coalesce(es.picos, '[]'::jsonb) as picos,
      lo.venc_prox,
      coalesce(lo.n, 0) as count_lotes
    from universo u
    left join sku_desc   sd on sd.sku = u.sku_base
    left join stock_zona sz on sz.sku_base = u.sku_base
    left join esp        es on es.sku_base = u.sku_base
    left join stock_alm  sa on sa.sku_base = u.sku_base
    left join lotes       lo on lo.sku_base = u.sku_base
  )
  select jsonb_build_object(
    'zona', v_zona,
    'filtro', nullif(v_filtro,''),
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'skuBase', f.sku_base,
      'descripcion', f.descripcion,
      'stockZona', f.stock_zona,
      'esperada', f.esperada,
      'brecha', f.brecha,
      'stockAlmacen', f.stock_almacen,
      'tendencia', f.tendencia,
      'bcg', f.bcg,
      'picos', f.picos,
      'vencimientoProximo', case when f.venc_prox is null then null else jsonb_build_object(
        'fecha', to_char((f.venc_prox at time zone 'America/Lima')::date, 'YYYY-MM-DD'),
        'dias', ((f.venc_prox at time zone 'America/Lima')::date - v_hoy)) end,
      'countLotes', f.count_lotes
    ) order by f.brecha desc, f.stock_zona desc), '[]'::jsonb)
  ) into v_data
  from filas f
  where v_filtro = '' or v_filtro is null
     or (v_filtro = 'BRECHA' and f.brecha > 0)
     or (v_filtro = 'SIN_ROTACION' and f.tendencia = 'NULA')
     or (v_filtro in ('CRECIENTE','DECRECIENTE','ESTABLE') and f.tendencia = v_filtro)
     or (v_filtro in ('ESTRELLA','VACA','INTERROGANTE','PERRO') and f.bcg = v_filtro);

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$fn$;
revoke all on function me.zona_panel(jsonb) from public;
grant execute on function me.zona_panel(jsonb) to service_role, authenticated;
