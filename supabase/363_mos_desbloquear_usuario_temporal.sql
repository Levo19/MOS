-- ════════════════════════════════════════════════════════════════════════════
-- 363 · mos.desbloquear_usuario_temporal(p) — NIVEL 1 corte-GAS (WH + ME)
-- ════════════════════════════════════════════════════════════════════════════
-- BLOQUEADOR DURO compartido: el desbloqueo temporal (15 min) de un operador
-- bloqueado era 100% GAS (Bloqueos.gs::desbloquearUsuarioTemporal) en WH
-- (app.js:3685) y ME (index:13955). Sin esto, borrado GAS, un operador bloqueado
-- queda SIN forma de recibir acceso temporal. Espejo del GAS:
--   1. Valida la clave admin de 8 díg vía mos.verificar_clave_admin (bcrypt, con
--      su propio gate de app WH/ME/MOS + lockout).
--   2. Resuelve el usuario (idPersonal/nombre) — permite desbloquear aunque no
--      esté en mos.personal (legacy).
--   3. unlock_hasta = now()+15min en mos.bloqueos_usuario (update de la fila del
--      usuario; si no hay, inserta). mos.estado_bloqueo_usuario (278) ya lo LEE.
-- Retorno = shape que ambos frontends consumen: {ok, data:{autorizado, unlockHasta
-- (epoch ms), msRestantes (ms), validadoPor, error?}}.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function mos.desbloquear_usuario_temporal(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_app    text := coalesce(p->>'appOrigen', '');
  v_id     text := nullif(btrim(coalesce(p->>'idPersonal', '')), '');
  v_nom    text := nullif(btrim(coalesce(p->>'nombre', '')), '');
  v_clave  text := coalesce(p->>'claveAdmin', '');
  v_mot    text := coalesce(nullif(btrim(coalesce(p->>'motivo', '')), ''), 'desbloqueo_temporal_15min');
  v_verif  jsonb;
  v_por    text;
  v_unlock timestamptz := now() + interval '15 minutes';
  v_n      int;
  v_tid text; v_tnom text; v_tapp text;
begin
  -- Gate de app (mismo criterio que verificar_clave_admin). El device ya está autenticado al desbloquear.
  if coalesce(me.jwt_app(), '') not in ('', 'warehouseMos', 'MOS', 'mosExpress') then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_clave = '' then return jsonb_build_object('ok', false, 'error', 'Requiere claveAdmin'); end if;
  if v_id is null and v_nom is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere nombre o idPersonal');
  end if;

  -- (1) Validar clave admin (8 díg) — bcrypt + lockout dentro de la core.
  v_verif := mos.verificar_clave_admin(v_clave, 'DESBLOQUEO_USUARIO', coalesce(v_nom, v_id, ''), v_app, '', 'Desbloqueo temporal 15 min');
  if not coalesce((v_verif->>'autorizado')::boolean, false) then
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'autorizado', false, 'error', coalesce(v_verif->>'error', 'Clave incorrecta')));
  end if;
  v_por := coalesce(nullif(v_verif->>'validado_por', ''), 'admin');

  -- (2) Resolver target (permitir desbloqueo aunque no esté en mos.personal).
  select id_personal, nombre, app_origen into v_tid, v_tnom, v_tapp
  from mos.personal
  where (v_id is not null and id_personal = v_id)
     or (v_id is null and v_nom is not null and upper(btrim(coalesce(nombre, ''))) = upper(btrim(v_nom)))
  limit 1;
  v_tid  := coalesce(v_tid, v_id, '');
  v_tnom := coalesce(v_tnom, v_nom, '');
  v_tapp := coalesce(nullif(v_tapp, ''), v_app, '');

  -- (3) Aplicar unlock (update de la fila del usuario; si no hay, insertar).
  update mos.bloqueos_usuario
     set unlock_hasta = v_unlock, desbloqueado_por = v_por
   where (v_tid <> '' and id_personal = v_tid)
      or (v_tid = '' and v_tnom <> '' and upper(btrim(coalesce(nombre, ''))) = upper(btrim(v_tnom)));
  get diagnostics v_n = row_count;
  if v_n = 0 then
    insert into mos.bloqueos_usuario (id_bloqueo, id_personal, nombre, app_origen, motivo,
      bloqueado_por, fecha_bloqueo, unlock_hasta, desbloqueado_por)
    values ('BQ_' || coalesce(nullif(v_tid, ''), 'x') || '_' || (extract(epoch from clock_timestamp()) * 1000)::bigint,
      v_tid, v_tnom, v_tapp, v_mot, '', now(), v_unlock, v_por);
  end if;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'autorizado',   true,
    'unlockHasta',  floor(extract(epoch from v_unlock) * 1000)::bigint,
    'msRestantes',  floor(extract(epoch from (v_unlock - now())) * 1000)::bigint,
    'validadoPor',  v_por,
    'nombre',       v_tnom));
end;
$fn$;

revoke all on function mos.desbloquear_usuario_temporal(jsonb) from public;
grant execute on function mos.desbloquear_usuario_temporal(jsonb) to authenticated, service_role;
