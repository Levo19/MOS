-- 373 · mos.etiqueta_marcar(p) — NIVEL 4 corte-GAS (ME). Escrituras de estado de
-- etiquetas de cambio de precio (mos.etiquetas_zona): pegada / pegadas_batch / visto.
-- Reemplaza marcarPegadaEtiqueta / marcarPegadasBatch / marcarVistoEtiqueta (GAS).
-- Gate: token ME/MOS/WH (me._claim_zona_ok). (reimprimir → Edge de impresión aparte;
-- CAMBIO_IMPRESORA_CAJA → config de estación, follow-up.)
create or replace function mos.etiqueta_marcar(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_acc  text := lower(btrim(coalesce(p->>'accion','')));
  v_id   text := nullif(btrim(coalesce(p->>'idEtiq','')),'');
  v_ids  jsonb := p->'idEtiqs';
  v_usr  text := coalesce(nullif(btrim(coalesce(p->>'usuario','')),''),'');
  v_n int := 0;
begin
  if not me._claim_zona_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_acc = 'pegada' then
    if v_id is null then return jsonb_build_object('ok',false,'error','idEtiq requerido'); end if;
    update mos.etiquetas_zona set ts_pegada = now(), pegada_por = v_usr, estado = 'PEGADA' where id_etiq = v_id;
    get diagnostics v_n = row_count;
  elsif v_acc = 'pegadas_batch' then
    if v_ids is null or jsonb_typeof(v_ids) <> 'array' then return jsonb_build_object('ok',false,'error','idEtiqs requerido'); end if;
    update mos.etiquetas_zona set ts_pegada = now(), pegada_por = v_usr, estado = 'PEGADA'
     where id_etiq = any(select jsonb_array_elements_text(v_ids));
    get diagnostics v_n = row_count;
  elsif v_acc = 'visto' then
    if v_id is null then return jsonb_build_object('ok',false,'error','idEtiq requerido'); end if;
    -- append usuario al visto_csv si no está.
    update mos.etiquetas_zona set visto_csv = case
        when coalesce(visto_csv,'') = '' then v_usr
        when ('|'||visto_csv||'|') like ('%|'||v_usr||'|%') then visto_csv
        else visto_csv || '|' || v_usr end
     where id_etiq = v_id and v_usr <> '';
    get diagnostics v_n = row_count;
  else
    return jsonb_build_object('ok',false,'error','accion inválida: '||v_acc);
  end if;
  return jsonb_build_object('ok',true,'filas',v_n);
end; $fn$;
revoke all on function mos.etiqueta_marcar(jsonb) from public, anon;
grant execute on function mos.etiqueta_marcar(jsonb) to authenticated, service_role;
