-- ============================================================
-- 424 · wh.rotacion_cache — rotación semanal PRECALCULADA (catálogo v4)
-- ============================================================
-- Problema: wh.rotacion_semanal (SQL 11) recalcula 8 semanas de guías EN VIVO en cada
-- llamada → chip/sparkline del catálogo MOS tarda (TTL 15min + failsafes 20-25s en el front).
-- Fix: tabla cache refrescada por pg_cron cada hora + al vuelo tras cada refresh manual.
--   · MISMA lógica de negocio que SQL 11 (SALIDA% + CERRADA/AUTOCERRADA + obs<>ANULADO,
--     semana ISO en TZ Lima, ventana lunes-00:00 de (N-1) semanas atrás).
--   · NUEVO: corte por zona destino (wh.guias.id_zona) — fila id_zona='' = TOTAL.
--   · NUEVO: kg_equiv — normalización a unidades del CANÓNICO (regla mos._venta_canonico):
--       peso (KGM/KG/LTR/...) → cant directa · derivado NIU → cant × factor_conversion_base
--       presentación → cant × factor_conversion (kilos si el grupo es granel; unidades base si no).
-- Directriz: CERO GAS. El wrapper mos.wh_rotacion_semanal se redefine para leer la cache
-- (mismo shape {ok,data:{etiquetas,semanas,productos}}); si la cache está vacía o piden
-- semanas<>8, cae al cálculo en vivo wh.rotacion_semanal (Supabase↔Supabase, jamás GAS).
-- ============================================================

-- 1) Tabla cache
create table if not exists wh.rotacion_cache (
  cod_producto  text not null,          -- UPPER(codigo de barra real del despacho)
  semana        text not null,          -- 'IYYY-WIW' (ISO, TZ Lima)
  id_zona       text not null default '', -- '' = total todas las zonas
  unidades      numeric not null default 0,
  kg_equiv      numeric,                -- null si no aplica conversión (producto no registrado)
  refrescado_en timestamptz not null default now(),
  primary key (cod_producto, semana, id_zona)
);
create index if not exists ix_wh_rotcache_sem  on wh.rotacion_cache (semana);
create index if not exists ix_wh_rotcache_zona on wh.rotacion_cache (id_zona) where id_zona <> '';
-- [rev B3] convención del repo: toda tabla nueva con RLS (hoy inocuo, mañana blindado)
alter table wh.rotacion_cache enable row level security;

-- 2) Refresh (delete+insert en una tx; ~8 semanas de guías, corre en <1s con los índices ya existentes)
create or replace function wh.rotacion_cache_refrescar(p_semanas int default 8)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_n int := greatest(1, least(12, coalesce(p_semanas, 8)));
  v_ini timestamptz;
  v_filas int;
  v_t0 timestamptz := clock_timestamp();
begin
  -- [rev B4] serializar refreshes concurrentes (cron + manual futuro): sin esto,
  -- dos delete+insert cruzados bajo READ COMMITTED terminan en PK violation.
  perform pg_advisory_xact_lock(hashtext('wh_rotcache_refresh'));

  v_ini := ((date_trunc('week', now() at time zone 'America/Lima') at time zone 'America/Lima')
            - ((v_n - 1)::text || ' weeks')::interval);

  delete from wh.rotacion_cache;

  with guias_win as (
    select g.id_guia,
           to_char(g.fecha at time zone 'America/Lima', 'IYYY"-W"IW') as sem,
           coalesce(nullif(btrim(g.id_zona), ''), 'SIN_ZONA')          as zona
    from wh.guias g
    where g.tipo like 'SALIDA%'
      and upper(coalesce(g.estado, '')) in ('CERRADA', 'AUTOCERRADA')
      and g.fecha is not null
      and g.fecha >= v_ini
      and g.fecha <= now()
  ),
  det as (
    select upper(btrim(d.cod_producto)) as cb, gw.sem, gw.zona,
           sum(coalesce(d.cant_recibida, 0)) as unidades
    from wh.guia_detalle d
    join guias_win gw on gw.id_guia = d.id_guia
    where upper(coalesce(d.observacion, '')) <> 'ANULADO'
      and coalesce(btrim(d.cod_producto), '') <> ''
      and coalesce(d.cant_recibida, 0) > 0
    group by 1, 2, 3
  ),
  -- por zona + fila total (zona='')
  filas as (
    select cb, sem, zona, unidades from det
    union all
    select cb, sem, '' as zona, sum(unidades) from det group by cb, sem
  ),
  -- factor de conversión a canónico por producto (regla mos._venta_canonico):
  --   derivado → factor_conversion_base (porción) · peso → 1:1 · presentación → factor_conversion
  -- [rev C1] distinct on: codigo_barra NO tiene unique en mos.productos — un cb duplicado
  --   histórico duplicaría el left join y reventaría la PK del insert (refresh congelado).
  -- [rev B2] derivado ANTES que peso: un derivado mal etiquetado KGM debe usar su porción.
  -- [rev B1] presentación fraccionaria (0<factor<1) también convierte (alineado con SQL 425).
  conv as (
    -- [rev pase2-M1] las guías registran el codigoBarra REAL escaneado — que puede ser una
    -- EQUIVALENCIA activa (top-3 de rotación del almacén salía kg NULL). Se agregan con el
    -- factor de su grupo: 1:1 si el dueño es canónico/granel, ×porción si el dueño es derivado.
    -- prio 0 = productos gana sobre equivalencia ante colisión histórica de cb.
    select distinct on (cb) cb, f_canon from (
      select upper(btrim(pr.codigo_barra)) as cb,
             case
               when coalesce(nullif(btrim(pr.codigo_producto_base), ''), '') <> ''
                    and coalesce(pr.factor_conversion_base, 0) > 0
                 then pr.factor_conversion_base
               when upper(coalesce(pr.unidad_medida, '')) in
                    ('KGM','KG','LTR','L','MTR','M','GR','GMS','G','GRAMO','GRAMOS','KILO','KILOS','LITRO','LITROS')
                 then 1::numeric
               when coalesce(nullif(pr.factor_conversion, 0), 1) <> 1
                 then coalesce(nullif(pr.factor_conversion, 0), 1)
               else 1::numeric
             end as f_canon,
             0 as prio, pr.id_producto as ord
      from mos.productos pr
      where coalesce(btrim(pr.codigo_barra), '') <> ''
      union all
      select upper(btrim(e.codigo_barra)),
             coalesce(dueño.f, 1::numeric),
             1 as prio, e.id_equiv
      from mos.equivalencias e
      left join lateral (
        select case
                 when coalesce(nullif(btrim(d.codigo_producto_base), ''), '') <> ''
                      and coalesce(d.factor_conversion_base, 0) > 0
                   then d.factor_conversion_base
                 else 1::numeric
               end as f
        from mos.productos d
        where (coalesce(nullif(btrim(d.sku_base), ''), d.id_producto) = e.sku_base
               or d.id_producto = e.sku_base)
          and coalesce(nullif(d.factor_conversion, 0), 1) = 1
        limit 1
      ) dueño on true
      where e.activo and coalesce(btrim(e.codigo_barra), '') <> ''
    ) u
    order by cb, prio, ord
  )
  insert into wh.rotacion_cache (cod_producto, semana, id_zona, unidades, kg_equiv, refrescado_en)
  select f.cb, f.sem, f.zona, f.unidades,
         case when c.cb is not null then round(f.unidades * c.f_canon, 3) end,
         now()
  from filas f
  left join conv c on c.cb = f.cb;

  get diagnostics v_filas = row_count;
  return jsonb_build_object('ok', true, 'filas', v_filas,
                            'ms', round(extract(milliseconds from clock_timestamp() - v_t0)));
end; $fn$;

revoke all on function wh.rotacion_cache_refrescar(int) from public, anon;
grant execute on function wh.rotacion_cache_refrescar(int) to service_role;

-- 3) Wrapper cron (patrón SQL 130: exception nunca mata el job + log en mos.cron_log)
create or replace function wh.cron_rotacion_cache()
returns void language plpgsql security definer set search_path='' as $fn$
declare v jsonb;
begin
  v := wh.rotacion_cache_refrescar(8);
  insert into mos.cron_log(job, ok, resultado) values ('wh-rotacion-cache', true, v);
exception when others then
  insert into mos.cron_log(job, ok, resultado)
  values ('wh-rotacion-cache', false, jsonb_build_object('error', sqlerrm));
end; $fn$;

revoke all on function wh.cron_rotacion_cache() from public, anon;
grant execute on function wh.cron_rotacion_cache() to service_role;

-- 4) Job horario (pg_cron corre en UTC; minuto 7 de cada hora — no coincide con crons nocturnos)
create extension if not exists pg_cron;
do $$
begin
  if exists (select 1 from cron.job where jobname = 'wh-rotacion-cache-horaria') then
    perform cron.unschedule('wh-rotacion-cache-horaria');
  end if;
end $$;
select cron.schedule('wh-rotacion-cache-horaria', '7 * * * *', $$ select wh.cron_rotacion_cache(); $$);

-- 5) Redefinir el wrapper cross-app (SQL 380) para servir DESDE LA CACHE.
--    Shape idéntico a SQL 11 ({etiquetas, semanas, productos:{cb:[{semana,unidades}]}}) +
--    campo 'kg' por punto (aditivo — los lectores viejos leen .unidades y no se enteran).
--    Cache vacía o semanas<>8 → cálculo en vivo (wh.rotacion_semanal). Sin zona aquí:
--    el corte por zona lo consume mos.analitica_grupo (SQL 425) leyendo la tabla directo.
create or replace function mos.wh_rotacion_semanal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_sem  int  := greatest(1, least(52, coalesce(mos._numn(p->>'semanas'), 8)::int));
  v_cods text := nullif(btrim(coalesce(p->>'codigos', p->>'codigosProducto', '')), '');
  v_filtro text[];
  v_out jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- cache solo materializa la ventana estándar de 8 semanas.
  -- [rev C1] FRESCURA: si el refresh lleva >2h fallando (cron muerto/PK violation),
  -- caer al cálculo en vivo — jamás servir rotación congelada como si fuera actual.
  -- Nota rollover lunes 00:00-00:07 Lima: hasta que corra el cron de la hora, la
  -- semana nueva muestra 0 (latencia inherente ≤7 min, aceptada).
  if v_sem <> 8
     or not exists (select 1 from wh.rotacion_cache limit 1)
     or (select max(refrescado_en) from wh.rotacion_cache) < now() - interval '2 hours' then
    return wh.rotacion_semanal(v_sem, v_cods);
  end if;

  if v_cods is not null then
    v_filtro := array(select upper(btrim(c)) from unnest(string_to_array(v_cods, ',')) c where btrim(c) <> '');
  end if;

  with sem_lbl as (
    select w,
           to_char((((date_trunc('week', now() at time zone 'America/Lima') at time zone 'America/Lima')
                     - ('7 weeks')::interval) + (w || ' weeks')::interval) at time zone 'America/Lima',
                   'IYYY"-W"IW') as lbl
    from generate_series(0, 7) as w
  ),
  base as (
    select rc.cod_producto as cb, rc.semana, rc.unidades, rc.kg_equiv
    from wh.rotacion_cache rc
    where rc.id_zona = ''
      and (v_filtro is null or rc.cod_producto = any(v_filtro))
  ),
  prods as (select distinct cb from base),
  series as (
    select pr.cb, sl.w, sl.lbl,
           coalesce(b.unidades, 0) as unidades,
           coalesce(b.kg_equiv, 0) as kg
    from prods pr
    cross join sem_lbl sl
    left join base b on b.cb = pr.cb and b.semana = sl.lbl
  )
  select jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'etiquetas', coalesce((select jsonb_agg(lbl order by w) from sem_lbl), '[]'::jsonb),
      'semanas', 8,
      'cache', true,
      'productos', coalesce((select jsonb_object_agg(cb, serie) from (
          select cb, jsonb_agg(jsonb_build_object('semana', lbl, 'unidades', unidades, 'kg', kg) order by w) as serie
          from series group by cb
        ) t), '{}'::jsonb)
    )
  ) into v_out;

  return v_out;
end; $fn$;

revoke all on function mos.wh_rotacion_semanal(jsonb) from public, anon;
grant execute on function mos.wh_rotacion_semanal(jsonb) to authenticated, service_role;

-- 6) Refresh inicial inmediato (que la cache nazca llena)
select wh.rotacion_cache_refrescar(8);
