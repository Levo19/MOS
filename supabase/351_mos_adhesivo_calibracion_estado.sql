-- 351: [CERO-GAS] estado de calibración/drift del rollo adhesivo → lee mos.config ADHESIVO_* (reemplaza gas
-- estadoCalibracionRollo, Envasados.gs:1089). Umbrales y fórmulas IDÉNTICOS al GAS (clamp [-1,16], recal>800,
-- casi-agotado>950, capacidad 1000). Solo LECTURA. Gate operador/admin. Additive, no cambia comportamiento.
create or replace function mos.adhesivo_calibracion_estado(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_claim text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'app','');
  v_cal_txt text; v_calibrado boolean;
  v_drift numeric; v_prints int; v_off numeric; v_fecha text;
  v_comp int; v_sinclamp numeric; v_efectivo numeric; v_clamp boolean;
begin
  if v_claim not in ('mosExpress','MOS','warehouseMos','') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  select valor into v_cal_txt from mos.config where clave='ADHESIVO_ROLLO_CALIBRADO';
  v_calibrado := coalesce(v_cal_txt = 'true', false);  -- GAS: null==='true' → false
  select coalesce(nullif(valor,'')::numeric,0) into v_drift  from mos.config where clave='ADHESIVO_DRIFT_DOTS_POR_PRINT';
  select coalesce(nullif(valor,'')::int,0)     into v_prints from mos.config where clave='ADHESIVO_PRINTS_DESDE_CAL';
  select coalesce(nullif(valor,'')::numeric,0) into v_off    from mos.config where clave='ADHESIVO_OFFSET_Y';
  select coalesce(valor,'')                    into v_fecha  from mos.config where clave='ADHESIVO_FECHA_CALIBRADO';
  v_drift  := coalesce(v_drift,0);  v_prints := coalesce(v_prints,0);  v_off := coalesce(v_off,0);
  v_comp     := round(v_drift * v_prints)::int;        -- compensación acumulada (dots)
  v_sinclamp := v_off + v_comp;
  v_clamp    := (v_sinclamp > 16 or v_sinclamp < -1);
  v_efectivo := greatest(-1, least(16, v_sinclamp));   -- clamp [-1,16]
  return jsonb_build_object('ok',true,'data',jsonb_build_object(
    'calibrado',                  v_calibrado,
    'driftDotsPorPrint',          v_drift,
    'printsDesdeCal',             v_prints,
    'offsetBase',                 v_off,
    'compensacionAcumulada',      v_comp,
    'offsetEfectivoProximoPrint', v_efectivo,
    'offsetSinClamp',             v_sinclamp,
    'clampActivo',                v_clamp,
    'fechaCalibrado',             coalesce(v_fecha,''),
    'necesitaRecalibrar',         (v_prints > 800),
    'rolloCasiAgotado',           (v_prints > 950),
    'driftMmPorPrint',            round(v_drift/8, 3),
    'driftConfigurado',           (v_drift > 0),
    'capacidadRollo',             1000,
    'umbralCasiAgotado',          950));
end;
$fn$;
revoke all on function mos.adhesivo_calibracion_estado(jsonb) from public;
grant execute on function mos.adhesivo_calibracion_estado(jsonb) to anon, authenticated, service_role;
