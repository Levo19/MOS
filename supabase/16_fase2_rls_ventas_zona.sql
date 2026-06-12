-- 16_fase2_rls_ventas_zona.sql — Piloto Fase 2: RPC que la PWA llama DIRECTO (rol authenticated),
-- derivando la zona del JWT (no de params del cliente → no falsificable). security definer + scoped.

-- Helper: zonas del JWT (claim 'zonas' que pone el mint-token). Fail-closed: sin claim → array vacío.
create or replace function me.jwt_zonas()
returns text[]
language sql stable
as $fn$
  select coalesce(
    array(select jsonb_array_elements_text(
      (nullif(current_setting('request.jwt.claims', true),'')::jsonb) -> 'zonas')),
    '{}'::text[]
  );
$fn$;

-- RPC piloto: ventas de HOY de la(s) zona(s) del dispositivo (deriva zona del JWT, ignora params del cliente).
-- security definer → lee me.ventas/me.cajas aunque authenticated NO tenga grants de tabla. Fail-closed por zona.
create or replace function me.ventas_hoy_zona_rls()
returns jsonb
language sql stable security definer
set search_path = ''
as $fn$
  with zz as (select me.jwt_zonas() as zonas),
  filt as (
    select v.*
    from me.ventas v
    join me.cajas c on c.id_caja = v.id_caja
    cross join zz
    where c.zona_id = any(zz.zonas)
      and to_char(v.fecha at time zone 'America/Lima','YYYY-MM-DD')
        = to_char(now()   at time zone 'America/Lima','YYYY-MM-DD')
  )
  select jsonb_build_object(
    'status','success',
    'zonas', (select zonas from zz),
    'ventas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id_venta', id_venta,
        'fecha', case when fecha is not null then to_char(fecha at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') else '' end,
        'vendedor', coalesce(vendedor,''),
        'cliente_nombre', coalesce(cliente_nombre,''),
        'total', coalesce(total,0),
        'tipo_doc', coalesce(tipo_doc,''),
        'forma_pago', coalesce(forma_pago,''),
        'correlativo', coalesce(correlativo,''),
        'id_caja', coalesce(id_caja,''),
        'status', coalesce(estado_envio,'')
      ) order by fecha)
      from filt), '[]'::jsonb)
  );
$fn$;

-- Grants: authenticated SOLO puede ejecutar esta RPC (NO leer tablas). public/anon nada.
revoke all on function me.jwt_zonas() from public;
revoke all on function me.ventas_hoy_zona_rls() from public;
grant execute on function me.ventas_hoy_zona_rls() to authenticated;
