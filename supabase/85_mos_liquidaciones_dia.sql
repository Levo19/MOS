-- 85_mos_liquidaciones_dia.sql — [MIGRACIÓN MOS · FASE 2 · LOTE LIQUIDACIONES_DIA (DINERO)]
-- RPCs de ESCRITURA directa para LIQUIDACIONES_DIA. Espeja gas/Liquidaciones.gs:
--   · _liqDiaUpsertRow (~894)        → mos.upsert_liquidacion_dia(p jsonb)
--   · _liqDiaSetBonSan (~985)        → mos.set_bonificacion_sancion(p jsonb)
--   · vetarLiquidacionDia (~1316)    → mos.vetar_liquidacion_dia(p jsonb)
--   · desvetarLiquidacionDia (~1379) → mos.desvetar_liquidacion_dia(p jsonb)
--   · recomputarLiquidacionDia (~1439): NO necesita RPC propia. Es getResumenDia(cross-app) +
--       _liqDiaUpsertRow. El cómputo cross-app queda en el cliente; la persistencia es
--       upsert_liquidacion_dia con los montos auto YA calculados → es un alias funcional.
--
-- ⚠️ EL RECOMPUTE NO VA EN LA RPC. monto_base/pago_envasado/bono_meta salen de actividad real
--    (jornadas + envasados ME+WH + ventas) que es CROSS-APP. El cliente/GAS los computa con
--    getResumenDia y se los PASA a la RPC ya calculados. La RPC solo PERSISTE, preservando lo manual.
--
-- ⚠️ NACE INERTE (triple, idéntico a 81/82/83/84): (1) kill-switch server-side por flag
--    mos.config MOS_LIQDIA_DIRECTO, default '0'; (2) nadie cablea js/api.js todavía; (3) MOS sigue
--    100% por GAS. Flag OFF → devuelve MOS_LIQDIA_DIRECTO_OFF y el front cae a GAS.
--
-- ── INVARIANTE DINERO (idéntica a GAS, capped ≥0) ─────────────────────────────────────────────────
--    total_dia = max(0, round((monto_base + pago_envasado + bono_meta + bonificacion − sancion)*100)/100)
--    Implementada en mos._liqdia_total (round a 2 decimales, greatest 0). DINERO: numeric, no float.
--
-- ── PRESERVACIÓN (lo MÁS CRÍTICO de este lote) ────────────────────────────────────────────────────
--    upsert_liquidacion_dia: si la fila YA existe, PRESERVA bonificacion, sancion, estado, id_pago,
--      ts_creado, + motivos. Solo recompone los AUTO (monto_base/pago_envasado/bono_meta/auditado/
--      score_final/evaluaciones_count/tarifa_envasado/presente) y recalcula total_dia con los
--      preservados + los auto. NUNCA pisa una fila PAGADA en su estado/id_pago (eso es tanda 3).
--
-- ── PARIDAD ESQUEMA REAL (verificado con pg) ──────────────────────────────────────────────────────
--    PK id_dia (text). Cols: fecha(timestamptz) id_personal nombre rol app_origen virtual(TEXT)
--      monto_base pago_envasado bono_meta sancion total_dia auditado(bool) evaluaciones_count
--      score_final tarifa_envasado presente(bool) estado id_pago ts_creado ts_actualizado
--      bonificacion bonificacion_motivo sancion_motivo.  (`virtual` es TEXT, GAS escribe boolean→texto.)
--    id_dia = 'LDIA-' + fecha_sin_guiones + '-' + idPersonal_con_[^A-Za-z0-9:]→'_'  (=_liqDiaKey).
--    estado ∈ {PENDIENTE, PAGADA, VETADA}.  virtual=true si idPersonal empieza con 'MEX:'.

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 0) KILL-SWITCH (default '0' → INERTE). Sembrado idempotente.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
insert into mos.config (clave, valor, descripcion) values
  ('MOS_LIQDIA_DIRECTO','0','MOS Fase 2: escritura directa de LIQUIDACIONES_DIA (liquidación diaria, DINERO) a Supabase. OFF → front cae a GAS.')
on conflict (clave) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- helpers (idempotentes). _liqdia_key = _liqDiaKey de GAS; _liqdia_total = invariante DINERO capped.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos._liqdia_key(p_id_personal text, p_fecha text)
returns text language sql immutable set search_path = '' as $fn$
  -- fecha sin guiones + idPersonal con [^a-zA-Z0-9:] → '_'  (paridad _liqDiaKey)
  select 'LDIA-' || replace(coalesce(p_fecha,''),'-','') || '-'
         || regexp_replace(coalesce(p_id_personal,''), '[^a-zA-Z0-9:]', '_', 'g');
$fn$;

create or replace function mos._liqdia_total(p_base numeric, p_env numeric, p_meta numeric, p_bon numeric, p_san numeric)
returns numeric language sql immutable set search_path = '' as $fn$
  -- max(0, round((base+env+meta+bon-san)*100)/100)  — idéntico a GAS, DINERO exacto.
  select greatest(0::numeric, round(
    coalesce(p_base,0) + coalesce(p_env,0) + coalesce(p_meta,0) + coalesce(p_bon,0) - coalesce(p_san,0)
  , 2));
$fn$;

-- Higiene "cero PUBLIC": `language sql` sin revoke deja EXECUTE a PUBLIC (anon incluido). Estos dos helpers son
-- funciones puras (key determinística / aritmética DINERO) sin acceso a datos ni side-effects → impacto de datos
-- nulo, pero cerramos el grant para mantener el estándar del proyecto (ver fix análogo en 77_/78_).
-- Internos: solo los llaman las RPCs definer de este lote (que corren como definer) y GAS (service_role).
revoke all on function mos._liqdia_key(text, text)                                  from public;
revoke all on function mos._liqdia_total(numeric, numeric, numeric, numeric, numeric) from public;
grant execute on function mos._liqdia_key(text, text)                                  to service_role;
grant execute on function mos._liqdia_total(numeric, numeric, numeric, numeric, numeric) to service_role;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.upsert_liquidacion_dia(p jsonb) — espeja _liqDiaUpsertRow.  ⚠️ DINERO + PRESERVACIÓN ⚠️
--    INSERT (fila nueva) o UPDATE atómico por PK id_dia. Si la fila YA existe:
--      PRESERVA bonificacion, sancion, estado, id_pago, ts_creado, bonificacion_motivo, sancion_motivo;
--      solo recompone los AUTO y recalcula total_dia con los FINALES (preservados + auto).
--    Requeridos paridad GAS: presente=true y rol NO bloqueado (MASTER/ADMIN/ADMINISTRADOR) → si no, no-op.
--    Recibe: idPersonal, fecha, nombre, rol, appOrigen, montoBase, pagoEnvasado, bonoMeta, auditado,
--      evaluacionesCount, scoreFinal, tarifaEnvasado, presente, bonificacion, sancion (estos 2 SOLO
--      se usan en fila nueva).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.upsert_liquidacion_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_rol     text := upper(coalesce(p->>'rol',''));
  v_id_dia  text;
  v_fecha   timestamptz;
  v_now     timestamptz := clock_timestamp();
  v_nowiso  text;
  v_virtual text;
  -- auto (recomputados por el cliente)
  v_base numeric := mos._numn(p->>'montoBase');
  v_env  numeric := mos._numn(p->>'pagoEnvasado');
  v_meta numeric := mos._numn(p->>'bonoMeta');
  -- existentes (preservados)
  v_exists  boolean;
  v_bon_pre numeric;
  v_san_pre numeric;
  v_bonmot_pre text;
  v_sanmot_pre text;
  v_estado_pre text;
  v_idpago_pre text;
  v_tscre_pre  timestamptz;
  -- finales
  v_bon_fin numeric;
  v_san_fin numeric;
  v_total   numeric;
  v_n int;
begin
  -- KILL-SWITCH antes del gate (paridad lote).
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  -- paridad _liqDiaUpsertRow: solo persiste presentes y NO bloqueados (admin/master no liquidan jornal)
  if coalesce((p->>'presente')::boolean, false) is not true then
    return jsonb_build_object('ok',false,'error','NO_PRESENTE','skipped',true);
  end if;
  if v_rol in ('MASTER','ADMIN','ADMINISTRADOR') then
    return jsonb_build_object('ok',false,'error','ROL_BLOQUEADO','skipped',true);
  end if;

  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;  -- medianoche Lima (= _mosDate GAS)
  v_nowiso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_virtual := case when v_idp like 'MEX:%' then 'true' else 'false' end;

  -- Leer fila existente CON LOCK (read-then-write seguro; evita carrera con set_bonificacion/veto).
  select true, coalesce(bonificacion,0), coalesce(sancion,0),
         coalesce(bonificacion_motivo,''), coalesce(sancion_motivo,''),
         coalesce(estado,'PENDIENTE'), coalesce(id_pago,''), coalesce(ts_creado, v_now)
    into v_exists, v_bon_pre, v_san_pre, v_bonmot_pre, v_sanmot_pre, v_estado_pre, v_idpago_pre, v_tscre_pre
    from mos.liquidaciones_dia
   where id_dia = v_id_dia
   for update;

  if v_exists then
    -- PRESERVAR manual + estado/id_pago (incl. PAGADA). Solo recomponer auto + total_dia.
    v_bon_fin := v_bon_pre;
    v_san_fin := v_san_pre;
    v_total   := mos._liqdia_total(v_base, v_env, v_meta, v_bon_fin, v_san_fin);

    update mos.liquidaciones_dia set
        fecha              = v_fecha,
        nombre             = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
        rol                = v_rol,
        app_origen         = coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''), app_origen),
        virtual            = v_virtual,
        monto_base         = v_base,
        pago_envasado      = v_env,
        bono_meta          = v_meta,
        -- bonificacion / sancion / motivos: PRESERVADOS (re-escritos con su propio valor previo)
        bonificacion       = v_bon_fin,
        sancion            = v_san_fin,
        bonificacion_motivo= v_bonmot_pre,
        sancion_motivo     = v_sanmot_pre,
        total_dia          = v_total,
        auditado           = coalesce((p->>'auditado')::boolean, auditado),
        evaluaciones_count = coalesce(mos._numn(p->>'evaluacionesCount'), evaluaciones_count),
        score_final        = coalesce(mos._numn(p->>'scoreFinal'), score_final),
        tarifa_envasado    = coalesce(mos._numn(p->>'tarifaEnvasado'), tarifa_envasado),
        presente           = true,
        -- estado / id_pago / ts_creado: PRESERVADOS (NO se tocan) — protege PAGADA (tanda 3)
        ts_actualizado     = v_now
      where id_dia = v_id_dia;
    get diagnostics v_n = row_count;
    return jsonb_build_object('ok',true,'created',false,'data',
      jsonb_build_object('idDia',v_id_dia,'totalDia',v_total,'estado',v_estado_pre,
                         'bonificacion',v_bon_fin,'sancion',v_san_fin,'idPago',v_idpago_pre));
  end if;

  -- FILA NUEVA: bonificacion/sancion vienen del resumen (rd), estado=PENDIENTE, id_pago=''.
  v_bon_fin := coalesce(mos._numn(p->>'bonificacion'), 0);
  v_san_fin := coalesce(mos._numn(p->>'sancion'), 0);
  v_total   := mos._liqdia_total(v_base, v_env, v_meta, v_bon_fin, v_san_fin);

  insert into mos.liquidaciones_dia (
    id_dia, fecha, id_personal, nombre, rol, app_origen, virtual,
    monto_base, pago_envasado, bono_meta, bonificacion, sancion,
    bonificacion_motivo, sancion_motivo, total_dia, auditado,
    evaluaciones_count, score_final, tarifa_envasado, presente, estado, id_pago,
    ts_creado, ts_actualizado
  ) values (
    v_id_dia, v_fecha, v_idp,
    coalesce(nullif(btrim(coalesce(p->>'nombre','')),''),''),
    v_rol,
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),''),
    v_virtual,
    coalesce(v_base,0), coalesce(v_env,0), coalesce(v_meta,0), v_bon_fin, v_san_fin,
    '', '', v_total,
    coalesce((p->>'auditado')::boolean, false),
    coalesce(mos._numn(p->>'evaluacionesCount'),0),
    coalesce(mos._numn(p->>'scoreFinal'),0),
    coalesce(mos._numn(p->>'tarifaEnvasado'),0),
    true, 'PENDIENTE', '',
    v_now, v_now
  )
  on conflict (id_dia) do nothing;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    -- carrera: otra tx insertó la fila entre el SELECT y el INSERT → reintentar como UPDATE preservando.
    return mos.upsert_liquidacion_dia(p);
  end if;

  return jsonb_build_object('ok',true,'created',true,'data',
    jsonb_build_object('idDia',v_id_dia,'totalDia',v_total,'estado','PENDIENTE',
                       'bonificacion',v_bon_fin,'sancion',v_san_fin,'idPago',''));
end;
$fn$;
revoke all on function mos.upsert_liquidacion_dia(jsonb) from public;
grant execute on function mos.upsert_liquidacion_dia(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.set_bonificacion_sancion(p jsonb) — espeja _liqDiaSetBonSan.  ⚠️ DINERO ⚠️
--    REEMPLAZA bonificacion y/o sancion (+ motivos) y recalcula total_dia. UPDATE atómico por PK.
--    soloTipo ∈ {'bonificacion','sancion', null}:
--      'sancion'      → solo sancion + sancion_motivo; bonificacion + su motivo PRESERVADOS.
--      'bonificacion' → solo bonificacion + bonificacion_motivo; sancion + su motivo PRESERVADOS.
--      null/ausente   → reemplaza AMBOS (legacy).
--    Mejora sobre GAS (que devolvía false si no existía): si la fila no existe, crea una MÍNIMA
--    (estado PENDIENTE, autos en 0) y aplica el bon/san. Documentado: el cliente debería upsertear
--    primero, pero esto evita perder un ajuste manual sobre una persona aún sin fila.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.set_bonificacion_sancion(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_solo    text := nullif(lower(btrim(coalesce(p->>'soloTipo',''))), '');
  v_id_dia  text;
  v_fecha   timestamptz;
  v_now     timestamptz := clock_timestamp();
  v_nowiso  text;
  v_bon_new numeric := coalesce(mos._numn(p->>'bonificacion'), 0);
  v_san_new numeric := coalesce(mos._numn(p->>'sancion'), 0);
  v_bonmot_new text := coalesce(p->>'bonificacionMotivo','');
  v_sanmot_new text := coalesce(p->>'sancionMotivo','');
  -- existentes
  v_exists  boolean;
  v_base numeric; v_env numeric; v_meta numeric;
  v_bon_pre numeric; v_san_pre numeric; v_bonmot_pre text; v_sanmot_pre text;
  -- finales
  v_bon_fin numeric; v_san_fin numeric; v_bonmot_fin text; v_sanmot_fin text;
  v_total numeric;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  if v_solo is not null and v_solo not in ('bonificacion','sancion') then
    return jsonb_build_object('ok',false,'error','soloTipo inválido');
  end if;

  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
  begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;  -- medianoche Lima (= _mosDate GAS)
  v_nowiso := to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

  select true, coalesce(monto_base,0), coalesce(pago_envasado,0), coalesce(bono_meta,0),
         coalesce(bonificacion,0), coalesce(sancion,0),
         coalesce(bonificacion_motivo,''), coalesce(sancion_motivo,'')
    into v_exists, v_base, v_env, v_meta, v_bon_pre, v_san_pre, v_bonmot_pre, v_sanmot_pre
    from mos.liquidaciones_dia
   where id_dia = v_id_dia
   for update;

  -- Resolver finales según soloTipo (espeja _liqDiaSetBonSan).
  v_bon_fin := v_bon_new; v_san_fin := v_san_new;
  v_bonmot_fin := v_bonmot_new; v_sanmot_fin := v_sanmot_new;
  if v_solo = 'sancion' then
    v_bon_fin := coalesce(v_bon_pre,0); v_bonmot_fin := coalesce(v_bonmot_pre,'');
  elsif v_solo = 'bonificacion' then
    v_san_fin := coalesce(v_san_pre,0); v_sanmot_fin := coalesce(v_sanmot_pre,'');
  end if;

  if v_exists then
    v_total := mos._liqdia_total(v_base, v_env, v_meta, v_bon_fin, v_san_fin);
    update mos.liquidaciones_dia set
        bonificacion        = v_bon_fin,
        sancion             = v_san_fin,
        bonificacion_motivo = v_bonmot_fin,
        sancion_motivo      = v_sanmot_fin,
        total_dia           = v_total,
        ts_actualizado      = v_now
      where id_dia = v_id_dia;
    return jsonb_build_object('ok',true,'created',false,'data',
      jsonb_build_object('idDia',v_id_dia,'bonificacion',v_bon_fin,'sancion',v_san_fin,'totalDia',v_total));
  end if;

  -- No existe: crear fila MÍNIMA (autos en 0). soloTipo sobre fila nueva → el "otro" queda en 0.
  if v_solo = 'sancion' then v_bon_fin := 0; v_bonmot_fin := ''; end if;
  if v_solo = 'bonificacion' then v_san_fin := 0; v_sanmot_fin := ''; end if;
  v_total := mos._liqdia_total(0, 0, 0, v_bon_fin, v_san_fin);
  insert into mos.liquidaciones_dia (
    id_dia, fecha, id_personal, nombre, rol, app_origen, virtual,
    monto_base, pago_envasado, bono_meta, bonificacion, sancion,
    bonificacion_motivo, sancion_motivo, total_dia, auditado,
    evaluaciones_count, score_final, tarifa_envasado, presente, estado, id_pago,
    ts_creado, ts_actualizado
  ) values (
    v_id_dia, v_fecha, v_idp,
    coalesce(nullif(btrim(coalesce(p->>'nombre','')),''),''),
    upper(coalesce(p->>'rol','')),
    coalesce(nullif(btrim(coalesce(p->>'appOrigen','')),''),''),
    case when v_idp like 'MEX:%' then 'true' else 'false' end,
    0, 0, 0, v_bon_fin, v_san_fin, v_bonmot_fin, v_sanmot_fin, v_total, false,
    0, 0, 0, true, 'PENDIENTE', '',
    v_now, v_now
  )
  on conflict (id_dia) do nothing;

  return jsonb_build_object('ok',true,'created',true,'data',
    jsonb_build_object('idDia',v_id_dia,'bonificacion',v_bon_fin,'sancion',v_san_fin,'totalDia',v_total));
end;
$fn$;
revoke all on function mos.set_bonificacion_sancion(jsonb) from public;
grant execute on function mos.set_bonificacion_sancion(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.vetar_liquidacion_dia(p jsonb) — espeja vetarLiquidacionDia.  estado → VETADA (UPDATE atómico).
--    Paridad GAS: si estado actual = PAGADA → YA_PAGADA (no se veta un pago). No existe → NO_ENCONTRADA.
--    Idempotente: re-vetar una VETADA vuelve a sellar ts_actualizado y devuelve ok.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.vetar_liquidacion_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_id_dia  text;
  v_now     timestamptz := clock_timestamp();
  v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);

  -- UPDATE ATÓMICO condicional: no toca PAGADA (guard en WHERE). Lock de fila implícito.
  update mos.liquidaciones_dia
     set estado = 'VETADA', ts_actualizado = v_now
   where id_dia = v_id_dia
     and upper(coalesce(estado,'PENDIENTE')) <> 'PAGADA';
  get diagnostics v_n = row_count;

  if v_n = 1 then return jsonb_build_object('ok',true,'data',jsonb_build_object('idDia',v_id_dia,'estado','VETADA')); end if;

  -- 0 filas: o no existe, o estaba PAGADA. Distinguir (paridad: YA_PAGADA vs NO_ENCONTRADA).
  if exists (select 1 from mos.liquidaciones_dia where id_dia = v_id_dia) then
    return jsonb_build_object('ok',false,'error','YA_PAGADA');
  end if;
  return jsonb_build_object('ok',false,'error','NO_ENCONTRADA');
end;
$fn$;
revoke all on function mos.vetar_liquidacion_dia(jsonb) from public;
grant execute on function mos.vetar_liquidacion_dia(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) mos.desvetar_liquidacion_dia(p jsonb) — espeja desvetarLiquidacionDia. VETADA → PENDIENTE (atómico).
--    Paridad GAS: solo si estado actual = VETADA. No vetada → NO_VETADA. No existe → NO_ENCONTRADA.
--    Idempotente sobre una ya-PENDIENTE: GAS devuelve NO_VETADA (no es error de dinero); lo replicamos.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.desvetar_liquidacion_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_id_dia  text;
  v_now     timestamptz := clock_timestamp();
  v_estado  text;
  v_n int;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idp is null or v_fecha_s is null then
    return jsonb_build_object('ok',false,'error','idPersonal y fecha requeridos');
  end if;
  v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);

  -- UPDATE ATÓMICO condicional: solo si VETADA. Lock implícito.
  update mos.liquidaciones_dia
     set estado = 'PENDIENTE', ts_actualizado = v_now
   where id_dia = v_id_dia
     and upper(coalesce(estado,'')) = 'VETADA';
  get diagnostics v_n = row_count;

  if v_n = 1 then return jsonb_build_object('ok',true,'data',jsonb_build_object('idDia',v_id_dia,'estado','PENDIENTE')); end if;

  -- 0 filas: distinguir NO_ENCONTRADA vs NO_VETADA (paridad GAS).
  select upper(coalesce(estado,'')) into v_estado from mos.liquidaciones_dia where id_dia = v_id_dia;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',false,'error','NO_VETADA','mensaje','Estado actual: '||v_estado);
end;
$fn$;
revoke all on function mos.desvetar_liquidacion_dia(jsonb) from public;
grant execute on function mos.desvetar_liquidacion_dia(jsonb) to service_role, authenticated;
