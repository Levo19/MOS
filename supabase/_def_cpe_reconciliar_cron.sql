CREATE OR REPLACE FUNCTION me.cpe_reconciliar_cron()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    body    := jsonb_build_object('dias', 45, 'limite', 80)
  ) into v_req;
  return v_req;
end;
$function$
