-- 787 · Fix chip amo/esclavo: incluir sesiones CERRADAS del día. El par amo-esclavo de HOY
-- es info válida aunque el equipo ya se haya desconectado (Marcelo/Diego/Mia se veían sin chip
-- porque su extensión ya estaba CERRADA; Sergio sí, por seguir ACTIVO). Ahora se empareja por
-- todo el día. Se conserva el "último registro por device" (order by ultima_conexion) para
-- respetar un re-abrir como principal más tarde.
create or replace function mos.dispositivos_amo_esclavo(p jsonb default '{}'::jsonb)
returns jsonb
language sql
stable security definer
set search_path to ''
as $function$
  with hoy as (
    select a.device_id, a.es_principal, a.id_dia, d.app,
           row_number() over (partition by a.device_id order by a.ultima_conexion desc nulls last) rn
      from mos.accesos_dispositivos a
      join mos.dispositivos d on d.id_dispositivo = a.device_id
     where a.id_dia >= 'LDIA-' || to_char((now() at time zone 'America/Lima')::date, 'YYYYMMDD')
  ),
  ult as (select * from hoy where rn = 1),
  pares as (
    select u.device_id,
      case
        when not u.es_principal then 'ESCLAVO'
        when exists (
          select 1 from ult e
           where e.id_dia = u.id_dia and e.app = u.app
             and not e.es_principal and e.device_id <> u.device_id
        ) then 'AMO'
        else 'SOLO'
      end rol
    from ult u
  )
  select coalesce(jsonb_object_agg(device_id, rol), '{}'::jsonb) from pares where rol <> 'SOLO';
$function$;
