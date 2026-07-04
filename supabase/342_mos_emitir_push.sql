-- 342_mos_emitir_push.sql
-- [CERO-GAS crons] Emisor de push server-side (para pg_cron). Resuelve audiencia en el Edge `push`
-- (modo audiencia -> mos.push_tokens_para deduped) autenticando con el secret compartido (vault
-- push_cron_secret + header x-push-cron; == Edge PUSH_CRON_SECRET). Patrón identico a me.cpe_reconciliar_cron.
-- p = {audiencia:{roles/usuarios/apps}, titulo, cuerpo, data?}. Fire-and-forget (net.http_post async).
create or replace function mos.emitir_push(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_sec text;
  v_url text := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/push';
  v_anon text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
  v_req bigint;
begin
  if p->'audiencia' is null or nullif(btrim(coalesce(p->>'titulo','')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'audiencia+titulo requeridos');
  end if;
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'push_cron_secret' limit 1;
  if v_sec is null then return jsonb_build_object('ok', false, 'error', 'push_cron_secret no configurado'); end if;
  select net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_anon,'x-push-cron', v_sec),
    body    := jsonb_build_object('op','send','audiencia', p->'audiencia','title', p->>'titulo','body', coalesce(p->>'cuerpo',''),'data', p->'data')
  ) into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req);
end; $fn$;
revoke all on function mos.emitir_push(jsonb) from public, anon;
grant execute on function mos.emitir_push(jsonb) to service_role;
