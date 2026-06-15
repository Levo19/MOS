-- 84_mos_jornadas.sql — [MIGRACIÓN MOS · FASE 2 · LOTE JORNADAS (DINERO, jornal)]
-- RPCs de ESCRITURA directa para JORNADAS. Espeja gas/Finanzas.gs:
--   · registrarJornada(params)   → mos.registrar_jornada(p jsonb)   (router case 'registrarJornada')
--   · eliminarJornada(params)    → mos.eliminar_jornada(p jsonb)    (router case 'eliminarJornada')  [VETO tombstone]
--   · rehabilitarJornada(params) → mos.rehabilitar_jornada(p jsonb) (router case 'rehabilitarJornada')
--
-- NO se incluye importarJornadasDesdeCajas: lee CAJAS de MosExpress (cross-app) → queda en GAS.
--
-- ⚠️ NACE INERTE (triple, idéntico al patrón de 81/82/83): (1) kill-switch server-side por flag
--    mos.config MOS_JORNADAS_DIRECTO, default '0'; (2) nadie cablea js/api.js todavía → ninguna PWA
--    llama estas RPCs; (3) MOS sigue 100% por GAS. Las RPCs existen y tienen grant, pero el flag OFF
--    las hace devolver MOS_JORNADAS_DIRECTO_OFF (el front cae a GAS).
--
-- ── PARIDAD HONESTA CON GAS (verificada contra los handlers reales en gas/Finanzas.gs) ──────────────
--   Esquema REAL mos.jornadas (verificado con pg): id_jornada(text,PK) / fecha(timestamptz) /
--     id_personal / nombre / rol / app_origen / zona / monto_jornal(numeric) / observacion /
--     registrado_por / fuente.  (La columna de monto es monto_jornal, NO 'monto'.)
--
--   · registrarJornada (GAS ~119): appendRow CRUDO (sin lock ni dedup) → doble-tap / reintento de cola
--       offline = jornada DUPLICADA. En DINERO eso es inaceptable → acá idempotencia por `local_id`
--       (índice único parcial + SELECT-previo + on conflict PK + red unique_violation).
--       Validación paridad GAS: requiere nombre y montoJornal (GAS rechaza !params.montoJornal, lo que
--       también descarta 0 y vacío → acá monto > 0).  Campos por NOMBRE.
--       Defaults paridad GAS: fecha→now() (GAS _hoy()); idPersonal→''; rol→''; appOrigen→'MOS';
--         zona→''; observacion→''; registradoPor→''; fuente→'MANUAL'.
--       ⚠️ DINERO: monto_jornal EXACTO vía mos._numn (numeric, no float binario).
--
--   · eliminarJornada (GAS ~142): VETO tombstone — NO borra la fila. UPDATE atómico:
--       monto_jornal=0, observacion='VETO_TS:<ISO> · por <actor>', fuente='ELIMINADA'.
--       actor = params.actor || params.registradoPor || 'admin' (paridad GAS).
--       Devuelve vetoTs (ISO). GAS devolvía 'Jornada no encontrada' si no existía; acá IDÉNTICO error
--       cuando no hay fila (no se inventa idempotencia donde GAS falla). Re-vetar una ya vetada vuelve a
--       sellar el timestamp (paridad: GAS también re-escribe sin chequear estado previo).
--
--   · rehabilitarJornada (GAS ~174): revierte el veto. Solo si fuente='ELIMINADA' actual (igual que GAS,
--       que devuelve 'La jornada no está vetada' en otro caso). UPDATE atómico:
--       monto_jornal = <resuelto>, observacion='REHAB_TS:<ISO> · por <actor>', fuente='MANUAL'.
--       Resolución de monto (paridad GAS): params.monto (>0) → si no, mos.personal.monto_base
--       (match por id_personal exacto, si no por nombre lower) → si no, params.montoDefault.
--       Devuelve rehabTs (ISO) y monto. 'Jornada no encontrada' si no existe la fila.
--
-- ── IDS ─────────────────────────────────────────────────────────────────────────────────────────────
--   _generateId('JOR') de GAS = 'JOR' + Date.getTime() (epoch ms). Acá:
--     'JOR'||(extract(epoch from clock_timestamp())*1000)::bigint::text  (verificado: filas reales
--     existentes tienen ese formato, ej. 'JOR1777142470777'). La idempotencia REAL es por local_id;
--     el id de negocio se puede mandar desde el front (lo obtiene de la 1ra respuesta) → on conflict PK.

-- ───────────────────────────────────────────────────────────────────────────────────────────────────
-- 0) CIMIENTO (idempotente): columna local_id + índice único PARCIAL en mos.jornadas.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────
alter table mos.jornadas add column if not exists local_id text;

create unique index if not exists ux_mos_jornadas_localid on mos.jornadas (local_id) where local_id is not null;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) KILL-SWITCH (default '0' → INERTE). Sembrado idempotente.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────
insert into mos.config (clave, valor, descripcion) values
  ('MOS_JORNADAS_DIRECTO','0','MOS Fase 2: escritura directa de JORNADAS (jornal, DINERO) a Supabase. OFF → front cae a GAS.')
on conflict (clave) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.registrar_jornada(p jsonb) — espeja registrarJornada.  ⚠️ DINERO (jornal) ⚠️
--   Idempotencia por local_id (gesto de cliente) y por PK id_jornada (si el front reenvía el id).
--   monto_jornal EXACTO (numeric vía _numn) y > 0. Validación paridad GAS: requiere nombre + montoJornal.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.registrar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local  text    := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id     text    := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_nombre text    := nullif(btrim(coalesce(p->>'nombre','')), '');
  v_monto  numeric := mos._numn(p->>'montoJornal');
  v_fecha  timestamptz;
  v_inserted int;
  v_existe text;
begin
  -- KILL-SWITCH antes del gate (paridad 83).
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- Validación paridad GAS: requiere nombre y montoJornal. DINERO: monto > 0.
  if v_nombre is null then return jsonb_build_object('ok',false,'error','Requiere nombre y montoJornal'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok',false,'error','Requiere nombre y montoJornal'); end if;

  -- IDEMPOTENCIA por local_id (gesto): si ya se registró esta jornada → dedup, devolver el id persistido.
  if v_local is not null then
    select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
  end if;

  -- IDEMPOTENCIA por PK (reintento que reenvía idJornada)
  if v_id is not null and exists (select 1 from mos.jornadas where id_jornada = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
  end if;

  -- fecha: texto (yyyy-MM-dd o ISO) → timestamptz; ausente/basura → now() (paridad GAS _hoy()).
  begin
    v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());

  v_id := coalesce(v_id, 'JOR'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.jornadas (
    id_jornada, fecha, id_personal, nombre, rol, app_origen, zona,
    monto_jornal, observacion, registrado_por, fuente, local_id
  ) values (
    v_id, v_fecha,
    coalesce(nullif(btrim(coalesce(p->>'idPersonal','')),''),''),   -- GAS: '' si ausente
    v_nombre,
    coalesce(nullif(btrim(coalesce(p->>'rol','')),''),''),          -- GAS: '' si ausente
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),'MOS'), -- GAS default 'MOS'
    coalesce(nullif(btrim(coalesce(p->>'zona','')),''),''),         -- GAS: '' si ausente
    v_monto,                                                        -- numeric exacto, NO float
    coalesce(nullif(btrim(coalesce(p->>'observacion','')),''),''),  -- GAS: '' si ausente
    coalesce(nullif(btrim(coalesce(p->>'registradoPor','')),''),''),-- GAS: '' si ausente
    'MANUAL',                                                       -- GAS hardcodea 'MANUAL'
    v_local
  )
  on conflict (id_jornada) do nothing;
  get diagnostics v_inserted = row_count;

  -- carrera: el conflicto pudo ser por id_jornada (PK). El local_id chocaría como unique_violation (abajo).
  if v_inserted = 0 then
    if v_local is not null then
      select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idJornada', v_id));
exception
  -- red ANTI-DOBLE-JORNADA: dos tx con el MISMO local_id en paralelo → la perdedora choca el índice único
  -- parcial; en vez de propagar el error (que abortaría su tx), devolvemos la jornada persistida.
  when unique_violation then
    if v_local is not null then
      select id_jornada into v_existe from mos.jornadas where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idJornada', v_id));
end;
$fn$;
revoke all on function mos.registrar_jornada(jsonb) from public;
grant execute on function mos.registrar_jornada(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.eliminar_jornada(p jsonb) — espeja eliminarJornada (VETO tombstone, NO borra fila).  ⚠️ DINERO ⚠️
--   UPDATE atómico por PK: monto_jornal=0, observacion='VETO_TS:<ISO> · por <actor>', fuente='ELIMINADA'.
--   Idempotente por naturaleza del UPDATE (re-vetar re-sella el timestamp). 'Jornada no encontrada' si
--   no existe la fila (paridad GAS literal).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.eliminar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id    text := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_actor text := coalesce(
                    nullif(btrim(coalesce(p->>'actor','')),''),
                    nullif(btrim(coalesce(p->>'registradoPor','')),''),
                    'admin');                                       -- paridad GAS: actor||registradoPor||'admin'
  v_now   timestamptz := clock_timestamp();
  v_iso   text;
  v_n     int;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idJornada'); end if;

  -- ISO 8601 UTC con milisegundos y 'Z' (espeja new Date().toISOString() de GAS).
  v_iso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

  -- UPDATE ATÓMICO (lock de fila implícito; sin read-modify-write).
  update mos.jornadas
     set monto_jornal = 0,
         observacion  = 'VETO_TS:' || v_iso || ' · por ' || v_actor,
         fuente       = 'ELIMINADA'
   where id_jornada = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('vetoTs', v_iso, 'idJornada', v_id));
end;
$fn$;
revoke all on function mos.eliminar_jornada(jsonb) from public;
grant execute on function mos.eliminar_jornada(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.rehabilitar_jornada(p jsonb) — espeja rehabilitarJornada (revierte el veto).  ⚠️ DINERO ⚠️
--   Solo si fuente actual = 'ELIMINADA' (paridad GAS: 'La jornada no está vetada' en otro caso).
--   UPDATE atómico: monto_jornal=<resuelto>, observacion='REHAB_TS:<ISO> · por <actor>', fuente='MANUAL'.
--   Resolución monto (paridad GAS): params.monto(>0) → mos.personal.monto_base (id_personal exacto, si no
--   nombre lower) → params.montoDefault.  Devuelve rehabTs y monto.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.rehabilitar_jornada(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'idJornada','')), '');
  v_actor  text := coalesce(
                     nullif(btrim(coalesce(p->>'actor','')),''),
                     nullif(btrim(coalesce(p->>'registradoPor','')),''),
                     'admin');
  v_now    timestamptz := clock_timestamp();
  v_iso    text;
  v_fuente text;
  v_nombre text;
  v_idpers text;
  v_monto  numeric := mos._numn(p->>'monto');
  v_montoDef numeric := mos._numn(p->>'montoDefault');
  v_final  numeric;
  v_n      int;
begin
  if coalesce((select valor from mos.config where clave='MOS_JORNADAS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_JORNADAS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idJornada'); end if;

  -- Leer la fila CON LOCK para evitar carrera con un veto concurrente (read-then-update seguro).
  select upper(coalesce(fuente,'')), coalesce(nombre,''), coalesce(id_personal,'')
    into v_fuente, v_nombre, v_idpers
    from mos.jornadas
   where id_jornada = v_id
   for update;

  if not found then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  if v_fuente <> 'ELIMINADA' then return jsonb_build_object('ok',false,'error','La jornada no está vetada'); end if;

  -- Resolver monto (paridad GAS).
  v_final := case when v_monto is not null and v_monto > 0 then v_monto else null end;
  if v_final is null then
    select monto_base into v_final
      from mos.personal
     where (nullif(v_idpers,'') is not null and id_personal = v_idpers)
        or (lower(coalesce(nombre,'')) = lower(v_nombre))
     order by (nullif(v_idpers,'') is not null and id_personal = v_idpers) desc  -- prioriza match por id
     limit 1;
    if v_final is null or v_final <= 0 then v_final := null; end if;
  end if;
  if v_final is null then
    v_final := case when v_montoDef is not null and v_montoDef > 0 then v_montoDef else 0 end;
  end if;

  v_iso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

  update mos.jornadas
     set monto_jornal = v_final,
         observacion  = 'REHAB_TS:' || v_iso || ' · por ' || v_actor,
         fuente       = 'MANUAL'
   where id_jornada = v_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then return jsonb_build_object('ok',false,'error','Jornada no encontrada'); end if;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('rehabTs', v_iso, 'idJornada', v_id, 'monto', v_final));
end;
$fn$;
revoke all on function mos.rehabilitar_jornada(jsonb) from public;
grant execute on function mos.rehabilitar_jornada(jsonb) to service_role, authenticated;
