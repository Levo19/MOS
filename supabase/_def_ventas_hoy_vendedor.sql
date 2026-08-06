CREATE OR REPLACE FUNCTION me.ventas_hoy_vendedor(p_vendedor text DEFAULT NULL::text, desde_str text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with guard as (select me.jwt_app() = 'mosExpress' as ok),
  params as (
    select
      greatest(
        case when desde_str is not null and btrim(desde_str)<>'' then btrim(desde_str)::timestamptz
             else (now() at time zone 'America/Lima')::date::timestamptz end,
        ((now() at time zone 'America/Lima')::date - 2)::timestamptz
      ) as desde,
      nullif(btrim(coalesce(p_vendedor,'')),'') as vend
  ),
  filt as (
    select v.*
    from me.ventas v, params p, guard g
    where g.ok
      and v.fecha >= p.desde
      -- fail-closed: sin vendedor ⇒ 0 filas (no exponemos las de otros)
      and p.vend is not null and lower(btrim(coalesce(v.vendedor,''))) = lower(p.vend)
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
        'nf_estado', coalesce(nf_estado,''),
        'ref_local', coalesce(ref_local,''),
        'obs', coalesce(obs,'')
      ) order by fecha)
      from filt), '[]'::jsonb)
  );
$function$
