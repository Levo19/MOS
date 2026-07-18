-- ============================================================
-- 120_mos_resumen_todos_dia_full.sql — [MIGRACIÓN MOS · FASE 2 · DINERO · INERTE]
-- REEMPLAZA mos.resumen_todos_dia (definida parcial en 119) por la versión COMPLETA y PARITARIA
-- con getResumenTodosDia (gas/Evaluaciones.gs:829), el motor del panel "Personal del Día".
--
-- ⚠️ INERTE: grant a authenticated+service_role + gate mos._claim_ok(); el wiring en api.js lo hace
--    el usuario tras revisión 40x. MOS sigue por GAS hasta el flip. Idéntico patrón inerte que 93/119.
--
-- ── QUÉ HACE (paridad 1:1 con getResumenTodosDia) ───────────────────────────────────────────────────
--   1) PERSONAL REAL DEL DÍA: reusa mos.resumen_dia(fecha, NULL) — el motor de dinero YA validado
--      (montoBase/pagoEnvasado/bonoMeta + ventasReales/envasados/metaVenta/zonaPrincipal/presente/
--      auditado/aplicaBonoMeta) — y SELECCIONA los items con presente=true. Eso emula EXACTAMENTE la
--      lista del GAS para personal real:
--        · WH: appOrigen='warehouseMos' con sesión del día (wh.sesiones)  ──┐ resumen_dia.presente =
--        · ME real: nombre en me.cajas (cajero) o me.ventas (vendedor)     ──┘ (sesión WH) OR (caja/venta ME)
--      El rol del master MANDA (resumen_dia ya lee el rol de mos.personal; no se reasigna por actividad).
--      virtual := false en estos.
--
--   2) PERSONAL VIRTUAL "MEX:<nombre>": vendedores/cajeros de ME que NO están en mos.personal evaluable
--      y NO son admin/master excluido. Se construyen tal como el GAS (idPersonal='MEX:'||nombre, rol
--      CAJERO si abrió caja ese día, si no VENDEDOR; montoBase del genérico ME por rol, 0 si no hay).
--      Su dinero se computa con LA MISMA fórmula que mos.resumen_dia (réplica inline — resumen_dia no
--      puede calcular un MEX: porque filtra sobre mos.personal; ver NOTA V). virtual := true.
--
--   3) CRUCE LIQUIDACIONES_DIA: a cada item se le setea liqEstado (estado en mos.liquidaciones_dia para
--      ese id_personal+fecha, default 'PENDIENTE') y, si liqEstado='VETADA', vetada:=true. Igual que el GAS.
--
-- ── REGLAS DE SELECCIÓN/EXCLUSIÓN/MATCHING (réplica EXACTA del GAS) ──────────────────────────────────
--   · evaluable: app_origen<>'MOS' y rol no en (MASTER,ADMINISTRADOR,ADMIN) y estado=true. (_esPersonalEvaluable)
--   · excluidosNorm: para CADA persona NO-evaluable de mos.personal con estado=true, clave n2 =
--       lower(trim(nombre||' '||apellido)) SOLO si contiene un espacio (nombre+apellido). Un vendedor MEX
--       se descarta si su nombre (lower) coincide con alguna de esas claves. REGLA: exclusión por
--       nombre+apellido completo, NO por primer nombre (evita falsos positivos: "Javier" vendedor vs
--       "Javier Vasquez" ADMIN → "javier" != "javier vasquez" → NO se excluye → SÍ crea MEX:Javier).
--   · roles del día ME: me.cajas (cajero, fecha_apertura=fecha) → 'CAJERO'; me.ventas (vendedor, fecha=fecha)
--       → 'VENDEDOR' SOLO si el nombre aún no quedó como 'CAJERO' (cajero más autoritativo). [NOTA: el GAS
--       NO filtra forma_pago para la PRESENCIA/rol — cuenta cualquier venta del día; replicado igual.]
--   · matching MEX→real: para cada nombre detectado, buscar primero en mosExpress, luego en cualquier app,
--       una persona evaluable cuyo full=lower(trim(nombre||' '||apellido)) == nLow  O  lower(nombre)==nLow.
--       Si hay match real (y no es genérico) → ya está cubierto por la rama (1) (su presente=true); NO se
--       crea virtual. Si no hay match → virtual MEX.
--
-- ── DINERO VIRTUAL (réplica de getResumenDia para un MEX, ver Evaluaciones.gs:381) ──────────────────
--   p sintético: rol=CAJERO|VENDEDOR, montoBase=genérico ME del rol (0 si no hay), appOrigen=mosExpress.
--   presente=true (existe por evidencia). auditado = ∃ evaluación activa de 'MEX:nombre' (en la práctica 0).
--   ventasReales = Σ me.ventas.total del día (forma_pago cobrada) match contención bidireccional vs nombre.
--   metaVenta = politica de la zona principal (zona_id de la venta) si >0, si no cfg.metaCajero.
--   bonoMeta(bruto) si aplicaBonoMeta & meta>0; bonoMeta(out) = (presente AND auditado) ? bruto : 0  → 0.
--   montoBase(out) = (presente AND no-envasador) ? montoBase : 0  → montoBase del genérico (0 si no hay).
--   pagoEnvasado = 0 (rol POS). Shape idéntico al de resumen_dia.
--
--   TZ America/Lima en todos los cortes. camelCase paritario. Envoltorio:
--     { ok:true, fecha, data:[ <resumen_dia.data + {virtual, liqEstado, vetada}> ] } || mos._frescura_sombra().
--   SIN _parcial (ahora es completo en cardinalidad: personal real del día + virtuales + liqEstado).
--   Seguridad: security definer, search_path='', gate mos._claim_ok(), revoke public, grant auth+service_role.
-- ============================================================

create schema if not exists mos;

-- ── helper de normalización sin acentos para 'generic' (replica _norm del GAS para genéricos) ────────
-- Reemplaza á/é/í/ó/ú comunes; el llamador baja a minúsculas con lower(). Idempotente.
create or replace function mos.unaccent_simple(p text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select translate(coalesce(p,''),
    'áàäéèëíìïóòöúùüÁÀÄÉÈËÍÌÏÓÒÖÚÙÜ',
    'aaaeeeiiiooouuuAAAEEEIIIOOOUUU');
$fn$;
revoke all on function mos.unaccent_simple(text) from public;
grant execute on function mos.unaccent_simple(text) to service_role, authenticated;

create or replace function mos.resumen_todos_dia(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_fecha      date := coalesce(nullif(btrim(coalesce(p->>'fecha','')), '')::date, (now() at time zone 'America/Lima')::date);
  v_meta_cajero numeric := mos._cfg_num('evalMetaCajero', 2000);
  v_bono_base   numeric := mos._cfg_num('evalBonoMetaBase', 8);
  v_bono_doble  numeric := mos._cfg_num('evalBonoMetaDoble', 15);
  v_tarifa_env  numeric := mos._cfg_num('evalTarifaEnvasadoPorUnidad', 0.10);
  v_meta_aud_def numeric := mos._cfg_num('evalMetaAuditorias', 30);
  -- pesos del score (cfg/100, mismos defaults que _getEvalConfig / mos.resumen_dia 122)
  v_peso_ventas  numeric := mos._cfg_num('evalPesoVentas',  30) / 100.0;
  v_peso_audit   numeric := mos._cfg_num('evalPesoAudit',   20) / 100.0;
  v_peso_limp    numeric := mos._cfg_num('evalPesoLimp',    15) / 100.0;
  v_peso_control numeric := mos._cfg_num('evalPesoControl', 35) / 100.0;
  v_rd          jsonb;
  v_data        jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- ── (1) Motor de dinero ya validado para TODO el personal real evaluable ─────────────────────────
  -- mos.resumen_dia re-evalúa su propio gate (inofensivo; ya pasamos el nuestro). Devuelve .data = array
  -- de objetos por persona real con presente/auditado/aplicaBonoMeta + dinero + KPIs.
  v_rd := mos.resumen_dia(v_fecha, null);
  if coalesce((v_rd->>'ok')::boolean, false) is not true then
    return v_rd;  -- propagar fallo (p.ej. gate)
  end if;

  with
  -- ── Maestro de personas (para evaluable / excluidos / matching) ─────────────────────────────────
  pm as (
    select p2.id_personal,
           coalesce(p2.nombre,'')   as nombre,
           coalesce(p2.apellido,'') as apellido,
           upper(coalesce(p2.rol,''))       as rol,
           coalesce(p2.app_origen,'')       as app_origen,
           coalesce(p2.monto_base,0)::numeric as monto_base,
           lower(btrim(coalesce(p2.nombre,'')))                                  as n1,
           lower(btrim(coalesce(p2.nombre,'') || ' ' || coalesce(p2.apellido,''))) as nfull,
           ( upper(coalesce(p2.app_origen,'')) <> 'MOS'
             and upper(coalesce(p2.rol,'')) not in ('MASTER','ADMINISTRADOR','ADMIN') ) as evaluable
    from mos.personal p2
    where p2.estado = true
  ),
  -- excluidos: NO-evaluables, clave full-name SOLO si tiene espacio (nombre+apellido). Réplica exacta.
  excluidos as (
    select distinct nfull as clave
    from pm
    where not evaluable
      and nfull <> ''
      and position(' ' in nfull) > 0
  ),
  -- genéricos ME por rol (plantilla de montoBase para virtuales). lower(nombre||' '||apellido) ~ 'generic'
  genericos as (
    select rol, monto_base
    from pm
    where lower(app_origen) = 'mosexpress'
      and (lower(mos.unaccent_simple(nombre || ' ' || apellido)) like '%generic%')
  ),
  -- ── Roles del día ME (réplica de rolesDelDia) ────────────────────────────────────────────────────
  -- 2a. Cajeros: cualquier caja abierta ese día. nombre tal cual (sin lower) como en el GAS (clave del map).
  caj as (
    select distinct btrim(coalesce(c.vendedor,'')) as nombre
    from me.cajas c
    where (c.fecha_apertura at time zone 'America/Lima')::date = v_fecha
      and btrim(coalesce(c.vendedor,'')) <> ''
  ),
  -- 2b. Vendedores: cualquier venta del día (el GAS NO filtra forma_pago para presencia/rol). Solo
  --     si el nombre no quedó ya como cajero.
  ven as (
    select distinct btrim(coalesce(v.vendedor,'')) as nombre
    from me.ventas v
    where (v.fecha at time zone 'America/Lima')::date = v_fecha
      and btrim(coalesce(v.vendedor,'')) <> ''
  ),
  roles_dia as (
    select nombre, 'CAJERO'::text as rol from caj
    union
    select nombre, 'VENDEDOR'::text as rol from ven v2
    where not exists (select 1 from caj where caj.nombre = v2.nombre)
  ),
  -- ── Virtuales candidatos: nombre del día que NO es excluido y NO matchea persona evaluable ────────
  --    matching: existe evaluable con (nfull = nLow) OR (n1 = nLow). (preferencia mosExpress no cambia
  --    el resultado booleano "hay match"; solo importa para reasignar rol, que NO aplica a virtuales.)
  virt as (
    select rd.nombre,
           lower(btrim(rd.nombre)) as nlow,
           rd.rol
    from roles_dia rd
    where lower(btrim(rd.nombre)) not in (select clave from excluidos)
      and not exists (
        select 1 from pm
        where pm.evaluable
          and ( pm.nfull = lower(btrim(rd.nombre))
             or pm.n1    = lower(btrim(rd.nombre)) )
      )
  ),
  -- montoBase del virtual: genérico del rol detectado, si no el primero, si no 0. (réplica _genericoPorRol)
  virt_base as (
    select v3.nombre, v3.nlow, v3.rol,
           coalesce(
             (select g.monto_base from genericos g where upper(coalesce(g.rol,'')) = v3.rol limit 1),
             (select g.monto_base from genericos g limit 1),
             0
           )::numeric as monto_base
    from virt v3
  ),
  -- ── DINERO del virtual (réplica inline de getResumenDia para rol POS) ─────────────────────────────
  -- ventas cobradas del día, match contención bidireccional vs nlow; zona por zona_id de la venta.
  vventas as (
    select vb.nlow,
           -- [UNIF id · fix 500x 2026-07-18] zona de la VENTA primero (como el recompute 289 que puebla la
           -- mega tabla: usa v.zona_id). Antes `coalesce(c.zona_id, v.zona_id)` tomaba la zona de la CAJA,
           -- que en cajas mal configuradas (ej. zona_id 'SINZONA') difería de la mega → clave distinta →
           -- comisión NO aparecía. La caja queda solo como fallback si la venta no trae zona.
           coalesce(nullif(v.zona_id,''), nullif(c.zona_id,''), '') as zona,
           coalesce(v.total,0)::numeric as total
    from virt_base vb
    join me.ventas v
      on lower(btrim(coalesce(v.vendedor,''))) <> ''
     and ( lower(btrim(v.vendedor)) = vb.nlow
        or position(vb.nlow in lower(btrim(v.vendedor))) > 0
        or position(lower(btrim(v.vendedor)) in vb.nlow) > 0 )
    left join me.cajas c on c.id_caja = v.id_caja
    where (v.fecha at time zone 'America/Lima')::date = v_fecha
      and upper(coalesce(v.forma_pago,'')) not in ('ANULADO','POR_COBRAR','CREDITO')
  ),
  vventas_tot as (
    select nlow, round(sum(total),2) as ventas_reales from vventas group by nlow
  ),
  vventas_zona as (
    select nlow, zona, sum(total) as tot from vventas where zona <> '' group by nlow, zona
  ),
  -- [fix 500x 2026-07-18] zona principal = la de la MEGA TABLA (liquidaciones_dia) cuando existe fila ese
  -- día (es la fuente de verdad del dinero, seteada al crear la liquidación en ME). Solo si NO hay fila se
  -- deriva de ventas. Antes se derivaba SIEMPRE de ventas → cajas/ventas con zona_id espuria ('SINZONA')
  -- daban una zona distinta a la mega → la clave canónica no matcheaba → comisión NO aparecía.
  vzona_ppal as (
    select vb.nlow,
           coalesce(
             (select nullif(split_part(l.id_personal,'|',2),'')
                from mos.liquidaciones_dia l
               where (l.fecha at time zone 'America/Lima')::date = v_fecha
                 and l.id_personal like 'MEX:%'
                 and mos._norm_nom(replace(split_part(l.id_personal,'|',1),'MEX:','')) = mos._norm_nom(vb.nombre)
               order by coalesce(l.total_dia,0) desc, l.id_personal
               limit 1),
             (select vzp.zona from vventas_zona vzp where vzp.nlow = vb.nlow order by vzp.tot desc, vzp.zona limit 1)
           ) as zona
    from virt_base vb
  ),
  vmeta as (
    select vb.nlow,
           coalesce(
             nullif( (select (z.politica_json->>'metaDiaria')::numeric
                        from mos.zonas z
                       where z.id_zona = zp.zona
                         and z.politica_json is not null
                         and (z.politica_json->>'metaDiaria') ~ '^-?[0-9]+(\.[0-9]+)?$'
                         and (z.politica_json->>'metaDiaria')::numeric > 0), 0),
             v_meta_cajero) as meta_venta
    from virt_base vb
    left join vzona_ppal zp on zp.nlow = vb.nlow
  ),
  -- ── EVALUACIONES activas del día del virtual (id 'MEX:'||nombre) — réplica EXACTA de 122 ────────────
  -- El virtual SÍ recibe evaluaciones (hay filas MEX:<nombre> en mos.evaluaciones). La ÚNICA diferencia
  -- con una persona real es que montoBase viene del genérico ME y no existe fila en mos.personal; TODO
  -- lo demás (evals/bono/sanción/score) es idéntico. Por eso replicamos ev_agg/ev_checks/detalles igual.
  -- 1) agregados escalares por virtual (MAX limpieza, OR aplica*, SUMA sanción/bonif, comentarios)
  vev_agg as (
    select 'MEX:'||vb.nombre as idp,
           count(*)::int                                    as cnt,
           coalesce(max(coalesce(e.limpieza_pct,0)),0)      as max_limp,
           coalesce(max(coalesce(e.limpieza_prof_pct,0)),0) as max_limp_prof,
           bool_and(coalesce(e.aplica_comision,  true))     as aplica_comision,
           bool_and(coalesce(e.aplica_bono_meta, true))     as aplica_bono_meta,
           round(coalesce(sum(case when coalesce(e.sancion,0)      > 0 then e.sancion      else 0 end),0),2) as sancion_total,
           round(coalesce(sum(case when coalesce(e.bonificacion,0) > 0 then e.bonificacion else 0 end),0),2) as bonificacion_total,
           string_agg(case when coalesce(btrim(e.comentario),'') <> ''
                           then '[' || coalesce(e.hora,'') || '] ' || e.comentario end,
                      E'\n' order by e.hora)                 as comentarios
    from virt_base vb
    join mos.evaluaciones e
      on mos._norm_nom(replace(split_part(e.id_personal,'|',1),'MEX:','')) = mos._norm_nom(vb.nombre)
     and coalesce(e.activo, true) = true
     and (e.fecha at time zone 'America/Lima')::date = v_fecha
    group by vb.nombre
  ),
  -- 2) control_checks: desplegar llaves, OR acumulado, checkTotal=#distintas, checkCount=#true
  vev_checks_raw as (
    select 'MEX:'||vb.nombre as idp, kv.key as ckey,
           (kv.value = to_jsonb(true) or lower(kv.value::text) in ('true','"true"','1','"1"')) as cval
    from virt_base vb
    join mos.evaluaciones e
      on mos._norm_nom(replace(split_part(e.id_personal,'|',1),'MEX:','')) = mos._norm_nom(vb.nombre)
     and coalesce(e.activo, true) = true
     and (e.fecha at time zone 'America/Lima')::date = v_fecha
     and jsonb_typeof(coalesce(e.control_checks,'{}'::jsonb)) = 'object'
    cross join lateral jsonb_each(coalesce(e.control_checks, '{}'::jsonb)) kv
  ),
  vev_checks_key as (
    select idp, ckey, bool_or(cval) as on_acum
    from vev_checks_raw group by idp, ckey
  ),
  vev_checks as (
    select idp,
           count(*)::int                                  as check_total_seen,
           count(*) filter (where on_acum)::int           as check_count,
           coalesce(jsonb_object_agg(ckey, true) filter (where on_acum), '{}'::jsonb) as checks_acum
    from vev_checks_key
    group by idp
  ),
  -- 3) detalles sanción / bonificación [{hora,monto,motivo}] (orden por hora, igual que el push del GAS)
  vev_san_det as (
    select 'MEX:'||vb.nombre as idp,
           coalesce(jsonb_agg(jsonb_build_object(
             'hora', coalesce(e.hora,''),
             'monto', e.sancion,
             'motivo', coalesce(e.sancion_motivo,'')
           ) order by e.hora), '[]'::jsonb) as detalle
    from virt_base vb
    join mos.evaluaciones e
      on mos._norm_nom(replace(split_part(e.id_personal,'|',1),'MEX:','')) = mos._norm_nom(vb.nombre)
     and coalesce(e.activo, true) = true
     and (e.fecha at time zone 'America/Lima')::date = v_fecha
     and coalesce(e.sancion,0) > 0
    group by vb.nombre
  ),
  vev_bon_det as (
    select 'MEX:'||vb.nombre as idp,
           coalesce(jsonb_agg(jsonb_build_object(
             'hora', coalesce(e.hora,''),
             'monto', e.bonificacion,
             'motivo', coalesce(e.bonificacion_motivo,'')
           ) order by e.hora), '[]'::jsonb) as detalle
    from virt_base vb
    join mos.evaluaciones e
      on mos._norm_nom(replace(split_part(e.id_personal,'|',1),'MEX:','')) = mos._norm_nom(vb.nombre)
     and coalesce(e.activo, true) = true
     and (e.fecha at time zone 'America/Lima')::date = v_fecha
     and coalesce(e.bonificacion,0) > 0
    group by vb.nombre
  ),
  -- ── AUDITORÍAS del día del virtual (réplica _calcularKpisAutoDia POS: me.auditorias) ────────────────
  -- nombre virtual es un solo token (sin apellido) ⇒ n1 = nlow. Match contención bidireccional vs vendedor.
  vaud as (
    select vb.nlow, count(*)::numeric as hechas
    from virt_base vb
    join me.auditorias a
      on lower(btrim(coalesce(a.vendedor,''))) <> ''
     and ( lower(btrim(a.vendedor)) = vb.nlow
        or position(vb.nlow in lower(btrim(a.vendedor))) > 0
        or position(lower(btrim(a.vendedor)) in vb.nlow) > 0 )
    where (a.fecha at time zone 'America/Lima')::date = v_fecha
    group by vb.nlow
  ),
  virt_calc as (
    select vb.nombre, vb.nlow, vb.rol, vb.monto_base,
           coalesce(vt.ventas_reales,0)::numeric  as ventas_reales,
           coalesce(vm.meta_venta, v_meta_cajero) as meta_venta,
           coalesce(zp.zona,'')                   as zona_principal,
           coalesce(va.hechas,0)::numeric         as auditorias_hechas,
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
           coalesce(bd.detalle,'[]'::jsonb)       as bonificaciones_detalle
    from virt_base vb
    left join vventas_tot vt on vt.nlow = vb.nlow
    left join vmeta       vm on vm.nlow = vb.nlow
    left join vzona_ppal  zp on zp.nlow = vb.nlow
    left join vaud        va on va.nlow = vb.nlow
    left join vev_agg     ea on ea.idp = 'MEX:'||vb.nombre
    left join vev_checks  ec on ec.idp = 'MEX:'||vb.nombre
    left join vev_san_det sd on sd.idp = 'MEX:'||vb.nombre
    left join vev_bon_det bd on bd.idp = 'MEX:'||vb.nombre
  ),
  -- derivados del virtual (checkTotal def 9, controlPct, ventasPct/auditPct, bonoMeta, score, metaPct)
  virt_der as (
    select vc.*,
      (case when vc.check_total_seen > 0 then vc.check_total_seen else 9 end) as check_total,
      (case when vc.meta_venta > 0
            then least(100, (vc.ventas_reales / vc.meta_venta) * 100) else 0 end) as ventas_pct,
      (case when v_meta_aud_def > 0
            then least(100, (vc.auditorias_hechas / v_meta_aud_def) * 100) else 0 end) as audit_pct
    from virt_calc vc
  ),
  virt_fin as (
    select vd.*,
      (case when vd.check_total > 0 then (vd.check_count::numeric / vd.check_total) * 100 else 0 end) as control_pct,
      -- baseEfectiva: presente=true y rol POS (no envasador) ⇒ montoBase del genérico
      round(vd.monto_base,2) as base_efectiva,
      -- bonoMeta bruto (POS, aplicaBonoMeta, meta>0)
      (case when vd.aplica_bono_meta and vd.meta_venta > 0 then
          case when vd.ventas_reales >= vd.meta_venta * 2 then v_bono_doble
               when vd.ventas_reales >= vd.meta_venta     then v_bono_base
               else 0 end
        else 0 end) as bono_meta_bruto
    from virt_der vd
  ),
  -- objeto por virtual con shape IDÉNTICO al de resumen_dia (122, paritario) + virtual:true.
  -- Réplica de getResumenDia para un MEX leyendo SUS evaluaciones (id 'MEX:'||nombre):
  --   evaluacionesCount=count, auditado=(count>0), maxLimp/maxLimpProf, checks*, sanción/bonif SUMA+detalles,
  --   aplicaComision/aplicaBonoMeta (AND), montoBase=genérico del rol, baseEfectiva=(presente?montoBase:0),
  --   bonoMeta efectivo=(presente&&auditado)?bruto:0, metaEfectivo, auditPct desde me.auditorias,
  --   scoreFinal con los 4 pesos, totalDia=max(0, base+metaEfectivo+0+bonif-sancion).
  virt_json as (
    select jsonb_build_object(
      -- ── PREEXISTENTES / paritarios con resumen_dia ──
      -- [UNIF id 2026-07-18] clave CANÓNICA MEX:<NOMBRE>|<ZONA> (mos._identidad_persona), = la que usa
      -- liquidaciones_dia/veto/pago/recompute → el lápiz de Liquidación y el botón Auditar leen el MISMO id,
      -- el JOIN liq (abajo) matchea → ventaZona/comisión aparecen, y "Sin meta" desaparece.
      'idPersonal',     mos._identidad_persona(null, vc.nombre, vc.zona_principal, true),
      'nombre',         vc.nombre,                              -- GAS: apellido vacío → trim(nombre||' '||'')
      'rol',            vc.rol,
      'appOrigen',      'mosExpress',
      'presente',       true,                                  -- existe por evidencia operativa del día
      'auditado',       vc.auditado,
      'aplicaBonoMeta', vc.aplica_bono_meta,
      'ventasReales',   round(vc.ventas_reales,2),
      'envasados',      0::numeric,
      'metaVenta',      vc.meta_venta,
      'zonaPrincipal',  vc.zona_principal,
      -- montoBase EFECTIVO = (presente AND no-envasador) ? genérico : 0. presente=true, rol POS ⇒ baseEfectiva.
      'montoBase',      round(vc.base_efectiva,2),
      'pagoEnvasado',   0::numeric,
      -- bonoMeta efectivo (metaEfectivo) = (presente AND auditado) ? bruto : 0
      'bonoMeta',       (case when vc.auditado then vc.bono_meta_bruto else 0 end),
      'tarifaEnvasado', v_tarifa_env,
      -- ── paridad getResumenDia / resumen_dia 122 — leyendo evaluaciones del MEX ──
      'evaluacionesCount', vc.eval_count,
      'aplicaComision',    vc.aplica_comision,
      'kpis', jsonb_build_object(
        'ventasReales',     round(vc.ventas_reales,2),
        'envasados',        0::numeric,
        'metaVenta',        vc.meta_venta,
        'zonaPrincipal',    vc.zona_principal,
        'ventasPct',        round(vc.ventas_pct,1),
        'auditPct',         round(vc.audit_pct,1),
        'auditoriasHechas', vc.auditorias_hechas,
        'metaAuditorias',   v_meta_aud_def
      ),
      'manual', jsonb_build_object(
        'limpiezaPct',     vc.max_limp,
        'limpiezaProfPct', vc.max_limp_prof,
        'checksAcum',      vc.checks_acum,
        'checkCount',      vc.check_count,
        'checkTotal',      vc.check_total,
        'controlPct',      round(vc.control_pct,1),
        'comentarios',     vc.comentarios
      ),
      -- scoreFinal con los 4 pesos (crudos al score, round 1 dec) — idéntico a 122
      'scoreFinal',    round( ( vc.ventas_pct * v_peso_ventas
                              + vc.audit_pct  * v_peso_audit
                              + ((vc.max_limp + vc.max_limp_prof) / 2.0) * v_peso_limp
                              + vc.control_pct * v_peso_control
                              )::numeric, 1),
      'bonusPctScore', 0,
      'bonusScore',    0,
      -- metaPct (POS, aplicaBonoMeta, meta>0): round(real/meta*1000)/10
      'metaPct',       (case when vc.aplica_bono_meta and vc.meta_venta > 0
                             then round(vc.ventas_reales / vc.meta_venta * 1000) / 10.0
                             else 0 end),
      'sancion',                vc.sancion_total,
      'sancionesDetalle',       vc.sanciones_detalle,
      'bonificacion',           vc.bonificacion_total,
      'bonificacionesDetalle',  vc.bonificaciones_detalle,
      'tarifaDiaria',     round(vc.monto_base,2),               -- tarifa configurada (= montoBase genérico)
      'unidadesEnvasadas', 0::numeric,
      -- totalDia = max(0, round(baseEfectiva + 0(bonus) + metaEfectivo + 0(envasado) + bonif - sancion, 2))
      'totalDia',       greatest(0, round(
                          vc.base_efectiva + 0 + (case when vc.auditado then vc.bono_meta_bruto else 0 end)
                          + 0 + vc.bonificacion_total - vc.sancion_total, 2)),
      'virtual',        true
    -- [UNIF id 2026-07-18] id_key CANÓNICO = idPersonal (arriba) → el JOIN liq (mos.liquidaciones_dia)
    -- matchea la fila de la mega tabla y los kpis ventaZona/comisión/envasados afloran. La union `todos`
    -- ya NO antepone 'MEX:' porque esta clave ya viene completa (MEX:<NOMBRE>|<ZONA>).
    ) as obj, mos._identidad_persona(null, vc.nombre, vc.zona_principal, true) as id_key
    from virt_fin vc
  ),
  -- ── (1) items reales (presente=true) con virtual:false ───────────────────────────────────────────
  reales_json as (
    select (elem || jsonb_build_object('virtual', false)) as obj,
           elem->>'idPersonal' as id_key
    from jsonb_array_elements(coalesce(v_rd->'data','[]'::jsonb)) as elem
    where coalesce((elem->>'presente')::boolean, false) = true
  ),
  -- ── union real + virtual ─────────────────────────────────────────────────────────────────────────
  todos as (
    select obj, id_key from reales_json
    union all
    select obj, id_key from virt_json   -- id_key ya es canónico MEX:<NOMBRE>|<ZONA> (no re-prefijar)
  ),
  -- ── (3) cruce liquidaciones_dia → liqEstado/vetada ────────────────────────────────────────────────
  liq as (
    select btrim(l.id_personal) as id_personal,
           upper(coalesce(l.estado,'')) as estado,
           coalesce(l.venta_zona, 0)          as venta_zona,
           coalesce(l.bono_meta, 0)           as bono_meta,
           coalesce(l.productos_envasados, 0) as productos_envasados,
           -- [fix 2026-07-18] dinero DE RECORD (mega tabla = lo que se paga; modelo comisión)
           coalesce(l.monto_base, 0)          as monto_base,
           coalesce(l.pago_envasado, 0)       as pago_envasado,
           coalesce(l.sancion, 0)             as sancion,
           coalesce(l.bonificacion, 0)        as bonificacion,
           coalesce(l.total_dia, 0)           as total_dia
    from mos.liquidaciones_dia l
    where (l.fecha at time zone 'America/Lima')::date = v_fecha
      and btrim(coalesce(l.id_personal,'')) <> ''
  ),
  fin as (
    select t.id_key,
           t.obj
             || jsonb_build_object('liqEstado', coalesce(nullif(lq.estado,''), 'PENDIENTE'))
             || (case when coalesce(nullif(lq.estado,''),'') = 'VETADA'
                      then jsonb_build_object('vetada', true)
                      else '{}'::jsonb end)
             -- [v2.43.388] Exponer en kpis los valores CANÓNICOS de la mega tabla que este
             -- RPC (modelo viejo de bono) NO trae: venta de zona, comisión 5% del excedente
             -- y envasados reales. Así el modal Auditar es IDÉNTICO se abra desde Personal
             -- del día (RPC 105) o desde Liquidaciones (este RPC). Solo cuando la fila existe;
             -- si no, se conserva lo computado (no pisa con ceros).
             || (case when lq.id_personal is not null
                      then jsonb_build_object('kpis',
                             coalesce(t.obj->'kpis','{}'::jsonb)
                               || jsonb_build_object(
                                    'ventaZona', lq.venta_zona,
                                    'comision',  lq.bono_meta,
                                    'envasados', lq.productos_envasados))
                      else '{}'::jsonb end)
             -- [fix 2026-07-18] DINERO DE RECORD. Antes el bonoMeta/totalDia de este RPC seguían el modelo
             -- VIEJO (bono plano por umbral = 0 en config hoy) → el lápiz mostraba TOTAL S/50 mientras
             -- Auditar/mega mostraba S/122.99 (base + comisión) = subpago. Ahora, cuando hay fila en la mega
             -- tabla (fuente de verdad de lo que se paga), se toman de ELLA los campos de dinero → ambos
             -- modales muestran EXACTO lo mismo. Los campos de evaluación (score/checks/limpieza/auditorías)
             -- se conservan de este RPC (los computa de las evaluaciones).
             || (case when lq.id_personal is not null
                      then jsonb_build_object(
                             'montoBase',    lq.monto_base,
                             'bonoMeta',     lq.bono_meta,
                             'pagoEnvasado', lq.pago_envasado,
                             'sancion',      lq.sancion,
                             'bonificacion', lq.bonificacion,
                             'totalDia',     lq.total_dia)
                      else '{}'::jsonb end) as obj
    from todos t
    left join liq lq on lq.id_personal = t.id_key
  )
  select coalesce(jsonb_agg(f.obj order by f.id_key), '[]'::jsonb)
    into v_data
  from fin f;

  return jsonb_build_object(
    'ok', true,
    'fecha', to_char(v_fecha,'YYYY-MM-DD'),
    'data', v_data
  ) || mos._frescura_sombra();
end;
$fn$;

revoke all on function mos.resumen_todos_dia(jsonb) from public;
grant execute on function mos.resumen_todos_dia(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS DE PARIDAD / DIVERGENCIAS (honestidad 40x)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- V) VIRTUALES vía réplica inline (no mos.resumen_dia): mos.resumen_dia filtra `per` sobre mos.personal, así
--    que NO puede computar un id 'MEX:<nombre>' (no existe en master). El GAS sí, porque _resolverPersona
--    fabrica el objeto sintético y corre la MISMA tubería de dinero. Aquí replicamos esa tubería inline para
--    POS (ventasReales/metaVenta/bonoMeta/montoBase) usando las MISMAS fórmulas y configs que resumen_dia (93).
--    No se duplica el dinero del personal real (ese sale 1:1 de resumen_dia). Si en el futuro se desea un
--    único motor, refactorizar resumen_dia para aceptar una tabla de personas sintéticas y llamarlo aquí.
--
-- D) SHAPE DE ITEM = exactamente el de mos.resumen_dia.data PARITARIO (122): idPersonal/nombre/rol/appOrigen/
--    presente/auditado/aplicaBonoMeta/ventasReales/envasados/metaVenta/zonaPrincipal/montoBase/pagoEnvasado/
--    bonoMeta/tarifaEnvasado + evaluacionesCount/aplicaComision/kpis{}/manual{}/scoreFinal/bonusPctScore/
--    bonusScore/metaPct/sancion/sancionesDetalle/bonificacion/bonificacionesDetalle/tarifaDiaria/
--    unidadesEnvasadas/totalDia + {virtual, liqEstado, vetada?}. El bloque de VIRTUALES replica inline ese
--    shape COMPLETO (un MEX no tiene fila en personal/evaluaciones): evaluacionesCount=0, auditado=false,
--    sancion=bonificacion=0 (detalles []), manual{} en ceros (checkTotal 9), montoBase=genérico del rol,
--    baseEfectiva=montoBase, bonoMeta efectivo=0 (nunca auditado), pagoEnvasado=0, scoreFinal=ventasPct*
--    pesoVentas, metaPct=round(real/meta*1000)/10, totalDia=baseEfectiva (=montoBase del genérico, 0 si no
--    hay). El personal REAL sale 1:1 de resumen_dia (122) — NO se recalcula aquí. Así el panel "Personal del
--    Día" lee r.totalDia/r.scoreFinal por item, real Y virtual, con el MISMO set de campos.
--
-- X) EXCLUSIÓN admin/master: por nombre+apellido completo (clave con espacio), NUNCA por primer nombre. Por
--    eso "Javier" (vendedor ME) NO se excluye contra "Javier Vasquez" (ADMIN): "javier" != "javier vasquez".
--    Idéntico al GAS (línea 868-869 + 975).
--
-- R) ROL/PRESENCIA ME no filtran forma_pago (cualquier venta del día cuenta para detectar al vendedor del
--    día y su presencia), pero el DINERO (ventasReales) sí excluye ANULADO/POR_COBRAR/CREDITO. Réplica del GAS.
--
-- L) liqEstado: estado de mos.liquidaciones_dia por (id_personal, día Lima). default 'PENDIENTE'. vetada=true
--    SOLO si estado='VETADA'. Match por id_personal exacto (incluye 'MEX:<nombre>' si la liquidación se
--    materializó para un virtual). Igual que getResumenTodosDia:1040.
--
-- C) FRESCURA: lee sombras me.*/wh.* + resumen_dia (que también lee sombras). _frescura_sombra() expone _fresh
--    para que el front decida caer a GAS. El sync de esas tablas debe estar vivo antes del cutover.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
