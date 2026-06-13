-- 45_wh_rls_lecturas.sql — [PASO 5 · B3 backend] Wrappers de lectura con gate de claim para el NAVEGADOR.
-- Las RPCs de lectura originales (stock_enriquecido, rotacion_semanal) quedan INTACTAS (las usa GAS con
-- service_role). Estos wrappers _rls chequean wh._claim_ok() y delegan → el frontend con JWT WH los llama.
-- security definer: corren como owner (acceden a wh.* y mos.productos). Cero cambio en las funciones base.
create or replace function wh.stock_enriquecido_rls(solo_alertas boolean default false)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when wh._claim_ok() then wh.stock_enriquecido(solo_alertas)
              else jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA') end;
$$;
revoke all on function wh.stock_enriquecido_rls(boolean) from public;
grant execute on function wh.stock_enriquecido_rls(boolean) to authenticated, service_role;

create or replace function wh.rotacion_semanal_rls(semanas int default 8, codigos_producto text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when wh._claim_ok() then wh.rotacion_semanal(semanas, codigos_producto)
              else jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA') end;
$$;
revoke all on function wh.rotacion_semanal_rls(int, text) from public;
grant execute on function wh.rotacion_semanal_rls(int, text) to authenticated, service_role;
