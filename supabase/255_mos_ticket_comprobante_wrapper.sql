-- 255 · REPARACIÓN #9 fix — wrapper mos.ticket_comprobante (PostgREST NO expone el schema `fac`)
-- El Edge ticket-comprobante llamaba fac.ticket_comprobante via PostgREST con Content-Profile:fac → 406
-- PGRST106 "Invalid schema: fac" (solo expone public/me/mos/wh). Wrapper en `mos` (expuesto) que delega.
create or replace function mos.ticket_comprobante(p jsonb)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  select fac.ticket_comprobante(p);
$fn$;
revoke all on function mos.ticket_comprobante(jsonb) from public, anon;
grant execute on function mos.ticket_comprobante(jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
