-- ============================================================
-- 93_mos_resumen_dia.sql — [MIGRACIÓN MOS · FASE 2 · DINERO · INERTE]
-- Porta el recálculo CROSS-APP de los KPIs auto del día (gas/Evaluaciones.gs::_calcularKpisAutoDia
-- + la derivación de dinero de getResumenDia:381) a una RPC Supabase.
--
-- Esta es la PIEZA que desbloquea el cutover de JORNALES: LIQUIDACIONES_DIA se materializa
-- desde getResumenDia(...).data (ver Liquidaciones.gs::_liqDiaRecomputar/_liqDiaUpsertRow), y los
-- 3 campos de dinero auto (montoBase, pagoEnvasado, bonoMeta) salen de aquí.
--
-- ⚠️ INERTE: grant a authenticated+service_role + gate mos._claim_ok(), pero NADIE la llama todavía
--    (el wiring del cutover de jornales llega en una tanda posterior). MOS sigue 100% por GAS.
--
-- ── REGLAS REPLICADAS (1:1 contra el GAS, leídas en Evaluaciones.gs) ─────────────────────────────────
--  Para una persona p (rol, nombre, apellido, app_origen, monto_base) en una fecha (día Lima):
--
--  A) KPIs AUTO (_calcularKpisAutoDia):
--     • ventasReales  (CAJERO/VENDEDOR): Σ me.ventas.total  donde día Lima = fecha,
--         upper(forma_pago) NOT IN ('ANULADO','POR_COBRAR','CREDITO'),
--         y lower(vendedor) hace match BIDIRECCIONAL de contención con lower(p.nombre) [SOLO primer nombre].
--     • envasados     (ENVASADOR/ALMACENERO): Σ wh.envasados.unidades_producidas donde día Lima = fecha,
--         upper(estado)='COMPLETADO', y lower(usuario) match bidireccional con lower(p.nombre||' '||p.apellido).
--         OJO contención: el GAS usa `u===nLow OR u.indexOf(p.nombre) OR nLow.indexOf(u)` — el lado izq
--         del 2º término es SOLO p.nombre (primer nombre), no el full. Replicado EXACTO abajo.
--     • metaVenta (CAJERO/VENDEDOR): zona principal = la zona (vía me.cajas.zona_id de la venta) donde
--         MÁS vendió ese día; su politica_json.metaDiaria (si >0) manda, si no cfg.metaCajero.
--         (auditoriasHechas/auditPct NO afectan dinero → no se calculan aquí; el cutover de jornales
--          solo materializa montoBase/pagoEnvasado/bonoMeta/totalDia.)
--
--  B) DINERO (getResumenDia):
--     • presente: WH → existe sesión (wh.sesiones) de ese id_personal ese día Lima; ME → abrió caja
--         (me.cajas) o selló venta (me.ventas) ese día (match por nombre, bidireccional contención).
--     • auditado: ∃ ≥1 fila activa en mos.evaluaciones de (id_personal, fecha-día-Lima).
--     • aplicaBonoMeta: true salvo que ALGUNA evaluación activa del día la ponga en false.
--     • esEnvasadorPuro = (rol = 'ENVASADOR').
--     • montoBase(out) = (presente AND NOT envasadorPuro) ? p.monto_base : 0
--     • bonoMeta(bruto) = (aplicaBonoMeta AND rol∈{CAJERO,VENDEDOR} AND meta>0)
--                         ? (ventasReales >= meta*2 ? bonoMetaDoble
--                            : ventasReales >= meta  ? bonoMetaBase : 0) : 0
--       bonoMeta(out) = (presente AND auditado AND NOT envasadorPuro) ? bonoMeta(bruto) : 0
--     • pagoEnvasado(bruto) = (rol∈{ENVASADOR,ALMACENERO}) ? round(envasados * tarifaEnvasado, 2) : 0
--       pagoEnvasado(out) = presente ? pagoEnvasado(bruto) : 0
--
--  CONFIG (mos.config, mismos defaults que _getEvalConfig):
--     metaCajero=evalMetaCajero||2000 · bonoMetaBase=evalBonoMetaBase||8 · bonoMetaDoble=evalBonoMetaDoble||15
--     tarifaEnvasadoPorUnidad=evalTarifaEnvasadoPorUnidad||0.10
--  (parseFloat(''||N) del GAS = N cuando la clave falta o no parsea → replicado con regex + coalesce).
--
--  TZ: día = (fecha AT TIME ZONE 'America/Lima')::date (script TZ de GAS = America/Lima → idéntico).
--  Redondeos: pagoEnvasado round(.,2); ventasReales round(.,2); bonoMeta es valor de config (entero típico).
--
--  Seguridad: security definer, search_path='', gate mos._claim_ok(), revoke public, grant authenticated+service_role.
-- ============================================================

create schema if not exists mos;

-- Config numérica con default estilo parseFloat(cfg.x || DEF) del GAS:
-- toma el valor SOLO si parsea como número; si falta/no parsea → default.
create or replace function mos._cfg_num(p_clave text, p_def numeric)
returns numeric
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
    (select v.valor::numeric
       from mos.config v
      where v.clave = p_clave
        and v.valor ~ '^-?[0-9]+(\.[0-9]+)?$'
      limit 1),
    p_def);
$fn$;
revoke all on function mos._cfg_num(text,numeric) from public;
grant execute on function mos._cfg_num(text,numeric) to service_role, authenticated;

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
  v_out            jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  with
  -- ── Personal evaluable (real, en master). Excluye admin/MOS/master.
  --    Espeja _esPersonalEvaluable: app_origen<>'MOS' y rol no en (MASTER,ADMINISTRADOR,ADMIN).
  --    (Los virtuales MEX: no se materializan aquí — el cutover de jornales arranca con personal real.)
  per as (
    select p.id_personal, p.nombre, coalesce(p.apellido,'') as apellido, upper(coalesce(p.rol,'')) as rol,
           p.app_origen, coalesce(p.monto_base,0)::numeric as monto_base,
           lower(btrim(p.nombre)) as n1,                                  -- primer nombre (match ME ventas/auditorias)
           lower(btrim(p.nombre || ' ' || coalesce(p.apellido,''))) as nfull  -- nombre+apellido (match WH)
    from mos.personal p
    where p.estado = true
      and upper(coalesce(p.app_origen,'')) <> 'MOS'
      and upper(coalesce(p.rol,'')) not in ('MASTER','ADMINISTRADOR','ADMIN')
      and (p_id_personal is null or p.id_personal = p_id_personal)
  ),
  -- ── VENTAS COBRADAS del día (CAJERO/VENDEDOR). Match por contención bidireccional vs n1 (primer nombre).
  --    zona de la venta = me.cajas.zona_id por id_caja (para inferir zona principal).
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
  -- zona principal = la de mayor venta acumulada del día por persona
  ventas_zona as (
    select id_personal, zona, sum(total) as tot
    from v_ventas where zona <> '' group by id_personal, zona
  ),
  zona_ppal as (
    select distinct on (id_personal) id_personal, zona
    from ventas_zona
    order by id_personal, tot desc, zona
  ),
  -- meta efectiva por persona (politica_json.metaDiaria de la zona ppal si >0; si no, cfg.metaCajero)
  meta_pers as (
    select pr.id_personal,
           coalesce(
             nullif( (select (z.politica_json->>'metaDiaria')::numeric
                        from mos.zonas z
                       where z.id_zona = zp.zona
                         and z.politica_json is not null
                         and (z.politica_json->>'metaDiaria') ~ '^-?[0-9]+(\.[0-9]+)?$'
                         and (z.politica_json->>'metaDiaria')::numeric > 0), 0),
             v_meta_cajero) as meta_venta
    from per pr
    left join zona_ppal zp on zp.id_personal = pr.id_personal
    where pr.rol in ('CAJERO','VENDEDOR')
  ),
  -- ── ENVASADOS COMPLETADO del día (ENVASADOR/ALMACENERO). Match: u=nfull OR nfull contiene n1 OR u contiene...
  --    Réplica EXACTA del GAS: (u===nfull) OR (u.indexOf(n1)>=0) OR (nfull.indexOf(u)>=0).
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
  -- ── PRESENCIA ────────────────────────────────────────────────
  -- WH: ∃ sesión de ese id_personal ese día. (GAS: SESIONES col1=idPersonal, col2=fecha → fecha_inicio.)
  pres_wh as (
    select distinct pr.id_personal
    from per pr
    join wh.sesiones s on s.id_personal = pr.id_personal
    where lower(coalesce(pr.app_origen,'')) = 'warehousemos'
      and (s.fecha_inicio at time zone 'America/Lima')::date = p_fecha
  ),
  -- ME: abrió caja (me.cajas) o selló venta (me.ventas) ese día. Match por nombre (bidireccional contención).
  --     _verificarPresenciaME usa fecha de apertura de caja y fecha de venta.
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
  -- ── AUDITADO + aplicaBonoMeta: filas activas en mos.evaluaciones del día por persona ─
  ev as (
    select e.id_personal,
           count(*) as cnt,
           bool_and(coalesce(e.aplica_bono_meta, true)) as aplica_bono_meta
    from mos.evaluaciones e
    join per pr on pr.id_personal = e.id_personal
    where coalesce(e.activo, true) = true
      and (e.fecha at time zone 'America/Lima')::date = p_fecha
    group by e.id_personal
  ),
  -- ── ENSAMBLE por persona ─────────────────────────────────────
  base as (
    select pr.*,
           coalesce(vt.ventas_reales,0)::numeric as ventas_reales,
           coalesce(et.envasados,0)::numeric     as envasados,
           coalesce(mp.meta_venta, v_meta_cajero) as meta_venta,
           coalesce(zp.zona,'')                  as zona_principal,
           coalesce(ev.cnt,0) > 0                as auditado,
           coalesce(ev.aplica_bono_meta, true)   as aplica_bono_meta,
           ( pr.id_personal in (select id_personal from pres_wh)
          or pr.id_personal in (select id_personal from pres_me_caja)
          or pr.id_personal in (select id_personal from pres_me_venta) ) as presente,
           (pr.rol = 'ENVASADOR')                as envasador_puro
    from per pr
    left join ventas_tot vt on vt.id_personal = pr.id_personal
    left join env_tot    et on et.id_personal = pr.id_personal
    left join meta_pers  mp on mp.id_personal = pr.id_personal
    left join zona_ppal  zp on zp.id_personal = pr.id_personal
    left join ev            on ev.id_personal = pr.id_personal
  ),
  calc as (
    select b.*,
      -- bonoMeta bruto (solo CAJERO/VENDEDOR con meta>0 y aplicaBonoMeta)
      case
        when b.aplica_bono_meta and b.rol in ('CAJERO','VENDEDOR') and b.meta_venta > 0 then
          case
            when b.ventas_reales >= b.meta_venta * 2 then v_bono_doble
            when b.ventas_reales >= b.meta_venta     then v_bono_base
            else 0 end
        else 0 end as bono_meta_bruto,
      -- pagoEnvasado bruto (ENVASADOR o ALMACENERO)
      case when b.rol in ('ENVASADOR','ALMACENERO')
           then round(b.envasados * v_tarifa_env, 2) else 0 end as pago_env_bruto
    from base b
  ),
  fin as (
    select c.*,
      -- montoBase efectivo
      case when c.presente and not c.envasador_puro then c.monto_base else 0 end as monto_base_out,
      -- bonoMeta efectivo (presente AND auditado AND no envasador puro)
      case when c.presente and c.auditado and not c.envasador_puro then c.bono_meta_bruto else 0 end as bono_meta_out,
      -- pagoEnvasado efectivo (presente)
      case when c.presente then c.pago_env_bruto else 0 end as pago_env_out
    from calc c
  )
  select jsonb_build_object(
    'ok', true,
    'fecha', to_char(p_fecha,'YYYY-MM-DD'),
    'data', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idPersonal',     f.id_personal,
        'nombre',         btrim(f.nombre || ' ' || f.apellido),
        'rol',            f.rol,
        'appOrigen',      f.app_origen,
        'presente',       f.presente,
        'auditado',       f.auditado,
        'aplicaBonoMeta', f.aplica_bono_meta,
        -- KPIs auto
        'ventasReales',   round(f.ventas_reales,2),
        'envasados',      f.envasados,
        'metaVenta',      f.meta_venta,
        'zonaPrincipal',  f.zona_principal,
        -- DINERO efectivo (lo que materializa LIQUIDACIONES_DIA)
        'montoBase',      round(f.monto_base_out,2),
        'pagoEnvasado',   round(f.pago_env_out,2),
        'bonoMeta',       f.bono_meta_out,
        'tarifaEnvasado', v_tarifa_env
      ) order by f.id_personal)
      from fin f), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$fn$;
revoke all on function mos.resumen_dia(date,text) from public;
grant execute on function mos.resumen_dia(date,text) to service_role, authenticated;
