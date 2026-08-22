-- [939 · BUZÓN IGV cola de pendientes] El OCR de tributos es VITAL: la factura debe guardarse SIEMPRE y
-- procesarse sola apenas haya cupo de IA (nunca perderse ni depender de reintento manual). Flujo nuevo:
--   subir imagen → crear fila PENDIENTE (sin OCR) → intentar OCR → si hay cupo se aplica; si no, queda
--   PENDIENTE y el cron wh.cron_buzon_reintentar (940) la reanuda. Aprovecha el token: espera y ejecuta.
-- Estados: ocr_estado='PENDIENTE' (aún sin leer) → 'PROCESADO'/'SIN_IGV'/'ILEGIBLE'/'NO_COMPROBANTE' (leído).
--          estado (negocio) queda 'PENDIENTE' hasta que el OCR se aplica y lo reclasifica (VALIDA/SIN_IGV/…).

-- contador de intentos de OCR (corta el bucle si una imagen nunca se puede leer; sin_cupo NO cuenta)
alter table wh.igv_buzon add column if not exists ocr_intentos int not null default 0;

-- ── 1) crear fila PENDIENTE apenas se sube la imagen (sin OCR todavía; sin dedup, que necesita datos leídos) ──
create or replace function mos.igv_buzon_pendiente_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_mes int; v_anio int; v_id text;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if nullif(btrim(coalesce(p->>'foto','')),'') is null then return jsonb_build_object('ok',false,'error','FALTA_FOTO'); end if;
  v_mes  := coalesce(mos._numn(p->>'mes')::int,  extract(month from (now() at time zone 'America/Lima'))::int);
  v_anio := coalesce(mos._numn(p->>'anio')::int, extract(year  from (now() at time zone 'America/Lima'))::int);
  insert into wh.igv_buzon (foto, mes, anio, ocr_estado, estado, subido_por, ocr_intentos)
  values (btrim(p->>'foto'), v_mes, v_anio, 'PENDIENTE', 'PENDIENTE', nullif(btrim(coalesce(p->>'usuario','')),''), 0)
  returning id_buzon into v_id;
  return jsonb_build_object('ok',true,'idBuzon',v_id,'estado','PENDIENTE');
end $function$;
grant execute on function mos.igv_buzon_pendiente_crear(jsonb) to authenticated, anon, service_role;

-- ── 2) aplicar el OCR a una fila existente: MISMA cascada de clasificación + dedup que igv_buzon_registrar,
--       pero como UPDATE de la fila PENDIENTE. Deja ocr_estado leído y estado (negocio) reclasificado. ──
create or replace function mos.igv_buzon_ocr_aplicar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_id       text := btrim(coalesce(p->>'idBuzon',''));
  v_ruc_emp  text := btrim(coalesce((select valor from mos.config where clave='EMPRESA_RUC' limit 1),''));
  v_emisor   text := btrim(coalesce(p->>'rucEmisor',''));
  v_cliente  text := btrim(coalesce(p->>'rucCliente',''));
  v_serie    text := upper(btrim(coalesce(p->>'serie','')));
  v_numero   text := btrim(coalesce(p->>'numero',''));
  v_tipo     text := upper(btrim(coalesce(p->>'tipoComprobante','')));
  v_ocr_est  text := upper(btrim(coalesce(p->>'estado','')));
  v_igv      numeric := coalesce(mos._numn(p->>'igv'), 0);
  v_estado text; v_dup text := null;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' or not exists (select 1 from wh.igv_buzon where id_buzon=v_id) then return jsonb_build_object('ok',false,'error','BUZON_NO_ENCONTRADO'); end if;

  -- clasificación en cascada (igual que igv_buzon_registrar)
  if v_ocr_est in ('ILEGIBLE','NO_COMPROBANTE') then
    v_estado := v_ocr_est;
  elsif v_tipo <> 'FACTURA' or v_igv <= 0 then
    v_estado := 'SIN_IGV';
  elsif v_ruc_emp <> '' and v_cliente <> '' and v_cliente <> v_ruc_emp then
    v_estado := 'NO_ES_NUESTRA';
  else
    if v_emisor <> '' and v_serie <> '' and v_numero <> '' then
      select id_guia into v_dup from wh.guias
       where upper(coalesce(tipo,'')) like 'INGRESO_PROVEEDOR%'
         and btrim(coalesce(ocr_ruc_emisor,'')) = v_emisor
         and upper(btrim(coalesce(ocr_serie,''))) = v_serie
         and btrim(coalesce(ocr_numero,'')) = v_numero
       limit 1;
      if v_dup is null then
        select id_buzon into v_dup from wh.igv_buzon
         where id_buzon <> v_id
           and btrim(coalesce(ruc_emisor,'')) = v_emisor
           and upper(btrim(coalesce(serie,''))) = v_serie
           and btrim(coalesce(numero,'')) = v_numero
           and estado not in ('DUPLICADA','PENDIENTE')
         limit 1;
      end if;
    end if;
    v_estado := case when v_dup is not null then 'DUPLICADA' else 'VALIDA' end;
  end if;

  update wh.igv_buzon set
    ruc_emisor = v_emisor, razon_social = nullif(btrim(coalesce(p->>'razonSocial','')),''),
    ruc_cliente = v_cliente, serie = v_serie, numero = v_numero,
    fecha_comprobante = nullif(btrim(coalesce(p->>'fecha','')),''),
    total = coalesce(mos._numn(p->>'total'),0), igv = v_igv, tipo_comprobante = v_tipo,
    confidence = coalesce(mos._numn(p->>'confidence')::int,0),
    ocr_estado = coalesce(nullif(v_ocr_est,''),'PROCESADO'), estado = v_estado, dup_ref = v_dup,
    notas = nullif(btrim(coalesce(p->>'notas','')),'')
  where id_buzon = v_id;

  return jsonb_build_object('ok',true,'idBuzon',v_id,'estado',v_estado,'dupRef',v_dup,
    'igv', case when v_estado='VALIDA' then v_igv else 0 end);
end $function$;
grant execute on function mos.igv_buzon_ocr_aplicar(jsonb) to authenticated, anon, service_role;

-- ── 3) listar las pendientes para el cron (id + foto path; NO incrementa: sin_cupo debe poder reintentar sin tope) ──
create or replace function mos.igv_buzon_pendientes(p jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $function$
  select coalesce(jsonb_agg(jsonb_build_object('idBuzon',id_buzon,'foto',foto,'mes',mes,'anio',anio) order by ts asc),'[]'::jsonb)
    from wh.igv_buzon
   where ocr_estado = 'PENDIENTE' and coalesce(foto,'') <> '' and coalesce(ocr_intentos,0) < 6
   limit least(greatest(coalesce((p->>'max')::int, 3), 1), 10);
$function$;
grant execute on function mos.igv_buzon_pendientes(jsonb) to authenticated, anon, service_role;

-- ── 4) marcar un fallo de OCR que NO es de cupo (imagen ilegible de red/parse): sube intentos; al 6º corta a ERROR ──
create or replace function mos.igv_buzon_ocr_fallo(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_id text := btrim(coalesce(p->>'idBuzon','')); v_n int;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  update wh.igv_buzon set ocr_intentos = coalesce(ocr_intentos,0) + 1,
     estado = case when coalesce(ocr_intentos,0) + 1 >= 6 then 'ERROR' else estado end,
     ocr_estado = case when coalesce(ocr_intentos,0) + 1 >= 6 then 'ERROR' else ocr_estado end
   where id_buzon = v_id returning ocr_intentos into v_n;
  return jsonb_build_object('ok',true,'idBuzon',v_id,'intentos',coalesce(v_n,0));
end $function$;
grant execute on function mos.igv_buzon_ocr_fallo(jsonb) to authenticated, anon, service_role;

select 'RPCs buzón cola pendientes creadas' as ok;
