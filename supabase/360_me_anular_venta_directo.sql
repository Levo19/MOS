-- ════════════════════════════════════════════════════════════════════════════
-- 360 · me.anular_venta_directo(p) — ANULACIÓN ME POS 100% Supabase (cero-GAS)
-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUEANTE B3 del corte GAS: la anulación individual del POS ME (tipoEvento
-- 'ANULACION' → Caja.gs::anularVentaIndividual) era 100% GAS. Espejo atómico:
-- marca ANULADO + historial (source ME_ANULAR_VENTA, idéntico a GAS) + repone
-- stock si la caja cerró (idempotente 'ANUL:<id>') + descuenta el pickup origen.
--
-- REUSO ÍNTEGRO de me.anular_venta (SQL 260) — cero duplicación. me.anular_venta
-- ya es atómico e idempotente y hace EXACTAMENTE lo que hace el GAS (de hecho más
-- seguro: rollback total ante error SQL real, sin fantasmas parciales).
--
-- El único obstáculo era el gate: me.anular_venta exige app in ('','MOS') porque
-- su reposo anidado (me.zona_registrar_guia → mos._claim_ok = app in ('','MOS'))
-- rechazaría un token 'mosExpress' SIN lanzar → venta anulada sin reponer stock =
-- fantasma asimétrico. Solución contenida: este wrapper gatea el token ME real
-- ('mosExpress'/'MOS') + su kill-switch, ELEVA el claim a 'MOS' transaction-local
-- SOLO para la llamada anidada, y lo restaura. La elevación se revierte igual en
-- el rollback (set_config local). No amplía el gate de ninguna función core.
--
-- Kill-switch: mos.config ME_ANULAR_DIRECTO. ON por defecto en este archivo
-- (cutover cero-GAS/cero-fallback; el frontend ya no cae a GAS).
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor) values ('ME_ANULAR_DIRECTO', '1')
on conflict (clave) do update set valor = '1';

create or replace function me.anular_venta_directo(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app    text := me.jwt_app();
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_res    jsonb;
begin
  -- Gate del POS ME: token mosExpress (o MOS). Mismo criterio que cobrar/creditar_venta_directo.
  if v_app not in ('mosExpress', 'MOS') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- Kill-switch (paridad con COBRO_OFF): OFF → el front NO cae a GAS, reporta no-disponible.
  if coalesce((select valor from mos.config where clave = 'ME_ANULAR_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'ME_ANULAR_DIRECTO_OFF');
  end if;

  -- Elevar el claim a MOS (transaction-local) para que el reposo anidado autorice; reusar me.anular_venta
  -- ÍNTEGRO (atómico/idempotente). Restaurar el claim al final (el rollback lo revierte igual si algo lanza).
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app', 'MOS'))::text, true);
  v_res := me.anular_venta(p);
  perform set_config('request.jwt.claims', v_claims::text, true);
  return v_res;
end;
$fn$;

revoke all on function me.anular_venta_directo(jsonb) from public, anon;
grant execute on function me.anular_venta_directo(jsonb) to authenticated, service_role;
