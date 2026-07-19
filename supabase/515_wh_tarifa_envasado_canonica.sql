-- 515_wh_tarifa_envasado_canonica.sql — wh.get_tarifa_envasado lee la clave CANÓNICA.
-- ════════════════════════════════════════════════════════════════════════════════════
-- BUG de drift visual (detectado en el rediseño Config): el "Tu pago: N × S/tarifa" del
-- modal de envasado WH (SQL 423) leía mos.config.'tarifa_envasado' (clave legacy),
-- mientras el CÁLCULO REAL de la liquidación (SQL 120/93 · mos._cfg_num) usa
-- 'evalTarifaEnvasadoPorUnidad'. Hoy ambas valen 0.10 → sin daño; pero si el dueño
-- edita el chip de política del Almacén (evalTarifaEnvasadoPorUnidad), WH mostraría
-- una tarifa distinta a la que se paga. Fix: canónica primero, legacy de fallback.
-- Money-safe: solo LECTURA de display (el pago siempre salió de _cfg_num).
create or replace function wh.get_tarifa_envasado()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case when wh._claim_ok()
    then jsonb_build_object('ok', true,
           'tarifa', coalesce(
             mos._numn((select valor from mos.config where clave='evalTarifaEnvasadoPorUnidad' limit 1)),
             mos._numn((select valor from mos.config where clave='tarifa_envasado' limit 1)),
             0.10))
    else jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA') end;
$fn$;
