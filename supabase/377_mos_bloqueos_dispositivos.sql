-- 377 · kill-GAS (MOS) batch4 — bloqueos de dispositivos/vendedor. Gate mos._claim_ok().

create or replace function mos.rechazar_dispositivo_pendiente(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idDispositivo', p->>'ID_Dispositivo', p->>'deviceId','')),''); v_est text; v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idDispositivo requerido'); end if;
  select upper(coalesce(estado,'')) into v_est from mos.dispositivos where id_dispositivo = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','dispositivo no encontrado'); end if;
  if v_est = 'ACTIVO' then return jsonb_build_object('ok',true,'skipped',true,'motivo','ya_activo_no_se_rechaza'); end if;
  update mos.dispositivos set estado='INACTIVO' where id_dispositivo = v_id;
  return jsonb_build_object('ok',true);
end; $fn$;

create or replace function mos.liberar_dispositivo_bloqueado(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'deviceId', p->>'idDispositivo','')),''); v_clave text := coalesce(p->>'claveAdmin',''); v_verif jsonb; v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','deviceId requerido'); end if;
  if v_clave = '' then return jsonb_build_object('ok',false,'error','claveAdmin requerida'); end if;
  v_verif := mos.verificar_clave_admin(v_clave, 'LIBERAR_DISPOSITIVO', v_id, coalesce(p->>'app',''), v_id, coalesce(p->>'motivo','Liberar dispositivo bloqueado'));
  if not coalesce((v_verif->>'autorizado')::boolean,false) then
    return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',false,'error',coalesce(v_verif->>'error','Clave incorrecta')));
  end if;
  update mos.dispositivos set estado='ACTIVO', razon_bloqueo=null, bloqueado_desde=null where id_dispositivo = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','dispositivo no encontrado'); end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('autorizado',true));
end; $fn$;

create or replace function mos.bloquear_vendedor_me(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_app text := coalesce(p->>'appOrigen','mosExpress');
  v_bloq boolean := coalesce((p->>'bloquear')::boolean, false);
  v_por text := coalesce(nullif(btrim(coalesce(p->>'bloqueadoPor','')),''),'admin');
  v_mot text := coalesce(nullif(btrim(coalesce(p->>'motivo','')),''),'bloqueo_admin');
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','Requiere nombre'); end if;
  if v_bloq then
    -- BLOQUEAR: fila de bloqueo sin unlock (unlock_hasta NULL = bloqueo vigente).
    update mos.bloqueos_usuario set unlock_hasta = null, motivo = v_mot, bloqueado_por = v_por, fecha_bloqueo = now()
     where upper(btrim(coalesce(nombre,''))) = upper(v_nom) or (v_id is not null and id_personal = v_id);
    get diagnostics v_n = row_count;
    if v_n = 0 then
      insert into mos.bloqueos_usuario (id_bloqueo, id_personal, nombre, app_origen, motivo, bloqueado_por, fecha_bloqueo, unlock_hasta)
      values ('BQ_'||coalesce(nullif(v_id,''),'x')||'_'||(extract(epoch from clock_timestamp())*1000)::bigint,
        coalesce(v_id,''), v_nom, v_app, v_mot, v_por, now(), null);
    end if;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('bloqueado',true));
  else
    -- DESBLOQUEAR: unlock_hasta lejano (acceso restaurado).
    update mos.bloqueos_usuario set unlock_hasta = now() + interval '100 years', desbloqueado_por = v_por
     where upper(btrim(coalesce(nombre,''))) = upper(v_nom) or (v_id is not null and id_personal = v_id);
    return jsonb_build_object('ok',true,'data',jsonb_build_object('bloqueado',false));
  end if;
end; $fn$;

-- bloquearDispositivosDeUsuario: best-effort por ultima_sesion (mapeo device→usuario no es fuerte en la sombra).
create or replace function mos.bloquear_dispositivos_usuario(p jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_nom text := nullif(btrim(coalesce(p->>'nombre','')),''); v_mot text := coalesce(p->>'motivo','bloqueo_desde_personal_dia'); v_n int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','Requiere nombre'); end if;
  update mos.dispositivos set estado='INACTIVO', razon_bloqueo=v_mot, bloqueado_desde=now()
   where upper(coalesce(estado,'')) <> 'INACTIVO'
     and upper(coalesce(ultima_sesion,'')) like ('%'||upper(v_nom)||'%');
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('bloqueados',v_n));
end; $fn$;

revoke all on function mos.rechazar_dispositivo_pendiente(jsonb), mos.liberar_dispositivo_bloqueado(jsonb),
  mos.bloquear_vendedor_me(jsonb), mos.bloquear_dispositivos_usuario(jsonb) from public, anon;
grant execute on function mos.rechazar_dispositivo_pendiente(jsonb), mos.liberar_dispositivo_bloqueado(jsonb),
  mos.bloquear_vendedor_me(jsonb), mos.bloquear_dispositivos_usuario(jsonb) to authenticated, service_role;
