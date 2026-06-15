-- ============================================================
-- 92b_me_mensajeria_gate_admin.sql — HARDENING del ENVÍO de mensajería ME
-- ============================================================
-- HALLAZGO (auditoría 40x adversarial): me.enviar_mensaje gateaba SOLO por
--   me.jwt_app()='mosExpress'. El token de ME (mintSupabaseToken en GAS) NO lleva
--   rol — el dispositivo ROTA entre vendedor/admin. Por lo tanto CUALQUIER token de
--   ME (el de un vendedor) podía llamar la RPC directo y mandar avisos masivos
--   (broadcast/zona/persona) saltándose el `v-if esAdminME` + PIN del frontend.
--   Confirmado en vivo: ok:true + devolvía push_token de presentes (exfiltración).
--
-- FIX (defensa en profundidad, server-side): el ENVÍO ahora exige una clave admin
--   de 8 dígitos (global 4 + pin personal 4) verificada EN EL SERVIDOR contra el
--   mismo origen de verdad que mos.verificar_clave_admin (hash bcrypt del pin global
--   en mos.config + pin_hash personal en mos.personal con rol nivel>=2 y activo).
--   Sin clave válida → CLAVE_ADMIN_REQUERIDA / CLAVE_ADMIN_INVALIDA / NIVEL_INSUFICIENTE.
--
--   No reusamos mos.verificar_clave_admin directamente porque su gate _claim_ok()
--   acepta app in ('', 'MOS') / ('', 'warehouseMos') y RECHAZA 'mosExpress'. Creamos
--   un verificador interno en el schema me, SECURITY DEFINER, que NO re-chequea app
--   (enviar_mensaje ya validó jwt_app()='mosExpress' antes de llamarlo). Replica la
--   lógica de verificación (sin auditoría duplicada; el ENVÍO no necesita fila de
--   auditoría admin — el mensaje ya queda persistido con remitente).
--
-- ADITIVO: solo reemplaza me.enviar_mensaje + agrega me._verificar_admin_pin.
--   NO toca mis_mensajes / marcar_leido / presencia / tablas.
-- ============================================================

-- ───────────────────────────────────────────────────────────────────────────
-- 1) me._verificar_admin_pin(clave) — verificación server-side del PIN admin.
--    Devuelve { ok:true, autorizado:bool, nombre?, id_personal?, rol?, error? }.
--    NO audita (el envío persiste el mensaje con remitente). NO chequea app
--    (el caller ya gateó jwt_app()='mosExpress'). SECURITY DEFINER para leer
--    mos.config / mos.personal aunque authenticated no tenga grants directos.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function me._verificar_admin_pin(p_clave text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_clave  text := btrim(coalesce(p_clave,''));
  v_global text; v_user text; v_ghash text;
  v_id text; v_nombre text; v_apellido text; v_rol text;
begin
  if v_clave = '' or length(v_clave) <> 8 or v_clave !~ '^\d{8}$' then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'La clave debe ser de 8 dígitos numéricos');
  end if;
  v_global := substr(v_clave, 1, 4);
  v_user   := substr(v_clave, 5, 4);

  select valor into v_ghash from mos.config where clave = 'ADMIN_GLOBAL_PIN_HASH' limit 1;
  if v_ghash is null then
    return jsonb_build_object('ok', false, 'error', 'ADMIN_GLOBAL_PIN_HASH no configurado en MOS');
  end if;
  if v_ghash <> extensions.crypt(v_global, v_ghash) then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Clave incorrecta');
  end if;

  -- admin/master (nivel>=2), activo, con pin_hash que matchee
  select p.id_personal, p.nombre, p.apellido, p.rol
    into v_id, v_nombre, v_apellido, v_rol
    from mos.personal p
   where mos.rol_nivel(p.rol) >= 2
     and p.estado = true
     and p.pin_hash is not null
     and p.pin_hash = extensions.crypt(v_user, p.pin_hash)
   limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'autorizado', false, 'error', 'Clave incorrecta');
  end if;

  return jsonb_build_object(
    'ok', true, 'autorizado', true,
    'id_personal', v_id,
    'nombre', btrim(v_nombre || ' ' || coalesce(v_apellido,'')),
    'rol', v_rol
  );
end;
$fn$;
revoke all on function me._verificar_admin_pin(text) from public, anon, authenticated;
-- solo lo llaman funciones security definer del schema me (no se expone a PostgREST)

-- ───────────────────────────────────────────────────────────────────────────
-- 2) me.enviar_mensaje(p) — ahora exige clave_admin verificada server-side.
--    p += { clave_admin: '<8 dígitos>' }.  Si falta/invalida → rechazo.
--    Si la clave es válida pero el remitente no se mandó, lo derivamos del admin
--    verificado (no confiamos ciegamente en p->>'remitente', pero lo respetamos
--    si vino — es solo texto informativo del inbox).
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
  v_clave     text := coalesce(p->>'clave_admin','');
  v_auth      jsonb;
  v_id        bigint;
  v_dests     jsonb;
begin
  -- fail-closed: solo tokens de ME.
  if me.jwt_app() <> 'mosExpress' then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- [HARDENING 92b] Gate de ADMIN server-side: el ENVÍO es privilegiado y el token
  -- de ME no lleva rol. Exigir clave admin verificada (no confiar en el v-if del front).
  if btrim(v_clave) = '' then
    return jsonb_build_object('ok', false, 'error', 'CLAVE_ADMIN_REQUERIDA');
  end if;
  v_auth := me._verificar_admin_pin(v_clave);
  if coalesce((v_auth->>'ok')::boolean, false) is not true then
    -- error de configuración (ej. hash global ausente)
    return jsonb_build_object('ok', false, 'error', coalesce(v_auth->>'error','VERIFICACION_FALLIDA'));
  end if;
  if coalesce((v_auth->>'autorizado')::boolean, false) is not true then
    return jsonb_build_object('ok', false, 'error', 'CLAVE_ADMIN_INVALIDA',
                             'detalle', coalesce(v_auth->>'error',''));
  end if;

  -- validaciones de entrada
  if v_tipo not in ('persona','zona','broadcast') then
    return jsonb_build_object('ok', false, 'error', 'destino_tipo invalido');
  end if;
  if v_tipo in ('persona','zona') and v_dest is null then
    return jsonb_build_object('ok', false, 'error', 'destino_id requerido para ' || v_tipo);
  end if;
  if v_tipo = 'broadcast' then v_dest := null; end if;
  if btrim(v_titulo) = '' and btrim(v_cuerpo) = '' then
    return jsonb_build_object('ok', false, 'error', 'titulo o cuerpo requerido');
  end if;
  if v_prio not in ('normal','alta') then v_prio := 'normal'; end if;

  -- remitente: si no vino, usar el admin verificado (texto informativo del inbox)
  if btrim(v_remitente) = '' then
    v_remitente := 'admin:' || coalesce(v_auth->>'nombre','');
  end if;

  -- persistir cabecera
  insert into me.mensajes (remitente, destino_tipo, destino_id, titulo, cuerpo, prioridad)
  values (v_remitente, v_tipo, v_dest, v_titulo, v_cuerpo, v_prio)
  returning id into v_id;

  -- resolver destinatarios PRESENTES (TTL 2min) con push_token no vacío.
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
revoke all on function me.enviar_mensaje(jsonb) from public, anon;
grant execute on function me.enviar_mensaje(jsonb) to authenticated, service_role;
