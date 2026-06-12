-- 16_fase2_rls_ventas_zona.sql — Piloto Fase 2: RPC que la PWA llama DIRECTO (rol authenticated).
-- MODELO: autorización por DISPOSITIVO registrado (UUID), NO por zona — los dispositivos/empleados ROTAN
-- entre zonas. La zona la pone el turno (qué caja abre); el dispositivo pasa los prefijos de su estación,
-- igual que el path GAS. Defensa: el JWT debe ser de app=mosExpress (un dispositivo WH no puede leer ME).

-- Limpieza del intento anterior (scoping por zona, descartado).
drop function if exists me.ventas_hoy_zona_rls();

-- Helper: claim 'app' del JWT (fail-closed: '' si no hay token/claim).
create or replace function me.jwt_app()
returns text language sql stable as $fn$
  select coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb) ->> 'app', '');
$fn$;

-- RPC piloto para la PWA: ventas de HOY de la estación (prefijos como el path GAS). Autorización = token de
-- dispositivo mosExpress válido. security definer → lee me.ventas aunque authenticated no tenga grants de tabla.
create or replace function me.ventas_hoy_zona_auth(prefijos_str text default null, desde_str text default null)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with guard as (select me.jwt_app() = 'mosExpress' as ok),  -- fail-closed: solo tokens de ME
  params as (
    select
      case when desde_str is not null and btrim(desde_str)<>'' then btrim(desde_str)::timestamptz else null end as desde,
      case when prefijos_str is not null and btrim(prefijos_str)<>''
           then array(select replace(replace(btrim(p),'%','\%'),'_','\_') || '%' from unnest(string_to_array(prefijos_str, ',')) p)
           else null end as pref_like
  ),
  filt as (
    select v.*
    from me.ventas v, params p, guard g
    where g.ok
      and ( (p.desde is not null and v.fecha >= p.desde)
            or (p.desde is null and to_char(v.fecha at time zone 'America/Lima','YYYY-MM-DD')
                                  = to_char(now()   at time zone 'America/Lima','YYYY-MM-DD')) )
      and (p.pref_like is null or coalesce(v.correlativo,'') like any (p.pref_like))
  )
  select jsonb_build_object(
    'status','success',
    'ventas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id_venta', id_venta,
        'fecha', case when fecha is not null then to_char(fecha at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
        'vendedor', coalesce(vendedor,''),
        'cliente_doc', coalesce(cliente_doc,''),
        'cliente_nombre', coalesce(cliente_nombre,''),
        'total', coalesce(total,0),
        'tipo_doc', coalesce(tipo_doc,''),
        'forma_pago', coalesce(forma_pago,''),
        'correlativo', coalesce(correlativo,''),
        'id_caja', coalesce(id_caja,''),
        'status', coalesce(estado_envio,''),
        'ref_local', coalesce(ref_local,''),
        'obs', coalesce(obs,'')
      ) order by fecha)
      from filt), '[]'::jsonb)
  );
$fn$;

revoke all on function me.ventas_hoy_zona_auth(text, text) from public;
grant execute on function me.ventas_hoy_zona_auth(text, text) to authenticated;
