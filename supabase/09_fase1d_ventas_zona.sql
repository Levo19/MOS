-- ============================================================
-- 09_fase1d_ventas_zona.sql — Fase 1.D (canary) · función server-side de ventasHoyZona
-- ============================================================
-- Replica ventasHoyZona(prefijosStr, desdeStr) (Ventas.gs:435-483 de MosExpress).
-- Lee me.ventas (1 scan). Filtros:
--   · si desde_str (ISO) presente → fecha >= desde
--   · si no → fecha cae en HOY (fecha Lima = hoy Lima)
--   · si prefijos_str presente (CSV) → correlativo empieza con alguno (LIKE pref%)
-- Salida: {status, ventas:[15 campos]}. fecha en UTC ISO (toISOString); status=estado_envio; id_dispositivo=dispositivo_id.
-- Comparar con compararVentasHoyZonaME() (por id_venta, fecha a-segundo, varios escenarios).
-- ============================================================

create or replace function me.ventas_hoy_zona(prefijos_str text default null, desde_str text default null)
returns jsonb
language sql
stable
as $$
with params as (
  select
    case when desde_str is not null and btrim(desde_str)<>'' then btrim(desde_str)::timestamptz else null end as desde,
    case when prefijos_str is not null and btrim(prefijos_str)<>''
         -- replica split(',').map(trim) de GAS: NO descarta vacíos (prefijo '' → patrón '%' = pasa todo, como indexOf('')===0);
         -- escapa comodines LIKE %/_ para que el prefijo sea literal como indexOf
         then array(select replace(replace(btrim(p),'%','\%'),'_','\_') || '%' from unnest(string_to_array(prefijos_str, ',')) p)
         else null end as pref_like
),
filt as (
  select v.*
  from me.ventas v, params p
  where (
      (p.desde is not null and v.fecha >= p.desde)
      or
      (p.desde is null and to_char(v.fecha at time zone 'America/Lima','YYYY-MM-DD')
                         = to_char(now()    at time zone 'America/Lima','YYYY-MM-DD'))
    )
    and (p.pref_like is null or coalesce(v.correlativo,'') like any (p.pref_like))
)
select jsonb_build_object(
  'status','success',
  'ventas', coalesce((
     select jsonb_agg(jsonb_build_object(
       'id_venta',       id_venta,
       'fecha',          case when fecha is not null then to_char(fecha at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
       'vendedor',       coalesce(vendedor,''),
       'estacion',       coalesce(estacion,''),
       'cliente_doc',    coalesce(cliente_doc,''),
       'cliente_nombre', coalesce(cliente_nombre,''),
       'total',          coalesce(total,0),
       'tipo_doc',       coalesce(tipo_doc,''),
       'forma_pago',     coalesce(forma_pago,''),
       'correlativo',    coalesce(correlativo,''),
       'id_caja',        coalesce(id_caja,''),
       'id_dispositivo', coalesce(dispositivo_id,''),
       'status',         coalesce(estado_envio,''),
       'ref_local',      coalesce(ref_local,''),
       'obs',            coalesce(obs,'')
     ) order by fecha)
     from filt), '[]'::jsonb)
);
$$;

grant execute on function me.ventas_hoy_zona(text, text) to service_role;
