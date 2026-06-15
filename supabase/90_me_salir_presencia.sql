-- ============================================================
-- 90_me_salir_presencia.sql — BAJA EXPLÍCITA de presencia al cerrar sesión (ME)
-- ============================================================
-- OBJETIVO: cuando un vendedor/cajero hace "Cerrar sesión" (o cierra caja), el
--   login debe dejar de mostrarlo AL INSTANTE, sin esperar el TTL de 2 min de
--   presencia_por_zona. Hoy el front detiene el heartbeat pero la fila de
--   me.presencia se queda viva ~2 min → "vendedores fantasma" en el wizard.
--
--   Esta RPC borra la fila de la persona (o, si solo viene device_id, todas las
--   filas de ese dispositivo). Idempotente: borrar algo que no existe → ok:true.
--
-- MODELO DE ACCESO: idéntico al 88/89. ME habla DIRECTO a Supabase con JWT
--   scoped (claim app='mosExpress'). Gate fail-closed: me.jwt_app()='mosExpress'.
--   security definer + search_path='' (la tabla no tiene grants a authenticated;
--   solo la función security definer puede tocarla).
--
-- ADITIVO / NO ROMPE NADA: 1 RPC nueva. No toca tabla, ni el 88/89, ni cajas.
-- ============================================================

-- ───────────────────────────────────────────────────────────────────────────
-- me.salir_presencia(p jsonb) — baja explícita de presencia.
--   p = { id_personal?, device_id? }  (al menos uno; texto)
--   · Si viene id_personal → borra esa fila (PK).
--   · Si NO viene id_personal pero sí device_id → borra TODA fila de ese device
--     (cubre el caso "NOID:nombre": el front siempre tiene el deviceId aunque no
--     tenga id_personal real).
--   Devuelve { ok, borradas } (nº de filas eliminadas; 0 = ya no estaba → ok).
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.salir_presencia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'id_personal','')),'');
  v_device text := nullif(btrim(coalesce(p->>'device_id','')),'');
  v_n      integer := 0;
  v_extra  integer := 0;
begin
  -- fail-closed: solo tokens de ME (la PWA).
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  -- al menos un identificador.
  if v_id is null and v_device is null then
    return jsonb_build_object('ok', false, 'error', 'id_personal o device_id requerido');
  end if;

  if v_id is not null then
    delete from me.presencia where id_personal = v_id;
    get diagnostics v_n = row_count;
    -- si además vino device_id, limpiar cualquier fila huérfana de ese device
    -- (p.ej. una sesión previa "NOID:..." en el mismo aparato).
    if v_device is not null then
      delete from me.presencia where device_id = v_device and id_personal <> v_id;
      get diagnostics v_extra = row_count;
      v_n := v_n + v_extra;
    end if;
  else
    delete from me.presencia where device_id = v_device;
    get diagnostics v_n = row_count;
  end if;

  return jsonb_build_object('ok', true, 'borradas', v_n);
end;
$fn$;
revoke all on function me.salir_presencia(jsonb) from public;
grant execute on function me.salir_presencia(jsonb) to authenticated, service_role;
