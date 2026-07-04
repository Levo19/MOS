-- 349: [CERO-GAS] wrapper mos.* (gate mosExpress/MOS/warehouseMos) para getEstadoLoteAdhesivo (polling del
-- estado de un lote de adhesivo). Lee wh.lotes_adhesivo. Shape que consume membrete-modal: {status,completadas,
-- total,ultimoError,...}. Prepara el wiring (via _RPC_DIRECT) del write-path adhesivo.
create or replace function mos.adhesivo_lote_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_id text := nullif(btrim(coalesce(p->>'idLote','')), '');
  r wh.lotes_adhesivo%rowtype;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLote requerido'); end if;
  select * into r from wh.lotes_adhesivo where id_lote = v_id limit 1;
  if not found then return jsonb_build_object('ok',true,'data',jsonb_build_object('status','','completadas',0,'total',0)); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'idLote', r.id_lote, 'status', coalesce(r.status,''), 'completadas', coalesce(r.completadas,0),
    'total', coalesce(r.total_etq,0), 'ultimoError', coalesce(r.ultimo_error,''),
    'descripcion', coalesce(r.descripcion,''), 'codigoBarra', coalesce(r.codigo_barra,''),
    'subJobSize', coalesce(r.sub_job_size,0), 'tipoEtiqueta', coalesce(r.tipo_etiqueta,'')));
end;
$fn$;
revoke all on function mos.adhesivo_lote_estado(jsonb) from public;
grant execute on function mos.adhesivo_lote_estado(jsonb) to anon, authenticated, service_role;
