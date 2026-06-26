-- ════════════════════════════════════════════════════════════════════════════
-- 237 · me.get_flags += MOS_SUNAT_EDGE (#6 cross-app: ME también resuelve DNI/RUC por Edge)
-- ════════════════════════════════════════════════════════════════════════════
-- ME (MosExpress) hace su PROPIO lookup SUNAT/RENIEC (buscarClienteAPI → su GAS → APISPeru).
-- Para que ME use el Edge `consultar-documento` (cero GAS) hay que exponerle el flag. ME lee
-- me.get_flags() (Content-Profile 'me') que devuelve las claves RAW de mos.config. Agrego
-- MOS_SUNAT_EDGE a la lista → ME lo lee como _serverFlags['MOS_SUNAT_EDGE'] ('1' = Edge).
-- Mismo key que MOS → un solo interruptor para todo el ecosistema. KILL-SWITCH global compartido.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function me.get_flags()
returns jsonb language sql stable security definer set search_path = '' as $function$
  select coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
  from mos.config
  where clave in ('ME_ESCRITURA_DIRECTA','ME_LECTURA_DIRECTA','ME_IMPRESION_DIRECTA','ME_CPE_DIRECTO','MOS_SUNAT_EDGE');
$function$;

revoke all on function me.get_flags() from public;
grant execute on function me.get_flags() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
