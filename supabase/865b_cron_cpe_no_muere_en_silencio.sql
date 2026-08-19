-- 865b · El cron de CPE dejaba de correr a los 5 segundos y decía "succeeded".
--
-- me.cpe_reconciliar_cron llamaba a net.http_post SIN timeout → el default de pg_net es 5000 ms.
-- El reconciliador consulta NubeFact comprobante por comprobante; con 80 candidatos nunca entra
-- en 5 s. Verificado en vivo: la respuesta era `timed_out: true · "Timeout of 5000 ms reached"`.
-- Y `cron.job_run_details` decía **succeeded** en todas las corridas — porque http_post solo
-- ENCOLA y devuelve un id: el cron tenía éxito encolando. Por eso el tablero se veía sano
-- mientras 56 comprobantes se acumulaban sin llegar a SUNAT.
--
-- Acá: timeout de verdad, la respuesta se guarda en mos.cron_log (antes se descartaba), y el
-- reintento de emisión queda encendido — que es lo que convierte esto en una red de seguridad
-- en vez de un espejo.

begin;

create or replace function me.cpe_reconciliar_cron()
returns bigint
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_on text; v_sec text; v_req bigint;
  v_url text := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/reconciliar-cpe';
begin
  select valor into v_on from mos.config where clave = 'CPE_RECON_ON' limit 1;
  if coalesce(v_on,'0') <> '1' then return -1; end if;
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'cpe_cron_secret' limit 1;
  if v_sec is null then return -2; end if;
  select net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-cpe-cron', v_sec),
    -- reemitir: si un comprobante nunca llegó a NubeFact, se vuelve a mandar. El Edge solo
    -- reintenta los del DÍA EN CURSO: NubeFact no acepta otra fecha, y cambiarla movería el
    -- período fiscal — eso no lo decide un cron.
    body    := jsonb_build_object('dias', 45, 'limite', 80, 'reemitir', true),
    -- 240 s: 80 comprobantes × ~1-2 s de ida y vuelta a NubeFact, con aire.
    timeout_milliseconds := 240000
  ) into v_req;
  -- se anota el id para poder LEER la respuesta después; sin esto el resultado se perdía.
  insert into mos.cron_log (job, ok, resultado)
       values ('cpe-reconciliar', true, jsonb_build_object('request_id', v_req, 'estado','encolado'));
  return v_req;
end $$;

-- Recoge la respuesta de la corrida anterior y la deja legible en mos.cron_log. Corre unos
-- minutos después del reconciliador: sin esto, saber si funcionó exigía bucear en net._http_response.
create or replace function me.cpe_recon_recoger()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_id bigint; v_r record; v_j jsonb;
begin
  select (resultado->>'request_id')::bigint into v_id
    from mos.cron_log
   where job = 'cpe-reconciliar' and resultado->>'estado' = 'encolado'
   order by ts desc limit 1;
  if v_id is null then return jsonb_build_object('ok', true, 'nada', true); end if;

  select status_code, content, timed_out, error_msg into v_r
    from net._http_response where id = v_id;
  if not found then return jsonb_build_object('ok', true, 'aun_sin_respuesta', true); end if;

  begin v_j := v_r.content::jsonb; exception when others then v_j := null; end;

  update mos.cron_log
     set ok = (v_r.timed_out is not true and coalesce(v_r.status_code,0) = 200),
         resultado = jsonb_build_object(
           'request_id', v_id, 'estado', 'respondido',
           'http', v_r.status_code, 'timed_out', coalesce(v_r.timed_out,false),
           'error', left(coalesce(v_r.error_msg,''), 200),
           'revisados', v_j->'revisados', 'emitidos', v_j->'emitidos',
           'sin_cambio', v_j->'sin_cambio', 'detalle', v_j->'detalle')
   where job = 'cpe-reconciliar' and resultado->>'request_id' = v_id::text;

  return jsonb_build_object('ok', true, 'request_id', v_id, 'http', v_r.status_code,
                            'timed_out', coalesce(v_r.timed_out,false), 'emitidos', v_j->'emitidos');
end $$;

revoke all on function me.cpe_recon_recoger() from public, anon, authenticated;

commit;

-- ── los crones ────────────────────────────────────────────────────────────────
select cron.unschedule('cpe-recoger')  where exists (select 1 from cron.job where jobname='cpe-recoger');
select cron.unschedule('cpe-vigilar')  where exists (select 1 from cron.job where jobname='cpe-vigilar');

-- recoge la respuesta 12 min después del reconciliador (que corre al minuto 23)
select cron.schedule('cpe-recoger', '35 * * * *', 'select me.cpe_recon_recoger();');

-- LA ALARMA. Cada 15 min: si hay comprobantes sin llegar a SUNAT, avisa al MASTER por push.
-- Esto es lo que no existía — el sistema sabía y no se lo decía a nadie.
select cron.schedule('cpe-vigilar', '*/15 * * * *', 'select me.cpe_vigilar();');
