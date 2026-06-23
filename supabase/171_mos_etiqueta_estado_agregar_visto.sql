-- 171_mos_etiqueta_estado_agregar_visto.sql — [MIGRACIÓN MOS · CIERRE ETIQUETAS · ÚLTIMO STATE-PATH NO-MONEY]
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════
-- CONTEXTO: los CAMBIOS DE ESTADO de una etiqueta (marcar visto / pegada / impresa) seguían escribiendo la
--   HOJA ETIQUETAS_ZONA + dual-write (_dwEtiq) en gas/Etiquetas.gs. Migramos esos write-paths a directo-puro
--   sobre mos.etiquetas_zona vía mos.actualizar_etiqueta_zona (82). Esa RPC YA cubre pegada/impresa
--   (estado/ts_pegada/pegada_por/ts_impresa/impresa_por/job_id) con UPDATE atómico por PK.
--
-- ── EL ÚNICO CAMPO QUE FALTABA ATÓMICO: visto_csv ───────────────────────────────────────────────────────
--   marcarVistoEtiqueta de GAS hace READ(visto_csv) → split CSV → append usuario si no está → JOIN → WRITE.
--   Eso es un read-modify-write: en directo-puro, dos cajeros marcando visto a la MISMA etiqueta a la vez
--   se pisarían (lost-update) si lo replicáramos como `vistoCsv` (replace total) calculado en GAS.
--   Por eso EXTENDEMOS actualizar_etiqueta_zona con la clave OPCIONAL `agregarVisto`: el merge del CSV ocurre
--   100% server-side, dentro del MISMO UPDATE atómico por PK → idempotente (re-marcar = no-op) y sin lost-update.
--   `vistoCsv` (replace) se conserva por compat; si vienen ambos, `agregarVisto` tiene prioridad sobre el campo.
--
-- ── PARIDAD EXACTA con marcarVistoEtiqueta (GAS) ─────────────────────────────────────────────────────────
--   · usuario normalizado: lower(trim(usuario))  (GAS: String(usuario).toLowerCase().trim())
--   · lista actual: lower(visto_csv) split por ',', trim cada token, descarta vacíos (GAS idéntico)
--   · si el usuario YA está ⇒ NO duplica (idempotente; GAS: if indexOf<0)
--   · resultado: tokens.join(',')  (GAS: list.join(','))
--   · usuario vacío/blank ⇒ NO toca visto_csv (defensivo; GAS exige usuario en el handler)
--
-- ── INERTE/SEGURO ────────────────────────────────────────────────────────────────────────────────────────
--   Mismo gate MOS_ETIQ_DIRECTO + mos._claim_ok() de la 82. Idempotente al re-aplicar (create or replace).
--   Sin cambio de firma (sigue siendo actualizar_etiqueta_zona(p jsonb)). Sin tocar datos.

create or replace function mos.actualizar_etiqueta_zona(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idEtiq','')), '');
  v_tsp  timestamptz; v_tsp_set boolean := false;
  v_tsi  timestamptz; v_tsi_set boolean := false;
  v_tsc  timestamptz; v_tsc_set boolean := false;
  v_addv text;                       -- usuario a agregar a visto_csv (normalizado), NULL si no aplica
  v_n    int;
begin
  if coalesce((select valor from mos.config where clave='MOS_ETIQ_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_ETIQ_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idEtiq'); end if;

  -- timestamps presentes → cast tolerante (basura → NULL, sin reventar)
  if p ? 'tsPegada' then v_tsp_set := true;
    begin v_tsp := nullif(btrim(coalesce(p->>'tsPegada','')),'')::timestamptz; exception when others then v_tsp := null; end;
  end if;
  if p ? 'tsImpresa' then v_tsi_set := true;
    begin v_tsi := nullif(btrim(coalesce(p->>'tsImpresa','')),'')::timestamptz; exception when others then v_tsi := null; end;
  end if;
  if p ? 'tsCambio' then v_tsc_set := true;
    begin v_tsc := nullif(btrim(coalesce(p->>'tsCambio','')),'')::timestamptz; exception when others then v_tsc := null; end;
  end if;

  -- agregarVisto: usuario a fusionar atómicamente en visto_csv (append-set, paridad marcarVistoEtiqueta).
  -- Normalizado lower(trim). Vacío/blank ⇒ NULL ⇒ no toca visto_csv por esta vía.
  v_addv := nullif(lower(btrim(coalesce(p->>'agregarVisto',''))), '');

  update mos.etiquetas_zona t set
    estado          = case when p ? 'estado'         then nullif(btrim(coalesce(p->>'estado','')),'')         else t.estado end,
    visto_csv       = case
                        when v_addv is not null then (
                          -- merge atómico server-side: tokens existentes (lower/trim/no-vacío) + usuario si no está,
                          -- dedup preservando el ORDEN de primera aparición (paridad list.push + indexOf de GAS).
                          select coalesce(string_agg(tok, ',' order by ord), '')
                          from (
                            select tok, min(ord) ord
                            from (
                              select lower(btrim(x)) tok, ord
                              from unnest(
                                string_to_array(coalesce(t.visto_csv,''), ',')
                                || array[v_addv]
                              ) with ordinality as u(x, ord)
                              where btrim(coalesce(x,'')) <> ''
                            ) y
                            group by tok
                          ) z
                        )
                        when p ? 'vistoCsv' then coalesce(btrim(coalesce(p->>'vistoCsv','')),'')
                        else t.visto_csv
                      end,
    precio_anterior = case when p ? 'precioAnterior' then coalesce(mos._numn(p->>'precioAnterior'),0)         else t.precio_anterior end,
    precio_nuevo    = case when p ? 'precioNuevo'    then coalesce(mos._numn(p->>'precioNuevo'),0)            else t.precio_nuevo end,
    cambiado_por    = case when p ? 'cambiadoPor'    then nullif(btrim(coalesce(p->>'cambiadoPor','')),'')    else t.cambiado_por end,
    impresa_por     = case when p ? 'impresaPor'     then nullif(btrim(coalesce(p->>'impresaPor','')),'')     else t.impresa_por end,
    job_id          = case when p ? 'jobId'          then nullif(btrim(coalesce(p->>'jobId','')),'')          else t.job_id end,
    pegada_por      = case when p ? 'pegadaPor'      then nullif(btrim(coalesce(p->>'pegadaPor','')),'')      else t.pegada_por end,
    comentario      = case when p ? 'comentario'     then nullif(btrim(coalesce(p->>'comentario','')),'')     else t.comentario end,
    ts_pegada       = case when v_tsp_set            then v_tsp                                               else t.ts_pegada end,
    ts_impresa      = case when v_tsi_set            then v_tsi                                               else t.ts_impresa end,
    ts_cambio       = case when v_tsc_set            then v_tsc                                               else t.ts_cambio end
  where id_etiq = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','idEtiq no encontrado'); end if;
  -- devolvemos visto_csv resultante para que el handler responda vistoPor (paridad marcarVistoEtiqueta)
  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'idEtiq', v_id,
    'vistoCsv', (select visto_csv from mos.etiquetas_zona where id_etiq = v_id)));
end;
$fn$;
revoke all on function mos.actualizar_etiqueta_zona(jsonb) from public;
grant execute on function mos.actualizar_etiqueta_zona(jsonb) to service_role, authenticated;
