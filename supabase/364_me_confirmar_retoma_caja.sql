-- ════════════════════════════════════════════════════════════════════════════
-- 364 · me.confirmar_retoma_caja(p) — NIVEL 1 corte-GAS (ME)
-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUEADOR DURO: retomar una caja ABIERTA con clave admin (tras perder sesión)
-- era 100% GAS (Caja.gs::confirmarRetomaCaja, tipoEvento CONFIRMAR_RETOMA_CAJA).
-- Sin esto, borrado GAS, el cajero que perdió localStorage no puede reanudar su
-- caja. Espejo del GAS: (1) busca la caja ABIERTA de HOY del deviceId (mismo
-- lookup que me.retomar_caja_device, 329); (2) valida la clave admin de 8 díg vía
-- mos.verificar_clave_admin (tier 2, bcrypt+lockout); (3) devuelve los datos de la
-- caja para repoblar la sesión. Retorno = shape que confirmarRetomaConPin consume.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function me.confirmar_retoma_caja(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_dev   text := nullif(btrim(coalesce(p->>'deviceId', '')), '');
  v_clave text := coalesce(p->>'claveAdmin', '');
  v_caja  me.cajas%rowtype;
  v_verif jsonb;
begin
  if coalesce(me.jwt_app(), '') not in ('mosExpress', 'MOS') then
    return jsonb_build_object('status', 'error', 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_dev is null then return jsonb_build_object('status', 'error', 'error', 'deviceId requerido'); end if;
  if v_clave = '' or v_clave !~ '^\d{8}$' then
    return jsonb_build_object('status', 'error', 'error', 'claveAdmin debe ser 8 dígitos numéricos');
  end if;

  -- (1) Caja ABIERTA de HOY del deviceId (mismo criterio que me.retomar_caja_device).
  select * into v_caja from me.cajas
  where upper(coalesce(estado, '')) = 'ABIERTA' and coalesce(printnode_id, '') = v_dev
    and to_char(fecha_apertura at time zone 'America/Lima', 'YYYY-MM-DD') = to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD')
  order by fecha_apertura desc nulls last, created_at desc nulls last
  limit 1;
  if not found then return jsonb_build_object('status', 'error', 'error', 'No hay caja ABIERTA para este deviceId'); end if;

  -- (2) Validar clave admin (8 díg, bcrypt + lockout).
  v_verif := mos.verificar_clave_admin(v_clave, 'RETOMA_CAJA_DESPUES_LOST_SESSION', coalesce(v_caja.id_caja, ''),
    'ME', v_dev, 'Retoma caja por deviceId ' || v_dev || ' · vendedor ' || coalesce(v_caja.vendedor, ''), 2);
  if not coalesce((v_verif->>'autorizado')::boolean, false) then
    return jsonb_build_object('status', 'success', 'autorizado', false,
      'mensaje', coalesce(v_verif->>'error', 'Clave incorrecta'));
  end if;

  -- (3) Autorizado → devolver la caja para repoblar la sesión.
  return jsonb_build_object('status', 'success', 'autorizado', true,
    'idCaja',   coalesce(v_caja.id_caja, ''),
    'vendedor', coalesce(v_caja.vendedor, ''),
    'zona',     coalesce(v_caja.zona_id, ''),
    'estacion', coalesce(v_caja.estacion, ''),
    'monto',    coalesce(v_caja.monto_inicial, 0));
end;
$fn$;

revoke all on function me.confirmar_retoma_caja(jsonb) from public, anon;
grant execute on function me.confirmar_retoma_caja(jsonb) to authenticated, service_role;
