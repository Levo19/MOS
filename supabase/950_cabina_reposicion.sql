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
  -- por considerado (creado en ventana, no DESCARTADO): despacho computado por zona + primera SALIDA
  with base as (
    select c.id, c.sku_base, c.nombre, c.estado, c.creado, c.guia_tipo,
           coalesce(c.zonas,'[]'::jsonb) zonas
      from wh.considerados c
     where c.creado >= v_desde and upper(coalesce(c.estado,'')) <> 'DESCARTADO'
  ),
  zexp as (
    select b.id, b.sku_base, b.nombre, b.estado, b.creado, b.guia_tipo,
           (zz->>'zona') zona, (zz->>'pend')::numeric pend,
           ( select min(coalesce(gd.created_at, g.fecha))
               from wh.guias g
               join wh.guia_detalle gd on gd.id_guia = g.id_guia
               left join mos.productos     pr on btrim(coalesce(pr.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
               left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,'')) = btrim(coalesce(gd.cod_producto,''))
              where g.tipo like 'SALIDA%'
                and coalesce(g.id_zona,'') = (zz->>'zona')
                and coalesce(pr.sku_base, eq.sku_base) = b.sku_base
                and coalesce(gd.created_at, g.fecha) >= b.creado
                and upper(coalesce(gd.observacion,'')) not like 'ANULADO%' ) desp_ts
      from base b
      cross join lateral jsonb_array_elements(case when jsonb_typeof(b.zonas)='array' then b.zonas else '[]'::jsonb end) zz
  ),
  porcons as (   -- colapso a nivel considerado: ¿alguna zona despachada? + primera SALIDA global
    select id, max(sku_base) sku, max(nombre) nombre, max(estado) estado, max(creado) creado,
           bool_or(desp_ts is not null) desp_alguna,
           min(desp_ts) primera_salida,
           count(*) nz, count(*) filter (where desp_ts is not null) nz_desp,
           jsonb_agg(jsonb_build_object('zona', zona, 'pend', pend,
             'despachado', (desp_ts is not null),
             'despachadoTs', to_char(desp_ts at time zone 'America/Lima','YYYY-MM-DD"T"HH24:MI')) order by zona) zonas
      from zexp group by id
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
      'zonas', zonas) order by desp_alguna asc, creado asc ) filter (where true), '[]'::jsonb)
  into v_tot, v_desp, v_venc, v_horas, v_rows
  from porcons;

  -- fill-rate por zona (a nivel zona-considerado)
  with zexp as (
    select (zz->>'zona') zona,
           ( select 1 from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
               left join mos.productos pr on btrim(coalesce(pr.codigo_barra,''))=btrim(coalesce(gd.cod_producto,''))
               left join mos.equivalencias eq on btrim(coalesce(eq.codigo_barra,''))=btrim(coalesce(gd.cod_producto,''))
              where g.tipo like 'SALIDA%' and coalesce(g.id_zona,'')=(zz->>'zona')
                and coalesce(pr.sku_base,eq.sku_base)=c.sku_base
                and coalesce(gd.created_at,g.fecha)>=c.creado
                and upper(coalesce(gd.observacion,'')) not like 'ANULADO%' limit 1) hit
      from wh.considerados c
      cross join lateral jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz
     where c.creado>=v_desde and upper(coalesce(c.estado,''))<>'DESCARTADO'
  )
  select coalesce(jsonb_agg(jsonb_build_object('zona', zona, 'total', tot, 'despachados', des,
           'fillRatePct', case when tot>0 then round(des*100.0/tot) else 0 end) order by tot desc), '[]'::jsonb)
    into v_porzona
    from ( select zona, count(*) tot, count(*) filter (where hit=1) des from zexp group by zona ) q;

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
