-- ============================================================================
-- 1012_regulador_master.sql — 🧿 REGULADOR (módulo solo-MASTER, pedido 02-sep)
-- ----------------------------------------------------------------------------
-- "Lo que el Master revisa periódicamente a los admins, automatizado": una RPC
-- devuelve la situación EN VIVO de los checkpoints por zona (ALMACEN/ZONA-01/ZONA-02).
-- El front pinta el semáforo + detalle y arma el reporte WhatsApp para el admin.
-- Secciones v1 (los puntos 4 y 5 del dueño incluidos):
--   P1 negativos          — stock < 0 (zonas: me.stock_zonas · almacén: wh.stock). Regla: no deben existir.
--   P2 consideradosStock  — (solo ALMACEN) considerados ACTIVOS con stock>0 y zonas aún sin despacho.
--   P3 mermasVencidas     — (ALMACEN) pendientes > SLA 3 días (mismo criterio del cron mermas_vencidas).
--   P4 devoluciones       — match por zona-DÍA (14d): guías SALIDA_DEVOLUCION_WH de la zona vs
--                           INGRESO_DEVOLUCION_ZONA de WH (ventana día..día+2) ítem por ítem (sku) +
--                           ¿se creó la merma? (wh.mermas ligada a esa guía o de esa zona en día..día+3).
--                           Estados: OK · DIFIERE · SIN_RECEPCION · y merma OK/PROCESADA/FALTA.
--   P5 auditorias         — zonas: me.auditorias 7d por día (conteos/operadores/con diferencia) +
--                           mos.evaluaciones de HOY (limpieza/checks por el admin). ALMACÉN: wh.auditorias 7d.
--   (P6 cuadrantes lo calcula el front con el MISMO clasificador de la vista Zona — no se duplica aquí.)
-- Solo lectura. Gate mos._claim_ok (panel MOS).
-- ============================================================================
create or replace function mos.regulador_reporte(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_zonas text[] := array['ALMACEN','ZONA-01','ZONA-02'];
  v_out jsonb := '{}'::jsonb;
  v_z  text;
  v_neg jsonb; v_cons jsonb; v_mer jsonb; v_dev jsonb; v_aud jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- P2 necesita el stock por sku del almacén (misma prep que considerados)
  perform wh._cons_prep();

  foreach v_z in array v_zonas loop
    -- ── P1 · negativos ──────────────────────────────────────────────────────
    if v_z = 'ALMACEN' then
      select jsonb_build_object('n', count(*), 'total', coalesce(round(sum(s.cantidad_disponible)::numeric,2),0),
        'items', coalesce(jsonb_agg(jsonb_build_object('cod', s.cod_producto,
                   'nombre', coalesce(nullif(pr.descripcion,''), s.cod_producto),
                   'cant', round(s.cantidad_disponible::numeric,2)) order by s.cantidad_disponible asc) filter (where s.rn <= 15), '[]'::jsonb))
      into v_neg
      from (select cod_producto, cantidad_disponible, row_number() over (order by cantidad_disponible asc) rn
              from wh.stock where coalesce(cantidad_disponible,0) < 0) s
      left join mos.productos pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''));
    else
      select jsonb_build_object('n', count(*), 'total', coalesce(round(sum(s.cantidad)::numeric,2),0),
        'items', coalesce(jsonb_agg(jsonb_build_object('cod', s.cod_barras,
                   'nombre', coalesce(nullif(pr.descripcion,''), s.cod_barras),
                   'cant', round(s.cantidad::numeric,2)) order by s.cantidad asc) filter (where s.rn <= 15), '[]'::jsonb))
      into v_neg
      from (select cod_barras, cantidad, row_number() over (order by cantidad asc) rn
              from me.stock_zonas where zona_id = v_z and cantidad < 0) s
      left join mos.productos pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_barras,''));
    end if;

    -- ── P2 · considerados con stock sin despachar (solo almacén) ───────────
    if v_z = 'ALMACEN' then
      with det as (
        select c.id, c.sku_base, c.nombre, c.creado,
               coalesce((select a.stock from pg_temp._alm a where a.sku = c.sku_base), 0) stock,
               (select coalesce(jsonb_agg(distinct jsonb_build_object('zona', e.zona, 'pend', e.pend)), '[]'::jsonb)
                  from (select zz->>'zona' zona, round(sum((zz->>'pend')::numeric),2) pend
                          from jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
                         where not exists (select 1 from pg_temp._sal s where s.sku = c.sku_base and s.zona = (zz->>'zona') and s.ts >= c.creado)
                         group by 1) e) zonas_pend
          from wh.considerados c where c.estado = 'ACTIVO'
      )
      select jsonb_build_object('n', count(*),
        'items', coalesce(jsonb_agg(jsonb_build_object('sku', d.sku_base, 'nombre', d.nombre,
                   'stock', round(d.stock::numeric,2), 'zonas', d.zonas_pend,
                   'dias', round((extract(epoch from (now() - d.creado)) / 86400)::numeric, 1))
                 order by (extract(epoch from (now() - d.creado))) desc) filter (where d.rn <= 15), '[]'::jsonb))
      into v_cons
      from (select *, row_number() over (order by creado asc) rn from det
             where stock > 0 and jsonb_array_length(zonas_pend) > 0) d;
    else v_cons := null; end if;

    -- ── P3 · mermas vencidas (SLA 3 días, mismo criterio del cron) ──────────
    if v_z = 'ALMACEN' then
      select jsonb_build_object('n', count(*),
        'items', coalesce(jsonb_agg(jsonb_build_object('id', m.id_merma, 'cod', m.cod_producto,
                   'nombre', coalesce(nullif(pr.descripcion,''), m.cod_producto),
                   'pend', round(coalesce(m.cantidad_pendiente,0)::numeric,2), 'estado', m.estado,
                   'dias', round((extract(epoch from (now() - m.fecha_ingreso)) / 86400)::numeric))
                 order by m.fecha_ingreso asc) filter (where m.rn <= 15), '[]'::jsonb))
      into v_mer
      from (select *, row_number() over (order by fecha_ingreso asc) rn from wh.mermas
             where coalesce(cantidad_pendiente,0) > 0 and fecha_ingreso < now() - interval '3 days') m
      left join mos.productos pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(m.cod_producto,''));
    else v_mer := null; end if;

    -- ── P4 · devoluciones zona→almacén (14d, match por zona-DÍA + merma) ───
    if v_z <> 'ALMACEN' then
      with me_dev as (
        select (g.fecha at time zone 'America/Lima')::date dia,
               coalesce(pr.sku_base, eq.sku_base, d.cod_barras) sku,
               max(coalesce(nullif(pr.descripcion,''), d.cod_barras)) nombre,
               sum(coalesce(d.cantidad_aplicada, d.cantidad, 0)) cant
          from me.guias_cabecera g
          join me.guias_detalle d on d.id_guia = g.id_guia
          left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(d.cod_barras,''))
          left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(d.cod_barras,''))
         where g.tipo = 'SALIDA_DEVOLUCION_WH' and g.zona_id = v_z
           and g.fecha >= now() - interval '14 days'
         group by 1, 2
      ),
      wh_dev as (
        select (g.fecha at time zone 'America/Lima')::date dia, g.id_guia,
               coalesce(pr.sku_base, eq.sku_base, d.cod_producto) sku,
               sum(coalesce(d.cant_recibida, d.cantidad_aplicada, 0)) cant
          from wh.guias g
          join wh.guia_detalle d on d.id_guia = g.id_guia
          left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(d.cod_producto,''))
          left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(d.cod_producto,''))
         where g.tipo = 'INGRESO_DEVOLUCION_ZONA' and coalesce(g.id_zona,'') = v_z
           and g.fecha >= now() - interval '17 days'
         group by 1, 2, 3
      ),
      dias as (
        select m.dia,
               sum(m.cant) piezas_zona,
               (select count(distinct g2.id_guia) from me.guias_cabecera g2
                 where g2.tipo = 'SALIDA_DEVOLUCION_WH' and g2.zona_id = v_z
                   and (g2.fecha at time zone 'America/Lima')::date = m.dia) guias_zona,
               (select coalesce(sum(w.cant),0) from wh_dev w where w.dia between m.dia and m.dia + 2) piezas_wh,
               (select coalesce(jsonb_agg(distinct w.id_guia),'[]'::jsonb) from wh_dev w where w.dia between m.dia and m.dia + 2) wh_guias,
               (select coalesce(jsonb_agg(jsonb_build_object('sku', m2.sku, 'nombre', m2.nombre,
                          'zona', round(m2.cant::numeric,2),
                          'wh', round(coalesce((select sum(w.cant) from wh_dev w where w.sku = m2.sku and w.dia between m.dia and m.dia + 2),0)::numeric,2))
                        order by m2.cant desc), '[]'::jsonb)
                  from me_dev m2 where m2.dia = m.dia
                   and abs(m2.cant - coalesce((select sum(w.cant) from wh_dev w where w.sku = m2.sku and w.dia between m.dia and m.dia + 2),0)) > 0.001) difs
          from me_dev m group by m.dia
      )
      select jsonb_build_object(
        'total', (select count(*) from dias),
        'sinRecepcion', (select count(*) from dias where piezas_wh <= 0),
        'difieren', (select count(*) from dias where piezas_wh > 0 and jsonb_array_length(difs) > 0),
        'sinMerma', (select count(*) from dias d2 where d2.piezas_wh > 0
                       and not exists (select 1 from wh.mermas mm
                             where (mm.id_guia in (select jsonb_array_elements_text(d2.wh_guias))
                                    or upper(coalesce(mm.origen,'')) = v_z)
                               and (mm.fecha_ingreso at time zone 'America/Lima')::date between d2.dia and d2.dia + 3)),
        'dias', coalesce((select jsonb_agg(jsonb_build_object(
                   'dia', to_char(d3.dia,'YYYY-MM-DD'), 'guias', d3.guias_zona,
                   'piezasZona', round(d3.piezas_zona::numeric,2), 'piezasWh', round(d3.piezas_wh::numeric,2),
                   'estado', case when d3.piezas_wh <= 0 then 'SIN_RECEPCION'
                                  when jsonb_array_length(d3.difs) > 0 then 'DIFIERE' else 'OK' end,
                   'merma', case
                     when exists (select 1 from wh.mermas mm
                            where (mm.id_guia in (select jsonb_array_elements_text(d3.wh_guias)) or upper(coalesce(mm.origen,'')) = v_z)
                              and (mm.fecha_ingreso at time zone 'America/Lima')::date between d3.dia and d3.dia + 3
                              and mm.estado in ('RESUELTA','DESECHADA')) then 'PROCESADA'
                     when exists (select 1 from wh.mermas mm
                            where (mm.id_guia in (select jsonb_array_elements_text(d3.wh_guias)) or upper(coalesce(mm.origen,'')) = v_z)
                              and (mm.fecha_ingreso at time zone 'America/Lima')::date between d3.dia and d3.dia + 3) then 'OK'
                     when d3.piezas_wh <= 0 then '—' else 'FALTA' end,
                   'difs', d3.difs) order by d3.dia desc) from dias d3), '[]'::jsonb))
      into v_dev;
    else v_dev := null; end if;

    -- ── P5 · auditorías del admin a su personal ─────────────────────────────
    if v_z = 'ALMACEN' then
      select jsonb_build_object(
        'alm', true,
        'asignadas7d', count(*),
        'ejecutadas', count(*) filter (where a.estado = 'EJECUTADA' or a.fecha_ejecucion is not null),
        'conDif', count(*) filter (where coalesce(a.diferencia,0) <> 0),
        'pendientes', count(*) filter (where a.estado <> 'EJECUTADA' and a.fecha_ejecucion is null),
        'operadores', (select coalesce(jsonb_agg(jsonb_build_object('op', q.usuario, 'n', q.n, 'conDif', q.cd) order by q.n desc), '[]'::jsonb)
                         from (select usuario, count(*)::int n, sum((coalesce(diferencia,0) <> 0)::int)::int cd
                                 from wh.auditorias where fecha_asignacion >= now() - interval '7 days' group by 1 limit 8) q))
      into v_aud from wh.auditorias a where a.fecha_asignacion >= now() - interval '7 days';
    else
      select jsonb_build_object(
        'alm', false,
        'dias', coalesce((select jsonb_agg(jsonb_build_object('dia', to_char(q.dia,'YYYY-MM-DD'), 'conteos', q.n,
                            'operadores', q.ops, 'conDif', q.cd) order by q.dia desc)
                  from (select (fecha at time zone 'America/Lima')::date dia, count(*)::int n,
                               count(distinct vendedor)::int ops, sum((coalesce(diferencia,0) <> 0)::int)::int cd
                          from me.auditorias where zona_id = v_z and fecha >= now() - interval '7 days'
                         group by 1) q), '[]'::jsonb),
        'hoyConteos', (select count(*) from me.auditorias
                        where zona_id = v_z and (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date),
        'operadores', (select coalesce(jsonb_agg(jsonb_build_object('op', q.vendedor, 'n', q.n, 'conDif', q.cd) order by q.n desc), '[]'::jsonb)
                         from (select vendedor, count(*)::int n, sum((coalesce(diferencia,0) <> 0)::int)::int cd
                                 from me.auditorias where zona_id = v_z and fecha >= now() - interval '7 days' group by 1 limit 8) q),
        'evalHoy', (select coalesce(jsonb_agg(jsonb_build_object('quien', e.evaluado_por, 'rol', e.rol,
                              'limpieza', e.limpieza_pct, 'limpiezaProf', e.limpieza_prof_pct,
                              'checks', (select count(*) from jsonb_each_text(coalesce(e.control_checks,'{}'::jsonb)) kv where kv.value = 'true'))), '[]'::jsonb)
                      from mos.evaluaciones e
                     where (e.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
                       and coalesce(e.activo, true)
                       -- zona del evaluado = su fila del día (mos.personal no tiene zona; liquidaciones_dia sí)
                       and exists (select 1 from mos.liquidaciones_dia ld
                                    where ld.id_personal = e.id_personal
                                      and (ld.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
                                      and upper(coalesce(ld.zona,'')) = v_z)))
      into v_aud;
    end if;

    v_out := v_out || jsonb_build_object(v_z, jsonb_build_object(
      'negativos', v_neg, 'considerados', v_cons, 'mermas', v_mer,
      'devoluciones', v_dev, 'auditorias', v_aud));
  end loop;

  return jsonb_build_object('ok', true,
    'ts', to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'zonas', v_out);
end $function$;
revoke all on function mos.regulador_reporte(jsonb) from public, anon;
grant execute on function mos.regulador_reporte(jsonb) to authenticated, service_role;
