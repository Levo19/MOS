-- ════════════════════════════════════════════════════════════════════════════
-- 423 · wh.get_tarifa_envasado() — la tarifa por unidad para el modal de WH
-- ════════════════════════════════════════════════════════════════════════════
-- El modal de envasado rediseñado muestra "Tu pago: N × S/tarifa" (refuerzo
-- anti-fraude). WH no tenía acceso a mos.config.tarifa_envasado (solo MOS la
-- usa en el recompute). RPC de LECTURA mínima, gate de claim del ecosistema.

create or replace function wh.get_tarifa_envasado()
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select case when wh._claim_ok()
    then jsonb_build_object('ok', true,
           'tarifa', coalesce(mos._numn((select valor from mos.config where clave='tarifa_envasado' limit 1)), 0.10))
    else jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA') end;
$fn$;
revoke all on function wh.get_tarifa_envasado() from public, anon;
grant execute on function wh.get_tarifa_envasado() to authenticated, service_role;

notify pgrst, 'reload schema';
