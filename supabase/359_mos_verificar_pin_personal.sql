-- ════════════════════════════════════════════════════════════════════════════
-- 359 · mos.verificar_pin_personal(p) — LOGIN por PIN 100% Supabase (cero-GAS)
-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUEANTE B2 del corte GAS: el login de MOS (confirmarPin → API.post
-- 'verificarPinPersonal') era 100% GAS (Config.gs::verificarPinPersonal). Sin
-- este RPC, al borrar GAS nadie entra a MOS.
--
-- Espejo EXACTO del GAS: busca en mos.personal (= PERSONAL_MASTER) por
-- id_personal + app_origen='MOS' + estado activo; compara el PIN en TEXTO PLANO
-- (idéntico a GAS, que hace String(persona.pin) === String(pin)); devuelve
-- {autorizado, nombre, rol}. Shape de retorno {ok, data:{...}} = el que el front
-- ya consume vía _fetch('POST').data.
--
-- Nota seguridad: el PIN vive en texto plano en la sombra (así lo guarda el
-- ecosistema hoy). El hash (mos.personal.pin_hash) es una migración aparte, NO
-- en alcance de este corte — este RPC mantiene la paridad conductual con GAS.
-- El gate mos._claim_ok() exige token de app MOS (mint-mos); el device ya está
-- autenticado (DeviceAuth) ANTES del login personal, así que hay token.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function mos.verificar_pin_personal(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal', p->>'id_personal', '')), '');
  v_pin text := coalesce(p->>'pin', '');
  v_r   record;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_pin = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere idPersonal y pin');
  end if;

  select nombre, rol, pin into v_r
  from mos.personal
  where id_personal = v_id and app_origen = 'MOS' and estado = true
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Usuario no encontrado');
  end if;

  -- PIN incorrecto → autorizado:false (NO es error de sistema; el front muestra "PIN incorrecto").
  if v_r.pin is null or v_r.pin <> v_pin then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object('autorizado', false));
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'autorizado', true, 'nombre', v_r.nombre, 'rol', v_r.rol));
end;
$fn$;

revoke all on function mos.verificar_pin_personal(jsonb) from public;
grant execute on function mos.verificar_pin_personal(jsonb) to service_role, authenticated;
