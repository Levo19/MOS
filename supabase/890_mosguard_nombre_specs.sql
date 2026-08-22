-- [890 · MosGuard NOMBRE + SPECS] El dueño: "al instalarlo le pongo nombre (para ubicarlo rápido en el panel)
-- y que MOS también vea marca/modelo/specs del equipo". Dos cosas:
--   1) el auto-registro ahora guarda marca + versión de Android (además del modelo que ya guardaba),
--      y acepta un `nombre` opcional (si el dueño lo tipeó al instalar).
--   2) RPC para RENOMBRAR el equipo desde el APK, autenticado por su PROPIO secreto (no necesita la
--      clave master de nuevo): el equipo prueba su identidad con el secreto que ya tiene.
-- ADITIVO y money-safe: no toca zona ni captura_yapes; los equipos de producción quedan intactos.

alter table mos.yape_dispositivos add column if not exists marca   text;
alter table mos.yape_dispositivos add column if not exists so_ver  text;

-- ── auto-registro: ahora también marca/so_ver y nombre opcional ──
create or replace function mos.yape_guard_autoregistrar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_clave  text := coalesce(p->>'clave','');
  v_uuid   text := left(nullif(btrim(coalesce(p->>'deviceUuid','')),''), 64);
  v_modelo text := left(btrim(coalesce(p->>'modelo','')), 40);
  v_marca  text := left(btrim(coalesce(p->>'marca','')), 40);
  v_so     text := left(btrim(coalesce(p->>'so','')), 24);
  v_nombre text := left(btrim(coalesce(p->>'nombre','')), 60);   -- opcional: nombre puesto por el dueño
  v_auth   jsonb; v_sec text; v_nom text; v_id bigint;
begin
  -- AUTORIZACIÓN: la misma clave MASTER del desbloqueo (acción MOSGUARD_UNLOCK, nivel 3 = solo MASTER).
  v_auth := mos.verificar_clave_admin(v_clave, 'MOSGUARD_UNLOCK', '', 'mosGuard', coalesce(v_uuid,''), 'autoregistro', null, null);
  if not coalesce((v_auth->>'autorizado')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'clave no autorizada');
  end if;
  if v_uuid is null then return jsonb_build_object('ok', false, 'error', 'falta deviceUuid'); end if;

  v_sec := 'yc_' || encode(extensions.gen_random_bytes(24), 'hex');   -- secreto nuevo (mismo formato que el código)
  -- nombre: el que puso el dueño; si no, modelo · 4 del uuid (legible en el panel)
  v_nom := coalesce(nullif(v_nombre,''), nullif(v_modelo,''), 'MosGuard') ||
           (case when v_nombre = '' then ' · ' || left(v_uuid, 4) else '' end);

  select id into v_id from mos.yape_dispositivos where device_uuid = v_uuid;
  if v_id is null then
    insert into mos.yape_dispositivos (nombre, zona, secreto_hash, activo, modelo, marca, so_ver, captura_yapes, device_uuid, creado_ts)
    values (v_nom, null, encode(extensions.digest(v_sec,'sha256'),'hex'), true, v_modelo,
            nullif(v_marca,''), nullif(v_so,''), false, v_uuid, now())
    returning id into v_id;
  else
    -- ya existía (reinstalación / perdió el secreto): rota el secreto, reactiva, refresca specs, NO toca zona ni captura.
    -- El nombre SOLO se pisa si el dueño mandó uno nuevo explícito (no sobrescribir el que ya nombró en el panel).
    update mos.yape_dispositivos
       set secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex'), activo = true,
           modelo = coalesce(nullif(v_modelo,''), modelo),
           marca  = coalesce(nullif(v_marca,''),  marca),
           so_ver = coalesce(nullif(v_so,''),     so_ver),
           nombre = case when v_nombre <> '' then v_nombre else nombre end
     where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'secreto', v_sec, 'nombre', (select nombre from mos.yape_dispositivos where id = v_id), 'zona', ''));
end $function$;
grant execute on function mos.yape_guard_autoregistrar(jsonb) to authenticated, anon, service_role;

-- ── renombrar: el equipo prueba su identidad con su PROPIO secreto (no la clave master) ──
create or replace function mos.yape_guard_renombrar(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_sec    text := coalesce(p->>'secreto','');
  v_nombre text := left(btrim(coalesce(p->>'nombre','')), 60);
  v_id bigint;
begin
  if v_nombre = '' then return jsonb_build_object('ok', false, 'error', 'falta nombre'); end if;
  select id into v_id from mos.yape_dispositivos
   where secreto_hash = encode(extensions.digest(v_sec,'sha256'),'hex') and activo;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'secreto no válido'); end if;
  update mos.yape_dispositivos set nombre = v_nombre where id = v_id;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('nombre', v_nombre));
end $function$;
grant execute on function mos.yape_guard_renombrar(jsonb) to authenticated, anon, service_role;

select 'yape_guard_autoregistrar + renombrar + specs listos' as ok;
