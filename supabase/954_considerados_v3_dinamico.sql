-- [954] CONSIDERADOS v3 — dinámico, por prioridad, sin borrado a 7 días.
-- Modelo (pedido del dueño):
--  · Un considerado = producto que ALGUNA VEZ se debió de almacén a Z1/Z2, que NO está en el acumulado
--    de esta semana, pero del cual HAY stock en almacén. (creación: wh.considerados_barrer_stock, intacta).
--  · Ciclo: ACTIVO → (despachado a TODAS las zonas debidas) ATENDIDO (con sello, visible toda la semana) ·
--    stock de almacén cae a 0 → IMPOSIBLE (oculto; si vuelve el stock, reactiva) · YA NO se vence a 7 días.
--  · Domingo noche: los ATENDIDOS de la semana se ARCHIVAN (historial) y salen de la lista; los pendientes
--    quedan. Un considerado debido a 2 zonas no se cierra hasta despachar a ambas.
--  · Prioridad BALANCEADA = deuda (Σpend) + stock en almacén + antigüedad (días), normalizados 0..1.
-- Perf: SALIDAs y stock de almacén se materializan UNA vez (temp) y se unen (no subconsulta correlada).

-- ── esquema ──
alter table wh.considerados add column if not exists atendido_ts timestamptz;
create table if not exists wh.considerados_historial (like wh.considerados including defaults);
alter table wh.considerados_historial add column if not exists archivado_ts timestamptz default now();

-- ── temp tables compartidas (SALIDAs 120d + stock almacén por sku), reusables en la misma transacción ──
create or replace function wh._cons_prep()
returns void language plpgsql security definer set search_path to '' as $function$
begin
  if to_regclass('pg_temp._sal') is null then
    create temporary table _sal on commit drop as
      select coalesce(pr.sku_base, eq.sku_base) sku, coalesce(g.id_zona,'') zona, coalesce(gd.created_at, g.fecha) ts
        from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
        left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
        left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
       where g.tipo like 'SALIDA%' and coalesce(gd.created_at, g.fecha) >= now() - interval '120 days'
         and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
         and coalesce(pr.sku_base, eq.sku_base) is not null;
    create index on _sal (sku, zona);
  end if;
  if to_regclass('pg_temp._alm') is null then
    create temporary table _alm on commit drop as
      select coalesce(pr.sku_base, eq.sku_base) sku, sum(greatest(0, coalesce(s.cantidad_disponible,0))) stock
        from wh.stock s
        left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
        left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(s.cod_producto,''))
       where coalesce(pr.sku_base, eq.sku_base) is not null group by 1;
    create index on _alm (sku);
  end if;
end $function$;

-- ── reconciliador: transiciones de estado dinámicas ──
create or replace function wh.considerados_reconciliar()
returns void language plpgsql security definer set search_path to '' as $function$
begin
  perform wh._cons_prep();
  drop table if exists _rc;
  create temporary table _rc on commit drop as
    select c.id, (zz->>'zona') zona,
           exists (select 1 from _sal s where s.sku = c.sku_base and s.zona = (zz->>'zona') and s.ts >= c.creado) hit
      from wh.considerados c
      cross join lateral jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
     where c.estado in ('ACTIVO','IMPOSIBLE');

  -- 1) ATENDIDO: todas las zonas debidas ya despachadas
  update wh.considerados c set estado='ATENDIDO', atendido_ts=coalesce(atendido_ts, now()), resuelto_ts=coalesce(resuelto_ts, now())
   where c.estado='ACTIVO' and c.id in (select id from _rc group by id having bool_and(hit) and count(*) > 0);
  -- 2) IMPOSIBLE: ACTIVO sin stock en almacén
  update wh.considerados c set estado='IMPOSIBLE'
   where c.estado='ACTIVO' and coalesce((select stock from _alm a where a.sku=c.sku_base),0) <= 0;
  -- 3) reactivar: IMPOSIBLE que volvió a tener stock y aún no despachado a todo
  update wh.considerados c set estado='ACTIVO'
   where c.estado='IMPOSIBLE' and coalesce((select stock from _alm a where a.sku=c.sku_base),0) > 0
     and c.id not in (select id from _rc group by id having bool_and(hit) and count(*) > 0);
end $function$;
grant execute on function wh.considerados_reconciliar() to authenticated, anon, service_role;

-- ── archivo dominical: mueve los ATENDIDOS de la semana al historial ──
create or replace function wh.considerados_archivar_dom()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_n int;
begin
  insert into wh.considerados_historial select c.*, now() from wh.considerados c where c.estado='ATENDIDO';
  get diagnostics v_n = row_count;
  delete from wh.considerados where estado='ATENDIDO';
  return jsonb_build_object('ok', true, 'archivados', v_n);
end $function$;
grant execute on function wh.considerados_archivar_dom() to authenticated, anon, service_role;

-- ── listado v3: reconcilia, ordena PENDIENTES por prioridad balanceada, separa ATENDIDOS (sello) ──
create or replace function wh.considerados_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_lim int := greatest(1, least(300, coalesce((p->>'limite')::int, 120)));
  v_pend jsonb; v_atn jsonb;
begin
  perform wh.considerados_reconciliar();   -- deja _sal/_alm listos y estados frescos (ya NO se vence a 7 días)

  drop table if exists _cm;
  create temporary table _cm on commit drop as
    select c.id, c.sku_base, c.nombre, c.cant_ingresada, c.guia_tipo, c.id_guia, c.creado, c.zonas,
           coalesce((select sum((zz->>'pend')::numeric) from jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz),0) deuda,
           coalesce((select stock from _alm a where a.sku=c.sku_base),0) stock,
           greatest(0, extract(epoch from (now()-c.creado))/86400.0) dias
      from wh.considerados c where c.estado='ACTIVO';

  with mx as (select greatest(max(deuda),1) d, greatest(max(stock),1) s, greatest(max(dias),1) di from _cm)
  select coalesce(jsonb_agg(x order by (x->>'prioridad')::numeric desc, (x->>'dias')::numeric desc), '[]'::jsonb) into v_pend
    from (
      select jsonb_build_object(
        'id', m.id, 'skuBase', m.sku_base, 'nombre', m.nombre, 'cant', m.cant_ingresada,
        'guiaTipo', m.guia_tipo, 'idGuia', m.id_guia,
        'foto', (select pr.foto_url from mos.productos pr where pr.sku_base=m.sku_base and nullif(btrim(pr.foto_url),'') is not null limit 1),
        'creado', to_char(m.creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
        'dias', round(m.dias::numeric,1), 'deuda', round(m.deuda,2), 'stock', round(m.stock,2),
        'prioridad', round((m.deuda/mx.d + m.stock/mx.s + m.dias/mx.di)::numeric, 3),
        -- zonas COLAPSADAS por zona (varias semanas → una sola línea), con su despacho
        'zonas', (select coalesce(jsonb_agg(jsonb_build_object('zona', t.zona, 'pend', round(t.pend,2), 'despachado', t.dts is not null, 'despachadoTs', t.dts) order by t.pend desc), '[]'::jsonb)
                    from (select zona, sum(pend) pend, max(dts) dts
                            from (select zz->>'zona' zona, (zz->>'pend')::numeric pend,
                                    (select to_char(max(s.ts) at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI') from _sal s where s.sku=m.sku_base and s.zona=(zz->>'zona') and s.ts>=m.creado) dts
                                   from jsonb_array_elements(case when jsonb_typeof(m.zonas)='array' then m.zonas else '[]'::jsonb end) zz) e
                           group by zona) t)
      ) x
      from _cm m cross join mx limit v_lim
    ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'skuBase', c.sku_base, 'nombre', c.nombre,
           'atendidoTs', to_char(c.atendido_ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
           'zonas', (select coalesce(jsonb_agg(distinct zz->>'zona'),'[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz)
         ) order by c.atendido_ts desc), '[]'::jsonb)
    into v_atn from wh.considerados c where c.estado='ATENDIDO';

  return jsonb_build_object('ok', true, 'items', v_pend, 'pendientes', v_pend, 'atendidos', v_atn,
    'total', (select count(*) from wh.considerados where estado='ACTIVO'),
    'totalAtendidos', (select count(*) from wh.considerados where estado='ATENDIDO'));
end $function$;
grant execute on function wh.considerados_listar(jsonb) to authenticated, anon, service_role;

select cron.schedule('wh-considerados-archivar-dom', '0 4 * * 1', 'select wh.considerados_archivar_dom();')
  where not exists (select 1 from cron.job where jobname='wh-considerados-archivar-dom');

select 'considerados v3 listo' ok;
