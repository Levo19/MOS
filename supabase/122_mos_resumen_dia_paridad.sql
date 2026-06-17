-- ============================================================
-- 122_mos_resumen_dia_paridad.sql — [MIGRACIÓN MOS · FASE 2 · DINERO · PARIDAD]
-- AMPLÍA mos.resumen_dia (definida en 93) para que su .data sea PARITARIA con getResumenDia
-- (gas/Evaluaciones.gs:398-570). El 93 era un PORT PARCIAL (solo dinero AUTO + KPIs base) que NO
-- exponía: totalDia, scoreFinal, sancion(+detalle), bonificacion(+detalle), manual{}, metaPct,
-- evaluacionesCount, aplicaComision, bonusScore/bonusPctScore, tarifaDiaria, unidadesEnvasadas,
-- bonoMeta como "metaEfectivo" ya lo daba. Eso bloqueaba el panel "Personal del Día"
-- (lee r.totalDia y r.scoreFinal por item, vía mos.resumen_todos_dia que reusa este motor).
--
-- ⚠️ REGLA DE ORO — BACKWARD-COMPAT: 93 YA ESTÁ EN PRODUCCIÓN (mos.materializar_liquidacion_dia/semana
--    consumen su .data). Esta versión MANTIENE LA MISMA FIRMA (date,text), el MISMO envoltorio
--    { ok, fecha, data:[...] }, y TODOS los campos preexistentes con MISMO nombre/tipo/semántica:
--      idPersonal, nombre, rol, appOrigen, presente, auditado, aplicaBonoMeta, ventasReales, envasados,
--      metaVenta, zonaPrincipal, montoBase, pagoEnvasado, bonoMeta, tarifaEnvasado.
--    SOLO AGREGA campos nuevos al objeto de cada item. NO renombra, NO cambia tipos, NO cambia firma.
--    El materializador (96) ya leía evaluacionesCount/scoreFinal con coalesce(...,0); ahora los recibe
--    poblados (mejora intencional, paritaria con _liqDiaUpsertRow del GAS). NO lee sancion/bonificacion
--    del resumen (los preserva de la fila) → agregarlos aquí es puramente aditivo, sin tocar su dinero.
--
-- ── CAMPOS AÑADIDOS (1:1 con getResumenDia:528-568) ─────────────────────────────────────────────────
--   evaluacionesCount, aplicaComision,
--   manual{ limpiezaPct, limpiezaProfPct, checksAcum, checkCount, checkTotal, controlPct, comentarios },
--   scoreFinal, bonusPctScore(=0), bonusScore(=0), metaPct,
--   sancion, sancionesDetalle[{hora,monto,motivo}], bonificacion, bonificacionesDetalle[{hora,monto,motivo}],
--   tarifaDiaria(=monto_base configurado), unidadesEnvasadas(=envasados), totalDia.
--   (kpis{}: el panel del GAS lee kpis.ventasReales/.envasados/.metaVenta — esos YA salen como campos
--    planos en 93. Aquí AÑADO también un sub-objeto 'kpis' con ventasReales/envasados/metaVenta/
--    zonaPrincipal/ventasPct/auditPct/metaVenta/auditoriasHechas para paridad con kpis{} del GAS, sin
--    quitar los planos preexistentes. Ver NOTA K.)
--
-- ── FÓRMULAS (réplica EXACTA del GAS) ───────────────────────────────────────────────────────────────
--   ACUMULATIVO sobre mos.evaluaciones activas del día (TZ Lima) por persona:
--     maxLimp=MAX(limpieza_pct), maxLimpProf=MAX(limpieza_prof_pct);
--     checksAcum = OR de las llaves true de control_checks (jsonb); checkCount=#llaves true;
--     checkTotal=#llaves DISTINTAS vistas (default 9 si 0); controlPct=checkCount/checkTotal*100;
--     sancionTotal=Σ sancion>0; bonificacionTotal=Σ bonificacion>0 (round 2); detalles=[{hora,monto,motivo}];
--     aplicaComision=AND; aplicaBonoMeta=AND (este último YA estaba en 93); evaluacionesCount=count(*).
--   KPIS (_calcularKpisAutoDia):
--     ventasPct = min(100, round(ventasReales/metaVenta*100,?)) [GAS no redondea ventasPct/auditPct; aquí
--       round a 1 dec inofensivo para score — ver NOTA P]; auditPct = min(100, auditoriasHechas/metaAud*100).
--       auditoriasHechas: CAJERO/VENDEDOR → count me.auditorias del día (match por PRIMER nombre, contención
--       bidireccional vs vendedor); ALMACENERO/ENVASADOR → count wh.auditorias estado='EJECUTADA' del día
--       (fecha_ejecucion, match por nombre+apellido contención). metaAud = politica zona ppal (POS) si >0,
--       si no cfg.evalMetaAuditorias||30.
--   SCORE: scoreFinal = round( ventasPct*pesoVentas + auditPct*pesoAudit
--                              + ((maxLimp+maxLimpProf)/2)*pesoLimp + controlPct*pesoControl , 1).
--   METAPCT: solo POS y aplicaBonoMeta y meta>0 → round(ventasReales/meta*1000)/10, si no 0.
--   TOTALDIA = max(0, round(montoBase_out + 0(bonus) + bonoMeta_out + pagoEnvasado_out
--                            + bonificacionTotal - sancionTotal, 2)).
--   (montoBase_out/bonoMeta_out/pagoEnvasado_out = los EFECTIVOS ya calculados en 93.)
--
--   CONFIG (mos.config, mismos defaults que _getEvalConfig): evalPesoVentas||30 /100, evalPesoAudit||20 /100,
--     evalPesoLimp||15 /100, evalPesoControl||35 /100, evalMetaAuditorias||30. (+ los de 93).
--   Seguridad: security definer, search_path='', gate mos._claim_ok(), revoke public, grant auth+service_role.
--   FRESCURA: 93 NO adjunta mos._frescura_sombra() (lo hace su wrapper 120). Mantengo IGUAL (no adjunto)
--     para no alterar el shape que el materializador 96 espera. La paridad de campos es el alcance.
-- ============================================================

create schema if not exists mos;

create or replace function mos.resumen_dia(p_fecha date, p_id_personal text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_meta_cajero    numeric := mos._cfg_num('evalMetaCajero', 2000);
  v_bono_base      numeric := mos._cfg_num('evalBonoMetaBase', 8);
  v_bono_doble     numeric := mos._cfg_num('evalBonoMetaDoble', 15);
  v_tarifa_env     numeric := mos._cfg_num('evalTarifaEnvasadoPorUnidad', 0.10);
  v_meta_aud_def   numeric := mos._cfg_num('evalMetaAuditorias', 30);
  -- pesos (cfg/100, mismos defaults que _getEvalConfig)
  v_peso_ventas    numeric := mos._cfg_num('evalPesoVentas',   30) / 100.0;
  v_peso_audit     numeric := mos._cfg_num('evalPesoAudit',    20) / 100.0;
  v_peso_limp      numeric := mos._cfg_num('evalPesoLimp',     15) / 100.0;
  v_peso_control   numeric := mos._cfg_num('evalPesoControl',  35) / 100.0;
  v_out            jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  with
  -- ── Personal evaluable (igual que 93) ────────────────────────────────────────────────────────────
  per as (
    select p.id_personal, p.nombre, coalesce(p.apellido,'') as apellido, upper(coalesce(p.rol,'')) as rol,
           p.app_origen, coalesce(p.monto_base,0)::numeric as monto_base,
           lower(btrim(p.nombre)) as n1,
           lower(btrim(p.nombre || ' ' || coalesce(p.apellido,''))) as nfull
    from mos.personal p
    where p.estado = true
      and upper(coalesce(p.app_origen,'')) <> 'MOS'
      and upper(coalesce(p.rol,'')) not in ('MASTER','ADMINISTRADOR','ADMIN')
      and (p_id_personal is null or p.id_personal = p_id_personal)
  ),
  -- ── VENTAS COBRADAS del día (igual que 93) ────────────────────────────────────────────────────────
  v_ventas as (
    select pr.id_personal,
           coalesce(c.zona_id,'') as zona,
           coalesce(v.total,0)::numeric as total
    from me.ventas v
    join per pr
      on pr.rol in ('CAJERO','VENDEDOR')
     and lower(btrim(coalesce(v.vendedor,''))) <> ''
     and ( lower(btrim(v.vendedor)) = pr.n1
        or position(pr.n1 in lower(btrim(v.vendedor))) > 0
        or position(lower(btrim(v.vendedor)) in pr.n1) > 0 )
    left join me.cajas c on c.id_caja = v.id_caja
    where (v.fecha at time zone 'America/Lima')::date = p_fecha
      and upper(coalesce(v.forma_pago,'')) not in ('ANULADO','POR_COBRAR','CREDITO')
  ),
  ventas_tot as (
    select id_personal, round(sum(total),2) as ventas_reales
    from v_ventas group by id_personal
  ),
  ventas_zona as (
    select id_personal, zona, sum(total) as tot
    from v_ventas where zona <> '' group by id_personal, zona
  ),
  zona_ppal as (
    select distinct on (id_personal) id_personal, zona
    from ventas_zona
    order by id_personal, tot desc, zona
  ),
  -- meta de VENTA y de AUDITORÍAS efectivas por persona POS (politica zona ppal si >0, si no defaults)
  meta_pers as (
    select pr.id_personal,
           coalesce(
             nullif( (select (z.politica_json->>'metaDiaria')::numeric
                        from mos.zonas z
                       where z.id_zona = zp.zona
                         and z.politica_json is not null
                         and (z.politica_json->>'metaDiaria') ~ '^-?[0-9]+(\.[0-9]+)?$'
                         and (z.politica_json->>'metaDiaria')::numeric > 0), 0),
             v_meta_cajero) as meta_venta,
           coalesce(
             nullif( (select (z.politica_json->>'metaAuditorias')::numeric
                        from mos.zonas z
                       where z.id_zona = zp.zona
                         and z.politica_json is not null
                         and (z.politica_json->>'metaAuditorias') ~ '^-?[0-9]+(\.[0-9]+)?$'
                         and (z.politica_json->>'metaAuditorias')::numeric > 0), 0),
             v_meta_aud_def) as meta_aud
    from per pr
    left join zona_ppal zp on zp.id_personal = pr.id_personal
    where pr.rol in ('CAJERO','VENDEDOR')
  ),
  -- ── ENVASADOS COMPLETADO del día (igual que 93) ───────────────────────────────────────────────────
  env_tot as (
    select pr.id_personal, sum(coalesce(e.unidades_producidas,0)::numeric) as envasados
    from wh.envasados e
    join per pr
      on pr.rol in ('ENVASADOR','ALMACENERO')
     and lower(btrim(coalesce(e.usuario,''))) <> ''
     and ( lower(btrim(e.usuario)) = pr.nfull
        or position(pr.n1 in lower(btrim(e.usuario))) > 0
        or position(lower(btrim(e.usuario)) in pr.nfull) > 0 )
    where (e.fecha at time zone 'America/Lima')::date = p_fecha
      and upper(coalesce(e.estado,'')) = 'COMPLETADO'
    group by pr.id_personal
  ),
  -- ── AUDITORÍAS del día (réplica de _calcularKpisAutoDia auditoriasHechas) ───────────────────────────
  -- CAJERO/VENDEDOR → me.auditorias: match por PRIMER nombre (n1), contención bidireccional vs vendedor.
  aud_me as (
    select pr.id_personal, count(*)::numeric as hechas
    from me.auditorias a
    join per pr
      on pr.rol in ('CAJERO','VENDEDOR')
     and lower(btrim(coalesce(a.vendedor,''))) <> ''
     and ( lower(btrim(a.vendedor)) = pr.n1
        or position(pr.n1 in lower(btrim(a.vendedor))) > 0
        or position(lower(btrim(a.vendedor)) in pr.n1) > 0 )
    where (a.fecha at time zone 'America/Lima')::date = p_fecha
    group by pr.id_personal
  ),
  -- ALMACENERO/ENVASADOR → wh.auditorias estado='EJECUTADA', match por nombre+apellido contención.
  --   GAS: uW===nfull OR uW contiene primer nombre OR nfull contiene uW. Réplica exacta.
  aud_wh as (
    select pr.id_personal, count(*)::numeric as hechas
    from wh.auditorias a
    join per pr
      on pr.rol in ('ALMACENERO','ENVASADOR')
     and lower(btrim(coalesce(a.usuario,''))) <> ''
     and ( lower(btrim(a.usuario)) = pr.nfull
        or position(pr.n1 in lower(btrim(a.usuario))) > 0
        or position(lower(btrim(a.usuario)) in pr.nfull) > 0 )
    where upper(coalesce(a.estado,'')) = 'EJECUTADA'
      and (a.fecha_ejecucion at time zone 'America/Lima')::date = p_fecha
    group by pr.id_personal
  ),
  aud_pers as (
    select pr.id_personal,
           coalesce(am.hechas, aw.hechas, 0)::numeric as auditorias_hechas
    from per pr
    left join aud_me am on am.id_personal = pr.id_personal
    left join aud_wh aw on aw.id_personal = pr.id_personal
  ),
  -- ── EVALUACIONES activas del día por persona (ACUMULATIVO MAX/OR/SUMA) ──────────────────────────────
  -- 1) agregados escalares por persona
  ev_agg as (
    select e.id_personal,
           count(*)::int                                   as cnt,
           coalesce(max(coalesce(e.limpieza_pct,0)),0)     as max_limp,
           coalesce(max(coalesce(e.limpieza_prof_pct,0)),0) as max_limp_prof,
           bool_and(coalesce(e.aplica_comision,  true))    as aplica_comision,
           bool_and(coalesce(e.aplica_bono_meta, true))    as aplica_bono_meta,
           round(coalesce(sum(case when coalesce(e.sancion,0)      > 0 then e.sancion      else 0 end),0),2) as sancion_total,
           round(coalesce(sum(case when coalesce(e.bonificacion,0) > 0 then e.bonificacion else 0 end),0),2) as bonificacion_total,
           string_agg(case when coalesce(btrim(e.comentario),'') <> ''
                           then '[' || coalesce(e.hora,'') || '] ' || e.comentario end,
                      E'\n' order by e.hora)                as comentarios
    from mos.evaluaciones e
    join per pr on pr.id_personal = e.id_personal
    where coalesce(e.activo, true) = true
      and (e.fecha at time zone 'America/Lima')::date = p_fecha
    group by e.id_personal
  ),
  -- 2) control_checks: desplegar todas las llaves de todas las evals del día.
  --    OR acumulado por llave; checkTotal = #llaves distintas vistas; checkCount = #llaves true.
  ev_checks_raw as (
    select e.id_personal, kv.key as ckey,
           (kv.value = to_jsonb(true) or lower(kv.value::text) in ('true','"true"','1','"1"')) as cval
    from mos.evaluaciones e
    join per pr on pr.id_personal = e.id_personal
    cross join lateral jsonb_each(coalesce(e.control_checks, '{}'::jsonb)) kv
    where coalesce(e.activo, true) = true
      and (e.fecha at time zone 'America/Lima')::date = p_fecha
      and jsonb_typeof(coalesce(e.control_checks,'{}'::jsonb)) = 'object'
  ),
  ev_checks_key as (
    select id_personal, ckey, bool_or(cval) as on_acum
    from ev_checks_raw group by id_personal, ckey
  ),
  ev_checks as (
    select id_personal,
           count(*)::int                                  as check_total_seen,
           count(*) filter (where on_acum)::int           as check_count,
           coalesce(jsonb_object_agg(ckey, true) filter (where on_acum), '{}'::jsonb) as checks_acum
    from ev_checks_key
    group by id_personal
  ),
  -- 3) detalles de sanción / bonificación [{hora,monto,motivo}] (orden por hora, igual que el push del GAS)
  ev_san_det as (
    select e.id_personal,
           coalesce(jsonb_agg(jsonb_build_object(
             'hora', coalesce(e.hora,''),
             'monto', e.sancion,
             'motivo', coalesce(e.sancion_motivo,'')
           ) order by e.hora), '[]'::jsonb) as detalle
    from mos.evaluaciones e
    join per pr on pr.id_personal = e.id_personal
    where coalesce(e.activo, true) = true
      and (e.fecha at time zone 'America/Lima')::date = p_fecha
      and coalesce(e.sancion,0) > 0
    group by e.id_personal
  ),
  ev_bon_det as (
    select e.id_personal,
           coalesce(jsonb_agg(jsonb_build_object(
             'hora', coalesce(e.hora,''),
             'monto', e.bonificacion,
             'motivo', coalesce(e.bonificacion_motivo,'')
           ) order by e.hora), '[]'::jsonb) as detalle
    from mos.evaluaciones e
    join per pr on pr.id_personal = e.id_personal
    where coalesce(e.activo, true) = true
      and (e.fecha at time zone 'America/Lima')::date = p_fecha
      and coalesce(e.bonificacion,0) > 0
    group by e.id_personal
  ),
  -- ── PRESENCIA (igual que 93) ──────────────────────────────────────────────────────────────────────
  pres_wh as (
    select distinct pr.id_personal
    from per pr
    join wh.sesiones s on s.id_personal = pr.id_personal
    where lower(coalesce(pr.app_origen,'')) = 'warehousemos'
      and (s.fecha_inicio at time zone 'America/Lima')::date = p_fecha
  ),
  pres_me_caja as (
    select distinct pr.id_personal
    from per pr
    join me.cajas c
      on lower(coalesce(pr.app_origen,'')) = 'mosexpress'
     and lower(btrim(coalesce(c.vendedor,''))) <> ''
     and ( lower(btrim(c.vendedor)) = pr.n1
        or position(pr.n1 in lower(btrim(c.vendedor))) > 0
        or position(lower(btrim(c.vendedor)) in pr.n1) > 0 )
    where (c.fecha_apertura at time zone 'America/Lima')::date = p_fecha
  ),
  pres_me_venta as (
    select distinct pr.id_personal
    from per pr
    join me.ventas v
      on lower(coalesce(pr.app_origen,'')) = 'mosexpress'
     and lower(btrim(coalesce(v.vendedor,''))) <> ''
     and ( lower(btrim(v.vendedor)) = pr.n1
        or position(pr.n1 in lower(btrim(v.vendedor))) > 0
        or position(lower(btrim(v.vendedor)) in pr.n1) > 0 )
    where (v.fecha at time zone 'America/Lima')::date = p_fecha
  ),
  -- ── ENSAMBLE por persona ──────────────────────────────────────────────────────────────────────────
  base as (
    select pr.*,
           coalesce(vt.ventas_reales,0)::numeric  as ventas_reales,
           coalesce(et.envasados,0)::numeric      as envasados,
           coalesce(mp.meta_venta, v_meta_cajero) as meta_venta,
           coalesce(mp.meta_aud,  v_meta_aud_def) as meta_aud,
           coalesce(ap.auditorias_hechas,0)::numeric as auditorias_hechas,
           coalesce(zp.zona,'')                   as zona_principal,
           coalesce(ea.cnt,0)                     as eval_count,
           coalesce(ea.cnt,0) > 0                 as auditado,
           coalesce(ea.aplica_bono_meta, true)    as aplica_bono_meta,
           coalesce(ea.aplica_comision,  true)    as aplica_comision,
           coalesce(ea.max_limp,0)                as max_limp,
           coalesce(ea.max_limp_prof,0)           as max_limp_prof,
           coalesce(ea.sancion_total,0)           as sancion_total,
           coalesce(ea.bonificacion_total,0)      as bonificacion_total,
           coalesce(ea.comentarios,'')            as comentarios,
           coalesce(ec.check_total_seen,0)        as check_total_seen,
           coalesce(ec.check_count,0)             as check_count,
           coalesce(ec.checks_acum,'{}'::jsonb)   as checks_acum,
           coalesce(sd.detalle,'[]'::jsonb)       as sanciones_detalle,
           coalesce(bd.detalle,'[]'::jsonb)       as bonificaciones_detalle,
           ( pr.id_personal in (select id_personal from pres_wh)
          or pr.id_personal in (select id_personal from pres_me_caja)
          or pr.id_personal in (select id_personal from pres_me_venta) ) as presente,
           (pr.rol = 'ENVASADOR')                 as envasador_puro
    from per pr
    left join ventas_tot vt on vt.id_personal = pr.id_personal
    left join env_tot    et on et.id_personal = pr.id_personal
    left join meta_pers  mp on mp.id_personal = pr.id_personal
    left join aud_pers   ap on ap.id_personal = pr.id_personal
    left join zona_ppal  zp on zp.id_personal = pr.id_personal
    left join ev_agg     ea on ea.id_personal = pr.id_personal
    left join ev_checks  ec on ec.id_personal = pr.id_personal
    left join ev_san_det sd on sd.id_personal = pr.id_personal
    left join ev_bon_det bd on bd.id_personal = pr.id_personal
  ),
  calc as (
    select b.*,
      -- checkTotal con default 9 (igual que el GAS: `|| 9`)
      (case when b.check_total_seen > 0 then b.check_total_seen else 9 end) as check_total,
      -- bonoMeta bruto (solo CAJERO/VENDEDOR con meta>0 y aplicaBonoMeta)
      case
        when b.aplica_bono_meta and b.rol in ('CAJERO','VENDEDOR') and b.meta_venta > 0 then
          case
            when b.ventas_reales >= b.meta_venta * 2 then v_bono_doble
            when b.ventas_reales >= b.meta_venta     then v_bono_base
            else 0 end
        else 0 end as bono_meta_bruto,
      case when b.rol in ('ENVASADOR','ALMACENERO')
           then round(b.envasados * v_tarifa_env, 2) else 0 end as pago_env_bruto
    from base b
  ),
  kpi as (
    select c.*,
      -- controlPct = checkCount/checkTotal*100
      (case when c.check_total > 0 then (c.check_count::numeric / c.check_total) * 100 else 0 end) as control_pct,
      -- ventasPct/auditPct (min 100). ENVASADOR usa metaEnvasador para ventasPct en el GAS, pero ese
      -- ventasPct NO afecta dinero ni el panel; el score de envasador pondera ventas igual. Para POS
      -- ventasPct=ventas/metaVenta. Para roles WH ventasPct=0 (no aplica). Réplica honesta: ver NOTA P.
      (case when c.rol in ('CAJERO','VENDEDOR') and c.meta_venta > 0
            then least(100, (c.ventas_reales / c.meta_venta) * 100) else 0 end) as ventas_pct,
      (case when c.meta_aud > 0
            then least(100, (c.auditorias_hechas / c.meta_aud) * 100) else 0 end) as audit_pct
    from calc c
  ),
  fin as (
    select k.*,
      -- DINERO efectivo (idéntico a 93)
      (case when k.presente and not k.envasador_puro then k.monto_base else 0 end) as monto_base_out,
      (case when k.presente and k.auditado and not k.envasador_puro then k.bono_meta_bruto else 0 end) as bono_meta_out,
      (case when k.presente then k.pago_env_bruto else 0 end) as pago_env_out,
      -- scoreFinal (round 1 dec)
      round( ( k.ventas_pct * v_peso_ventas
             + k.audit_pct  * v_peso_audit
             + (( k.max_limp + k.max_limp_prof) / 2.0) * v_peso_limp
             + (case when k.check_total > 0 then (k.check_count::numeric / k.check_total)*100 else 0 end) * v_peso_control
             )::numeric, 1) as score_final,
      -- metaPct (solo POS con aplicaBonoMeta y meta>0): round(real/meta*1000)/10
      (case when k.aplica_bono_meta and k.rol in ('CAJERO','VENDEDOR') and k.meta_venta > 0
            then round(k.ventas_reales / k.meta_venta * 1000) / 10.0
            else 0 end) as meta_pct
    from kpi k
  )
  select jsonb_build_object(
    'ok', true,
    'fecha', to_char(p_fecha,'YYYY-MM-DD'),
    'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        -- ── PREEXISTENTES (93) — NO TOCAR nombre/tipo/semántica ──
        'idPersonal',     f.id_personal,
        'nombre',         btrim(f.nombre || ' ' || f.apellido),
        'rol',            f.rol,
        'appOrigen',      f.app_origen,
        'presente',       f.presente,
        'auditado',       f.auditado,
        'aplicaBonoMeta', f.aplica_bono_meta,
        'ventasReales',   round(f.ventas_reales,2),
        'envasados',      f.envasados,
        'metaVenta',      f.meta_venta,
        'zonaPrincipal',  f.zona_principal,
        'montoBase',      round(f.monto_base_out,2),
        'pagoEnvasado',   round(f.pago_env_out,2),
        'bonoMeta',       f.bono_meta_out,
        'tarifaEnvasado', v_tarifa_env,
        -- ── NUEVOS (paridad getResumenDia) ──
        'evaluacionesCount', f.eval_count,
        'aplicaComision',    f.aplica_comision,
        'kpis', jsonb_build_object(
          'ventasReales',     round(f.ventas_reales,2),
          'envasados',        f.envasados,
          'metaVenta',        f.meta_venta,
          'zonaPrincipal',    f.zona_principal,
          'ventasPct',        round(f.ventas_pct,1),
          'auditPct',         round(f.audit_pct,1),
          'auditoriasHechas', f.auditorias_hechas,
          'metaAuditorias',   f.meta_aud
        ),
        'manual', jsonb_build_object(
          'limpiezaPct',     f.max_limp,
          'limpiezaProfPct', f.max_limp_prof,
          'checksAcum',      f.checks_acum,
          'checkCount',      f.check_count,
          'checkTotal',      f.check_total,
          'controlPct',      round(f.control_pct,1),
          'comentarios',     f.comentarios
        ),
        'scoreFinal',    f.score_final,
        'bonusPctScore', 0,
        'bonusScore',    0,
        'metaPct',       f.meta_pct,
        'sancion',                f.sancion_total,
        'sancionesDetalle',       f.sanciones_detalle,
        'bonificacion',           f.bonificacion_total,
        'bonificacionesDetalle',  f.bonificaciones_detalle,
        'tarifaDiaria',     round(f.monto_base,2),
        'unidadesEnvasadas', f.envasados,
        -- totalDia = max(0, round(base + 0 + meta + envasado + bonif - sancion, 2))
        'totalDia', greatest(0, round(
                       f.monto_base_out + 0 + f.bono_meta_out + f.pago_env_out
                       + f.bonificacion_total - f.sancion_total, 2))
      ) order by f.id_personal)
      from fin f), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$fn$;
revoke all on function mos.resumen_dia(date,text) from public;
grant execute on function mos.resumen_dia(date,text) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / DIVERGENCIAS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- K) kpis{}: el GAS retorna kpis = _calcularKpisAutoDia (objeto). El panel del GAS lee kpis.ventasReales,
--    kpis.envasados, kpis.metaVenta. 93 los expuso PLANOS (ventasReales/envasados/metaVenta) — los conservo
--    para no romper a 93/96/120. AÑADO un sub-objeto 'kpis' para paridad con el shape del GAS. Si el panel
--    lee r.kpis.ventasReales, ahora existe; si lee r.ventasReales (plano), también. Ambos cubiertos.
--
-- P) ventasPct/auditPct: el GAS NO redondea ventasPct/auditPct (los usa crudos en el score). Aquí los expongo
--    redondeados a 1 dec SOLO en el sub-objeto kpis (cosmético); el scoreFinal se computa con los valores
--    CRUDOS (sin redondear) → el score es 1:1 con el GAS salvo el redondeo final round(.,1) que el GAS también
--    aplica. Para ENVASADOR el GAS pone ventasPct=envasados/metaEnvasador*100; ese ventasPct entra al score
--    con pesoVentas. AQUÍ ventasPct(envasador)=0 → DIVERGENCIA de score SOLO para ENVASADOR (ver NOTA E).
--    No afecta dinero (totalDia de envasador = pagoEnvasado±ajustes, sin score). El panel muestra score
--    informativo. Documentado, no inventado: si se requiere paridad exacta de score de envasador, añadir
--    rama ventasPct=envasados/evalMetaEnvasador. ALMACENERO: el GAS computa 'guias' pero NO los usa en score
--    (ventasPct queda 0 para almacenero) → aquí también 0 → PARITARIO.
--
-- E) Por el alcance (desbloquear totalDia/scoreFinal del panel para personal real, y el DINERO ya validado en
--    93/96), la única divergencia conocida es el ventasPct del ENVASADOR dentro de scoreFinal (informativo).
--    Todo el DINERO (montoBase/bonoMeta/pagoEnvasado/totalDia/sancion/bonificacion) es EXACTO.
--
-- C) control_checks: el GAS hace JSON.parse y OR de truthy. Aquí trato true/"true"/1/"1" como verdadero y
--    cuento todas las llaves vistas (checkTotal) con default 9 si no hubo ninguna. checksAcum solo lista las
--    true (jsonb_object_agg filter on_acum). Igual semántica que checksAcum del GAS (solo keys true).
--
-- B) BACKWARD-COMPAT verificada: los 15 campos de 93 se emiten con MISMO nombre/round/valor. El materializador
--    96 lee montoBase/pagoEnvasado/bonoMeta/presente/auditado/rol/nombre/appOrigen (intactos) y ahora también
--    evaluacionesCount/scoreFinal (antes coalesce→0/preservado; ahora poblados = mejora paritaria). NO lee
--    sancion/bonificacion del resumen (preserva los de la fila) → agregarlos es inocuo para su dinero.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
