-- [950] CABINA · motor de REPOSICIÓN & CONSIDERADOS — responde la pregunta del dueño:
-- "lo que se le debía a una zona, ¿se despachó o no?". El despacho NO está persistido como estado
-- (el front dejó de usar ✔/✕): se COMPUTA como en 933 → ¿hubo una guía SALIDA% de ese sku a esa zona,
-- posterior a `creado`, no anulada? Medimos el fill-rate por ese despacho REAL, no por `estado`.
-- Ventana móvil (default 30 días) porque los considerados no son semanales. Solo lectura.
create or replace function mos.cabina_reposicion(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_dias int := greatest(7, least(90, coalesce(nullif(p->>'dias','')::int, 30)));
  v_desde timestamptz := now() - make_interval(days => v_dias);
  v_lim int := greatest(1, least(300, coalesce(nullif(p->>'limite','')::int, 60)));
  v_rows jsonb; v_tot int; v_desp int; v_venc int; v_horas numeric; v_porzona jsonb;
begin
  -- ⚡ v2 (perf): en vez de una subconsulta correlada por cada considerado-zona (escaneaba
  -- guias×guia_detalle ~366 veces → 14s), armamos las SALIDAs de la ventana UNA sola vez y las
  -- unimos por hash join. Mismo resultado, ~15x más rápido.
  create temporary table _cz on commit drop as
    select c.id, c.sku_base, c.nombre, c.estado, c.creado,
           (zz->>'zona') zona, (zz->>'pend')::numeric pend
      from wh.considerados c
      cross join lateral jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
     where c.creado >= v_desde and upper(coalesce(c.estado,'')) <> 'DESCARTADO';

  create temporary table _sal on commit drop as
    select coalesce(pr.sku_base, eq.sku_base) sku, coalesce(g.id_zona,'') zona,
           coalesce(gd.created_at, g.fecha) ts
      from wh.guias g
      join wh.guia_detalle gd on gd.id_guia = g.id_guia
      left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
      left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
     where g.tipo like 'SALIDA%'
       and coalesce(gd.created_at, g.fecha) >= v_desde
       and upper(coalesce(gd.observacion,'')) not like 'ANULADO%'
       and coalesce(pr.sku_base, eq.sku_base) is not null;

  -- por considerado-zona: primera SALIDA posterior a `creado` (join, no subconsulta correlada)
  with matched as (
    select cz.id, cz.sku_base, cz.nombre, cz.estado, cz.creado, cz.zona, cz.pend,
           min(s.ts) desp_ts
      from _cz cz
      left join _sal s on s.sku = cz.sku_base and s.zona = cz.zona and s.ts >= cz.creado
     group by cz.id, cz.sku_base, cz.nombre, cz.estado, cz.creado, cz.zona, cz.pend
  ),
  porcons as (
    select id, max(sku_base) sku, max(nombre) nombre, max(estado) estado, max(creado) creado,
           bool_or(desp_ts is not null) desp_alguna,
           min(desp_ts) primera_salida,
           jsonb_agg(jsonb_build_object('zona', zona, 'pend', pend,
             'despachado', (desp_ts is not null),
             'despachadoTs', to_char(desp_ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')) order by zona) zonas
      from matched group by id
  )
  select
    count(*) , count(*) filter (where desp_alguna),
    count(*) filter (where upper(estado)='VENCIDO' and not desp_alguna),
    round(avg( extract(epoch from (primera_salida - creado))/3600.0 ) filter (where desp_alguna)::numeric, 1),
    coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'nombre', nombre, 'sku', sku, 'estado', estado,
      'creado', to_char(creado at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI'),
      'despachado', desp_alguna,
      'diasDesde', round(extract(epoch from (now()-creado))/86400.0)::int,
      'horasDespacho', case when desp_alguna then round(extract(epoch from (primera_salida-creado))/3600.0)::int end,
      'zonas', zonas) order by desp_alguna asc, creado asc ), '[]'::jsonb)
  into v_tot, v_desp, v_venc, v_horas, v_rows
  from porcons;

  -- fill-rate por zona (reusa el mismo join)
  select coalesce(jsonb_agg(jsonb_build_object('zona', zona, 'total', tot, 'despachados', des,
           'fillRatePct', case when tot>0 then round(des*100.0/tot) else 0 end) order by tot desc), '[]'::jsonb)
    into v_porzona
    from ( select cz.zona, count(*) tot, count(*) filter (where ex.hit) des
             from _cz cz
             left join lateral (select exists(select 1 from _sal s where s.sku=cz.sku_base and s.zona=cz.zona and s.ts>=cz.creado) hit) ex on true
            group by cz.zona ) q;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'ventanaDias', v_dias,
    'total', coalesce(v_tot,0), 'despachados', coalesce(v_desp,0),
    'pendientes', coalesce(v_tot,0) - coalesce(v_desp,0), 'vencidos', coalesce(v_venc,0),
    'fillRatePct', case when coalesce(v_tot,0)>0 then round(v_desp*100.0/v_tot) else 0 end,
    'horasMediaDespacho', v_horas,
    'porZona', v_porzona,
    'items', (select coalesce(jsonb_agg(x order by (x->>'despachado')::boolean asc, x->>'creado' asc), '[]'::jsonb)
                from (select value x from jsonb_array_elements(v_rows) limit v_lim) t) ));
end $function$;
grant execute on function mos.cabina_reposicion(jsonb) to authenticated, anon, service_role;

select 'cabina_reposicion listo' ok;
