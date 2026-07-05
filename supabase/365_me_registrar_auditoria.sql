-- ════════════════════════════════════════════════════════════════════════════
-- 365 · me.registrar_auditoria(p) — NIVEL 1 corte-GAS (ME)
-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUEADOR DURO: el guardado del conteo físico de auditoría (tipoEvento
-- REGISTRAR_AUDITORIA → Guias.gs::registrarAuditoria, ME index autoGuardarItem)
-- era 100% GAS. Sin esto, borrado GAS, el módulo de auditoría de stock no guarda.
-- Espejo del GAS: por cada ítem (1) SET absoluto del stock al valor auditado vía
-- me.zona_ajustar_stock (kardex AUDITORIA, idempotente por localId); (2) upsert
-- del registro en me.auditorias. La diferencia usa el stockAntes REAL de la RPC.
--
-- me.zona_ajustar_stock gatea mos._claim_ok()=('','MOS); el token ME es
-- 'mosExpress' → se ELEVA el claim a 'MOS' transaction-local para el ajuste
-- anidado y se restaura (rollback lo revierte igual).
--
-- Idempotencia: id_auditoria determinístico por día+vendedor+zona (upsert PK
-- (id_auditoria, cod_barras)); localId del ajuste estable por (evento, código,
-- valor) → re-auditar a un valor NUEVO aplica; reintento del MISMO valor dedupea.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function me.registrar_auditoria(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app    text  := me.jwt_app();
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_vend   text  := nullif(btrim(coalesce(p->>'vendedor', '')), '');
  v_zona   text  := upper(btrim(coalesce(p->>'zona', '')));
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_day    text  := to_char(now() at time zone 'America/Lima', 'YYYYMMDD');
  v_idaud  text;
  v_it     jsonb; v_cb text; v_real numeric; v_sis numeric; v_aj jsonb;
  v_n int := 0;
begin
  if v_app not in ('mosExpress', 'MOS') then return jsonb_build_object('status', 'error', 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_zona = '' then return jsonb_build_object('status', 'error', 'error', 'zona requerida'); end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('status', 'error', 'error', 'items requerido');
  end if;
  v_idaud := 'A-' || v_day || '-' || substr(md5(coalesce(v_vend, '') || '|' || v_zona), 1, 10);

  -- Elevar claim a MOS para el ajuste anidado (me.zona_ajustar_stock gatea mos._claim_ok).
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app', 'MOS'))::text, true);

  for v_it in select * from jsonb_array_elements(v_items) loop
    v_cb := upper(btrim(coalesce(v_it->>'cod_barras', v_it->>'codBarra', '')));
    if v_cb = '' then continue; end if;
    v_real := coalesce((v_it->>'cantReal')::numeric, 0);
    v_sis  := coalesce((v_it->>'cantSistema')::numeric, 0);

    -- (1) SET absoluto del stock al valor auditado.
    v_aj := me.zona_ajustar_stock(jsonb_build_object(
      'zona', v_zona, 'codBarra', v_cb, 'nuevo', v_real, 'usuario', coalesce(v_vend, ''),
      'localId', v_idaud || ':' || v_cb || ':' || v_real, 'origen', 'AUDITORIA'));
    -- stockAntes REAL de la RPC (no el cache del front) para la diferencia; en dedup conservamos el del payload.
    if coalesce((v_aj->>'ok'), 'false') = 'true' and (v_aj->'data'->>'stockAntes') is not null then
      v_sis := coalesce((v_aj->'data'->>'stockAntes')::numeric, v_sis);
    end if;

    -- (2) Upsert del registro de auditoría (PK id_auditoria+cod_barras).
    insert into me.auditorias (id_auditoria, fecha, vendedor, zona_id, cod_barras, cant_sistema, cant_real, diferencia)
    values (v_idaud, now(), coalesce(v_vend, ''), v_zona, v_cb, v_sis, v_real, (v_real - v_sis))
    on conflict (id_auditoria, cod_barras) do update
      set fecha = now(), cant_sistema = excluded.cant_sistema, cant_real = excluded.cant_real, diferencia = excluded.diferencia;
    v_n := v_n + 1;
  end loop;

  perform set_config('request.jwt.claims', v_claims::text, true);
  return jsonb_build_object('status', 'success', 'registrados', v_n, 'idAuditoria', v_idaud);
end;
$fn$;

revoke all on function me.registrar_auditoria(jsonb) from public, anon;
grant execute on function me.registrar_auditoria(jsonb) to authenticated, service_role;
