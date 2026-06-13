-- 38_wh_ping_auth.sql — [PASO 5 · B1] RPC de diagnóstico de auth: devuelve el claim 'app' del JWT del request.
-- Sirve para VALIDAR que el mint de WH produce un token aceptado por PostgREST y con app='warehouseMos'.
-- Reusa me.jwt_app() (genérica, lee request.jwt.claims->>'app'). Inofensiva (solo lee el claim, no escribe).
create or replace function wh.ping_auth()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('app', me.jwt_app(), 'role', current_setting('request.jwt.claim.role', true));
$$;
revoke all on function wh.ping_auth() from public;
grant execute on function wh.ping_auth() to anon, authenticated;
