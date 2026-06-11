-- ============================================================
-- 11_fase1d_wh_rotacion.sql — Fase 1.D (canary WH) · función server-side de getRotacionSemanal
-- ============================================================
-- Replica getRotacionSemanal(params) (Productos.gs:840-931 de warehouseMos).
-- Pivote de unidades de salida por (codigoProducto UPPER, semana ISO) en una ventana de N semanas.
--   · ventana = lunes de (semana actual − (N−1)) semanas .. ahora   (lunes 00:00 Lima)
--   · GUIAS: tipo LIKE 'SALIDA%' + estado CERRADA/AUTOCERRADA + fecha en ventana
--   · GUIA_DETALLE: observacion != ANULADO + cod_producto (UPPER/trim) + cant_recibida > 0 + filtro opcional
--   · semana ISO 8601 (IYYY-IW en TZ Lima); etiquetas = N semanas cronológicas; faltantes → 0
--   · generadoEn lo agrega el wrapper GAS (la RPC NO lo incluye; difiere entre llamadas)
-- Forma: {ok:true, data:{etiquetas, semanas, productos:{cb:[{semana,unidades}]}}}.
-- ============================================================

create or replace function wh.rotacion_semanal(semanas int default 8, codigos_producto text default null)
returns jsonb
language sql
stable
as $$
with nbase as (
  select (case when coalesce(semanas,0) <= 0 then 8 else semanas end) as n   -- GAS: parseInt(semanas)||8 → 0/NaN/'' = 8
),
params as (
  select n,
    ((date_trunc('week', now() at time zone 'America/Lima') at time zone 'America/Lima')
       - ((n-1)::text||' weeks')::interval) as ventana_inicio,
    case when codigos_producto is not null and btrim(codigos_producto)<>''
         then array(select upper(btrim(c)) from unnest(string_to_array(codigos_producto, ',')) c where btrim(c)<>'')
         else null end as filtro
  from nbase
),
semanas_lbl as (
  select w, to_char((p.ventana_inicio + (w||' weeks')::interval) at time zone 'America/Lima','IYYY"-W"IW') as lbl
  from params p, generate_series(0, (select n-1 from params)) as w
),
guias_win as (
  select g.id_guia, to_char(g.fecha at time zone 'America/Lima','IYYY"-W"IW') as sem
  from wh.guias g, params p
  where g.tipo like 'SALIDA%'
    and upper(coalesce(g.estado,'')) in ('CERRADA','AUTOCERRADA')
    and g.fecha is not null
    and g.fecha >= p.ventana_inicio
    and g.fecha <= now()
),
detalle as (
  select upper(btrim(d.cod_producto)) as cb, gw.sem, sum(coalesce(d.cant_recibida,0)) as unidades
  from wh.guia_detalle d
  join guias_win gw on gw.id_guia = d.id_guia
  cross join params p
  where upper(coalesce(d.observacion,'')) <> 'ANULADO'
    and coalesce(btrim(d.cod_producto),'') <> ''
    and coalesce(d.cant_recibida,0) > 0
    and (p.filtro is null or upper(btrim(d.cod_producto)) = any(p.filtro))
  group by upper(btrim(d.cod_producto)), gw.sem
),
prods as (select distinct cb from detalle),
series as (
  select pr.cb, sl.w, sl.lbl, coalesce(dt.unidades,0) as unidades
  from prods pr
  cross join semanas_lbl sl
  left join detalle dt on dt.cb = pr.cb and dt.sem = sl.lbl
)
select jsonb_build_object(
  'ok', true,
  'data', jsonb_build_object(
    'etiquetas', coalesce((select jsonb_agg(lbl order by w) from semanas_lbl), '[]'::jsonb),
    'semanas',   (select n from params),
    'productos', coalesce((select jsonb_object_agg(cb, serie) from (
        select cb, jsonb_agg(jsonb_build_object('semana', lbl, 'unidades', unidades) order by w) as serie
        from series group by cb
      ) t), '{}'::jsonb)
  )
);
$$;

grant execute on function wh.rotacion_semanal(int, text) to service_role;
