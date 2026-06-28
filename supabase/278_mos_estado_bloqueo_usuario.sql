-- ============================================================================================================
-- 278_mos_estado_bloqueo_usuario.sql — [CERO-GAS WH · G1] estado de bloqueo de usuario + heartbeat, 1 RPC anon
-- ------------------------------------------------------------------------------------------------------------
-- Reemplaza el poll GAS `getEstadoBloqueoUsuario` (Bloqueos.gs:51) que WH (BloqueoRemoto._check) y ME pegan
-- cada 120s. Ese endpoint hace DOS cosas en una llamada:
--   (1) LEE el estado de bloqueo del usuario (merge de mos.personal.estado + mos.bloqueos_usuario).
--   (2) HEARTBEAT: actualiza mos.dispositivos.ultima_conexion/ultima_sesion/zona/estacion (para que el panel
--       admin vea el equipo "en línea") + mos.personal.ultima_conexion (presencia del operador).
-- Acá lo replicamos en UN solo RPC anon `mos.estado_bloqueo_usuario(p)` con paridad EXACTA del shape de salida.
--
-- PARIDAD con GAS (Bloqueos.gs) — EXACTA en el path PRIMARIO de WH (match por idPersonal):
--   · _normalizarNombre = trim().toLowerCase()  → lower(btrim(...))  (SIN unaccent: GAS no lo hace; mantener).
--   · _normalizarApp: 'express'|'me'→mosexpress ; 'warehouse'|'wh'→warehousemos ; else lower(trim).
--   · estaInactivoEnPM: SOLO apps != mosexpress (los vendedores ME comparten usuario plantilla → se identifican
--     por nombre, no viven como persona real). persona.estado=false ⇔ inactivo.
--   · idPersonal es el identificador PRIMARIO de WH (el match por nombre es fallback). WH manda idPersonal
--     siempre (BloqueoRemoto._check sale temprano si no hay idPersonal) → el path real es idéntico a GAS.
--   · bloqueado = (estaInactivoEnPM OR fecha_bloqueo seteado) AND NOT unlockVigente.
--   · unlockHasta se devuelve en epoch MS (int) como GAS; msRestantes idem.
--
-- ⚠ DIVERGENCIAS DELIBERADAS (NO "paridad exacta") en los paths NO-primarios — documentadas, no bugs:
--   · Fallback por NOMBRE: acá comparo nombre COMPLETO (nombre||' '||apellido); GAS compara solo PERSONAL_MASTER.
--     nombre (nombre de pila). GAS por eso casi nunca matchea WH por nombre (manda full) → cae a idPersonal igual.
--     El full-name es un refinamiento más correcto; solo importa si idPersonal NO matchea (caso raro).
--   · Fila de bloqueos elegida: GAS escanea bottom-up y toma el 1er match (última fila física); acá ordeno
--     "unlock vigente primero, luego fecha_bloqueo más reciente". Idéntico con 1 fila por usuario/app (lo común);
--     más correcto si hubiese filas stray. (Bloquear-por-dispositivo guarda el deviceId en id_personal, no el id
--     del operador → no colisiona con el bloqueo de usuario por idPersonal.)
--   · unlock_hasta: GAS lee el epoch-ms crudo de la hoja; acá derivo de timestamptz → puede diferir <1s del valor
--     GAS para la misma fila. El countdown lo tolera (verificar que la sombra guarde unlock_hasta a full precisión).
--
-- SEGURIDAD: grant anon SIN gate _claim_ok (paridad con los RPC anon de dispositivos `verificar_dispositivo`/
-- `registrar_dispositivo`, y con el endpoint GAS que hoy ya es abierto). Solo devuelve el estado de bloqueo del
-- nombre/idPersonal consultado (no-secreto, mismo nivel de exposición que el GAS actual). Los heartbeats son
-- UPDATEs idempotentes (ultima_conexion=now()) acotados a una fila; van envueltos en sub-bloque que traga
-- errores (paridad con el try/catch de GAS) para que un fallo de heartbeat NUNCA bloquee la respuesta de bloqueo.
--
-- INERTE por kill-switch: con WH_BLOQUEO_DIRECTO != '1' el RPC devuelve *_OFF y WH usa GAS (sin cambio de
--   comportamiento del bloqueo). MATIZ: el cliente WH (default ON) igual hace 1 RPC extra por poll mientras el
--   flag está OFF (recibe OFF y cae a GAS). Es ~1 llamada/120s/equipo de más SOLO durante la ventana INERTE;
--   al activar el flag, el poll GAS desaparece y la carga NETA baja. No es "cero llamadas", es "cero cambio de
--   comportamiento del bloqueo + fallback garantizado".
--
-- ⚠ PRE-REQUISITO DE CUTOVER (antes de poner WH_BLOQUEO_DIRECTO='1'): con el flag ON, el heartbeat de WH escribe
--   en mos.dispositivos/mos.personal (Supabase) y DEJA de escribir la Hoja GAS. El panel admin de MOS DEBE leer
--   la presencia (ultima_conexion) desde Supabase (getDispositivos directo / _mosLecturaDirecta ON), o los
--   equipos WH se congelarán en "hace Nh". Ver doc de cutover. Sin esto, NO activar.
-- ============================================================================================================

create schema if not exists mos;

-- Helper: normalizador de app (paridad EXACTA con _normalizarApp de Bloqueos.gs:40-45).
create or replace function mos._norm_app(s text)
returns text language sql immutable as $fn$
  select case
    when position('express' in lower(coalesce(s,''))) > 0 or lower(btrim(coalesce(s,''))) = 'me'
         then 'mosexpress'
    when position('warehouse' in lower(coalesce(s,''))) > 0 or lower(btrim(coalesce(s,''))) = 'wh'
         then 'warehousemos'
    else lower(btrim(coalesce(s,'')))
  end
$fn$;
revoke all on function mos._norm_app(text) from public;
grant execute on function mos._norm_app(text) to anon, authenticated, service_role;

create or replace function mos.estado_bloqueo_usuario(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_nombre    text := btrim(coalesce(p->>'nombre',''));
  v_idp       text := btrim(coalesce(p->>'idPersonal',''));
  v_app       text := mos._norm_app(coalesce(p->>'appOrigen',''));
  v_dev       text := btrim(coalesce(p->>'deviceId',''));
  v_zona      text := btrim(coalesce(p->>'idZona',''));
  v_esta      text := btrim(coalesce(p->>'idEstacion',''));
  v_nom_norm  text := lower(btrim(coalesce(p->>'nombre','')));
  v_now       timestamptz := now();
  v_persona   mos.personal%rowtype;
  v_found     boolean := false;
  v_inactivo_pm boolean := false;
  v_idp_reg   text;
  v_nom_reg   text;
  v_unlock    timestamptz;
  v_fb        timestamptz;
  v_motivo    text;
  v_unlock_vig boolean;
  v_bloqueado boolean;
  v_flag_clave text;
begin
  -- ── KILL-SWITCH server-side APP-AWARE (cutover por app, sin redeploy): cada app tiene su flag en mos.config.
  -- WH→WH_BLOQUEO_DIRECTO ; ME→ME_BLOQUEO_DIRECTO ; otra app→siempre OFF (no migrada). Si el flag != '1' → OFF →
  -- esa app cae a GAS. INERTE por default (flag ausente/'0'). Va PRIMERO: en OFF no hace heartbeat ni lee nada.
  v_flag_clave := case
    when v_app = 'warehousemos' then 'WH_BLOQUEO_DIRECTO'
    when v_app = 'mosexpress'   then 'ME_BLOQUEO_DIRECTO'
    else 'BLOQUEO_DIRECTO_APP_NO_MIGRADA'
  end;
  if coalesce((select valor from mos.config where clave = v_flag_clave limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', v_flag_clave || '_OFF');
  end if;

  -- Validación de entrada (paridad: requiere nombre o idPersonal).
  if v_nombre = '' and v_idp = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere nombre o idPersonal');
  end if;

  -- ── (2a) HEARTBEAT de dispositivo (tolerante; no-op si la fila no existe) ──
  if v_dev ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    begin
      -- Auto-resolver estación de Almacén para WH sin estación explícita (paridad Bloqueos.gs:80-99).
      if v_esta = '' and v_app = 'warehousemos' then
        select e.id_estacion, coalesce(nullif(v_zona,''), e.id_zona)
          into v_esta, v_zona
          from mos.estaciones e
         where position('warehouse' in lower(coalesce(e.app_origen,''))) > 0
           and coalesce(e.activo, true) = true
         order by e.id_estacion
         limit 1;
        v_esta := coalesce(v_esta, '');
        v_zona := coalesce(v_zona, '');
      end if;
      update mos.dispositivos
         set ultima_conexion = v_now,
             ultima_sesion   = case when v_nombre <> '' then v_nombre else ultima_sesion end,
             ultima_zona     = case when coalesce(v_zona,'') <> '' then v_zona else ultima_zona end,
             ultima_estacion = case when coalesce(v_esta,'') <> '' then v_esta else ultima_estacion end
       where id_dispositivo = v_dev;
    exception when others then null; -- nunca bloquea la respuesta de bloqueo
    end;
  end if;

  -- ── (2b) HEARTBEAT de personal (por idPersonal, o por nombre completo) ──
  begin
    if v_idp <> '' then
      update mos.personal set ultima_conexion = v_now where id_personal = v_idp;
    elsif v_nom_norm <> '' then
      update mos.personal set ultima_conexion = v_now
       where lower(btrim(coalesce(nombre,'') || ' ' || coalesce(apellido,''))) = v_nom_norm
         and (v_app = '' or mos._norm_app(app_origen) = v_app);
    end if;
  exception when others then null;
  end;

  -- ── (1a) estaInactivoEnPM: SOLO apps != mosexpress. idPersonal primero, nombre como fallback. ──
  if v_app <> 'mosexpress' then
    if v_idp <> '' then
      select * into v_persona from mos.personal where id_personal = v_idp limit 1;
      v_found := found;
    end if;
    if not v_found and v_nom_norm <> '' then
      select * into v_persona from mos.personal
       where lower(btrim(coalesce(nombre,'') || ' ' || coalesce(apellido,''))) = v_nom_norm
         and (v_app = '' or mos._norm_app(app_origen) = v_app)
       limit 1;
      v_found := found;
    end if;
    if v_found then
      v_inactivo_pm := (coalesce(v_persona.estado, true) = false);
    end if;
  end if;

  v_idp_reg := case when v_found then coalesce(v_persona.id_personal,'') else v_idp end;
  v_nom_reg := case when v_found
                    then btrim(coalesce(v_persona.nombre,'') || ' ' || coalesce(v_persona.apellido,''))
                    else v_nombre end;

  -- ── (1b) bloqueos_usuario: fila más relevante (unlock vigente primero, luego bloqueo más reciente). ──
  select b.unlock_hasta, b.fecha_bloqueo, coalesce(b.motivo,'')
    into v_unlock, v_fb, v_motivo
    from mos.bloqueos_usuario b
   where ( (v_idp_reg <> '' and b.id_personal = v_idp_reg)
        or (v_nom_reg <> '' and lower(btrim(coalesce(b.nombre,''))) = lower(btrim(v_nom_reg))) )
     and (v_app = '' or mos._norm_app(b.app_origen) = v_app)
   order by (b.unlock_hasta is not null and b.unlock_hasta > v_now) desc,
            coalesce(b.fecha_bloqueo, b.unlock_hasta, '-infinity'::timestamptz) desc
   limit 1;

  v_unlock_vig := (v_unlock is not null and v_unlock > v_now);
  v_bloqueado  := (v_inactivo_pm or v_fb is not null) and not v_unlock_vig;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'bloqueado',     v_bloqueado,
    'inactivo',      (v_inactivo_pm or v_fb is not null),
    'unlockHasta',   case when v_unlock is not null then (extract(epoch from v_unlock) * 1000)::bigint else 0 end,
    'unlockVigente', v_unlock_vig,
    'msRestantes',   case when v_unlock_vig
                          then greatest(0, floor(extract(epoch from (v_unlock - v_now)) * 1000))::bigint
                          else 0 end,
    'motivo',        coalesce(v_motivo, ''),
    'idPersonal',    coalesce(v_idp_reg, ''),
    'nombre',        coalesce(v_nom_reg, '')
  ));
end; $fn$;

revoke all on function mos.estado_bloqueo_usuario(jsonb) from public;
-- anon: WH/ME pueden pegarlo con anon-key o con su JWT de sesión (sin gate, igual que verificar_dispositivo).
grant execute on function mos.estado_bloqueo_usuario(jsonb) to anon, authenticated, service_role;
