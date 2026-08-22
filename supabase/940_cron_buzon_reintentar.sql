-- [940 · BUZÓN IGV] cron que reanuda las facturas PENDIENTE del buzón: dispara la Edge buzon-igv en modo
-- reintento (baja la imagen guardada y re-OCRea). Mismo patrón que wh.cron_ocr_guias: anon bearer para pasar
-- la puerta de la plataforma + x-ocr-cron como auth real (reusa el secret ocr_cron_secret del vault).
-- El OCR de tributos es vital → aunque hoy no haya cupo, la factura ya está guardada y esto la termina sola.
create or replace function wh.cron_buzon_reintentar()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_sec text; v_r record; v_n int := 0;
begin
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'ocr_cron_secret' limit 1;
  if v_sec is null then return jsonb_build_object('ok', false, 'error', 'ocr_cron_secret no configurado'); end if;
  for v_r in
    select id_buzon, foto from wh.igv_buzon
     where ocr_estado = 'PENDIENTE' and coalesce(foto,'') <> '' and coalesce(ocr_intentos,0) < 6
     order by ts asc
     limit 3                                                            -- control de gasto Vision por tick
  loop
    perform net.http_post(
      url     := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/buzon-igv',
      headers := jsonb_build_object('Content-Type','application/json',
                   'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k',
                   'x-ocr-cron', v_sec),
      body    := jsonb_build_object('modo','reintento','idBuzon', v_r.id_buzon, 'foto', v_r.foto)
    );
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'disparadas', v_n);
end $function$;

-- agendar cada 10 min (min 4,14,… — offset de descripcion 3,33 y ocr-guia 9,19,…)
select cron.schedule('buzon-igv-reintentar', '4,14,24,34,44,54 * * * *', $$ select wh.cron_buzon_reintentar(); $$)
where not exists (select 1 from cron.job where jobname = 'buzon-igv-reintentar');

select 'cron buzon-igv-reintentar listo' as ok;
