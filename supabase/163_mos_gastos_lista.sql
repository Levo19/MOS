-- 160_mos_gastos_lista.sql — [CUTOVER DELETE-SAFE · LECTURA GASTOS]
-- Espeja getGastos (gas/Finanzas.gs:304) y el read de _calcularGastos (Finanzas.gs:884) para que el read-back
-- de GAS pueda leer la sombra mos.gastos en vez de la HOJA → MOS sigue funcionando "aunque borre el Sheet".
--
-- ── SHAPE (paridad con GAS / _sheetToObjects(GASTOS)) ──────────────────────────────────────────────────────
--   getGastos devuelve {ok:true,data:[filas camelCase]}. Columnas de la hoja GASTOS (= sombra mos.gastos):
--   idGasto, fecha, categoria, tipo, descripcion, monto, comprobante, registradoPor.  Esta RPC mapea snake→camel
--   EXACTO y emite { ok, data:[{camelCase}], _count } || _frescura_sombra().  El consumidor (getGastos / front /
--   _calcularGastos) lee data[].monto/categoria/tipo/fecha → paridad.
--
-- ── FILTROS (paridad con getGastos) ───────────────────────────────────────────────────────────────────────
--   · fecha  : igualdad por día en TZ America/Lima (espeja String(r.fecha).substring(0,10) === params.fecha).
--   · categoria : igualdad exacta (r.categoria === params.categoria).
--   · desde+hasta : rango de día (>= desde AND <= hasta), AMBOS requeridos juntos (paridad GAS).
--   Sin filtros → todas las filas (= _sheetToObjects sin filtrar).
--
-- ── DINERO / TIPOS ────────────────────────────────────────────────────────────────────────────────────────
--   monto se emite como NÚMERO JSON (numeric); el consumidor hace parseFloat() defensivo. fecha = timestamptz
--   serializada ISO 8601 (el consumidor usa String(r.fecha).substring(0,10) → toma el día UTC; idéntico a hoy
--   porque la hoja también guarda la fecha así). _calcularGastos suma por r.tipo==='FIJO' y r.categoria.
--
-- INERTE respecto a flags: NO toca flags. El gate de lectura lo aplica GAS (_sbLeerListaMOS con
-- 'MOS_GASTOS_LECTURA' / maestro). Idempotente (create or replace).

create or replace function mos.gastos_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_cat   text := nullif(btrim(coalesce(p->>'categoria','')), '');
  v_desde text := nullif(btrim(coalesce(p->>'desde','')), '');
  v_hasta text := nullif(btrim(coalesce(p->>'hasta','')), '');
  v_data  jsonb;
  v_count int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;

  -- Validación de formatos fecha (basura → error limpio, no filtro silencioso roto).
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
      'idGasto',       t.id_gasto,
      'fecha',         t.fecha,
      'categoria',     t.categoria,
      'tipo',          t.tipo,
      'descripcion',   t.descripcion,
      'monto',         t.monto,
      'comprobante',   t.comprobante,
      'registradoPor', t.registrado_por
    ) as row,
    t.fecha as ord_fecha, t.id_gasto as ord_id
    from mos.gastos t
    where (v_fecha is null
           or (t.fecha at time zone 'America/Lima')::date = v_fecha::date)
      and (v_cat is null or t.categoria = v_cat)
      and (v_desde is null or v_hasta is null
           or ((t.fecha at time zone 'America/Lima')::date >= v_desde::date
               and (t.fecha at time zone 'America/Lima')::date <= v_hasta::date))
  ) s;

  return jsonb_build_object('ok', true, 'data', v_data, '_count', v_count) || mos._frescura_sombra();
end;
$fn$;
revoke all on function mos.gastos_lista(jsonb) from public;
grant execute on function mos.gastos_lista(jsonb) to service_role, authenticated;
