-- [937 · GESTIÓN IA] mos.ia_pendientes_listar — COLA DE PENDIENTES en tiempo real + reconciliación.
-- El dueño quiere ver "cuánto falta por hacer" para decidir si el cupo GRATIS de Gemini alcanza o hay que
-- recargar Anthropic. Muestra, por cada cola de IA de fondo (se retoman solas en cada corrida del cron):
--   · pendientes (cuántos faltan)  · edad del más viejo (¿se está estancando?)  · procesados hoy (throughput)
--   · último intento y su MOTIVO (ok / sin_cupo / error) para saber si está frenado por falta de tokens.
-- Más un resumen del día (ok/fallos/sin_cupo/costo). SOLO LECTURA. Las definiciones de "pendiente" son EXACTAS,
-- copiadas de ia_desc_pendientes / sust_pendientes / wh.cron_ocr_guias para que el número calce con lo que el cron hará.
create or replace function mos.ia_pendientes_listar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_desc int; v_sust int; v_ocr int; v_buz int; v_buz_err int;
  v_desc_h numeric; v_ocr_h numeric; v_sust_int int;
  v_colas jsonb; v_ia jsonb;
begin
  if not (mos._claim_ok() or wh._claim_ok()) then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- ── conteos vivos (mismo WHERE que cada cron usa para elegir qué procesar) ──
  select count(*) into v_desc from mos.productos pr
   where pr.tipo_producto::text='CANONICO' and coalesce(pr.estado,true) and coalesce(pr.es_insumo,false)=false
     and length(btrim(pr.descripcion))>=6
     -- [fix M1] mismo filtro anti-basura que ia_desc_pendientes (descripción puramente numérica/medida NO se procesa)
     and pr.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
     and (pr.ia_refresh=true or (pr.descripcion_ia is null and coalesce(pr.fecha_creacion,pr.created_at)>now()-interval '7 days'));

  select count(*), max(pr.sust_intentos) into v_sust, v_sust_int from mos.productos pr
   where pr.tipo_producto::text in ('CANONICO','DERIVADO') and coalesce(pr.estado,true) and coalesce(pr.es_insumo,false)=false
     and pr.descripcion_ia is not null and pr.categoria_ia is not null
     and (pr.sust_stale or pr.sustitutos_internos is null);

  select count(*) into v_ocr from wh.guias
   where coalesce(foto,'')<>'' and tipo like 'INGRESO%' and tipo<>'INGRESO_DEVOLUCION_ZONA'
     and (ocr_estado is null or ocr_estado='PENDIENTE');

  -- [fix M3] "pendiente" = solo las que el cron REALMENTE reintenta (ocr_estado=PENDIENTE, intentos<6). Las ERROR
  -- (agotaron los 6 intentos) NO drenan solas → van aparte como "atención manual", no inflan el pendiente.
  select count(*) filter (where ocr_estado='PENDIENTE' and coalesce(ocr_intentos,0)<6),
         count(*) filter (where upper(coalesce(estado,''))='ERROR' or coalesce(ocr_intentos,0)>=6)
    into v_buz, v_buz_err
    from wh.igv_buzon where upper(coalesce(estado,'')) in ('PENDIENTE','ERROR');

  -- edad (horas) del pendiente más viejo → si crece, el cupo NO alcanza
  select round(extract(epoch from (now()-min(coalesce(pr.fecha_creacion,pr.created_at))))/3600.0,1) into v_desc_h
    from mos.productos pr
   where pr.tipo_producto::text='CANONICO' and coalesce(pr.estado,true) and coalesce(pr.es_insumo,false)=false
     and length(btrim(pr.descripcion))>=6
     and pr.descripcion !~* '^[0-9 .,x*/-]+\s*(metros?|unidades?|mil(lar)?|cm|mm|gr?|kg|ml|lt|litros?)?\.?\s*$'
     and (pr.ia_refresh=true or (pr.descripcion_ia is null and coalesce(pr.fecha_creacion,pr.created_at)>now()-interval '7 days'));
  select round(extract(epoch from (now()-min(fecha)))/3600.0,1) into v_ocr_h from wh.guias
   where coalesce(foto,'')<>'' and tipo like 'INGRESO%' and tipo<>'INGRESO_DEVOLUCION_ZONA'
     and (ocr_estado is null or ocr_estado='PENDIENTE');

  -- ── throughput + último motivo por función (ia_uso, día Lima) ──
  with u as (
    select case
             when funcion ilike 'descripcion%' then 'descripcion'
             when funcion ilike 'sustitutos%'  then 'sustitutos'
             when funcion ilike 'ocrguia%' or funcion='ocrGuia' then 'ocr_guia'
             when funcion ilike 'buzon%' or funcion ilike '%buzon-igv%' then 'buzon'
             else 'otro' end as cola,
           ok, error, costo_usd, ts,
           (not ok and coalesce(error,'') ~* 'quota|exceeded|resource_exhausted|credit balance|too low|429|rate[[:space:]_-]*limit') as sin_cupo
      from mos.ia_uso
     where (ts at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
  ),
  porcola as (
    select cola,
           count(*) filter (where ok) ok_n,
           count(*) filter (where not ok and not sin_cupo) err_n,
           count(*) filter (where sin_cupo) cupo_n
      from u group by cola
  ),
  ultimo as (   -- el motivo del intento MÁS reciente de cada cola
    select distinct on (cola) cola,
           case when ok then 'ok' when sin_cupo then 'sin_cupo' else 'error' end motivo,
           ts, left(coalesce(error,''),140) detalle
      from u order by cola, ts desc
  )
  select jsonb_object_agg(cola, jsonb_build_object(
           'ok_hoy',ok_n,'err_hoy',err_n,'cupo_hoy',cupo_n,
           'ultimo_motivo',(select motivo from ultimo z where z.cola=porcola.cola),
           'ultimo_ts',(select ts from ultimo z where z.cola=porcola.cola),
           'ultimo_detalle',(select detalle from ultimo z where z.cola=porcola.cola)))
    into v_ia from porcola;
  v_ia := coalesce(v_ia,'{}'::jsonb);

  -- ── armar colas (orden: primero lo importante — OCR y descripción; sustitutos al final) ──
  v_colas := jsonb_build_array(
    jsonb_build_object('tipo','ocr_guia','label','OCR de guías (facturas proveedor)','critico',true,
      'pendientes',v_ocr,'mas_viejo_h',v_ocr_h,'cron','wh-ocr-guias (cada 10 min, 3/tick)',
      'hoy',v_ia->'ocr_guia'),
    jsonb_build_object('tipo','buzon','label','OCR buzón IGV (tributos)','critico',true,
      'pendientes',v_buz,'error_manual',coalesce(v_buz_err,0),'mas_viejo_h',null,
      'cron','buzon-igv-reintentar (cada 10 min) — se reanuda sola',
      'hoy',v_ia->'buzon'),
    jsonb_build_object('tipo','descripcion','label','Descripciones de productos','critico',false,
      'pendientes',v_desc,'mas_viejo_h',v_desc_h,'cron','descripcion-ia-auto (cada 30 min)',
      'hoy',v_ia->'descripcion'),
    jsonb_build_object('tipo','sustitutos','label','Sustitutos de productos','critico',false,
      'pendientes',v_sust,'mas_viejo_h',null,'reintentos_max',coalesce(v_sust_int,0),
      'cron','sustitutos-ia-auto (PAUSADO)','hoy',v_ia->'sustitutos')
  );

  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'colas',v_colas,
    'total_pendientes',(v_ocr+v_buz+v_desc+v_sust),
    'criticos_pendientes',(v_ocr+v_buz),
    'resumen_hoy',(
      select jsonb_build_object(
        'llamadas',count(*),'ok',count(*) filter (where ok),
        'fallos',count(*) filter (where not ok),
        'sin_cupo',count(*) filter (where not ok and coalesce(error,'') ~* 'quota|exceeded|resource_exhausted|credit balance|too low|429|rate[[:space:]_-]*limit'),
        'costo_usd',round(coalesce(sum(costo_usd),0)::numeric,4))
        from mos.ia_uso where (ts at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date),
    'ts',(now() at time zone 'America/Lima')));
end $function$;
grant execute on function mos.ia_pendientes_listar(jsonb) to authenticated, anon, service_role;

select mos.ia_pendientes_listar('{}'::jsonb) as muestra;
