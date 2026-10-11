-- [1044] Recálculo automático de stock_minimo/stock_maximo → CRON NOCTURNO (04:05 Lima). El cliente ya no lo dispara.
--
-- Incidente 10-oct (13:05 Lima, congelamiento ~66 s por MEMORIA: swap 0,5→1 GB, conexiones PostgREST 14→40):
--   12:54:27 un panel MOS recién reactivado llamó mos.recalcular_stock_min_max_auto({dias:28}) desde
--   js/app.js (_maybeRecalcularMinMaxAuto, cada navegador cada 12 h). Esa llamada actualizó ~220 productos en
--   una sola transacción de 4-7 s → tg_touch_updated_at + tg_bump_catversion → refresco de catálogo en TODOS
--   los equipos en pleno horario de venta. Evidencia extra: IDPRO0001095 y IDPRO0002423 (mismo sku LEV1385)
--   tienen updated_at 17:54:27 y 17:54:35 UTC = DOS transacciones distintas → más de un panel lo corrió.
--
-- Qué cambia:
--   1. mos._minmax_recalcular_core(p_dias int): MISMA regla de negocio que la 379 viva, pero SET-BASED.
--        ventas últimos N días (no anuladas) → sku canónico (id_producto → codigo_barra → equivalencia)
--        → min = ceil(total/semanas), max = ceil(total/semanas × 1.2) → se escribe a la fila canónica.
--      Antes: un loop plpgsql con un seq scan de mos.productos (2.203 filas) POR CADA sku vendido (~880)
--      → ~1 s solo de cálculo + 1 UPDATE por fila. Ahora: 1 sola pasada con window function (~0,3 s
--      medido en solo-lectura el 10-oct) y 1 solo UPDATE que toca únicamente las filas cuyo valor cambia.
--      Desempate del canónico: se agregó (factor_conversion = 1) y id_producto como criterios finales.
--      Antes el `order by … limit 1` empataba y elegía al azar: hoy LEV1341 y LEV1385 tienen la unidad
--      (factor 1, con codigo_producto_base) y el TRIPACK (factor 3) empatados → el min/max de UNIDADES caía a
--      veces en el tripack (IDPRO0002431 hoy tiene min 17/max 20, valores de unidades). Ahora gana la unidad.
--   2. mos.recalcular_stock_min_max_auto(p): conserva firma, gate _claim_ok y forma de respuesta; delega
--      en el core. Se le QUITA el grant a authenticated: ningún navegador vuelve a dispararlo (los clientes
--      viejos aún cacheados reciben un 4xx que el cliente ya captura en silencio: .catch → console.warn).
--   3. mos.cron_minmax_nocturno(): wrapper solo-postgres (sin grant a nadie) + bitácora en mos.cron_log.
--      Por qué funciona sin JWT: mos._claim_ok() = coalesce(me.jwt_app(),'') in ('','MOS'); en pg_cron no
--      existe request.jwt.claims → '' → pasa. Igual que el resto de crons mos.cron_* (corren como postgres,
--      que es el dueño). El wrapper llama al core directamente, sin depender de esa sutileza.
--   4. cron 'mos-minmax-nocturno' 5 9 * * * (04:05 Lima) con statement_timeout 90 s y lock_timeout 5 s.
--
-- DECISIÓN updated_at + bump de catálogo: SE MANTIENEN (no se suprimen).
--   · mos.catalogo_wh_delta y mos.productos_master_delta devuelven to_jsonb(fila completa) filtrando por
--     updated_at → stock_minimo/stock_maximo VIAJAN en el delta de WH y MOS (WH los muestra/usa en stock
--     enriquecido y el panel MOS en Almacén/alertas). Si el cambio no subiera updated_at, esos caches
--     quedarían con min/max viejos hasta un reload completo → incoherencia silenciosa.
--   · El bump de mos.catalogo_meta es 1 solo por transacción (dedupe 'mosrt.cat' de _bump_catalogo_version) y
--     es lo que avisa a WH/MOS que pidan el delta. ME (catalogo_pos_rls) NO usa min/max: su huella
--     _catalogo_pos_fp no los incluye → la caché versionada del POS sigue en HIT; los ME despiertos solo
--     re-leen el bundle una vez (barato).
--   · A las 04:00 Lima no hay ventas (cajas cerradas 23:00, mos-cierre-forzado-11pm) y casi ningún equipo
--     está despierto: el refresco se absorbe al abrir, repartido. El costo que motivó el incidente (bump +
--     refresco masivo en horario de venta, con la base corta de memoria) desaparece por el HORARIO, no por
--     esconder el cambio.
--
-- Riesgos y mitigación:
--   · Fila bloqueada por un editor a las 4 a.m. → lock_timeout 5 s → la corrida falla limpia (rollback del
--     subbloque), queda en mos.cron_log ok=false y se reintenta la noche siguiente. Nada a medias: 1 UPDATE.
--   · Concurrencia con un editor: el UPDATE compara contra p.stock_minimo/p.stock_maximo (columnas de la
--     tabla, re-evaluadas por EvalPlanQual), no contra la foto del CTE → no pisa a ciegas.
--   · No es dinero: min/max son parámetros de reposición. Sí alimenta RIZ / alertas de stock.
--   · Productos sin ventas en la ventana NO se resetean a 0 (igual que la 379; decisión de negocio vigente).
--
-- Verificación previa (solo lectura, 10-oct): el cálculo set-based vs el loop vivo dan las mismas 878 filas;
-- difieren solo LEV1341/LEV1385 (el empate descrito). Hoy cambiarían 142 productos y 736 quedarían igual.

begin;

-- ── 1. Core set-based (sin gate; solo lo ejecuta postgres) ──
create or replace function mos._minmax_recalcular_core(p_dias int default 28)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_dias    int     := greatest(7, least(120, coalesce(p_dias, 28)));
  v_semanas numeric := v_dias / 7.0;
  v_desde   timestamptz := now() - make_interval(days => v_dias);
  v_res     jsonb;
begin
  with sales as (
    select d.sku, btrim(coalesce(d.cod_barras,'')) as cb, sum(coalesce(d.cantidad,0)) as qty
      from me.ventas_detalle d
      join me.ventas v on v.id_venta = d.id_venta
     where v.fecha >= v_desde
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
     group by d.sku, btrim(coalesce(d.cod_barras,''))
  ),
  -- cada línea → sku canónico: id_producto=sku → cb=codigo_barra → equivalencia cb→sku_base (idéntico a 379)
  resolved as (
    select coalesce(
      (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where pr.id_producto = s.sku limit 1),
      (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where s.cb <> '' and pr.codigo_barra = s.cb limit 1),
      (select e.sku_base from mos.equivalencias e where s.cb <> '' and e.codigo_barra = s.cb and coalesce(e.activo,true) limit 1)
    ) as sku_canon, s.qty
    from sales s
  ),
  agg as (
    select sku_canon, sum(qty) as total from resolved where sku_canon is not null group by sku_canon
  ),
  -- fila canónica por sku (réplica rowCanonBySku): id==sku, luego factor=1 sin base, luego factor=1, luego id.
  canon as (
    select x.id_producto, x.canon
      from (select pr.id_producto,
                   coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) as canon,
                   row_number() over (
                     partition by coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto)
                     order by (pr.id_producto = coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto)) desc,
                              (coalesce(pr.factor_conversion,1) = 1 and btrim(coalesce(pr.codigo_producto_base,'')) = '') desc,
                              (coalesce(pr.factor_conversion,1) = 1) desc,
                              pr.id_producto) as rn
              from mos.productos pr) x
     where x.rn = 1
  ),
  calc as (
    select a.sku_canon, a.total, c.id_producto,
           case when a.total > 0 then ceil(a.total / v_semanas)::int end        as nmin,
           case when a.total > 0 then ceil((a.total / v_semanas) * 1.2)::int end as nmax
      from agg a
      left join canon c on c.canon = a.sku_canon
  ),
  upd as (
    update mos.productos p
       set stock_minimo = k.nmin, stock_maximo = k.nmax
      from calc k
     where k.total > 0
       and k.id_producto is not null
       and p.id_producto = k.id_producto
       and (coalesce(p.stock_minimo,0) <> k.nmin or coalesce(p.stock_maximo,0) <> k.nmax)
    returning k.sku_canon, k.nmin, k.nmax
  )
  select jsonb_build_object(
           'actualizados', (select count(*) from upd),
           'sinCambio',    (select count(*) from calc where total > 0 and id_producto is not null) - (select count(*) from upd),
           'sinVentas',    (select count(*) from calc where coalesce(total,0) <= 0),
           'errores',      (select count(*) from calc where total > 0 and id_producto is null),
           'ventana',      v_dias || ' días',
           'sample',       coalesce((select jsonb_agg(jsonb_build_object('sku', u.sku_canon, 'min', u.nmin, 'max', u.nmax))
                                       from (select * from upd order by sku_canon limit 20) u), '[]'::jsonb))
    into v_res;
  return v_res;
end;
$function$;

revoke all on function mos._minmax_recalcular_core(int) from public, anon, authenticated, service_role;

-- ── 2. RPC pública: misma firma/gate/forma; delega en el core. Sin grant a authenticated. ──
create or replace function mos.recalcular_stock_min_max_auto(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  -- [1044] desde el cliente ya no se llama (cron nocturno mos-minmax-nocturno). Queda para service_role / SQL manual.
  return jsonb_build_object('ok', true,
    'data', mos._minmax_recalcular_core(coalesce(mos._numn(p->>'dias'), 28)::int));
end;
$function$;

revoke all on function mos.recalcular_stock_min_max_auto(jsonb) from public, anon, authenticated;
grant execute on function mos.recalcular_stock_min_max_auto(jsonb) to service_role;

-- ── 3. Wrapper de cron (solo postgres) con bitácora ──
create or replace function mos.cron_minmax_nocturno()
returns jsonb
language plpgsql
security definer
set search_path to ''
set lock_timeout to '5s'
as $function$
declare
  v_t0  timestamptz := clock_timestamp();
  v_res jsonb;
begin
  begin
    v_res := mos._minmax_recalcular_core(28);
    v_res := v_res || jsonb_build_object('ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
    insert into mos.cron_log(job, ok, resultado) values ('minmax_nocturno', true, v_res - 'sample');
    return jsonb_build_object('ok', true, 'data', v_res);
  exception when query_canceled or others then   -- [QA] OTHERS no atrapa el timeout (57014)
    -- el subbloque revierte el UPDATE entero; queda rastro y se reintenta la noche siguiente
    insert into mos.cron_log(job, ok, resultado)
      values ('minmax_nocturno', false, jsonb_build_object('excepcion', sqlerrm, 'sqlstate', sqlstate,
                                                           'ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000)));
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end;
$function$;

revoke all on function mos.cron_minmax_nocturno() from public, anon, authenticated, service_role;

-- ── 4. Cron 04:00 Lima (09:00 UTC). cron.schedule con el mismo nombre = upsert. ──
select cron.schedule('mos-minmax-nocturno', '5 9 * * *',
  $cron$set statement_timeout = '90s'; select mos.cron_minmax_nocturno();$cron$);

commit;

-- ── Smoke test post-apply (NO correr en horario de venta: escribe ~140 filas y bumpea catálogo) ──
--   select mos.cron_minmax_nocturno();                       -- ok=true, actualizados≈N, ms < 2000
--   select * from mos.cron_log where job='minmax_nocturno' order by ts desc limit 3;
--   select proacl from pg_proc where oid='mos.recalcular_stock_min_max_auto'::regproc;  -- sin authenticated
--   select jobname, schedule, command from cron.job where jobname='mos-minmax-nocturno';
-- Al día siguiente:
--   select status, start_time, end_time - start_time dur, return_message from cron.job_run_details
--    where jobid=(select jobid from cron.job where jobname='mos-minmax-nocturno') order by runid desc limit 3;

-- ── ROLLBACK (vuelve al estado 379: loop vivo + grant a authenticated; el cliente 2.44.67 lo volvería a disparar) ──
-- begin;
-- select cron.unschedule('mos-minmax-nocturno');
-- create or replace function mos.recalcular_stock_min_max_auto(p jsonb default '{}'::jsonb)
--  returns jsonb language plpgsql security definer set search_path to '' as $function$
-- declare
--   v_dias    int     := greatest(7, least(120, coalesce(mos._numn(p->>'dias'),28)::int));
--   v_semanas numeric := v_dias / 7.0;
--   v_desde   timestamptz := now() - (v_dias || ' days')::interval;
--   v_act int := 0; v_sc int := 0; v_sv int := 0; v_err int := 0;
--   rec record;
--   v_row text; v_min int; v_max int; v_minA numeric; v_maxA numeric;
--   v_sample jsonb := '[]'::jsonb;
-- begin
--   if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
--   perform set_config('statement_timeout','120s',true);
--   for rec in
--     with sales as (
--       select d.sku, btrim(coalesce(d.cod_barras,'')) as cb, sum(coalesce(d.cantidad,0)) as qty
--         from me.ventas_detalle d
--         join me.ventas v on v.id_venta = d.id_venta
--        where v.fecha >= v_desde
--          and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
--        group by d.sku, btrim(coalesce(d.cod_barras,''))
--     ),
--     resolved as (
--       select coalesce(
--         (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where pr.id_producto = s.sku limit 1),
--         (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where s.cb <> '' and pr.codigo_barra = s.cb limit 1),
--         (select e.sku_base from mos.equivalencias e where s.cb <> '' and e.codigo_barra = s.cb and coalesce(e.activo,true) limit 1)
--       ) as sku_canon, s.qty
--       from sales s
--     )
--     select sku_canon, sum(qty) as total
--       from resolved
--      where sku_canon is not null
--      group by sku_canon
--   loop
--     if coalesce(rec.total,0) <= 0 then v_sv := v_sv + 1; continue; end if;
--     v_min := ceil((rec.total / v_semanas));
--     v_max := ceil((rec.total / v_semanas) * 1.2);
--     v_row := null;
--     select id_producto, coalesce(stock_minimo,0), coalesce(stock_maximo,0)
--       into v_row, v_minA, v_maxA
--       from mos.productos
--      where coalesce(nullif(btrim(sku_base),''), id_producto) = rec.sku_canon
--      order by (id_producto = rec.sku_canon) desc,
--               (coalesce(factor_conversion,1) = 1 and btrim(coalesce(codigo_producto_base,'')) = '') desc
--      limit 1;
--     if v_row is null then v_err := v_err + 1; continue; end if;
--     if v_minA = v_min and v_maxA = v_max then v_sc := v_sc + 1; continue; end if;
--     update mos.productos set stock_minimo = v_min, stock_maximo = v_max where id_producto = v_row;
--     v_act := v_act + 1;
--     if jsonb_array_length(v_sample) < 20 then
--       v_sample := v_sample || jsonb_build_object('sku', rec.sku_canon, 'min', v_min, 'max', v_max);
--     end if;
--   end loop;
--   return jsonb_build_object('ok',true,'data',jsonb_build_object(
--     'actualizados',v_act,'sinCambio',v_sc,'sinVentas',v_sv,'errores',v_err,
--     'ventana', v_dias || ' días', 'sample', v_sample));
-- end; $function$;
-- grant execute on function mos.recalcular_stock_min_max_auto(jsonb) to authenticated;
-- drop function if exists mos.cron_minmax_nocturno();
-- drop function if exists mos._minmax_recalcular_core(int);
-- commit;
