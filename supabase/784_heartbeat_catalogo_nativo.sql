-- 784 · URGENTE: heartbeat del catálogo huérfano tras el funeral GAS (14-ago-2026).
-- CATALOGO_SYNC_HEARTBEAT lo bumpeaba el sync GAS (dual-write). Con el entierro
-- (deployments eliminados 07:44Z) nadie lo actualiza → a las 10:39Z venció el TTL
-- (180 min) y productos_master_rls/_delta devuelven _fresh=false → el front
-- fail-closea y los dispositivos quedan pegados a su caché local ("demoran en
-- cargar productos"). Hoy la sombra ES la única verdad (escritura directa pura),
-- así que el latido nativo debe cubrir también el catálogo.
begin;

create or replace function mos.cron_heartbeat_nativo()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_iso text := to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  insert into mos.config (clave, valor, descripcion) values
    ('MOS_SYNC_HEARTBEAT', v_iso, 'Latido NATIVO (pg_cron mos-heartbeat-nativo): sombras DIRECTO-PURAS — la sombra ES la verdad.')
  on conflict (clave) do update set valor = excluded.valor;
  -- [784 · post-funeral GAS] El catálogo también es directo-puro: el latido nativo lo cubre.
  insert into mos.config (clave, valor, descripcion) values
    ('CATALOGO_SYNC_HEARTBEAT', v_iso, 'Latido NATIVO del catálogo (784): mos.productos es la única verdad desde el funeral GAS 14-ago; antes lo bumpeaba el sync GAS (muerto).')
  on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok', true, 'heartbeat', v_iso);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$function$;

-- Bump inmediato (no esperar al próximo tick de 10 min): los dispositivos recuperan
-- el catálogo fresco YA.
select mos.cron_heartbeat_nativo();

commit;
