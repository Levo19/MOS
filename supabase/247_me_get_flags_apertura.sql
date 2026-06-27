-- ════════════════════════════════════════════════════════════════════════════
-- 247 · me.get_flags += ME_APERTURA_DIRECTO (+ ME_CIERRE_DIRECTO) — REPARACIÓN #1
-- ════════════════════════════════════════════════════════════════════════════
-- Para que la apertura de caja DIRECTA (me.abrir_caja, SQL 246) se pueda prender con UN solo
-- interruptor server-side (mos.config.ME_APERTURA_DIRECTO='1') que llegue a TODOS los dispositivos
-- ME, hay que exponer el flag por me.get_flags() (Content-Profile 'me'); el front lo lee como
-- _serverFlags['ME_APERTURA_DIRECTO']. Hoy NO estaba en el whitelist → un flip en mos.config no
-- llegaba a ME (solo funcionaba por localStorage per-device). Agrego ME_APERTURA_DIRECTO.
--
-- Aprovecho para incluir ME_CIERRE_DIRECTO, que estaba huérfano del control server-side por la misma
-- razón (la 237 no lo incluyó). SEGURO: el front usa _flagOn = (_serverFlags[k]==='1' || localStorage===…),
-- es un OR puro → exponer el valor server '0' NO desactiva a un dispositivo que ya lo tenga en local '1'.
-- Ambos quedan en '0' (inertes); el comportamiento vivo no cambia hasta el flip explícito.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function me.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $function$
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
  from mos.config
  where clave in ('ME_ESCRITURA_DIRECTA','ME_LECTURA_DIRECTA','ME_IMPRESION_DIRECTA',
                  'ME_CPE_DIRECTO','MOS_SUNAT_EDGE','ME_APERTURA_DIRECTO','ME_CIERRE_DIRECTO');
$function$;

revoke all on function me.get_flags() from public;
grant execute on function me.get_flags() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
