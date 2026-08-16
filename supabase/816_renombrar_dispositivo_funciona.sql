-- 816_renombrar_dispositivo_funciona.sql — [DUEÑO] "quiero fijar un dispositivo, me alerta que
-- debo poner nombre, se abre un modal… le pongo nombre y guardo, se cierra y sale este toast:
-- idDispositivo requerido".
--
-- DOS BUGS, y el gordo es anterior a mi botón:
--
-- (1) RENOMBRAR UN EQUIPO DESDE EL PANEL NUNCA FUNCIONÓ. El front manda
--     `{ ID_Dispositivo, Nombre_Equipo, App, Estado }` y `mos.actualizar_dispositivo` lee
--     `idDispositivo`/`deviceId` y `nombreEquipo`. Nunca coincidieron: la RPC cortaba en la
--     primera línea con "idDispositivo requerido" y el nombre no se guardaba jamás. Se confirma
--     con los datos: `nombre_manual` = 0 de 374 equipos.
--     (Hay una segunda ruta, `admin_actualizar_dispositivo`, que sí usa las claves del front —
--     pero el propio api.js documenta que es INALCANZABLE: `_MOS_ADMIN_RPC` resuelve la acción
--     antes y manda a `actualizar_dispositivo`.)
--
-- (2) MI GUARDIA DEL 808 ESTABA EN LA FUNCIÓN EQUIVOCADA. La puse en
--     `actualizar_dispositivo` creyendo que era el equipo reportándose solo, y es justo al revés:
--     esa es la del PANEL. El equipo se nombra en `registrar_dispositivo`, y solo en el INSERT
--     (nunca pisa un nombre existente), así que la fuga que quise tapar no existía. Tal como
--     quedó, el admin no habría podido renombrar un equipo ya bautizado.
--
-- FIX: la RPC acepta las claves de las DOS convenciones (nadie tiene que adivinar cuál), marca
-- `nombre_manual` cuando una persona pone el nombre desde el panel, y se retira la guardia.

create or replace function mos.actualizar_dispositivo(p jsonb)
returns jsonb language plpgsql security definer set search_path to ''
as $fn$
declare
  -- [816] se aceptan ambas convenciones: la del front (ID_Dispositivo/Nombre_Equipo) y la
  -- camelCase que usaban otras llamadas. Antes solo la segunda, y el front usa la primera.
  v_id     text := nullif(btrim(coalesce(p->>'idDispositivo', p->>'deviceId', p->>'ID_Dispositivo','')),'');
  v_nombre text := nullif(btrim(coalesce(p->>'nombreEquipo', p->>'Nombre_Equipo','')),'');
  v_estado text := nullif(btrim(coalesce(p->>'estado', p->>'Estado','')),'');
  v_app    text := nullif(btrim(coalesce(p->>'app', p->>'App','')),'');
  v_zona   text := nullif(btrim(coalesce(p->>'ultimaZona', p->>'Ultima_Zona','')),'');
  v_est    text := nullif(btrim(coalesce(p->>'ultimaEstacion', p->>'Ultima_Estacion','')),'');
  v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idDispositivo requerido'); end if;

  update mos.dispositivos set
    -- [816] el panel SÍ puede renombrar; y si lo hace, queda constancia de que el nombre lo
    -- puso una persona (requisito para poder FIJAR el equipo — ver 807/808).
    nombre_equipo = coalesce(v_nombre, nombre_equipo),
    nombre_manual = case when v_nombre is not null then true else nombre_manual end,
    estado        = coalesce(v_estado, estado),
    app           = coalesce(v_app, app),
    ultima_zona     = coalesce(v_zona, ultima_zona),
    ultima_estacion = coalesce(v_est, ultima_estacion),
    forzar_wizard   = coalesce(nullif(btrim(coalesce(p->>'forzarWizard','')),'')::boolean, forzar_wizard),
    forzar_push     = coalesce(nullif(btrim(coalesce(p->>'forzarPush','')),'')::boolean, forzar_push),
    forzar_reverify = coalesce(nullif(btrim(coalesce(p->>'forzarReverify','')),'')::boolean, forzar_reverify)
   where id_dispositivo = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','dispositivo no encontrado'); end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'ID_Dispositivo', v_id, 'Nombre_Equipo', v_nombre, 'nombreManual', (v_nombre is not null)));
end $fn$;

grant execute on function mos.actualizar_dispositivo(jsonb) to anon, authenticated, service_role;
