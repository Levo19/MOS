-- 338_mos_adhesivo_lotes_boot.sql
-- [CERO-GAS] Wrappers mos.* (gate acepta mosExpress/MOS/warehouseMos/'' — el módulo membrete-modal.js es
-- compartido por las 3 apps y llama vía DeviceAuth.rpc con anon) para las 2 lecturas del BOOT que hoy pegan a
-- GAS (getLotesAdhesivoHistorial + diagnosticoTriggerLotes). Leen wh.lotes_adhesivo. El 3ro del boot
-- (getMembretesMePendientes = alertas de precio) NO se migra acá: requiere tabla+trigger de precio (dedicado).

-- Historial de lotes de adhesivo: {pendientes:[...], historial:[...], totalPendientes, totalHistorial}.
-- Reemplaza gas Envasados.gs::getLotesAdhesivoHistorial. Keys de item = exactas al GAS (camelCase).
create or replace function mos.adhesivo_lotes_historial(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_tipo  text := nullif(btrim(coalesce(p->>'tipoEtiqueta','')), '');
  v_limit int  := coalesce(nullif(btrim(coalesce(p->>'limit','')),'')::int, 30);
  v_pend jsonb; v_hist jsonb; v_tp int; v_th int;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- pendientes = todo lo que no está COMPLETADO/CANCELADO (encolado/creado/imprimiendo/calibrando).
  select coalesce(jsonb_agg(row order by (row->>'fechaCreacion') desc), '[]'::jsonb), count(*)
    into v_pend, v_tp
  from (
    select jsonb_build_object(
      'idLote', l.id_lote, 'fechaCreacion', case when l.fecha_creacion is null then '' else to_char(l.fecha_creacion at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'fechaUltimoUpdate', case when l.fecha_ultimo_update is null then '' else to_char(l.fecha_ultimo_update at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'usuario', coalesce(l.usuario,''), 'origen', coalesce(l.origen,''), 'codigoBarra', coalesce(l.codigo_barra,''),
      'descripcion', coalesce(l.descripcion,''), 'vto', coalesce(l.vto,''), 'totalEtq', coalesce(l.total_etq,0),
      'completadas', coalesce(l.completadas,0), 'status', coalesce(l.status,''), 'ultimoError', coalesce(l.ultimo_error,''),
      'tipoEtiqueta', coalesce(l.tipo_etiqueta,'')
    ) as row
    from wh.lotes_adhesivo l
    where upper(coalesce(l.status,'')) not in ('COMPLETADO','CANCELADO')
      and (v_tipo is null or l.tipo_etiqueta = v_tipo)
  ) t;

  select coalesce(jsonb_agg(row order by (row->>'fechaCreacion') desc), '[]'::jsonb), count(*)
    into v_hist, v_th
  from (
    select jsonb_build_object(
      'idLote', l.id_lote, 'fechaCreacion', case when l.fecha_creacion is null then '' else to_char(l.fecha_creacion at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'fechaUltimoUpdate', case when l.fecha_ultimo_update is null then '' else to_char(l.fecha_ultimo_update at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"') end,
      'usuario', coalesce(l.usuario,''), 'origen', coalesce(l.origen,''), 'codigoBarra', coalesce(l.codigo_barra,''),
      'descripcion', coalesce(l.descripcion,''), 'vto', coalesce(l.vto,''), 'totalEtq', coalesce(l.total_etq,0),
      'completadas', coalesce(l.completadas,0), 'status', coalesce(l.status,''), 'ultimoError', coalesce(l.ultimo_error,''),
      'tipoEtiqueta', coalesce(l.tipo_etiqueta,'')
    ) as row
    from wh.lotes_adhesivo l
    where upper(coalesce(l.status,'')) in ('COMPLETADO','CANCELADO')
      and (v_tipo is null or l.tipo_etiqueta = v_tipo)
    order by l.fecha_creacion desc
    limit v_limit
  ) t;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'pendientes', v_pend, 'historial', v_hist, 'totalPendientes', coalesce(v_tp,0), 'totalHistorial', coalesce(v_th,0)));
end;
$fn$;
revoke all on function mos.adhesivo_lotes_historial(jsonb) from public;
grant execute on function mos.adhesivo_lotes_historial(jsonb) to anon, authenticated, service_role;

-- Diagnóstico del "trigger" de lotes. En Supabase el procesamiento es pg_cron (siempre activo) → triggerInstalado
-- constante true + conteos reales. Reemplaza gas LotesTrigger.gs::diagnosticoTriggerLotes (best-effort, catch→null).
create or replace function mos.adhesivo_lotes_diag(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_enc int; v_imp int;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select count(*) filter (where upper(coalesce(status,'')) in ('ENCOLADO','CREADO','CALIBRANDO')),
         count(*) filter (where upper(coalesce(status,'')) = 'IMPRIMIENDO')
    into v_enc, v_imp from wh.lotes_adhesivo;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'triggerInstalado', true, 'cantidadTriggers', 1, 'lotesEncolados', coalesce(v_enc,0),
    'lotesImprimiendo', coalesce(v_imp,0), 'idLotesEncolados', '[]'::jsonb, 'mensaje', 'pg_cron activo (Supabase)'));
end;
$fn$;
revoke all on function mos.adhesivo_lotes_diag(jsonb) from public;
grant execute on function mos.adhesivo_lotes_diag(jsonb) to anon, authenticated, service_role;
