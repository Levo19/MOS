-- 397 · Presencia EN VIVO sin fantasmas (login ME + picker de extensión).
-- Problema: el CAJERO (corona) salía de me.cajas estado='ABIERTA' SIN caducidad → si la caja no se
-- cerraba limpio (app cerrada, red caída), el avatar quedaba "horas después de que se fue". Y los
-- vendedores tenían TTL 2 min (lento para desaparecer). Fix:
--   (1) el cajero solo aparece si TAMBIÉN tiene un pulso de presencia fresco (<90s) → mata el fantasma.
--   (2) TTL de vendedores 2min → 90s (con heartbeat cada 30s, aguanta 2 pulsos perdidos y desaparece rápido).
-- Cero-GAS. Mantiene la MISMA forma de salida (mapa por zona) que ya consume el wizard.

create or replace function me.presencia_por_zona()
returns jsonb language sql stable security definer set search_path='' as $function$
  with guard as (select me.jwt_app() = 'mosExpress' as ok),
  -- cajero por zona: caja ABIERTA más reciente, PERO solo si el cajero sigue "vivo" (pulso <90s).
  -- Sin pulso fresco = equipo apagado/ido → NO se muestra (era el fantasma de la corona).
  cajero as (
    select distinct on (c.zona_id)
           c.zona_id,
           c.vendedor as cajero_nombre,
           c.id_caja,
           c.fecha_apertura as desde
    from me.cajas c, guard g
    where g.ok and c.estado = 'ABIERTA' and coalesce(c.zona_id,'') <> ''
      and exists (
        select 1 from me.presencia pr
        where pr.zona = c.zona_id
          and lower(btrim(pr.nombre)) = lower(btrim(c.vendedor))
          and pr.last_seen > now() - interval '90 seconds'
      )
    order by c.zona_id, c.fecha_apertura desc
  ),
  -- vendedores presentes (TTL 90s), excluyendo al cajero de su propia zona (por nombre)
  vend as (
    select pr.zona,
           jsonb_agg(jsonb_build_object(
             'id_personal', pr.id_personal,
             'nombre',      pr.nombre,
             'estacion',    pr.estacion,
             'desde',       to_char(pr.last_seen at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
             'ingreso',     case when pr.ingreso is not null
                                 then to_char(pr.ingreso at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
                                 else null end
           ) order by pr.nombre) as lista
    from me.presencia pr
    cross join guard g
    left join cajero ca on ca.zona_id = pr.zona
    where g.ok
      and pr.last_seen > now() - interval '90 seconds'   -- TTL 90s (antes 2min): fantasmas se van rápido
      and coalesce(pr.zona,'') <> ''
      and lower(btrim(pr.nombre)) is distinct from lower(btrim(coalesce(ca.cajero_nombre,'')))
    group by pr.zona
  ),
  zonas as (
    select zona_id from cajero
    union
    select zona from vend
  )
  select coalesce(
    (select jsonb_object_agg(
       z.zona_id,
       jsonb_build_object(
         'zona_id',     z.zona_id,
         'zona_nombre', coalesce(mz.nombre, z.zona_id),
         'cajero', case when ca.zona_id is not null then jsonb_build_object(
                          'nombre',  ca.cajero_nombre,
                          'id_caja', ca.id_caja,
                          'desde',   to_char(ca.desde at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
                        ) else null end,
         'vendedores', coalesce(vd.lista, '[]'::jsonb)
       )
     )
     from zonas z
     left join cajero ca on ca.zona_id = z.zona_id
     left join vend   vd on vd.zona     = z.zona_id
     left join mos.zonas mz on mz.id_zona = z.zona_id
     where (select ok from guard)
    ),
    '{}'::jsonb
  );
$function$;

grant execute on function me.presencia_por_zona() to authenticated, service_role, anon;
