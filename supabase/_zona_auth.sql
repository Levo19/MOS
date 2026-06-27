CREATE OR REPLACE FUNCTION me.ventas_hoy_zona_auth(prefijos_str text DEFAULT NULL::text, desde_str text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with guard as (select me.jwt_app() = 'mosExpress' as ok),  -- fail-closed: solo tokens de ME
  params as (
    select
      -- [Lote3-B · A3] piso duro: desde NO puede ser anterior a hace 2 días (Lima),
      -- aunque el cliente pida una fecha más vieja. greatest(pedido, piso).
      greatest(
        case when desde_str is not null and btrim(desde_str)<>'' then btrim(desde_str)::timestamptz
             else (now() at time zone 'America/Lima')::date::timestamptz end,
        ((now() at time zone 'America/Lima')::date - 2)::timestamptz
      ) as desde,
      case when prefijos_str is not null and btrim(prefijos_str)<>''
           then array(select replace(replace(btrim(p),'%','\%'),'_','\_') || '%' from unnest(string_to_array(prefijos_str, ',')) p)
           else null end as pref_like
  ),
  filt as (
    select v.*
    from me.ventas v, params p, guard g
    where g.ok
      and v.fecha >= p.desde
      -- [scope-ALTO] fail-closed: prefijos vacíos/null ⇒ 0 filas.
      and p.pref_like is not null and coalesce(v.correlativo,'') like any (p.pref_like)
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
$function$
