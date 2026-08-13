-- 762 · OCR AUTOMÁTICO de comprobantes (12-ago-2026) — pedido del dueño: "cada vez que un
-- operador sube una foto a una guía de proveedor debe analizarse sola, así se cambie después".
-- Hallazgo de la auditoría de agosto: 25 de 26 guías con foto SIN OCR — el front solo lo
-- disparaba en la subida directa; la foto heredada del preingreso (el camino usual) no.
-- Piezas: (1) trigger marca PENDIENTE al cambiar la foto · (2) cron cada 10 min procesa
-- hasta 3 por tick vía Edge ocr-guia (control de gasto Vision; el backlog de agosto se
-- procesa solo en ~90 min) · (3) los botones del centro tributario se vuelven
-- RE-ENCOLADORES (marcan PENDIENTE, cero GAS, cero costo hasta que el cron pasa).

-- ═══ (1) trigger: foto nueva o cambiada → OCR pendiente ═══════════════════════
create or replace function wh._tg_guia_foto_ocr()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if coalesce(new.foto,'') <> '' and (tg_op = 'INSERT' or new.foto is distinct from old.foto) then
    new.ocr_estado := 'PENDIENTE';
  end if;
  return new;
end;
$function$;

drop trigger if exists tg_guia_foto_ocr on wh.guias;
create trigger tg_guia_foto_ocr
  before insert or update of foto on wh.guias
  for each row execute function wh._tg_guia_foto_ocr();

-- ═══ (2) cron: procesar pendientes vía Edge ocr-guia ══════════════════════════
create or replace function wh.cron_ocr_guias()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_sec text;
  v_g   record;
  v_n   int := 0;
begin
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'ocr_cron_secret' limit 1;
  if v_sec is null then return jsonb_build_object('ok', false, 'error', 'ocr_cron_secret no configurado'); end if;

  for v_g in
    select id_guia from wh.guias
     where coalesce(foto,'') <> ''
       and tipo like 'INGRESO%' and tipo <> 'INGRESO_DEVOLUCION_ZONA'   -- solo comprobantes de proveedor
       and (ocr_estado is null or ocr_estado = 'PENDIENTE')
     order by fecha desc
     limit 3                                                            -- control de gasto Vision por tick
  loop
    perform net.http_post(
      url     := 'https://rzbzdeipbtqkzjqdchqk.supabase.co/functions/v1/ocr-guia',
      -- [fix 401] la plataforma Edge valida la FIRMA del Authorization ANTES de nuestro código
      -- (verify_jwt) → anon bearer para pasar la puerta + x-ocr-cron como auth real (patrón push).
      headers := jsonb_build_object('Content-Type','application/json',
                   'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k',
                   'x-ocr-cron', v_sec),
      body    := jsonb_build_object('idGuia', v_g.id_guia)
    );
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'encolados', v_n);
end;
$function$;

do $do$
begin
  begin perform cron.unschedule('wh-ocr-guias'); exception when others then null; end;
  perform cron.schedule('wh-ocr-guias', '*/10 * * * *', 'select wh.cron_ocr_guias();');
end;
$do$;

-- ═══ (3) re-encoladores para los botones del centro tributario (cero-GAS) ════
-- El ↻ por guía y el "OCR masivo del mes" ya no llaman al bridge GAS: solo marcan
-- PENDIENTE y el cron server-side hace el trabajo (con su límite de gasto).
create or replace function wh.reencolar_ocr_guia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id text := nullif(btrim(coalesce(p->>'idGuia', p->>'id_guia','')),'');
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGuia'); end if;
  update wh.guias set ocr_estado = 'PENDIENTE' where id_guia = v_id and coalesce(foto,'') <> '';
  if not found then return jsonb_build_object('ok',false,'error','Guía sin foto (sube el comprobante primero)'); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('encolada',true,'nota','el OCR corre en ~10 min'));
end;
$function$;

create or replace function wh.reencolar_ocr_mes(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_mes  int := coalesce((p->>'mes')::int, extract(month from now() at time zone 'America/Lima')::int);
  v_anio int := coalesce((p->>'anio')::int, extract(year  from now() at time zone 'America/Lima')::int);
  v_solo boolean := coalesce((p->>'soloSinProcesar')::boolean, true);
  v_n int;
begin
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update wh.guias set ocr_estado = 'PENDIENTE'
   where coalesce(foto,'') <> ''
     and tipo like 'INGRESO%' and tipo <> 'INGRESO_DEVOLUCION_ZONA'
     and extract(month from (fecha at time zone 'America/Lima')) = v_mes
     and extract(year  from (fecha at time zone 'America/Lima')) = v_anio
     and (not v_solo or ocr_estado is null or ocr_estado in ('PENDIENTE','ILEGIBLE'));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('encoladas',v_n,'nota','el cron procesa 3 cada 10 min'));
end;
$function$;

revoke all on function wh.reencolar_ocr_guia(jsonb) from public;
revoke all on function wh.reencolar_ocr_mes(jsonb) from public;
grant execute on function wh.reencolar_ocr_guia(jsonb) to authenticated, service_role;
grant execute on function wh.reencolar_ocr_mes(jsonb) to authenticated, service_role;
