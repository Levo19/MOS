-- ============================================================
-- 92_me_mensajeria.sql — MENSAJERÍA dirigida de MosExpress (ME)
-- ============================================================
-- OBJETIVO: que un admin/cajero pueda mandar un mensaje a (a) UNA persona,
--   (b) TODOS los de UNA zona, o (c) BROADCAST (todos los presentes), y que les
--   llegue (1) PUSH (vía FCM, disparado por GAS) y (2) IN-APP (los ven al pollear).
--
-- ARQUITECTURA DE ENVÍO (confirmada en el código real del ecosistema):
--   · El FCM real lo manda SOLO MOS GAS (Push.gs:enviarPushUsuario), que tiene la
--     server key. NINGUNA RPC de Supabase ni el cliente conoce esa key.
--   · ME GAS ya habla con MOS por UrlFetchApp (MOS_WEB_APP_URL) con
--     { action:'enviarPushUsuario', usuario:<NOMBRE>, titulo, cuerpo, idNotif, extra }.
--     ⚠️ enviarPushUsuario matchea por NOMBRE (lowercased) contra PUSH_TOKENS, NO por
--     id_personal ni token. Por eso esta RPC devuelve también el NOMBRE de cada
--     destinatario presente → GAS lo reenvía como 'usuario'. (También devolvemos
--     push_token por si una fase futura quiere mandar por token directo.)
--
--   CAMINO LIMPIO ELEGIDO:
--     1) Front/admin → RPC me.enviar_mensaje(p)  → PERSISTE el mensaje + resuelve los
--        destinatarios PRESENTES (TTL 2min) y devuelve {mensaje_id, destinatarios[]}.
--     2) El llamador (front o GAS) toma esa lista y, por cada destinatario, pega a
--        ME GAS action='msg_push_destinatarios' (wrapper nuevo en Code.gs) que reenvía
--        a MOS enviarPushUsuario. El IN-APP sale del polling de me.mis_mensajes.
--
-- MODELO DE ACCESO: idéntico al 88/89/90. Gate fail-closed me.jwt_app()='mosExpress'.
--   security definer + search_path='' (las tablas no tienen grants a authenticated;
--   solo las funciones security definer las tocan).
--
-- ADITIVO / NO ROMPE NADA: 2 tablas nuevas + 3 RPCs nuevas. No toca me.presencia
--   (88/89/90), ni me.cajas, ni ventas, ni el login. La PWA lo cableará en la
--   próxima tanda (UI). Numeración 92 (91 = wh_guia_detalle_operacional).
-- ============================================================

-- ───────────────────────────────────────────────────────────────────────────
-- 1) Tabla me.mensajes — un mensaje enviado (cabecera).
--    destino_tipo: 'persona' | 'zona' | 'broadcast'
--    destino_id  : id_personal (persona) | zona (zona) | NULL (broadcast)
--    prioridad   : 'normal' | 'alta'  (informativo; la UI decide el realce)
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists me.mensajes (
  id           bigint generated always as identity primary key,
  remitente    text not null default '',        -- nombre/“admin:” de quien envía (texto)
  destino_tipo text not null,                    -- 'persona' | 'zona' | 'broadcast'
  destino_id   text,                             -- id_personal | zona | null
  titulo       text not null default '',
  cuerpo       text not null default '',
  prioridad    text not null default 'normal',   -- 'normal' | 'alta'
  creado_at    timestamptz not null default now(),
  constraint me_mensajes_destino_tipo_chk
    check (destino_tipo in ('persona','zona','broadcast')),
  -- coherencia: persona/zona exigen destino_id; broadcast lo deja null
  constraint me_mensajes_destino_id_chk
    check (
      (destino_tipo = 'broadcast' and destino_id is null) or
      (destino_tipo in ('persona','zona') and coalesce(btrim(destino_id),'') <> '')
    )
);

-- Lectura del inbox: por destino y recencia.
create index if not exists idx_me_mensajes_tipo_dest_creado
  on me.mensajes (destino_tipo, destino_id, creado_at desc);
create index if not exists idx_me_mensajes_creado
  on me.mensajes (creado_at desc);

-- ───────────────────────────────────────────────────────────────────────────
-- 2) Tabla me.mensaje_lecturas — quién leyó qué (1 fila por (mensaje,persona)).
--    Idempotente: marcar_leido upsertea; releer no duplica.
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists me.mensaje_lecturas (
  mensaje_id  bigint not null references me.mensajes(id) on delete cascade,
  id_personal text   not null,
  leido_at    timestamptz not null default now(),
  primary key (mensaje_id, id_personal)
);
create index if not exists idx_me_lecturas_persona
  on me.mensaje_lecturas (id_personal);

-- RLS defensiva (todo va por RPCs security definer; authenticated NO toca tablas crudas).
alter table me.mensajes         enable row level security;
alter table me.mensaje_lecturas enable row level security;
revoke all on table me.mensajes,         me.mensaje_lecturas from anon, authenticated;
grant  all on table me.mensajes,         me.mensaje_lecturas to service_role;
-- la secuencia de identity también, para INSERT desde la función security definer
do $$ begin
  execute 'revoke all on all sequences in schema me from anon, authenticated';
exception when others then null; end $$;

-- ───────────────────────────────────────────────────────────────────────────
-- 3) me.enviar_mensaje(p jsonb) — persiste + resuelve destinatarios PRESENTES.
--    p = {
--      remitente?, destino_tipo:'persona'|'zona'|'broadcast',
--      destino_id? (id_personal o zona; null/omitido en broadcast),
--      titulo, cuerpo, prioridad? ('normal'|'alta')
--    }
--    Devuelve {
--      ok, mensaje_id,
--      destinatarios:[ {id_personal, nombre, zona, push_token} ]   (solo PRESENTES, TTL 2min)
--    }
--    · NO llama a FCM. El push real lo dispara GAS con la lista de destinatarios
--      (por 'nombre' → enviarPushUsuario de MOS).
--    · El mensaje se persiste SIEMPRE (aunque no haya nadie presente) → queda en el
--      inbox y lo verán cuando entren (in-app), aunque no reciban push en vivo.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.enviar_mensaje(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_remitente text := coalesce(p->>'remitente','');
  v_tipo      text := lower(btrim(coalesce(p->>'destino_tipo','')));
  v_dest      text := nullif(btrim(coalesce(p->>'destino_id','')),'');
  v_titulo    text := coalesce(p->>'titulo','');
  v_cuerpo    text := coalesce(p->>'cuerpo','');
  v_prio      text := lower(btrim(coalesce(nullif(p->>'prioridad',''),'normal')));
  v_id        bigint;
  v_dests     jsonb;
begin
  -- fail-closed: solo tokens de ME.
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- validaciones de entrada
  if v_tipo not in ('persona','zona','broadcast') then
    return jsonb_build_object('ok', false, 'error', 'destino_tipo invalido');
  end if;
  if v_tipo in ('persona','zona') and v_dest is null then
    return jsonb_build_object('ok', false, 'error', 'destino_id requerido para ' || v_tipo);
  end if;
  if v_tipo = 'broadcast' then v_dest := null; end if;       -- broadcast no lleva destino_id
  if btrim(v_titulo) = '' and btrim(v_cuerpo) = '' then
    return jsonb_build_object('ok', false, 'error', 'titulo o cuerpo requerido');
  end if;
  if v_prio not in ('normal','alta') then v_prio := 'normal'; end if;

  -- persistir cabecera
  insert into me.mensajes (remitente, destino_tipo, destino_id, titulo, cuerpo, prioridad)
  values (v_remitente, v_tipo, v_dest, v_titulo, v_cuerpo, v_prio)
  returning id into v_id;

  -- resolver destinatarios PRESENTES (TTL 2min). Mismo criterio de presencia que
  -- presencia_por_zona. Solo con push_token NO vacío (sin token → no hay a quién pushear,
  -- pero igual lo verán in-app).
  select coalesce(jsonb_agg(jsonb_build_object(
           'id_personal', pr.id_personal,
           'nombre',      pr.nombre,
           'zona',        pr.zona,
           'push_token',  pr.push_token
         ) order by pr.nombre), '[]'::jsonb)
    into v_dests
  from me.presencia pr
  where pr.last_seen > now() - interval '2 minutes'
    and coalesce(pr.push_token,'') <> ''
    and (
      (v_tipo = 'broadcast')
      or (v_tipo = 'zona'    and pr.zona = v_dest)
      or (v_tipo = 'persona' and pr.id_personal = v_dest)
    );

  return jsonb_build_object(
    'ok', true,
    'mensaje_id', v_id,
    'destinatarios', v_dests
  );
end;
$fn$;
revoke all on function me.enviar_mensaje(jsonb) from public;
grant execute on function me.enviar_mensaje(jsonb) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- 4) me.mis_mensajes(p jsonb) — inbox de una persona.
--    p = { id_personal, zona?, limit? }
--    Devuelve los mensajes RELEVANTES para esa persona:
--      · persona   → destino_id = id_personal
--      · zona      → destino_id = zona (la zona ACTUAL que manda el front)
--      · broadcast → siempre
--    No-leídos primero (leido=false), luego recientes; tope = limit (default 50).
--    Cada item incluye 'leido' (bool) y 'leido_at'.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me.mis_mensajes(p jsonb)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  with guard as (select me.jwt_app() = 'mosExpress' as ok),
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
    then jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA', 'mensajes', '[]'::jsonb, 'no_leidos', 0)
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
revoke all on function me.mis_mensajes(jsonb) from public;
grant execute on function me.mis_mensajes(jsonb) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- 5) me.marcar_leido(p jsonb) — marca un mensaje como leído por una persona.
--    p = { mensaje_id, id_personal }
--    Idempotente: 2 veces → 1 fila (conserva el 1er leido_at). Devuelve {ok}.
--    Valida que el mensaje exista (FK lo garantiza igual; devolvemos error claro).
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
  if not exists (select 1 from me.mensajes where id = v_mid) then
    return jsonb_build_object('ok', false, 'error', 'mensaje no existe');
  end if;

  insert into me.mensaje_lecturas (mensaje_id, id_personal, leido_at)
  values (v_mid, v_idp, now())
  on conflict (mensaje_id, id_personal) do nothing;   -- idempotente: conserva el 1er leido_at

  return jsonb_build_object('ok', true, 'mensaje_id', v_mid, 'id_personal', v_idp);
end;
$fn$;
revoke all on function me.marcar_leido(jsonb) from public;
grant execute on function me.marcar_leido(jsonb) to authenticated, service_role;
