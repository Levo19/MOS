-- 161_mos_liquidaciones_dia_lista.sql — [CUTOVER DELETE-SAFE · LECTURA CRUDA LIQUIDACIONES_DIA]
-- Espeja el read CRUDO de la hoja LIQUIDACIONES_DIA que hacen los read-backs de GAS que NO encajan en
-- personal_dia_lista (que fuerza presente:true y oculta el campo). Necesario para que estos sigan funcionando
-- "aunque borre el Sheet":
--   · _calcularPersonal  (gas/Finanzas.gs)  — filtra presente===true, lee estado/totalDia/montoBase/nombre/...
--   · getLiquidacionesPendientesDia / getPersonalDiaFast / getLiquidacionesVetadas / getLiqDiaBonSan
--     (gas/Liquidaciones.gs) — leen el shape CRUDO de la hoja para sus propios agregados de DINERO.
--
-- ── SHAPE (paridad EXACTA con _sheetToObjects(LIQUIDACIONES_DIA)) ──────────────────────────────────────────
--   Devuelve las filas con los headers camelCase de la hoja _LDIA_HDRS (Liquidaciones.gs:830):
--     idDia, fecha, idPersonal, nombre, rol, appOrigen, virtual, montoBase, pagoEnvasado, bonoMeta,
--     bonificacion, sancion, totalDia, auditado, evaluacionesCount, scoreFinal, tarifaEnvasado, presente,
--     estado, idPago, ts_creado, ts_actualizado, bonificacionMotivo, sancionMotivo.
--   Tipos: numeric→Number, boolean→bool, timestamptz→ISO. El consumidor hace parseFloat()/String() defensivo
--   y compara presente con (===true || String(presente).toLowerCase()==='true') → ambos toleran bool/'true'.
--
-- ── FILTROS (paridad) ─────────────────────────────────────────────────────────────────────────────────────
--   · fecha       : igualdad de DÍA en TZ America/Lima (= cómo _calcularPersonal/getPersonalDiaFast filtran el
--                   día del ecosistema; el GAS hace Utilities.formatDate(fecha, tzLima)).
--   · desde+hasta : rango de día Lima (>= desde AND <= hasta), para los pendientes/vetadas por rango.
--   · soloPresente: si true → solo presente=true (paridad con _calcularPersonal/getPersonalDiaFast).
--   Sin filtros → todas las filas (= _sheetToObjects sin filtrar).  Orden: fecha desc, id_dia.
--
-- DINERO: gate _claim_ok + frescura (_fresh). El consumidor GAS cae a la HOJA si _fresh=false (no sirve dato
-- viejo). Idempotente (create or replace). NO toca flags.

create or replace function mos.liquidaciones_dia_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_desde text := nullif(btrim(coalesce(p->>'desde','')), '');
  v_hasta text := nullif(btrim(coalesce(p->>'hasta','')), '');
  v_solop boolean := (coalesce(p->>'soloPresente','') in ('true','1','t'));
  v_estado text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_data  jsonb;
  v_count int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  begin
    if v_fecha is not null then perform v_fecha::date; end if;
    if v_desde is not null then perform v_desde::date; end if;
    if v_hasta is not null then perform v_hasta::date; end if;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'Fecha inválida (YYYY-MM-DD)');
  end;

  select coalesce(jsonb_agg(row order by ord_fecha desc nulls last, ord_id), '[]'::jsonb), count(*)
    into v_data, v_count
  from (
    select jsonb_build_object(
      'idDia',              t.id_dia,
      'fecha',              t.fecha,
      'idPersonal',         t.id_personal,
      'nombre',             t.nombre,
      'rol',                t.rol,
      'appOrigen',          t.app_origen,
      'virtual',            t.virtual,
      'montoBase',          t.monto_base,
      'pagoEnvasado',       t.pago_envasado,
      'bonoMeta',           t.bono_meta,
      'bonificacion',       t.bonificacion,
      'sancion',            t.sancion,
      'totalDia',           t.total_dia,
      'auditado',           t.auditado,
      'evaluacionesCount',  t.evaluaciones_count,
      'scoreFinal',         t.score_final,
      'tarifaEnvasado',     t.tarifa_envasado,
      'presente',           t.presente,
      'estado',             t.estado,
      'idPago',             t.id_pago,
      'ts_creado',          t.ts_creado,
      'ts_actualizado',     t.ts_actualizado,
      'bonificacionMotivo', t.bonificacion_motivo,
      'sancionMotivo',      t.sancion_motivo
    ) as row,
    t.fecha as ord_fecha, t.id_dia as ord_id
    from mos.liquidaciones_dia t
    where (v_fecha is null
           or (t.fecha at time zone 'America/Lima')::date = v_fecha::date)
      and (v_desde is null
           or (t.fecha at time zone 'America/Lima')::date >= v_desde::date)
      and (v_hasta is null
           or (t.fecha at time zone 'America/Lima')::date <= v_hasta::date)
      and (not v_solop or t.presente = true)
      and (v_estado is null or upper(coalesce(t.estado,'')) = upper(v_estado))
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.liquidaciones_dia_lista(jsonb) from public;
grant execute on function mos.liquidaciones_dia_lista(jsonb) to service_role, authenticated;
