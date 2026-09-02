-- ============================================================================
-- 1014_regulador_negativos_huerfanos.sql — Congruencia EXACTA de negativos (02-sep)
-- ----------------------------------------------------------------------------
-- El dueño: "el banner dice 44 y el Regulador 49 / 192 vs 232 — no tiene chiste".
-- Diagnóstico (diff real contra mos.zona_panel): la diferencia son CÓDIGOS HUÉRFANOS —
-- stock negativo bajo códigos que NO existen en el catálogo (ni producto ni equivalencia):
--   · códigos con Ñ mal tipeada: stock 'WHSASUÑO001KG' vs catálogo 'WHSASUNO001KG'
--   · códigos muertos: PRE062, 00205, ids sueltos (LEV1342 como código de stock)
-- La vista NO puede mostrarlos → el banner nunca los cuenta. Regla nueva del P1:
--   'visibles'  = productos cuyo código negativo SÍ está vinculado al catálogo
--                 (productos.codigo_barra o equivalencia activa) → cuadra 1:1 con el banner.
--   'huerfanos' = códigos negativos SIN vínculo — invisibles en la vista, se listan aparte
--                 CON SUGERENCIA del código correcto (matching Ñ→N / N→Ñ).
-- Solo cambia P1 dentro de mos.regulador_reporte (el resto queda igual que 1013).
-- ============================================================================
create or replace function mos.regulador_reporte(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_zonas text[] := array['ALMACEN','ZONA-01','ZONA-02'];
  v_out jsonb := '{}'::jsonb;
  v_z  text;
  v_meta numeric;
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_neg jsonb; v_cons jsonb; v_mer jsonb; v_dev jsonb; v_aud jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  v_meta := coalesce(mos._numn((select valor from mos.config where clave='evalMetaAuditorias' limit 1)), 30);
  if v_meta is null or v_meta <= 0 then v_meta := 30; end if;

  perform wh._cons_prep();

  foreach v_z in array v_zonas loop
    -- ── P1 · negativos: VISIBLES (regla del banner) + HUÉRFANOS con sugerencia ──
    if v_z = 'ALMACEN' then
      with neg as (
        select s.cod_producto cod, s.cantidad_disponible cant,
               coalesce(pr.sku_base, eq.sku_base) sku,               -- SOLO vínculos reales del catálogo
               (pr.sku_base is not null or eq.sku_base is not null) vinc
          from wh.stock s
          left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
          left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,'')) and coalesce(eq.activo, true)
         where coalesce(s.cantidad_disponible,0) < 0
      ),
      vis as (select sku, sum(cant) cant, min(cod) cod from neg where vinc group by sku),
      hue as (
        select n.cod, n.cant,
               coalesce(
                 (select p2.codigo_barra from mos.productos p2
                   where translate(upper(btrim(p2.codigo_barra)),'Ñ','N') = translate(upper(btrim(n.cod)),'Ñ','N') limit 1),
                 (select e2.codigo_barra from mos.equivalencias e2
                   where translate(upper(btrim(e2.codigo_barra)),'Ñ','N') = translate(upper(btrim(n.cod)),'Ñ','N') and coalesce(e2.activo,true) limit 1),
                 (select p3.descripcion from mos.productos p3 where p3.id_producto = n.cod limit 1)) sug
          from neg n where not n.vinc
      )
      select jsonb_build_object(
        'n', (select count(*) from vis) + (select count(*) from hue),
        'activos', (select count(*) from vis),
        'ocultos', (select count(*) from hue),
        'total', coalesce((select round((sum(cant))::numeric,2) from neg),0),
        'items', coalesce((select jsonb_agg(jsonb_build_object('cod', g.cod, 'cant', round(g.cant::numeric,2), 'activo', true,
                   'nombre', coalesce(
                     (select p4.descripcion from mos.productos p4 where p4.sku_base = g.sku and p4.factor_conversion = 1 order by (p4.codigo_producto_base is null) desc limit 1),
                     g.cod)) order by g.cant asc)
                   from (select *, row_number() over (order by cant asc) rn from vis) g where g.rn <= 15), '[]'::jsonb),
        'huerfanos', coalesce((select jsonb_agg(jsonb_build_object('cod', h.cod, 'cant', round(h.cant::numeric,2), 'sug', h.sug)
                   order by h.cant asc) from (select *, row_number() over (order by cant asc) rn from hue) h where h.rn <= 15), '[]'::jsonb))
      into v_neg;
    else
      with neg as (
        select s.cod_barras cod, s.cantidad cant,
               coalesce(pr.sku_base, eq.sku_base) sku,
               (pr.sku_base is not null or eq.sku_base is not null) vinc
          from me.stock_zonas s
          left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_barras,''))
          left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_barras,'')) and coalesce(eq.activo, true)
         where s.zona_id = v_z and s.cantidad < 0
      ),
      vis as (select sku, sum(cant) cant, min(cod) cod from neg where vinc group by sku),
      hue as (
        select n.cod, n.cant,
               coalesce(
                 (select p2.codigo_barra from mos.productos p2
                   where translate(upper(btrim(p2.codigo_barra)),'Ñ','N') = translate(upper(btrim(n.cod)),'Ñ','N') limit 1),
                 (select e2.codigo_barra from mos.equivalencias e2
                   where translate(upper(btrim(e2.codigo_barra)),'Ñ','N') = translate(upper(btrim(n.cod)),'Ñ','N') and coalesce(e2.activo,true) limit 1),
                 (select p3.descripcion from mos.productos p3 where p3.id_producto = n.cod limit 1)) sug
          from neg n where not n.vinc
      )
      select jsonb_build_object(
        'n', (select count(*) from vis) + (select count(*) from hue),
        'activos', (select count(*) from vis),
        'ocultos', (select count(*) from hue),
        'total', coalesce((select round((sum(cant))::numeric,2) from neg),0),
        'items', coalesce((select jsonb_agg(jsonb_build_object('cod', g.cod, 'cant', round(g.cant::numeric,2), 'activo', true,
                   'nombre', coalesce(
                     (select p4.descripcion from mos.productos p4 where p4.sku_base = g.sku and p4.factor_conversion = 1 order by (p4.codigo_producto_base is null) desc limit 1),
                     g.cod)) order by g.cant asc)
                   from (select *, row_number() over (order by cant asc) rn from vis) g where g.rn <= 15), '[]'::jsonb),
        'huerfanos', coalesce((select jsonb_agg(jsonb_build_object('cod', h.cod, 'cant', round(h.cant::numeric,2), 'sug', h.sug)
                   order by h.cant asc) from (select *, row_number() over (order by cant asc) rn from hue) h where h.rn <= 15), '[]'::jsonb))
      into v_neg;
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

    -- ── P3 · mermas vencidas (SLA 3 días) ───────────────────────────────────
    if v_z = 'ALMACEN' then
      select jsonb_build_object('n', count(*),
        'items', coalesce(jsonb_agg(jsonb_build_object('id', m.id_merma, 'cod', m.cod_producto,
                   'nombre', coalesce(nullif(pr.descripcion,''),
                     (select p2.descripcion from mos.productos p2 where p2.sku_base = eq.sku_base and p2.factor_conversion = 1 limit 1),
                     m.cod_producto),
                   'pend', round(coalesce(m.cantidad_pendiente,0)::numeric,2), 'estado', m.estado,
                   'dias', round((extract(epoch from (now() - m.fecha_ingreso)) / 86400)::numeric))
                 order by m.fecha_ingreso asc) filter (where m.rn <= 15), '[]'::jsonb))
      into v_mer
      from (select *, row_number() over (order by fecha_ingreso asc) rn from wh.mermas
             where coalesce(cantidad_pendiente,0) > 0 and fecha_ingreso < now() - interval '3 days') m
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(m.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(m.cod_producto,'')) and coalesce(eq.activo, true);
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

    -- ── P5 · auditorías: meta POR OPERADOR POR DÍA (hoy / ayer / deuda) ─────
    if v_z = 'ALMACEN' then
      with cnt as (
        select upper(btrim(usuario)) op, (coalesce(fecha_ejecucion, fecha_asignacion) at time zone 'America/Lima')::date dia,
               count(*)::int n, sum((coalesce(diferencia,0) <> 0)::int)::int cd
          from wh.auditorias where fecha_asignacion >= now() - interval '7 days' group by 1, 2),
      pres as (
        select distinct upper(btrim(ld.nombre)) op, (ld.fecha at time zone 'America/Lima')::date dia
          from mos.liquidaciones_dia ld
         where upper(coalesce(ld.zona,'')) = 'ALMACEN' and ld.fecha >= now() - interval '7 days' and coalesce(ld.presente, false)),
      ops as (select op from cnt union select op from pres where exists (select 1 from cnt where cnt.op = pres.op)),
      agg as (
        select o.op,
          coalesce((select sum(n) from cnt where cnt.op = o.op), 0) tot,
          coalesce((select sum(cd) from cnt where cnt.op = o.op), 0) cds,
          coalesce((select n from cnt where cnt.op = o.op and cnt.dia = v_hoy), 0) hoy,
          coalesce((select n from cnt where cnt.op = o.op and cnt.dia = v_hoy - 1), 0) ayer,
          case when exists (select 1 from pres p where p.op = o.op)
               then (select coalesce(sum(greatest(0, v_meta - coalesce((select n from cnt where cnt.op = o.op and cnt.dia = p.dia), 0))), 0)
                       from pres p where p.op = o.op and p.dia < v_hoy)
               else (select coalesce(sum(greatest(0, v_meta - n)), 0) from cnt where cnt.op = o.op and cnt.dia < v_hoy)
          end deuda
        from ops o)
      select jsonb_build_object('alm', true, 'meta', v_meta,
        'asignadas7d', (select count(*) from wh.auditorias where fecha_asignacion >= now() - interval '7 days'),
        'ejecutadas', (select count(*) from wh.auditorias where fecha_asignacion >= now() - interval '7 days' and (estado = 'EJECUTADA' or fecha_ejecucion is not null)),
        'conDif', (select count(*) from wh.auditorias where fecha_asignacion >= now() - interval '7 days' and coalesce(diferencia,0) <> 0),
        'pendientes', (select count(*) from wh.auditorias where fecha_asignacion >= now() - interval '7 days' and estado <> 'EJECUTADA' and fecha_ejecucion is null),
        'operadores', coalesce((select jsonb_agg(jsonb_build_object('op', initcap(lower(a.op)), 'hoy', a.hoy, 'ayer', a.ayer,
                        'n', a.tot, 'conDif', a.cds, 'deuda', a.deuda) order by a.deuda desc, a.tot desc) from agg a), '[]'::jsonb))
      into v_aud;
    else
      with cnt as (
        select upper(btrim(vendedor)) op, (fecha at time zone 'America/Lima')::date dia,
               count(*)::int n, sum((coalesce(diferencia,0) <> 0)::int)::int cd
          from me.auditorias where zona_id = v_z and fecha >= now() - interval '7 days' group by 1, 2),
      pres as (
        select distinct upper(btrim(ld.nombre)) op, (ld.fecha at time zone 'America/Lima')::date dia
          from mos.liquidaciones_dia ld
         where upper(coalesce(ld.zona,'')) = v_z and ld.fecha >= now() - interval '7 days' and coalesce(ld.presente, false)),
      ops as (select op from cnt union select op from pres where exists (select 1 from cnt where cnt.op = pres.op)),
      agg as (
        select o.op,
          coalesce((select sum(n) from cnt where cnt.op = o.op), 0) tot,
          coalesce((select sum(cd) from cnt where cnt.op = o.op), 0) cds,
          coalesce((select n from cnt where cnt.op = o.op and cnt.dia = v_hoy), 0) hoy,
          coalesce((select n from cnt where cnt.op = o.op and cnt.dia = v_hoy - 1), 0) ayer,
          case when exists (select 1 from pres p where p.op = o.op)
               then (select coalesce(sum(greatest(0, v_meta - coalesce((select n from cnt where cnt.op = o.op and cnt.dia = p.dia), 0))), 0)
                       from pres p where p.op = o.op and p.dia < v_hoy)
               else (select coalesce(sum(greatest(0, v_meta - n)), 0) from cnt where cnt.op = o.op and cnt.dia < v_hoy)
          end deuda
        from ops o)
      select jsonb_build_object('alm', false, 'meta', v_meta,
        'dias', coalesce((select jsonb_agg(jsonb_build_object('dia', to_char(q.dia,'YYYY-MM-DD'), 'conteos', q.n,
                            'operadores', q.ops, 'conDif', q.cd) order by q.dia desc)
                  from (select dia, sum(n)::int n, count(distinct op)::int ops, sum(cd)::int cd from cnt group by 1) q), '[]'::jsonb),
        'hoyConteos', coalesce((select sum(n) from cnt where dia = v_hoy), 0),
        'operadores', coalesce((select jsonb_agg(jsonb_build_object('op', initcap(lower(a.op)), 'hoy', a.hoy, 'ayer', a.ayer,
                        'n', a.tot, 'conDif', a.cds, 'deuda', a.deuda) order by a.deuda desc, a.tot desc) from agg a), '[]'::jsonb),
        'evalHoy', (select coalesce(jsonb_agg(jsonb_build_object('quien', e.evaluado_por, 'rol', e.rol,
                              'limpieza', e.limpieza_pct, 'limpiezaProf', e.limpieza_prof_pct,
                              'checks', (select count(*) from jsonb_each_text(coalesce(e.control_checks,'{}'::jsonb)) kv where kv.value = 'true'))), '[]'::jsonb)
                      from mos.evaluaciones e
                     where (e.fecha at time zone 'America/Lima')::date = v_hoy
                       and coalesce(e.activo, true)
                       and exists (select 1 from mos.liquidaciones_dia ld
                                    where ld.id_personal = e.id_personal
                                      and (ld.fecha at time zone 'America/Lima')::date = v_hoy
                                      and upper(coalesce(ld.zona,'')) = v_z)))
      into v_aud;
    end if;

    v_out := v_out || jsonb_build_object(v_z, jsonb_build_object(
      'negativos', v_neg, 'considerados', v_cons, 'mermas', v_mer,
      'devoluciones', v_dev, 'auditorias', v_aud));
  end loop;

  return jsonb_build_object('ok', true,
    'ts', to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD"T"HH24:MI:SS'),
    'meta', v_meta,
    'zonas', v_out);
end $function$;
revoke all on function mos.regulador_reporte(jsonb) from public, anon;
grant execute on function mos.regulador_reporte(jsonb) to authenticated, service_role;
