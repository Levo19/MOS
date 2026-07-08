-- 405 · Log de notificaciones push (cero-GAS). Reemplaza la hoja NOTIF_LOG del GAS.
-- La Edge `push` registra cada envío VISIBLE (no silencioso) vía notif_log_registrar (service role).
-- El panel MOS lee con notif_log_listar (getNotifLog) y reenvía con notif_log_get + Edge push (misma audiencia).

create table if not exists mos.notificaciones_log (
  id_log     text primary key,
  id_notif   text not null default '',
  titulo     text not null default '',
  cuerpo     text not null default '',
  data       jsonb,
  audiencia  jsonb,               -- {usuarios/apps/roles/deviceIds} o {tokens:N} si fue por tokens directos
  tokens_total int not null default 0,
  entregadas int not null default 0,
  errores    int not null default 0,
  estado     text not null default 'OK',   -- OK | ERROR | PARCIAL
  origen     text not null default '',     -- app del claim (MOS/mosExpress/warehouseMos) o 'cron'
  ts         timestamptz not null default now()
);
create index if not exists ix_notif_log_ts on mos.notificaciones_log (ts desc);
create index if not exists ix_notif_log_idnotif on mos.notificaciones_log (id_notif);
alter table mos.notificaciones_log enable row level security;

-- INSERT (lo llama la Edge push con service role; también acepta claim app por si un cliente registra manual)
create or replace function mos.notif_log_registrar(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLog','')),'');
begin
  if coalesce(me.jwt_app(),'') = '' and coalesce(auth.role(),'') <> 'service_role' then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA');
  end if;
  if v_id is null then v_id := 'NLOG_' || to_char(now() at time zone 'America/Lima','YYYYMMDDHH24MISS') || '_' || substr(md5(random()::text),1,6); end if;
  insert into mos.notificaciones_log (id_log, id_notif, titulo, cuerpo, data, audiencia, tokens_total, entregadas, errores, estado, origen)
  values (
    v_id,
    coalesce(p->>'idNotif',''),
    coalesce(p->>'titulo',''),
    coalesce(p->>'cuerpo',''),
    case when p ? 'data' then p->'data' else null end,
    case when p ? 'audiencia' then p->'audiencia' else null end,
    coalesce((p->>'tokensTotal')::int, 0),
    coalesce((p->>'entregadas')::int, 0),
    coalesce((p->>'errores')::int, 0),
    coalesce(nullif(btrim(coalesce(p->>'estado','')),''),'OK'),
    coalesce(p->>'origen','')
  )
  on conflict (id_log) do nothing;
  return jsonb_build_object('ok',true,'idLog',v_id);
end; $fn$;

-- LISTAR (getNotifLog): {limit?, idNotif?, desde?(YYYY-MM-DD)} → shape que el panel ya renderiza.
create or replace function mos.notif_log_listar(p jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select case
    when coalesce(me.jwt_app(),'') not in ('MOS') then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    else jsonb_build_object('ok',true,'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idLog', l.id_log, 'idNotif', l.id_notif, 'titulo', l.titulo, 'cuerpo', l.cuerpo,
        'ts', l.ts, 'estado', l.estado, 'entregadas', l.entregadas, 'errores', l.errores
      ) order by l.ts desc)
      from (
        select * from mos.notificaciones_log l0
        where (nullif(btrim(coalesce(p->>'idNotif','')),'') is null or l0.id_notif = btrim(p->>'idNotif'))
          and (nullif(btrim(coalesce(p->>'desde','')),'') is null
               or l0.ts >= ((p->>'desde')::date::timestamp at time zone 'America/Lima'))
        order by l0.ts desc
        limit least(greatest(coalesce((p->>'limit')::int,100),1),500)
      ) l
    ), '[]'::jsonb)) end;
$fn$;

-- GET una fila (para reenviar: el front lee titulo/cuerpo/data/audiencia y re-dispara la Edge push).
create or replace function mos.notif_log_get(p jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select case
    when coalesce(me.jwt_app(),'') not in ('MOS') then jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA')
    else coalesce((
      select jsonb_build_object('ok',true,'data', jsonb_build_object(
        'idLog', l.id_log, 'idNotif', l.id_notif, 'titulo', l.titulo, 'cuerpo', l.cuerpo,
        'data', l.data, 'audiencia', l.audiencia, 'ts', l.ts))
      from mos.notificaciones_log l where l.id_log = btrim(coalesce(p->>'idLog',''))
    ), jsonb_build_object('ok',false,'error','NO_ENCONTRADO')) end;
$fn$;

grant execute on function mos.notif_log_registrar(jsonb) to authenticated, service_role, anon;
grant execute on function mos.notif_log_listar(jsonb)    to authenticated, service_role, anon;
grant execute on function mos.notif_log_get(jsonb)       to authenticated, service_role, anon;
