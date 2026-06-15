-- ============================================================
-- 92c_me_mensajeria_gate_lectura.sql — gate de LECTURA por dispositivo (anti read-ajeno)
-- ============================================================
-- HALLAZGO (auditoría 40x): me.mis_mensajes(p) y me.marcar_leido(p) gateaban SOLO por
--   me.jwt_app()='mosExpress'. El id_personal venía del cliente SIN atar al token, así
--   que un vendedor podía pasar el id_personal de OTRA persona y leer sus mensajes de
--   tipo 'persona' (potencialmente privados: "ven a caja por el faltante"), o marcarlos
--   leídos. El token de ME no lleva id_personal — pero SÍ lleva sub=deviceId, y
--   me.presencia ata device_id ↔ id_personal en cada pulso (88/89). Usamos ese binding.
--
-- FIX: el id_personal solicitado debe estar ATADO al device del token (jwt sub) en
--   me.presencia. Si no hay binding (otro device, o nunca pulsó) → fail-closed:
--     · mis_mensajes  → ok:true con lista vacía (no filtra mensajes ajenos)
--     · marcar_leido  → error 'ID_PERSONAL_NO_ATADO_AL_DISPOSITIVO'
--   Se valida por BINDING (no por TTL de liveness): la identidad device↔persona persiste
--   aunque el pulso se atrase unos segundos; lo que se bloquea es OTRO device leyendo
--   por un id ajeno. broadcast/zona siguen siendo compartidos (no son privados).
--
-- NOTA: me.jwt_sub() — sub del token = deviceId (mintSupabaseToken en GAS ME).
-- ADITIVO: reemplaza mis_mensajes + marcar_leido; agrega helpers me.jwt_sub /
--   me._persona_atada_al_device. No toca enviar_mensaje (92b) ni tablas.
-- ============================================================

-- sub del JWT (= deviceId en ME). '' si no hay claim.
create or replace function me.jwt_sub()
returns text
language sql
stable
as $fn$
  select coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb) ->> 'sub', '');
$fn$;

-- ¿El id_personal está atado al device del token actual en me.presencia?
-- SECURITY DEFINER: lee me.presencia aunque authenticated no tenga grant directo.
-- Fail-closed: device vacío o id vacío → false.
create or replace function me._persona_atada_al_device(p_idp text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select case
    when coalesce(btrim(p_idp),'') = '' or coalesce(btrim(me.jwt_sub()),'') = '' then false
    else exists (
      select 1 from me.presencia pr
       where pr.id_personal = btrim(p_idp)
         and pr.device_id   = btrim(me.jwt_sub())
    )
  end;
$fn$;
revoke all on function me._persona_atada_al_device(text) from public, anon, authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- me.mis_mensajes(p) — ahora exige que id_personal esté atado al device del token.
--   Si no lo está → ok:true + lista vacía (no se filtran mensajes de otra persona).
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.mis_mensajes(p jsonb)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with guard as (
    select (me.jwt_app() = 'mosExpress')
       and me._persona_atada_al_device(btrim(coalesce(p->>'id_personal',''))) as ok
  ),
  params as (
    select
      btrim(coalesce(p->>'id_personal','')) as idp,
      nullif(btrim(coalesce(p->>'zona','')),'') as zona,
      least(greatest(coalesce((p->>'limit')::int, 50), 1), 200) as lim
  ),
  rel as (
    select m.id, m.remitente, m.destino_tipo, m.destino_id, m.titulo, m.cuerpo,
           m.prioridad, m.creado_at,
           (l.mensaje_id is not null) as leido,
           l.leido_at
    from me.mensajes m
    cross join params pa
    cross join guard g
    left join me.mensaje_lecturas l
      on l.mensaje_id = m.id and l.id_personal = pa.idp
    where g.ok and pa.idp <> ''
      and (
        m.destino_tipo = 'broadcast'
        or (m.destino_tipo = 'persona' and m.destino_id = pa.idp)
        or (m.destino_tipo = 'zona'    and pa.zona is not null and m.destino_id = pa.zona)
      )
    order by leido asc, m.creado_at desc
    limit (select lim from params)
  )
  select case when not (select ok from guard)
    then jsonb_build_object('ok', false, 'error', 'NO_AUTORIZADO', 'mensajes', '[]'::jsonb, 'no_leidos', 0)
    else jsonb_build_object(
    'ok', true,
    'mensajes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',          rel.id,
        'remitente',   rel.remitente,
        'destino_tipo',rel.destino_tipo,
        'destino_id',  rel.destino_id,
        'titulo',      rel.titulo,
        'cuerpo',      rel.cuerpo,
        'prioridad',   rel.prioridad,
        'leido',       rel.leido,
        'creado_at',   to_char(rel.creado_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
        'leido_at',    case when rel.leido_at is not null
                            then to_char(rel.leido_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS".000Z"')
                            else null end
      ) order by rel.leido asc, rel.creado_at desc)
      from rel
    ), '[]'::jsonb),
    'no_leidos', coalesce((select count(*) from rel where not rel.leido), 0)
  ) end;
$fn$;
revoke all on function me.mis_mensajes(jsonb) from public, anon;
grant execute on function me.mis_mensajes(jsonb) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- me.marcar_leido(p) — ahora exige binding device↔id_personal.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.marcar_leido(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_mid bigint;
  v_idp text := btrim(coalesce(p->>'id_personal',''));
begin
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  begin
    v_mid := (p->>'mensaje_id')::bigint;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'mensaje_id invalido');
  end;
  if v_mid is null or v_idp = '' then
    return jsonb_build_object('ok', false, 'error', 'mensaje_id e id_personal requeridos');
  end if;
  -- anti suplantación: solo puedes marcar leído en nombre de la persona atada a ESTE device.
  if not me._persona_atada_al_device(v_idp) then
    return jsonb_build_object('ok', false, 'error', 'ID_PERSONAL_NO_ATADO_AL_DISPOSITIVO');
  end if;
  if not exists (select 1 from me.mensajes where id = v_mid) then
    return jsonb_build_object('ok', false, 'error', 'mensaje no existe');
  end if;

  insert into me.mensaje_lecturas (mensaje_id, id_personal, leido_at)
  values (v_mid, v_idp, now())
  on conflict (mensaje_id, id_personal) do nothing;

  return jsonb_build_object('ok', true, 'mensaje_id', v_mid, 'id_personal', v_idp);
end;
$fn$;
revoke all on function me.marcar_leido(jsonb) from public, anon;
grant execute on function me.marcar_leido(jsonb) to authenticated, service_role;
