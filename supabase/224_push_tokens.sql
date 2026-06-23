-- 224_push_tokens.sql — Backend de push 100% Supabase (cero GAS). Tabla de tokens + registro + selección de
-- audiencia (port fiel de gas/Push.gs: PUSH_TOKENS + registrarPushToken + _seleccionarTokensActivos).
-- El ENVÍO lo hace la Edge `push` (FCM v1). Acá vive el almacén + a quién mandar.

create table if not exists mos.push_tokens (
  id_token     text primary key,
  token        text not null,
  usuario      text default '',
  dispositivo  text default '',
  app_origen   text default 'MOS',
  device_id    text default '',
  fecha        timestamptz default now(),
  ultima_vez   timestamptz default now(),
  activo       boolean default true
);
create unique index if not exists push_tokens_token_uq on mos.push_tokens (token);
create index if not exists push_tokens_usuario_idx on mos.push_tokens (lower(usuario));

-- ── Registro/actualización (réplica registrarPushToken): upsert por token, REACTIVA a true (un token reportado
--    AHORA está vivo). app authenticated (cualquier app del ecosistema) puede registrar el suyo. ──
create or replace function mos.registrar_push_token(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_token text := nullif(btrim(coalesce(p->>'token','')), '');
  v_app   text := coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''), 'MOS');
begin
  if coalesce(me.jwt_app(),'') = '' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_token is null then return jsonb_build_object('ok',false,'error','token requerido'); end if;
  insert into mos.push_tokens (id_token, token, usuario, dispositivo, app_origen, device_id, fecha, ultima_vez, activo)
  values ('PTK-'||substr(md5(v_token),1,12), v_token, coalesce(p->>'usuario',''), coalesce(p->>'dispositivo',''),
          v_app, coalesce(p->>'deviceId',''), now(), now(), true)
  on conflict (token) do update set
    usuario = coalesce(nullif(excluded.usuario,''), mos.push_tokens.usuario),
    dispositivo = coalesce(nullif(excluded.dispositivo,''), mos.push_tokens.dispositivo),
    app_origen = excluded.app_origen,
    device_id = coalesce(nullif(excluded.device_id,''), mos.push_tokens.device_id),
    ultima_vez = now(),
    activo = true;
  return jsonb_build_object('ok', true);
end;
$fn$;

-- ── Selección de audiencia (réplica _seleccionarTokensActivos): 1 token por usuario (el más reciente), con
--    filtros rol (master/admin vía mos.personal), app, exclusión del sender, soloUsuarios/usuariosExtra. ──
create or replace function mos.seleccionar_tokens_push(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_excl  text := lower(nullif(btrim(coalesce(p->>'excluirUsuario','')),''));
  v_app   text := upper(nullif(btrim(coalesce(p->>'soloAppOrigen','')),''));
  v_master boolean := coalesce((p->>'soloRolesMaster')::boolean,false);
  v_admin  boolean := coalesce((p->>'soloRolesAdmin')::boolean,false);
  v_solo  jsonb := case when jsonb_typeof(p->'soloUsuarios')='array' then p->'soloUsuarios' else null end;
  v_extra jsonb := case when jsonb_typeof(p->'usuariosExtra')='array' then p->'usuariosExtra' else null end;
  v_tokens jsonb;
begin
  if coalesce(me.jwt_app(),'') = '' and coalesce((current_setting('request.jwt.claims', true)::jsonb)->>'role','') <> 'service_role' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  with roles as (  -- usuarios permitidos por rol (si se pidió filtro de rol)
    select lower(btrim(nombre)) n from mos.personal
      where coalesce(estado,true) = true
        and ( (v_master and upper(coalesce(rol,''))='MASTER')
           or (v_admin  and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')) )
    union
    select lower(btrim(nombre||' '||coalesce(apellido,''))) from mos.personal
      where coalesce(estado,true) = true
        and ( (v_master and upper(coalesce(rol,''))='MASTER')
           or (v_admin  and upper(coalesce(rol,'')) in ('MASTER','ADMIN','ADMINISTRADOR')) )
  ),
  app_match as (  -- normaliza app_origen a WH/ME/MOS para el filtro
    select t.*, case
        when upper(coalesce(app_origen,'')) in ('WH','WAREHOUSEMOS','WAREHOUSE','WHM') then 'WH'
        when upper(coalesce(app_origen,'')) in ('ME','MOSEXPRESS') then 'ME'
        when upper(coalesce(app_origen,'')) in ('MOS','PROYECTOMOS') then 'MOS'
        else upper(coalesce(app_origen,'')) end as app_norm
      from mos.push_tokens t
     where activo = true and coalesce(token,'') <> ''
  ),
  filtrados as (
    select * from app_match am
     where (v_excl is null or lower(btrim(coalesce(usuario,''))) <> v_excl)
       and (v_app is null or app_norm = v_app)
       and (
         -- soloUsuarios pisa todo (modo test)
         (v_solo is not null and lower(btrim(coalesce(usuario,''))) in (select lower(btrim(x)) from jsonb_array_elements_text(v_solo) x))
         or
         -- sin soloUsuarios: si hay filtro de rol, exigir match (o estar en usuariosExtra); si no, todos
         (v_solo is null and (
            (not (v_master or v_admin))
            or lower(btrim(coalesce(usuario,''))) in (select n from roles)
            or (v_extra is not null and lower(btrim(coalesce(usuario,''))) in (select lower(btrim(x)) from jsonb_array_elements_text(v_extra) x))
         ))
       )
  ),
  ranked as (  -- 1 por (usuario[+app si se filtra app]) → el de ultima_vez más reciente
    select token, usuario, app_norm,
      row_number() over (
        partition by coalesce(nullif(lower(btrim(usuario)),''), 'tok:'||token) || case when v_app is not null then '@'||app_norm else '' end
        order by ultima_vez desc nulls last
      ) rn
    from filtrados
  )
  select coalesce(jsonb_agg(jsonb_build_object('token',token,'usuario',usuario) order by usuario), '[]'::jsonb)
    into v_tokens from ranked where rn = 1;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object('tokens', v_tokens));
end;
$fn$;

-- ── Marcar token muerto (UNREGISTERED reportado por la Edge) ──
create or replace function mos.desactivar_push_token(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_token text := nullif(btrim(coalesce(p->>'token','')), '');
begin
  if coalesce(me.jwt_app(),'') = '' and coalesce((current_setting('request.jwt.claims', true)::jsonb)->>'role','') <> 'service_role' then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_token is not null then update mos.push_tokens set activo = false where token = v_token; end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function mos.registrar_push_token(jsonb) from public;
revoke all on function mos.seleccionar_tokens_push(jsonb) from public;
revoke all on function mos.desactivar_push_token(jsonb) from public;
grant execute on function mos.registrar_push_token(jsonb)  to authenticated;
grant execute on function mos.seleccionar_tokens_push(jsonb) to authenticated, service_role;
grant execute on function mos.desactivar_push_token(jsonb) to authenticated, service_role;
