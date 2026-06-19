-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 191_riz_cola_diaria_refresca_semana_en_curso.sql
-- 🔴 BUG (verificado en prod, 2026-06-19, ZONA-02): el cron SEMANAL (riz-recompute-semanal, '0 4 * * 1' =
--    lunes 04:00 UTC = DOMINGO 23:00 Lima) materializa la cola de la SEMANA ENTRANTE con dos ventanas:
--      • rotacion/universo  → ventana ENTRANTE correcta (v_lunes_next-28 .. v_lunes_next-1)  ✅ (190)
--      • esperada/tendencia/picos → JOIN a me.zona_esperado (el SNAPSHOT) — pero en ese instante el snapshot
--        está anclado al lunes VIEJO (_riz_picos usa date_trunc('week', now Lima); domingo 23:00 → lunes-1sem),
--        ⇒ ventana 1 semana ATRASADA respecto de la cola que se está congelando.
--    Como la cola es JSON CONGELADO y el cron DIARIO (190) sólo refresca el snapshot (NO la cola), la cola de
--    la semana en curso queda con esperada/faltan calculadas sobre una ventana 4-ISO vieja durante TODA la semana.
--    Prueba: para semana 06-22, LEV1181 congeló esperada=63 cuando la ventana entrante correcta da 8; LEV197
--    congeló 4 cuando lo correcto es 11; LEV153/LEV1172 con esperada>0 pese a 0 ventas en la ventana entrante.
--    El UNIVERSO (set de skus) sí coincidía con el panel (probado, SIMDIFF=0) — el defecto es de CANTIDADES
--    (esperada/faltan), que es justo lo que decide la compra. SEVERIDAD 🔴 (dinero/decisión).
--
-- ✅ FIX (additivo, SOLO LECTURA salvo cola+snapshot; idempotente; no toca stock/dinero/sync/flags):
--    (1) Se extrae la construcción per-zona de la cola a un helper PARAMETRIZADO por el lunes ancla:
--        me._riz_materializar_cola(p_lunes date). Ventana de rotacion = p_lunes-28 .. p_lunes-1; partición de 7
--        días anclada a p_lunes; esperada/tendencia se toman de me.zona_esperado (ya fresco para ESA ventana
--        cuando el ancla = lunes en curso). Misma matemática/orden que 190 (rotacion desc, sku_base; ceil(n/7)).
--        Respeta ON CONFLICT: sólo PISA filas PENDIENTE (nunca REVISADA/IMPRESO/ajustes del admin).
--    (2) me.cron_riz_recompute_semanal ahora: recompute snapshot + materializar_cola(v_lunes_next) — igual que antes.
--    (3) El cron DIARIO pasa de "sólo recompute snapshot" a una función nueva me.cron_riz_recompute_diario():
--        recompute snapshot (ancla = lunes EN CURSO, ventana 4-ISO correcta de la semana en curso) + materializar
--        la cola de la SEMANA EN CURSO con ese mismo ancla. Así, aunque la cola se haya congelado el domingo con
--        ventana vieja, el lunes 02:07 Lima (y cada día) se REGENERAN las filas PENDIENTE de la semana en curso
--        con esperada/faltan de la ventana correcta. Self-healing: si el cron semanal falla, el diario igual cubre.
--    Resultado: la cola materializada de la semana EN CURSO == panel == on-the-fly (cantidades incluidas).
--    La cola de la semana ENTRANTE (creada el domingo) puede arrancar con cantidades de la ventana previa, pero
--    se corrige sola el lunes 02:07 cuando esa semana pasa a ser "en curso". Estable lun-dom.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── HELPER PARAMETRIZADO: materializa la cola de 7 días (LUN..DOM desde p_lunes) para todas las zonas activas ──
create or replace function me._riz_materializar_cola(p_lunes date)
returns int
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_desde      date := p_lunes - 28;   -- inicio 4-ISO-cerrada relativa a p_lunes
  v_hasta      date := p_lunes - 1;    -- fin 4-ISO-cerrada relativa a p_lunes
  v_total      int  := 0;
  r_z          record;
  v_es_almacen boolean;
  v_filas      int;
begin
  for r_z in
    select upper(btrim(z.id_zona)) as zona
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado,true) = true
    order by 1
  loop
    v_es_almacen := (r_z.zona = 'ALMACEN');

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
      from me._riz_ventas_base(v_desde, v_hasta) b
      where not v_es_almacen and b.zona_id = r_z.zona
      group by b.sku_base
    ),
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
      having sum(rotacion) > 0
    ),
    esp as (
      select e.sku_base, e.esperado, e.tendencia, e.picos
      from me.zona_esperado e where upper(btrim(e.zona_id)) = r_z.zona
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
             (row_number() over (order by f.rotacion desc, f.sku_base) - 1) as idx
      from filas f
    ),
    asignado as (
      select e.*,
             p_lunes + least((e.idx / greatest(ceil((select n from tot)::numeric / 7)::int, 1))::int, 6) as fecha
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
    v_total := v_total + coalesce(v_filas,0);
  end loop;

  return v_total;
end;
$fn$;
revoke all on function me._riz_materializar_cola(date) from public;

-- ── (A) CRON SEMANAL: recompute snapshot + materializar la SEMANA ENTRANTE (ancla = v_lunes_next) ───────────────
CREATE OR REPLACE FUNCTION me.cron_riz_recompute_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_lunes_next date := (date_trunc('week', (now() at time zone 'America/Lima'))::date) + 7;
  v_rec        jsonb;
  v_total_cola int;
begin
  v_rec := me.zona_esperado_recompute('{}'::jsonb);
  v_total_cola := me._riz_materializar_cola(v_lunes_next);

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

-- ── (B) CRON DIARIO: recompute snapshot (semana EN CURSO) + REFRESCAR la cola de la SEMANA EN CURSO ─────────────
--    Ancla = lunes EN CURSO (date_trunc week de hoy Lima). Cierra el desfase del snapshot domingo→lunes y
--    mantiene la cola en curso siempre coherente con el panel/on-the-fly. Self-healing si el semanal falla.
CREATE OR REPLACE FUNCTION me.cron_riz_recompute_diario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_lunes_act  date := (date_trunc('week', (now() at time zone 'America/Lima'))::date);
  v_rec        jsonb;
  v_total_cola int;
begin
  v_rec := me.zona_esperado_recompute('{}'::jsonb);
  v_total_cola := me._riz_materializar_cola(v_lunes_act);

  insert into mos.cron_log(job, ok, resultado)
  values ('riz_recompute_diario', coalesce((v_rec->>'ok')::boolean,false),
          jsonb_build_object('lunesEnCurso', to_char(v_lunes_act,'YYYY-MM-DD'),
                             'recompute', v_rec, 'colaFilas', v_total_cola, 'modo', 'refresca_semana_en_curso'));

  return jsonb_build_object('ok', true, 'recompute', v_rec, 'colaFilas', v_total_cola,
                            'lunesEnCurso', to_char(v_lunes_act,'YYYY-MM-DD'));
exception when others then
  insert into mos.cron_log(job, ok, resultado)
  values ('riz_recompute_diario', false, jsonb_build_object('excepcion', SQLERRM));
  return jsonb_build_object('ok', false, 'error', 'excepcion', 'detalle', SQLERRM);
end;
$function$;
revoke all on function me.cron_riz_recompute_diario() from public;

-- ── (C) Reapuntar el job diario al nuevo procedimiento (idempotente: unschedule por nombre, mismo horario) ──────
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'riz-recompute-diario';
    perform cron.schedule('riz-recompute-diario', '7 7 * * *', 'select me.cron_riz_recompute_diario();');
  end if;
end;
$cron$;
