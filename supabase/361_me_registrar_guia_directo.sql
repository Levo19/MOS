-- ════════════════════════════════════════════════════════════════════════════
-- 361 · me.registrar_guia_directo(p) — REGISTRAR GUÍA ME 100% Supabase (cero-GAS)
-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUEANTE B4 del corte GAS: confirmarGuia → _postGuiaBackground → POST GAS
-- (tipoEvento REGISTRAR_GUIA → Guias.gs::registrarGuia). Espejo EXACTO de la
-- bifurcación del GAS:
--
--   · CICLO ON (ME_GUIAS_CICLO_ABIERTA=1) + tipo MANUAL (ENTRADA_ALMACEN/LIBRE,
--     SALIDA_MOVIMIENTO/JEFA/DEVOLUCION_WH) → nace ABIERTA: SOLO metadata
--     (me.zona_guia_registrar_meta), SIN stock (el saldo lo aplica el CIERRE
--     me.cerrar_guia_zona una vez). SALIDA_MOVIMIENTO crea el espejo
--     ENTRADA_TRASLADO CONFIRMADO (aplicada=cantidad → nunca re-suma). Espejo de
--     registrarGuiaAbierta. me._claim_zona_ok ya acepta 'mosExpress' → sin elevación.
--
--   · LEGACY (ciclo OFF o tipo NO manual) → aplica stock inmediato
--     (me.zona_registrar_guia, atómico/idempotente por idGuia+cod) + metadata
--     CONFIRMADO. El reposo gatea mos._claim_ok=('','MOS'); el token ME es
--     'mosExpress' → se ELEVA el claim a 'MOS' transaction-local SOLO para esa
--     llamada y se restaura (rollback lo revierte igual). Espejo de registrarGuia.
--
-- Idempotente: mismo idGuia en un reintento NO dobla (meta on-conflict; kardex
-- dedup por refId). Reusa RPCs ya vivas (cero duplicación). Kill-switch
-- ME_REGISTRAR_GUIA_DIRECTO (ON por defecto — cutover cero-GAS/cero-fallback).
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor) values ('ME_REGISTRAR_GUIA_DIRECTO', '1')
on conflict (clave) do update set valor = '1';

create or replace function me.registrar_guia_directo(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app    text  := me.jwt_app();
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_id     text  := nullif(btrim(coalesce(p->>'idGuia', p->>'id_guia', '')), '');
  v_zona   text  := upper(btrim(coalesce(p->>'zona', '')));
  v_tipo   text  := upper(btrim(coalesce(p->>'tipo', '')));
  v_vend   text  := nullif(btrim(coalesce(p->>'vendedor', p->>'usuario', '')), '');
  v_obs    text  := coalesce(p->>'observacion', '');
  v_zdest  text  := upper(nullif(btrim(coalesce(p->>'zona_destino', p->>'zonaDestino', '')), ''));
  v_items  jsonb := coalesce(p->'items', '[]'::jsonb);
  v_ciclo  boolean := coalesce((select valor from mos.config where clave = 'ME_GUIAS_CICLO_ABIERTA' limit 1), '0') = '1';
  v_manual boolean;
  v_identr text := null;
  v_estado text;
  v_mres jsonb; v_sres jsonb;
begin
  if v_app not in ('mosExpress', 'MOS') then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if coalesce((select valor from mos.config where clave = 'ME_REGISTRAR_GUIA_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'ME_REGISTRAR_GUIA_DIRECTO_OFF');
  end if;
  if v_id is null or v_zona = '' or v_tipo = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere idGuia, zona y tipo');
  end if;

  v_manual := v_tipo in ('ENTRADA_ALMACEN', 'ENTRADA_LIBRE', 'SALIDA_MOVIMIENTO', 'SALIDA_JEFA', 'SALIDA_DEVOLUCION_WH');
  if v_tipo = 'SALIDA_MOVIMIENTO' and coalesce(v_zdest, '') <> '' then
    v_identr := nullif(btrim(coalesce(p->>'idGuiaEntrada', '')), '');
    if v_identr is null then v_identr := v_id || '-IN'; end if;
  end if;

  if v_ciclo and v_manual then
    -- ── MODELO ABIERTA: solo metadata, SIN stock (el cierre aplica el saldo) ──
    v_estado := 'ABIERTA';
    v_mres := me.zona_guia_registrar_meta(jsonb_build_object(
      'idGuia', v_id, 'zona', v_zona, 'tipo', v_tipo, 'vendedor', v_vend, 'observacion', v_obs,
      'zonaDestino', v_zdest, 'estado', 'ABIERTA', 'items', v_items));
    if coalesce((v_mres->>'ok'), 'false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', 'meta ABIERTA: ' || coalesce(v_mres->>'error', '?'));
    end if;
    -- Espejo de traslado (solo visibilidad): CONFIRMADO + aplicada=cantidad → nunca re-suma al cerrar.
    if v_identr is not null then
      perform me.zona_guia_registrar_meta(jsonb_build_object(
        'idGuia', v_identr, 'zona', v_zdest, 'tipo', 'ENTRADA_TRASLADO', 'vendedor', v_vend,
        'observacion', 'Traslado desde ' || v_zona || ' — Guía origen: ' || v_id,
        'zonaDestino', v_zona, 'estado', 'CONFIRMADO', 'items', v_items));
    end if;
  else
    -- ── LEGACY: stock inmediato (elevación de claim para el reposo) + metadata CONFIRMADO ──
    v_estado := 'CONFIRMADO';
    perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app', 'MOS'))::text, true);
    v_sres := me.zona_registrar_guia(jsonb_build_object(
      'idGuia', v_id, 'zona', v_zona, 'tipo', v_tipo, 'items', v_items, 'usuario', v_vend,
      'origen', 'ME_DIRECTO', 'idGuiaEntrada', v_identr, 'zonaDestino', v_zdest));
    perform set_config('request.jwt.claims', v_claims::text, true);
    if coalesce((v_sres->>'ok'), 'false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', 'stock: ' || coalesce(v_sres->>'error', '?'));
    end if;
    perform me.zona_guia_registrar_meta(jsonb_build_object(
      'idGuia', v_id, 'zona', v_zona, 'tipo', v_tipo, 'vendedor', v_vend, 'observacion', v_obs,
      'zonaDestino', v_zdest, 'estado', 'CONFIRMADO', 'items', v_items));
    if v_identr is not null then
      perform me.zona_guia_registrar_meta(jsonb_build_object(
        'idGuia', v_identr, 'zona', v_zdest, 'tipo', 'ENTRADA_TRASLADO', 'vendedor', v_vend,
        'observacion', 'Traslado desde ' || v_zona || ' — Guía origen: ' || v_id,
        'zonaDestino', v_zona, 'estado', 'CONFIRMADO', 'items', v_items));
    end if;
  end if;

  return jsonb_build_object('ok', true, 'idGuia', v_id, 'idGuiaEntrada', v_identr, 'estado', v_estado);
end;
$fn$;

revoke all on function me.registrar_guia_directo(jsonb) from public, anon;
grant execute on function me.registrar_guia_directo(jsonb) to authenticated, service_role;
