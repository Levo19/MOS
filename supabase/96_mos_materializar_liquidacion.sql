-- 96_mos_materializar_liquidacion.sql — [MIGRACIÓN MOS · FASE D · CIERRE/LIQUIDACIÓN · DINERO MÁXIMO · INERTE]
-- ====================================================================================================
-- Materializa LIQUIDACIONES_DIA (snapshot por persona-día) DIRECTO en Supabase, manejando TODO el
-- recálculo cross-app server-side vía mos.resumen_dia (SQL 93). Hoy GAS hace esto en 2 pasos cliente:
--   getResumenTodosDia → por cada presente _liqDiaUpsertRow  (gas/Liquidaciones.gs::_liqDiaSync ~1093).
-- Esta tanda lo colapsa a UNA transacción server-side, con:
--   (1) GATE DE FRESCURA wh.sesiones — si la sombra WH no tiene el día de negocio → NO materializa
--       (un envasador/almacenero cobraría 0 si la sombra está atrasada = pagar de MENOS). DINERO.
--   (2) PRESERVACIÓN idéntica a mos.upsert_liquidacion_dia (SQL 85): si la fila ya existe, PRESERVA
--       bonificacion / sancion / motivos / estado / id_pago / ts_creado; solo recompone los AUTO
--       (monto_base/pago_envasado/bono_meta/auditado/...) y recalcula total_dia con preservados+auto.
--       NUNCA pisa una fila PAGADA en su estado/id_pago.
--
-- ⚠️ NACE INERTE (idéntico a 85/86): (1) kill-switch server-side por flag mos.config MOS_LIQDIA_DIRECTO
--    (REUSADO — escribe la MISMA tabla LIQUIDACIONES_DIA que 85), default '0'; (2) nadie cablea
--    js/api.js todavía; (3) MOS sigue 100% por GAS. Flag OFF → devuelve MOS_LIQDIA_DIRECTO_OFF.
--
-- ── POR QUÉ ORQUESTADOR Y NO N×upsert DESDE EL CLIENTE ──────────────────────────────────────────────
--    El recompute de DINERO (monto_base/pago_envasado/bono_meta) es CROSS-APP (me.ventas/me.cajas/
--    wh.envasados/wh.sesiones/mos.evaluaciones). Materializar desde el cliente exigiría que GAS/PWA
--    leyera todo eso y lo pasara. mos.resumen_dia YA porta ese recompute (validado paridad EXACTA vs
--    GAS, verify_mos_93_paridad.js). El orquestador lo invoca server-side → 1 RPC, 1 tx, atómico.
--
-- ── ALCANCE: SOLO PERSONAL REAL ─────────────────────────────────────────────────────────────────────
--    mos.resumen_dia (93) excluye los virtuales MEX: por diseño (el cutover de jornales arranca con
--    personal real, ver 93 líneas 96-97). Por tanto este orquestador SOLO materializa/refresca filas
--    de personal real. Las filas virtuales MEX: existentes (que GAS sí materializa) NO se tocan: el
--    orquestador hace UPSERT por id_dia, nunca DELETE. La paridad de virtuales seguirá por GAS hasta
--    que se porte su detección (fuera del alcance de Fase D; documentado, no inventado).
--
-- ── GATE DE FRESCURA — DEFINICIÓN PRECISA (DINERO) ──────────────────────────────────────────────────
--    mos.resumen_dia deriva presencia/pago WH de wh.sesiones (presencia) y wh.envasados (pago). Si la
--    sombra WH NO refleja el día de negocio, un trabajador WH presente saldría presente=false →
--    monto_base=0 y pago_envasado=0 (pagar de MENOS). El gate aborta la materialización del día si
--    wh.sesiones NO tiene NINGUNA fila para ese día Lima. Cobertura honesta:
--      • Cubre el caso "la sombra WH de SESIONES está vacía para el día" (el más peligroso).
--      • NO puede detectar "sesiones llegaron pero faltan envasados de ese día" (no hay un ground-truth
--        independiente en Supabase para contar contra). Mitigación operativa: el sync WH sube ENVASADOS
--        junto con SESIONES; si hay sesión del día, los envasados de ese día normalmente también están.
--        Documentado como limitación; el operador valida físicamente antes de activar (Fase D = usuario).
--      • Si NINGÚN presente del día es de WH (solo cajeros ME), el día WH-vacío NO debería abortar:
--        por eso el gate es CONDICIONAL — solo exige sesiones si el resumen tiene ≥1 persona WH presente
--        O ≥1 persona de app warehouseMos evaluable ese día. (Ver mos._liq_gate_frescura abajo.)

create schema if not exists mos;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) GATE DE FRESCURA wh.sesiones — ¿la sombra WH tiene el día de negocio? (DINERO: no pagar de menos)
--    Devuelve jsonb { fresco:boolean, sesiones_dia:int, motivo:text }.
--    fresco = (no hay personal WH evaluable que dependa de ese día)  OR  (wh.sesiones tiene ≥1 fila ese día Lima).
--    "personal WH evaluable" = mos.personal activo, app warehouseMos, rol no admin/master.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos._liq_gate_frescura(p_fecha date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_ses_dia int;
  v_wh_personal int;
begin
  -- ¿cuántas sesiones WH (cualquier persona) hay ese día de negocio?
  select count(*) into v_ses_dia
    from wh.sesiones s
   where (s.fecha_inicio at time zone 'America/Lima')::date = p_fecha;

  -- ¿hay personal WH evaluable que PODRÍA estar presente ese día (y por tanto depende de wh.sesiones)?
  select count(*) into v_wh_personal
    from mos.personal p
   where p.estado = true
     and lower(coalesce(p.app_origen,'')) = 'warehousemos'
     and upper(coalesce(p.rol,'')) not in ('MASTER','ADMINISTRADOR','ADMIN');

  if v_wh_personal = 0 then
    return jsonb_build_object('fresco', true, 'sesiones_dia', v_ses_dia,
      'motivo', 'sin personal WH evaluable → no depende de wh.sesiones');
  end if;
  if v_ses_dia > 0 then
    return jsonb_build_object('fresco', true, 'sesiones_dia', v_ses_dia,
      'motivo', 'wh.sesiones tiene el día de negocio');
  end if;
  return jsonb_build_object('fresco', false, 'sesiones_dia', 0,
    'motivo', 'wh.sesiones SIN filas para el día Lima — sombra WH atrasada (no materializar: pagaría de menos)');
end;
$fn$;
revoke all on function mos._liq_gate_frescura(date) from public;
grant execute on function mos._liq_gate_frescura(date) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) ORQUESTADOR — mos.materializar_liquidacion_dia(p jsonb)  ⚠️ DINERO · ATÓMICO · IDEMPOTENTE · INERTE ⚠️
--    Entrada (p): { fecha:'YYYY-MM-DD' (req), forzar:boolean (opc, default false — saltar gate frescura) }
--    Flujo:
--      0. kill-switch MOS_LIQDIA_DIRECTO + gate mos._claim_ok().
--      1. GATE FRESCURA wh.sesiones (salvo forzar=true). Si NO fresco → aborta, NO escribe nada.
--      2. mos.resumen_dia(fecha) → personas REALES presentes con sus montos AUTO ya calculados.
--      3. Por cada presente NO bloqueado: UPSERT preservando (idéntico a upsert_liquidacion_dia).
--    Devuelve: { ok, fecha, fresco, sesionesDia, materializadas, creadas, actualizadas, saltadas, gate }
--    Idempotente: re-materializar la MISMA fecha preserva bon/san/estado/id_pago (PAGADA intacta) y solo
--    refresca los AUTO → NUNCA duplica filas ni infla montos.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.materializar_liquidacion_dia(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_fecha_s text := nullif(btrim(coalesce(p->>'fecha','')), '');
  v_forzar  boolean := coalesce((p->>'forzar')::boolean, false);
  v_fecha   date;
  v_gate    jsonb;
  v_rsm     jsonb;
  v_row     jsonb;
  -- por persona
  v_idp text; v_rol text; v_id_dia text; v_fecha_ts timestamptz;
  v_now timestamptz := clock_timestamp();
  v_virtual text;
  v_base numeric; v_env numeric; v_meta numeric;
  v_exists boolean; v_bon_pre numeric; v_san_pre numeric;
  v_bonmot_pre text; v_sanmot_pre text; v_estado_pre text; v_idpago_pre text; v_tscre_pre timestamptz;
  v_bon_fin numeric; v_san_fin numeric; v_total numeric; v_n int;
  -- contadores
  v_mat int := 0; v_cre int := 0; v_act int := 0; v_skip int := 0;
begin
  -- 0) KILL-SWITCH + GATE de claim (paridad lote: escribe la MISMA tabla que 85 → mismo flag).
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_fecha_s is null then return jsonb_build_object('ok',false,'error','Requiere fecha'); end if;
  begin v_fecha := v_fecha_s::date; exception when others then
    return jsonb_build_object('ok',false,'error','fecha inválida: '||v_fecha_s);
  end;

  -- 1) GATE DE FRESCURA wh.sesiones (DINERO: no pagar de menos). forzar=true lo salta (uso admin explícito).
  v_gate := mos._liq_gate_frescura(v_fecha);
  if not v_forzar and coalesce((v_gate->>'fresco')::boolean, false) is not true then
    return jsonb_build_object('ok',false,'error','WH_SESIONES_STALE','fecha',v_fecha_s,
      'gate', v_gate, 'materializadas', 0,
      'mensaje','Sombra WH atrasada para el día — NO se materializa (evita pagar de menos). Sincroniza WH y reintenta, o forzar=true.');
  end if;

  -- 2) RECÁLCULO CROSS-APP server-side (personal REAL; virtuales MEX: no, por diseño de 93).
  v_rsm := mos.resumen_dia(v_fecha, null);
  if coalesce((v_rsm->>'ok')::boolean,false) is not true then
    return jsonb_build_object('ok',false,'error','resumen_dia falló','detalle',v_rsm);
  end if;

  -- 3) UPSERT preservando por cada presente NO bloqueado (réplica EXACTA de upsert_liquidacion_dia).
  for v_row in select * from jsonb_array_elements(coalesce(v_rsm->'data','[]'::jsonb)) loop
    -- paridad _liqDiaUpsertRow: solo presentes y NO bloqueados (admin/master no liquidan jornal).
    if coalesce((v_row->>'presente')::boolean,false) is not true then v_skip := v_skip + 1; continue; end if;
    v_rol := upper(coalesce(v_row->>'rol',''));
    if v_rol in ('MASTER','ADMIN','ADMINISTRADOR') then v_skip := v_skip + 1; continue; end if;

    v_idp := nullif(btrim(coalesce(v_row->>'idPersonal','')), '');
    if v_idp is null then v_skip := v_skip + 1; continue; end if;

    v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
    -- ancla a medianoche Lima (= _mosDate de GAS; Perú siempre UTC-5). Con ::timestamptz directo se grababa
    -- UTC-midnight y el bucket Lima-date de finanzas_rango imputaba el costo del día X al X-1 (bug 40x).
    begin v_fecha_ts := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha_ts := v_now; end;
    v_virtual := case when v_idp like 'MEX:%' then 'true' else 'false' end;

    v_base := coalesce(mos._numn(v_row->>'montoBase'),0);
    v_env  := coalesce(mos._numn(v_row->>'pagoEnvasado'),0);
    v_meta := coalesce(mos._numn(v_row->>'bonoMeta'),0);

    -- Leer fila existente CON LOCK (read-then-write seguro; evita carrera con set_bonificacion/veto/pago).
    v_exists := false;
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
          fecha              = v_fecha_ts,
          nombre             = coalesce(nullif(btrim(coalesce(v_row->>'nombre','')),''), nombre),
          rol                = v_rol,
          app_origen         = coalesce(nullif(btrim(coalesce(v_row->>'appOrigen','')),''), app_origen),
          virtual            = v_virtual,
          monto_base         = v_base,
          pago_envasado      = v_env,
          bono_meta          = v_meta,
          bonificacion       = v_bon_fin,            -- PRESERVADO
          sancion            = v_san_fin,            -- PRESERVADO
          bonificacion_motivo= v_bonmot_pre,         -- PRESERVADO
          sancion_motivo     = v_sanmot_pre,         -- PRESERVADO
          total_dia          = v_total,
          auditado           = coalesce((v_row->>'auditado')::boolean, auditado),
          evaluaciones_count = coalesce(mos._numn(v_row->>'evaluacionesCount'), evaluaciones_count),
          score_final        = coalesce(mos._numn(v_row->>'scoreFinal'), score_final),
          tarifa_envasado    = coalesce(mos._numn(v_row->>'tarifaEnvasado'), tarifa_envasado),
          presente           = true,
          -- estado / id_pago / ts_creado: PRESERVADOS (NO se tocan) — protege PAGADA.
          ts_actualizado     = v_now
        where id_dia = v_id_dia;
      v_act := v_act + 1; v_mat := v_mat + 1;
    else
      -- FILA NUEVA: bon/san NO vienen del resumen (93 los omite por ser manuales) → 0, estado PENDIENTE.
      v_bon_fin := 0;
      v_san_fin := 0;
      v_total   := mos._liqdia_total(v_base, v_env, v_meta, v_bon_fin, v_san_fin);
      insert into mos.liquidaciones_dia (
        id_dia, fecha, id_personal, nombre, rol, app_origen, virtual,
        monto_base, pago_envasado, bono_meta, bonificacion, sancion,
        bonificacion_motivo, sancion_motivo, total_dia, auditado,
        evaluaciones_count, score_final, tarifa_envasado, presente, estado, id_pago,
        ts_creado, ts_actualizado
      ) values (
        v_id_dia, v_fecha_ts, v_idp,
        coalesce(nullif(btrim(coalesce(v_row->>'nombre','')),''),''),
        v_rol,
        coalesce(nullif(btrim(coalesce(v_row->>'appOrigen','')),''),''),
        v_virtual,
        v_base, v_env, v_meta, v_bon_fin, v_san_fin,
        '', '', v_total,
        coalesce((v_row->>'auditado')::boolean, false),
        coalesce(mos._numn(v_row->>'evaluacionesCount'),0),
        coalesce(mos._numn(v_row->>'scoreFinal'),0),
        coalesce(mos._numn(v_row->>'tarifaEnvasado'),0),
        true, 'PENDIENTE', '',
        v_now, v_now
      )
      on conflict (id_dia) do nothing;
      get diagnostics v_n = row_count;
      if v_n = 0 then
        -- carrera: otra tx insertó la fila entre el SELECT y el INSERT → re-leer y UPDATE preservando.
        select coalesce(bonificacion,0), coalesce(sancion,0),
               coalesce(bonificacion_motivo,''), coalesce(sancion_motivo,'')
          into v_bon_pre, v_san_pre, v_bonmot_pre, v_sanmot_pre
          from mos.liquidaciones_dia where id_dia = v_id_dia for update;
        v_total := mos._liqdia_total(v_base, v_env, v_meta, coalesce(v_bon_pre,0), coalesce(v_san_pre,0));
        update mos.liquidaciones_dia set
            monto_base=v_base, pago_envasado=v_env, bono_meta=v_meta,
            total_dia=v_total, presente=true, ts_actualizado=v_now
          where id_dia = v_id_dia;
        v_act := v_act + 1;
      else
        v_cre := v_cre + 1;
      end if;
      v_mat := v_mat + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'fecha', v_fecha_s,
    'fresco', coalesce((v_gate->>'fresco')::boolean,false),
    'forzado', v_forzar,
    'sesionesDia', coalesce((v_gate->>'sesiones_dia')::int, 0),
    'materializadas', v_mat, 'creadas', v_cre, 'actualizadas', v_act, 'saltadas', v_skip,
    'gate', v_gate
  );
end;
$fn$;
revoke all on function mos.materializar_liquidacion_dia(jsonb) from public;
grant execute on function mos.materializar_liquidacion_dia(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.materializar_liquidacion_semana(p jsonb) — conveniencia: materializa un rango [desde..hasta].
--    Entrada (p): { desde:'YYYY-MM-DD' (req), hasta:'YYYY-MM-DD' (req), forzar:boolean (opc) }.
--    Llama materializar_liquidacion_dia por cada día. Un día NO-fresco se SALTA (no aborta el resto):
--    devuelve su gate en `dias` para que el operador vea cuáles quedaron pendientes de sincronizar WH.
--    Rango acotado a ≤ 31 días (defensa: la liquidación es semanal; evita barridos accidentales enormes).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.materializar_liquidacion_semana(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_desde_s text := nullif(btrim(coalesce(p->>'desde','')), '');
  v_hasta_s text := nullif(btrim(coalesce(p->>'hasta','')), '');
  v_forzar  boolean := coalesce((p->>'forzar')::boolean, false);
  v_desde date; v_hasta date; v_d date;
  v_res jsonb; v_arr jsonb := '[]'::jsonb;
  v_mat int := 0; v_dias_fresco int := 0; v_dias_stale int := 0;
begin
  if coalesce((select valor from mos.config where clave='MOS_LIQDIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_LIQDIA_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_desde_s is null or v_hasta_s is null then
    return jsonb_build_object('ok',false,'error','Requiere desde y hasta');
  end if;
  begin v_desde := v_desde_s::date; v_hasta := v_hasta_s::date; exception when others then
    return jsonb_build_object('ok',false,'error','fechas inválidas');
  end;
  if v_hasta < v_desde then return jsonb_build_object('ok',false,'error','hasta < desde'); end if;
  if (v_hasta - v_desde) > 31 then return jsonb_build_object('ok',false,'error','rango > 31 días (acotado por seguridad)'); end if;

  v_d := v_desde;
  while v_d <= v_hasta loop
    v_res := mos.materializar_liquidacion_dia(jsonb_build_object('fecha', to_char(v_d,'YYYY-MM-DD'), 'forzar', v_forzar));
    if coalesce((v_res->>'ok')::boolean,false) then
      v_mat := v_mat + coalesce((v_res->>'materializadas')::int,0);
      v_dias_fresco := v_dias_fresco + 1;
    elsif (v_res->>'error') = 'WH_SESIONES_STALE' then
      v_dias_stale := v_dias_stale + 1;
    end if;
    v_arr := v_arr || jsonb_build_array(v_res);
    v_d := v_d + 1;
  end loop;

  return jsonb_build_object('ok', true, 'desde', v_desde_s, 'hasta', v_hasta_s,
    'materializadas', v_mat, 'diasFresco', v_dias_fresco, 'diasStale', v_dias_stale, 'dias', v_arr);
end;
$fn$;
revoke all on function mos.materializar_liquidacion_semana(jsonb) from public;
grant execute on function mos.materializar_liquidacion_semana(jsonb) to service_role, authenticated;
