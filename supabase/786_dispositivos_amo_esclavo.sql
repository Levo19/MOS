-- 786 · Roles amo/esclavo (principal/extensión) por dispositivo, para chip en el panel MOS.
-- Fuente: mos.accesos_dispositivos (es_principal + id_dia). id_dia = 'LDIA-<fecha>-<persona>',
-- así que MISMO id_dia = misma persona/día; la app la da mos.dispositivos. La relación
-- amo-esclavo es SIEMPRE dentro de la misma app (una caja ME con su extensión, etc.), NUNCA
-- entre apps distintas del mismo dueño (WH+ME+MosGo abiertos = 3 SOLO, sin relación).
-- Devuelve por dispositivo (con acceso HOY): 'AMO' (principal con al menos 1 esclavo),
-- 'ESCLAVO' (extensión), o 'SOLO' (principal sin extensión → no se chipea como par).
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
       and coalesce(a.estado,'') not in ('CERRADA','CERRADO')
  ),
  ult as (select * from hoy where rn = 1),
  -- ¿un principal tiene al menos un esclavo en su mismo id_dia + misma app? → es AMO real (par).
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

revoke all on function mos.dispositivos_amo_esclavo(jsonb) from public;
grant execute on function mos.dispositivos_amo_esclavo(jsonb) to authenticated, service_role;
