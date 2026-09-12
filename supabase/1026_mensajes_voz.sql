-- 1026 · Mensajes de VOZ (TTS) admin → dispositivo, cross-app ME + WH (12-sep-2026).
--
-- El admin/master escribe un texto en MOS, elige un dispositivo, y ese equipo LO LEE EN VOZ ALTA
-- (Web Speech API, que ambas apps ya usan: ME speechSynthesis, WH Voice.speak). Entrega por poll
-- liviano (voz_pendientes por deviceId, índice parcial). NO es dinero.
--
-- Nota autoplay: el TTS solo suena si la app está ABIERTA y hubo un toque previo (política del navegador).
-- Si el equipo está cerrado, el mensaje queda NUEVO y se lee al abrir. Por eso no usamos push aquí.

create table if not exists mos.mensajes_voz (
  id           bigint generated always as identity primary key,
  device_id    text not null,                 -- destino: dispositivo
  id_personal  text,                           -- a quién (informativo)
  nombre_dest  text,                           -- nombre destino (informativo)
  texto        text not null,
  emisor       text,                           -- quién lo envió
  app_destino  text,                           -- 'mosExpress' | 'warehouseMos' (informativo)
  estado       text not null default 'NUEVO',  -- NUEVO | LEIDO
  creado       timestamptz not null default now(),
  leido_at     timestamptz
);
create index if not exists ix_mensajes_voz_pend on mos.mensajes_voz (device_id, estado) where estado = 'NUEVO';
create index if not exists ix_mensajes_voz_creado on mos.mensajes_voz (creado desc);

-- ── ENVIAR (solo desde MOS admin) ──────────────────────────────────────────────────────────────
create or replace function mos.voz_enviar(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_app    text := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'app','');
  v_dev    text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_texto  text := nullif(btrim(coalesce(p->>'texto','')), '');
  v_id     bigint;
begin
  if v_app <> 'MOS' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null or v_texto is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if length(v_texto) > 600 then v_texto := left(v_texto, 600); end if;
  insert into mos.mensajes_voz (device_id, id_personal, nombre_dest, texto, emisor, app_destino)
  values (v_dev, nullif(btrim(coalesce(p->>'idPersonal','')),''), nullif(btrim(coalesce(p->>'nombreDest','')),''),
          v_texto, nullif(btrim(coalesce(p->>'emisor','')),''), nullif(btrim(coalesce(p->>'appDestino','')),''))
  returning id into v_id;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('id',v_id));
end;
$function$;

-- ── PENDIENTES (cualquier app, por su propio deviceId) ─────────────────────────────────────────
create or replace function mos.voz_pendientes(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_arr jsonb;
begin
  -- receptores: ME + WH + MOS (la seguridad real es el deviceId: cada equipo solo ve SUS mensajes).
  if coalesce(me.jwt_app(),'') not in ('mosExpress','warehouseMos','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null then return jsonb_build_object('ok',true,'data',jsonb_build_array()); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'texto', texto, 'emisor', coalesce(emisor,''),
           'hora', to_char(creado at time zone 'America/Lima','HH24:MI')
         ) order by creado asc), jsonb_build_array())
    into v_arr
  from mos.mensajes_voz
  where device_id = v_dev and estado = 'NUEVO' and creado > now() - interval '2 days';   -- no leer mensajes muy viejos
  return jsonb_build_object('ok',true,'data',v_arr);
end;
$function$;

-- ── MARCAR LEÍDO (el propio dispositivo, tras hablarlo) ────────────────────────────────────────
create or replace function mos.voz_marcar_leido(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_dev text := nullif(btrim(coalesce(p->>'deviceId','')), '');
  v_ids bigint[];
  v_n   int;
begin
  if coalesce(me.jwt_app(),'') not in ('mosExpress','warehouseMos','MOS') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_dev is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  select array_agg((x)::bigint) into v_ids from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) x;
  if v_ids is null then return jsonb_build_object('ok',true,'data',jsonb_build_object('leidos',0)); end if;
  update mos.mensajes_voz set estado='LEIDO', leido_at=now()
   where id = any(v_ids) and device_id = v_dev and estado='NUEVO';
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('leidos',v_n));
end;
$function$;

grant execute on function mos.voz_enviar(jsonb)       to authenticated;
grant execute on function mos.voz_pendientes(jsonb)   to authenticated;
grant execute on function mos.voz_marcar_leido(jsonb) to authenticated;

select '1026 mensajes_voz listo' ok;
