-- [889 · MosGuard AUTO-REGISTRO] El dueño: "instalo el APK, doy permiso, y el panel lo detecta solo — sin código".
-- Hoy el equipo obtiene su secreto SOLO canjeando el código de 6 letras (yape_emparejar). Esto agrega el
-- auto-registro: al DESBLOQUEAR la app con la clave MASTER (Desbloqueo.kt / MOSGUARD_UNLOCK), el equipo se
-- registra solo — la misma verificación de la clave master AUTORIZA el registro y le entrega su secreto.
-- ADITIVO y money-safe: los equipos de producción (ZONA-1/2) YA tienen secreto → NO re-registran, no se tocan.
-- yape_emparejar (código) sigue existiendo como respaldo.

-- identidad estable del equipo (ANDROID_ID; sobrevive reinstalación). `id` es serial → no sirve de identidad.
alter table mos.yape_dispositivos add column if not exists device_uuid text;
create unique index if not exists ux_yape_disp_uuid on mos.yape_dispositivos (device_uuid) where device_uuid is not null;

create or replace function mos.yape_guard_autoregistrar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_clave  text := coalesce(p->>'clave','');
  v_uuid   text := left(nullif(btrim(coalesce(p->>'deviceUuid','')),''), 64);
  v_modelo text := left(btrim(coalesce(p->>'modelo','')), 40);
  v_auth   jsonb; v_sec text; v_nom text; v_id bigint;
begin
  -- AUTORIZACIÓN: la misma clave MASTER del desbloqueo (acción MOSGUARD_UNLOCK, nivel 3 = solo MASTER).
  v_auth := mos.verificar_clave_admin(v_clave, 'MOSGUARD_UNLOCK', '', 'mosGuard', coalesce(v_uuid,''), 'autoregistro', null, null);
  if not coalesce((v_auth->>'autorizado')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'clave no autorizada');
  end if;
  if v_uuid is null then return jsonb_build_object('ok', false, 'error', 'falta deviceUuid'); end if;

  v_sec := 'yc_' || encode(extensions.gen_random_bytes(24), 'hex');   -- secreto nuevo (mismo formato que el código)
  v_nom := coalesce(nullif(v_modelo,''), 'MosGuard') || ' · ' || left(v_uuid, 4);

  -- upsert por device_uuid. Nace con zona=null y captura_yapes=false (solo resguardo; el Yape se asigna aparte).
  select id into v_id from mos.yape_dispositivos where device_uuid = v_uuid;
  if v_id is null then
    insert into mos.yape_dispositivos (nombre, zona, secreto_hash, activo, modelo, captura_yapes, device_uuid, creado_ts)
    values (v_nom, null, encode(extensions.digest(v_sec,'sha256'),'hex'), true, v_modelo, false, v_uuid, now())
    returning id into v_id;
  else
    -- ya existía (reinstalación / perdió el secreto): rota el secreto, reactiva, NO toca zona ni captura.
    update mos.yape_dispositivos
       set secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex'), activo = true,
           modelo = coalesce(nullif(v_modelo,''), modelo)
     where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'secreto', v_sec, 'nombre', (select nombre from mos.yape_dispositivos where id = v_id), 'zona', ''));
end $function$;
grant execute on function mos.yape_guard_autoregistrar(jsonb) to authenticated, anon, service_role;

select 'yape_guard_autoregistrar listo' as ok;
