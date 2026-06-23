-- ════════════════════════════════════════════════════════════════════════════
-- fac_05_wrappers.sql · Wrappers en schema `mos` (expuesto) → fac.* (no expuesto)
-- ════════════════════════════════════════════════════════════════════════════
-- PostgREST solo expone public/mos/me/wh (config de plataforma, no se cambia por SQL).
-- ME (claim mosExpress) y MOS (claim MOS) ya llaman RPCs del schema `mos`, así que
-- exponemos la capa fac a través de wrappers finos acá. fac._app() lee el claim del JWT
-- (funciona igual desde cualquier schema). Cada wrapper es security definer → puede
-- invocar las funciones fac.* (también security definer). Body PostgREST: {"p": {...}}.

create or replace function mos.fac_emitir_cpe(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.emitir_cpe(p) $$;
create or replace function mos.fac_anular(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.anular_comprobante(p) $$;
create or replace function mos.fac_consultar_documento(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.consultar_documento(p) $$;
create or replace function mos.fac_listar(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.listar_comprobantes(p) $$;
create or replace function mos.fac_get_config(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.get_config(p) $$;
create or replace function mos.fac_set_config(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.admin_set_config(p) $$;
create or replace function mos.fac_set_series(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.admin_set_series(p) $$;
create or replace function mos.fac_alinear(p jsonb) returns jsonb
  language sql security definer set search_path = '' as $$ select fac.admin_alinear_correlativo(p) $$;

revoke all on function mos.fac_emitir_cpe(jsonb)          from public;
revoke all on function mos.fac_anular(jsonb)              from public;
revoke all on function mos.fac_consultar_documento(jsonb) from public;
revoke all on function mos.fac_listar(jsonb)             from public;
revoke all on function mos.fac_get_config(jsonb)         from public;
revoke all on function mos.fac_set_config(jsonb)         from public;
revoke all on function mos.fac_set_series(jsonb)         from public;
revoke all on function mos.fac_alinear(jsonb)            from public;
grant execute on function mos.fac_emitir_cpe(jsonb)          to authenticated;
grant execute on function mos.fac_anular(jsonb)              to authenticated;
grant execute on function mos.fac_consultar_documento(jsonb) to authenticated;
grant execute on function mos.fac_listar(jsonb)             to authenticated;
grant execute on function mos.fac_get_config(jsonb)         to authenticated;
grant execute on function mos.fac_set_config(jsonb)         to authenticated;
grant execute on function mos.fac_set_series(jsonb)         to authenticated;
grant execute on function mos.fac_alinear(jsonb)            to authenticated;
