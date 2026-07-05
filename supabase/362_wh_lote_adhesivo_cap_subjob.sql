-- ════════════════════════════════════════════════════════════════════════════
-- 362 · FIX PROD (2026-07-04) — cap duro de sub_job_size en wh.lote_adhesivo_crear
-- ════════════════════════════════════════════════════════════════════════════
-- INCIDENTE: operadores envasando PIMIENTA NEGRA MOLIDO 50GR (250 uds) → los
-- adhesivos NO se imprimían. Causa raíz: mos.config ADHESIVO_SUB_JOB_SIZE se
-- había puesto en 500. lote_adhesivo_reservar da least(500, total)=250 en UN solo
-- sub-job → el Edge print-adhesivo intenta construir 250 etiquetas (cada una con
-- el bitmap del logo) en un único job TSPL2 → el array O(n²) cuelga el Edge / el
-- job base64 gigante es rechazado por PrintNode → el sub-job muere ENTRE reservar
-- y printNodePost, sin reembolsar → `completadas` queda avanzada; cada re-disparo
-- reserva más hasta 250 → siguiente reservar=0 → el lote termina COMPLETADO SIN
-- imprimir (ultimo_printnode_job_id=NULL). PAN BLANCO(50) y SANTIS(2) con size=500
-- SÍ imprimieron (jobs chicos) → el umbral de rotura está entre 50 y 250/job.
--
-- FIX: (1) config revertido a 25 (aparte). (2) CAP DURO aquí: sub_job_size nunca
-- > 50, aunque el config diga más. Así un mal valor de config no puede volver a
-- generar un job imprimible. Cero cambio de comportamiento para valores <= 50.
-- Idéntica a la definición viva (206) salvo la línea del cap.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function wh.lote_adhesivo_crear(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_cod   text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_total int  := floor(wh._num(p->>'total'))::int;
  v_idem  text := nullif(btrim(coalesce(p->>'idempotencyKey','')), '');
  v_size  int  := floor(wh._num(p->>'subJobSize'))::int;
  v_id    text;
  v_row   wh.lotes_adhesivo;
begin
  if coalesce((select valor from mos.config where clave='WH_LOTE_ADHESIVO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LOTE_ADHESIVO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_cod is null then return jsonb_build_object('ok',false,'error','FALTA_codigoBarra'); end if;
  if v_total <= 0 then return jsonb_build_object('ok',false,'error','TOTAL_INVALIDO'); end if;
  if v_size is null or v_size <= 0 then
    v_size := coalesce(floor(wh._num((select valor from mos.config where clave='ADHESIVO_SUB_JOB_SIZE' limit 1)))::int, 25);
    if v_size <= 0 then v_size := 25; end if;
  end if;
  -- [FIX 362] CAP DURO: un sub-job muy grande (ej. 250 etiquetas con logo en un solo job TSPL2) cuelga el Edge
  -- o lo rechaza PrintNode → el lote termina COMPLETADO sin imprimir. Nunca más de 50 etiquetas por job.
  if v_size > 50 then v_size := 50; end if;

  if v_idem is not null then
    select * into v_row from wh.lotes_adhesivo where idempotency_key = v_idem limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', wh._lote_adh_json(v_row)); end if;
  end if;

  v_id := 'LA' || (extract(epoch from clock_timestamp())*1000)::bigint
               || '_' || coalesce(v_idem, substr(md5(random()::text),1,6));

  insert into wh.lotes_adhesivo (id_lote, idempotency_key, codigo_barra, descripcion, vto,
    total_etq, completadas, sub_job_size, status, printer_id, tipo_etiqueta, items_json,
    usuario, origen, fecha_creacion, fecha_ultimo_update)
  values (v_id, v_idem, v_cod, coalesce(p->>'descripcion',''), coalesce(p->>'vto',''),
    v_total, 0, v_size, 'ENCOLADO', coalesce(p->>'printerId',''),
    upper(coalesce(p->>'tipoEtiqueta','ADHESIVO_ENVASADO')), p->'itemsJson',
    coalesce(p->>'usuario',''), upper(coalesce(p->>'origen','WH')), now(), now())
  on conflict (idempotency_key) where idempotency_key is not null do nothing
  returning * into v_row;

  if not found then
    select * into v_row from wh.lotes_adhesivo where idempotency_key = v_idem limit 1;
    return jsonb_build_object('ok',true,'dedup',true,'data', wh._lote_adh_json(v_row));
  end if;
  return jsonb_build_object('ok',true,'dedup',false,'data', wh._lote_adh_json(v_row));
end;
$fn$;
