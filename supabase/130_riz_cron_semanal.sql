-- 130_riz_cron_semanal.sql — [RIZ · CAPA 3 · pg_cron: MOTOR SEMANAL (recompute + cola diaria + lista de compras)]
-- Módulo de Reposición Inteligente por Zona (RIZ). Diseño: DISENO_modulo_reposicion_zona.md (Parte 1.5 "el motor",
-- 2.4, 4.1 idempotencia, 4.10 "pg_cron, no GAS").
--
-- ⚠️⚠️ INERTE (efecto nulo en producción) ⚠️⚠️
--   Estos jobs SÍ corren (active=true por defecto, ver más abajo el por qué), pero su efecto es INERTE para la
--   operación de negocio: SOLO materializan tablas RIZ nuevas (me.zona_esperado [A], me.zona_ticket_dia [B],
--   me.zona_compra_externa [C]) que HOY NADIE lee — el frontend de RIZ aún no está cableado (no hay wiring en
--   js/api.js, ni flag, ni vista 'zona'). MOS opera 100% por GAS. Este archivo NO toca:
--     · ninguna RPC de dinero/producción (cerrar_guia, liquidaciones, ventas, cajas, stock real de WH/ME)
--     · api.js / sw.js / version.json / GAS / flags de cutover / el sync Hoja→Supabase
--   El recompute solo escribe me.zona_esperado (fuente='auto'; respeta overrides 'manual'). La cola escribe
--   me.zona_ticket_dia. La lista escribe me.zona_compra_externa. Las TRES son tablas nuevas creadas inertes en
--   127_riz_tablas.sql. Si no hay zonas configuradas, los jobs corren y NO escriben nada (bucle vacío) → seguros.
--
-- ── POR QUÉ active=true (a diferencia de 97/Fase E que nacía deshabilitado) ──────────────────────────────────
--   Fase E (97) podía ESCRIBIR datos de negocio (liquidaciones_dia) si su flag se prendía → doble candado
--   (flag + active=false). Aquí NO hay datos de negocio en juego: lo peor que puede pasar si un job corre es que
--   me.zona_esperado/ticket_dia/compra_externa queden materializadas… que es exactamente para lo que existen, y
--   nadie las lee todavía. Por eso se dejan ACTIVOS — así el módulo arranca con datos frescos el día que el
--   frontend se cablee, sin tener que acordarse de prender el cron. Para CONGELARLOS (si se quisiera):
--     select cron.alter_job((select jobid from cron.job where jobname='riz-recompute-semanal'), active := false);
--     select cron.alter_job((select jobid from cron.job where jobname='riz-lista-compras'),     active := false);
--
-- ── HUSO HORARIO ───────────────────────────────────────────────────────────────────────────────────────────
--   pg_cron evalúa el schedule en UTC. Perú = UTC-5 FIJO (sin horario de verano). Equivalencias usadas:
--     · recompute+cola : DOM 23:00 Lima = LUN 04:00 UTC  → '0 4 * * 1'   (lunes UTC = domingo noche Lima)
--     · lista compras  : LUN 06:00 Lima =     11:00 UTC  → '0 11 * * 1'  (lunes UTC, 5h después del recompute)
--   El recompute corre primero (04:00 UTC) y la lista 7h después (11:00 UTC, mismo lunes UTC) → la lista SIEMPRE
--   lee el esperado ya recomputado de esta semana (diseño 1.5: "lista de compras del lunes TRAS recompute").
--
-- ── IDEMPOTENCIA (diseño 4.1) ───────────────────────────────────────────────────────────────────────────────
--   · esperado : upsert por (zona_id, sku_base) en me.zona_esperado_recompute (ya idempotente, 128). Re-correr no duplica.
--   · cola     : upsert por (zona_id, fecha, lote_dia) en me.zona_ticket_dia. Re-correr el mismo domingo regenera
--                los mismos lotes de los mismos días (lun..sáb de la semana entrante) sin duplicar. Solo pisa filas
--                en estado 'PENDIENTE' (no toca un ticket ya 'IMPRESO'/'REVISADO' por el admin).
--   · lista    : upsert por (zona_id, semana, sku_base) en me.zona_lista_compras (ya idempotente, 129). Semana =
--                etiqueta ISO determinista 'IYYY-Www' de la semana entrante.
--
-- ── LOG / OBSERVABILIDAD ────────────────────────────────────────────────────────────────────────────────────
--   Reusa mos.cron_log (creada en 97). job ∈ {'riz_recompute_semanal','riz_lista_compras'}. Cada wrapper envuelve
--   todo en begin/exception → NUNCA propaga error a pg_cron (un fallo no mata el job, solo loguea ok=false).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists me;
create extension if not exists pg_cron;
-- mos.cron_log ya existe (97_mos_cron_nocturno.sql). Defensivo idempotente por si se aplica fuera de orden:
create table if not exists mos.cron_log (
  id        bigint generated always as identity primary key,
  ts        timestamptz not null default now(),
  job       text        not null,
  ok        boolean,
  resultado jsonb
);


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- WRAPPER 1 — me.cron_riz_recompute_semanal()
--   (1) Recompute del esperado de TODAS las zonas → me.zona_esperado_recompute('{}') (128).
--   (2) Materializa la COLA diaria: parte los productos "relevantes" (brecha>0 O tendencia no estable/nula
--       relevante) de cada zona en lotes de ~10 por día, repartidos LUN..SÁB de la semana ENTRANTE (la que arranca
--       el lunes inmediatamente posterior a este domingo noche). Upsert en me.zona_ticket_dia.
--   Sin args (el comando del cron es texto fijo). Calcula la semana entrante en cada corrida.
--   SECURITY DEFINER + search_path='' (corre como owner; me.jwt_app()=NULL → mos._claim_ok() pasa como service_role).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.cron_riz_recompute_semanal()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_hoy        date := (now() at time zone 'America/Lima')::date;
  -- lunes de la semana ENTRANTE: si hoy es domingo, es mañana; en general el próximo lunes ISO.
  -- date_trunc('week', hoy) = lunes de la semana EN CURSO (lunes ISO). + 7 = lunes de la semana entrante.
  v_lunes_next date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) + 7;
  v_rec        jsonb;
  v_lote_sz    int  := 10;   -- tamaño de lote diario (~10 productos). Diseño 1.5/3.6.
  v_total_cola int  := 0;
  r_z          record;
  v_pol        jsonb;
  v_umb        numeric;
  v_dias_cola  int;          -- cuántos días hábiles repartir (lun..sáb = 6)
begin
  -- (1) RECOMPUTE del esperado de todas las zonas (idempotente; solo escribe me.zona_esperado).
  v_rec := me.zona_esperado_recompute('{}'::jsonb);

  -- (2) COLA diaria por zona — lun..sáb de la semana entrante.
  v_dias_cola := 6;  -- lunes(0)..sábado(5); domingo descansa.
  for r_z in
    select upper(btrim(z.id_zona)) as zona, z.politica_json as pol
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado,true) = true
    order by 1
  loop
    v_pol := r_z.pol;
    v_umb := coalesce((v_pol->>'umbral_tendencia')::numeric, 0.10);
    v_lote_sz := greatest(coalesce((v_pol->>'lote_diario')::int, 10), 1);

    -- Universo "relevante" de la zona: productos con brecha>0 (esperado > stock de zona) O tendencia accionable
    -- (CRECIENTE/DECRECIENTE/NULA → el admin debe mirarlos). Se ordena por brecha desc (lo más urgente primero),
    -- se enumera, y se asigna a un día (lun..sáb) y lote por bloques de v_lote_sz. lote_dia = bloque dentro del día.
    with
    cb_sku as (
      select distinct on (cb) cb, sku from (
        select upper(btrim(p2.codigo_barra)) cb, coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, 0 ord
          from mos.productos p2 where nullif(btrim(p2.codigo_barra),'') is not null
        union all
        select upper(btrim(ev.codigo_barra)), ev.sku_base, 1
          from mos.equivalencias ev where coalesce(ev.activo,true) and nullif(btrim(ev.codigo_barra),'') is not null and nullif(btrim(ev.sku_base),'') is not null
      ) t order by cb, ord
    ),
    sku_desc as (
      select distinct on (sku) sku, descripcion from (
        select coalesce(nullif(btrim(p2.sku_base),''), p2.id_producto) sku, p2.descripcion,
               case when coalesce(p2.codigo_producto_base,'')='' and coalesce(p2.factor_conversion,1)=1 then 0 else 1 end ord, p2.id_producto
        from mos.productos p2
      ) t order by sku, ord, id_producto
    ),
    stock_zona as (
      select cs.sku as sku_base, sum(coalesce(z.cantidad,0)) cant
      from me.stock_zonas z join cb_sku cs on cs.cb = upper(btrim(z.cod_barras))
      where upper(btrim(z.zona_id)) = r_z.zona group by cs.sku
    ),
    stock_alm as (
      select cs.sku as sku_base, sum(coalesce(s.cantidad_disponible,0)) cant
      from wh.stock s join cb_sku cs on cs.cb = upper(btrim(s.cod_producto)) group by cs.sku
    ),
    esp as (
      select e.sku_base, e.esperado, e.tendencia, e.picos
      from me.zona_esperado e where upper(btrim(e.zona_id)) = r_z.zona
    ),
    filas as (
      select e.sku_base,
             coalesce(sd.descripcion, e.sku_base) as nombre,
             coalesce(sz.cant,0) as stock_zona,
             coalesce(e.esperado,0) as esperada,
             coalesce(e.esperado,0) - coalesce(sz.cant,0) as faltan,
             coalesce(sa.cant,0) as stock_almacen,
             coalesce(e.tendencia,'NULA') as tendencia,
             coalesce(e.picos,'[]'::jsonb) as picos
      from esp e
      left join sku_desc sd on sd.sku = e.sku_base
      left join stock_zona sz on sz.sku_base = e.sku_base
      left join stock_alm sa on sa.sku_base = e.sku_base
      -- "relevante": hay brecha, o la tendencia pide revisión (no es la 'ESTABLE' tranquila).
      where (coalesce(e.esperado,0) - coalesce(sz.cant,0)) > 0
         or coalesce(e.tendencia,'NULA') in ('CRECIENTE','DECRECIENTE','NULA')
    ),
    enum as (
      select f.*, (row_number() over (order by f.faltan desc, f.stock_zona desc) - 1) as idx
      from filas f
    ),
    asignado as (
      -- idx 0.. → posición global; bloque de v_lote_sz por día; día = bloque mod 6 (+1 → lun..sáb); lote dentro = bloque/6 + 1.
      select e.*,
             (e.idx / v_lote_sz)            as bloque,
             v_lunes_next + ((e.idx / v_lote_sz) % v_dias_cola)            as fecha,   -- lun..sáb rotando
             ((e.idx / v_lote_sz) / v_dias_cola) + 1                        as lote_dia
      from enum e
    ),
    agrupado as (
      select a.fecha, a.lote_dia,
             jsonb_agg(jsonb_build_object(
               'skuBase', a.sku_base, 'nombre', a.nombre,
               'stockZona', a.stock_zona, 'esperada', a.esperada, 'faltan', a.faltan,
               'tendencia', a.tendencia, 'picos', a.picos, 'stockAlmacen', a.stock_almacen
             ) order by a.faltan desc) as items,
             count(*) as n
      from asignado a
      group by a.fecha, a.lote_dia
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
    select coalesce(sum(1),0) into v_dias_cola from up;  -- reutilizo var como contador local de filas upsertadas
    v_total_cola := v_total_cola + coalesce(v_dias_cola,0);
    v_dias_cola := 6;  -- restaurar para la próxima zona
  end loop;

  insert into mos.cron_log(job, ok, resultado)
  values ('riz_recompute_semanal', coalesce((v_rec->>'ok')::boolean,false),
          jsonb_build_object('lunesEntrante', to_char(v_lunes_next,'YYYY-MM-DD'),
                             'recompute', v_rec, 'colaFilas', v_total_cola));

  return jsonb_build_object('ok', true, 'recompute', v_rec, 'colaFilas', v_total_cola,
                            'lunesEntrante', to_char(v_lunes_next,'YYYY-MM-DD'));
exception when others then
  insert into mos.cron_log(job, ok, resultado)
  values ('riz_recompute_semanal', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok', false, 'error', 'excepcion', 'detalle', SQLERRM);
end;
$fn$;
revoke all on function me.cron_riz_recompute_semanal() from public, anon, authenticated;
grant execute on function me.cron_riz_recompute_semanal() to service_role;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- WRAPPER 2 — me.cron_riz_lista_compras()
--   Por cada zona activa → me.zona_lista_compras({zona, semana}) (129). semana = etiqueta ISO de la semana EN CURSO
--   (la que arranca este lunes Lima). Materializa me.zona_compra_externa de la semana (idempotente por zona+semana+sku).
--   Sin args. Envuelto en begin/exception (un fallo de una zona NO debe matar el job).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function me.cron_riz_lista_compras()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  -- semana ISO EN CURSO en Lima (lunes 06:00 Lima ya estamos dentro de la semana objetivo).
  v_semana   text := to_char((now() at time zone 'America/Lima')::date, 'IYYY"-W"IW');
  v_zonas    int  := 0;
  v_items    int  := 0;
  r_z        record;
  v_res      jsonb;
begin
  for r_z in
    select upper(btrim(z.id_zona)) as zona from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado,true) = true
    order by 1
  loop
    begin
      v_res := me.zona_lista_compras(jsonb_build_object('zona', r_z.zona, 'semana', v_semana));
      v_zonas := v_zonas + 1;
      v_items := v_items + coalesce((v_res#>>'{data,totalItems}')::int, 0);
    exception when others then
      -- una zona que falla no detiene a las demás (log lo recoge al final).
      null;
    end;
  end loop;

  insert into mos.cron_log(job, ok, resultado)
  values ('riz_lista_compras', true,
          jsonb_build_object('semana', v_semana, 'zonas', v_zonas, 'itemsTotales', v_items));

  return jsonb_build_object('ok', true, 'semana', v_semana, 'zonas', v_zonas, 'itemsTotales', v_items);
exception when others then
  insert into mos.cron_log(job, ok, resultado)
  values ('riz_lista_compras', false, jsonb_build_object('excepcion', SQLERRM, 'semana', v_semana));
  return jsonb_build_object('ok', false, 'error', 'excepcion', 'detalle', SQLERRM);
end;
$fn$;
revoke all on function me.cron_riz_lista_compras() from public, anon, authenticated;
grant execute on function me.cron_riz_lista_compras() to service_role;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- AGENDA pg_cron — idempotente (desagenda si ya existían, evita duplicar al re-aplicar). DB = 'postgres'.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
select cron.unschedule('riz-recompute-semanal') where exists (select 1 from cron.job where jobname='riz-recompute-semanal');
select cron.unschedule('riz-lista-compras')     where exists (select 1 from cron.job where jobname='riz-lista-compras');

-- DOM 23:00 Lima (= LUN 04:00 UTC) → recompute del esperado + materializar la cola diaria de la semana entrante.
select cron.schedule('riz-recompute-semanal', '0 4 * * 1', $$ select me.cron_riz_recompute_semanal(); $$);

-- LUN 06:00 Lima (= LUN 11:00 UTC, 7h tras el recompute) → materializar la lista de compras externa de la semana.
select cron.schedule('riz-lista-compras', '0 11 * * 1', $$ select me.cron_riz_lista_compras(); $$);

-- Quedan ACTIVOS (ver cabecera: su efecto es inerte porque nadie lee las tablas RIZ todavía).
