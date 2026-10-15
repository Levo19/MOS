-- [1046] ROLLBACK: definiciones VIVAS pre-1046 (pg_get_functiondef, 2026-10-15T02:48:59.822Z) de las 23 funciones
-- que cambia 1046_anulado_conversion_no_suma.sql. create or replace => grants/owner/comentarios intactos.
begin;

-- ── me.datos_turno(text) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me.datos_turno(p_id_caja text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tz constant text := 'America/Lima';
  v_caja      jsonb;
  v_zona      text;
  v_cajero    text;
  v_fecha_dia text;
  v_monto_ini numeric;

  -- totales
  v_t_efectivo numeric := 0;
  v_t_virtual  numeric := 0;
  v_ext_ing    numeric := 0;
  v_ext_egr    numeric := 0;
  v_ext_ing_v  numeric := 0;
  v_ext_egr_v  numeric := 0;
  v_monto_final_efe numeric := 0;
  v_virtual_final   numeric := 0;
  v_t_credito  numeric := 0;
  v_t_anul     numeric := 0;
  v_t_sincob   numeric := 0;

  -- agregados jsonb
  v_tickets    jsonb := '[]'::jsonb;
  v_anulados   jsonb := '[]'::jsonb;
  v_sincobrar  jsonb := '[]'::jsonb;
  v_creditos   jsonb := '[]'::jsonb;
  v_cobrados   jsonb := '[]'::jsonb;
  v_extras     jsonb := '[]'::jsonb;
  v_corr       jsonb := '{}'::jsonb;
  v_vendedores jsonb := '[]'::jsonb;
  v_pmap       jsonb := '{}'::jsonb;
  v_p_total    numeric := 0;
  v_impresoras jsonb := '[]'::jsonb;
  v_auditorias jsonb := '{}'::jsonb;
  v_audit_lower jsonb := '{}'::jsonb;
  v_actores    jsonb := '[]'::jsonb;

  -- meta / policy
  v_pol           jsonb;
  v_meta_diaria   numeric := 0;
  v_comision_pct  numeric := 0;
  v_meta_audit    numeric := 0;
  v_configurada   boolean := false;
  v_total_cobrado numeric := 0;
  v_meta_lograda  boolean := false;
  v_excedente     numeric := 0;
  v_comision_total numeric := 0;
  v_total_cob_pmap numeric := 0;
  v_comision_vend  jsonb := '[]'::jsonb;
  v_meta           jsonb;
begin
  if p_id_caja is null or btrim(p_id_caja) = '' then
    return jsonb_build_object('ok', false, 'error', 'idCaja requerido');
  end if;

  -- ── 1. CAJAS ───────────────────────────────────────────────
  select
    jsonb_build_object(
      'idCaja',       k.id_caja,
      'cajero',       coalesce(k.vendedor,''),
      'estacion',     coalesce(k.estacion,''),
      'zona',         coalesce(k.zona_id,''),
      'fechaApert',   case when k.fecha_apertura is not null
                           then to_char(k.fecha_apertura at time zone v_tz, 'DD/MM/YYYY HH24:MI') else '' end,
      'fechaDia',     case when k.fecha_apertura is not null
                           then to_char(k.fecha_apertura at time zone v_tz, 'YYYY-MM-DD') else '' end,
      'montoInicial', coalesce(k.monto_inicial,0),
      'estado',       coalesce(k.estado,''),
      'montoFinal',   coalesce(k.monto_final,0),
      'fechaCierre',  case when k.fecha_cierre is not null
                           then to_char(k.fecha_cierre at time zone v_tz, 'DD/MM/YYYY HH24:MI') else '' end
    ),
    coalesce(k.zona_id,''),
    coalesce(k.vendedor,''),
    case when k.fecha_apertura is not null
         then to_char(k.fecha_apertura at time zone v_tz, 'YYYY-MM-DD') else '' end,
    coalesce(k.monto_inicial,0)
  into v_caja, v_zona, v_cajero, v_fecha_dia, v_monto_ini
  from me.cajas k
  where k.id_caja = p_id_caja
  limit 1;

  if v_caja is null then
    return jsonb_build_object('ok', false, 'error', 'Caja no encontrada: ' || p_id_caja);
  end if;

  -- ── 2 + 2b. VENTAS_CABECERA + DETALLE (tickets con items) ──
  -- Mapeo GAS→columnas:
  --   1=Fecha→fecha 2=Vendedor 4=Cliente_Doc 5=Cliente_Nombre 6=Total
  --   7=Tipo_Doc 8=FormaPago→forma_pago(metodo) 9=Correlativo
  --   10=ID_Caja 12=Estado_Envio 14=Obs
  with tk as (
    select v.id_venta, v.fecha, v.vendedor, v.cliente_doc, v.cliente_nombre,
           v.total, v.tipo_doc, v.forma_pago, v.correlativo, v.estado_envio, v.obs,
           v.created_at
    from me.ventas v
    where v.id_caja = p_id_caja
  ),
  items as (
    select d.id_venta,
           jsonb_agg(
             jsonb_build_object(
               'sku',      coalesce(d.sku,''),
               'nombre',   coalesce(d.nombre,''),
               'cantidad', coalesce(d.cantidad,0),
               'precio',   coalesce(d.precio,0),
               'subtotal', coalesce(d.subtotal,0)
             ) order by d.linea
           ) as its
    from me.ventas_detalle d
    join tk on tk.id_venta = d.id_venta
    group by d.id_venta
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'idVenta',     coalesce(tk.id_venta,''),
      'hora',        case when tk.fecha is not null then to_char(tk.fecha at time zone v_tz,'HH24:MI') else '' end,
      'vendedor',    coalesce(tk.vendedor,''),
      'clienteDoc',  coalesce(tk.cliente_doc,''),
      'clienteNom',  coalesce(tk.cliente_nombre,''),
      'total',       coalesce(tk.total,0),
      'tipoDoc',     coalesce(nullif(tk.tipo_doc,''),'NOTA_DE_VENTA'),
      'metodo',      coalesce(nullif(tk.forma_pago,''),'EFECTIVO'),
      'correlativo', coalesce(tk.correlativo,''),
      'estado',      coalesce(nullif(tk.estado_envio,''),'COMPLETADO'),
      'obs',         coalesce(tk.obs,''),
      -- [848] a qué turno se le asignó este crédito ('' = todavía sin dueño)
      -- [855] Yape que verifica este ticket ('' = todavía sin verificar)
      'yape',        (select jsonb_build_object('pagador', coalesce(y.pagador,''), 'monto', y.monto,
                                'hora', to_char(y.ts_notificacion at time zone v_tz,'HH24:MI'))
                        from mos.yapes_entrantes y
                       where y.estado = 'MATCHEADO' and (y.id_venta = tk.id_venta
                         or exists (select 1 from mos.yape_ventas yv where yv.id_yape = y.id and yv.id_venta = tk.id_venta)) limit 1),
      'asignadoA',   coalesce((select cp.nombre_dia from mos.creditos_planilla cp
                                where cp.id_venta = tk.id_venta and cp.estado = 'ASIGNADO' limit 1),''),
      'items',       coalesce(items.its, '[]'::jsonb)
    )
    -- orden estable por created_at luego id (igual orden de aparición en la Hoja)
    order by tk.created_at nulls last, tk.id_venta
  ), '[]'::jsonb)
  into v_tickets
  from tk
  left join items on items.id_venta = tk.id_venta;

  -- ── 3. MOVIMIENTOS_EXTRA ───────────────────────────────────
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'tipo',     coalesce(nullif(e.tipo,''),'EGRESO'),
      'monto',    coalesce(e.monto,0),
      'concepto', coalesce(e.concepto,''),
      'obs',      coalesce(e.obs,''),
      'hora',     case when e.ts is not null then to_char(e.ts at time zone v_tz,'HH24:MI') else '' end
    ) order by e.ts nulls last, e.id_extra
  ), '[]'::jsonb)
  into v_extras
  from me.movimientos_extra e
  where e.id_caja = p_id_caja;

  -- ── 4. Clasificación de tickets ────────────────────────────
  select
    coalesce(jsonb_agg(t order by ord) filter (where t->>'metodo' = 'ANULADO'), '[]'::jsonb),
    coalesce(jsonb_agg(t order by ord) filter (where t->>'metodo' = 'POR_COBRAR'), '[]'::jsonb),
    coalesce(jsonb_agg(t order by ord) filter (where t->>'metodo' = 'CREDITO'), '[]'::jsonb),
    coalesce(jsonb_agg(t order by ord) filter (where t->>'metodo' <> 'ANULADO' and t->>'metodo' <> 'POR_COBRAR'), '[]'::jsonb)
  into v_anulados, v_sincobrar, v_creditos, v_cobrados
  from jsonb_array_elements(v_tickets) with ordinality as a(t, ord);

  -- ── 4b. Totales efectivo / virtual (solo cobrados, sin CREDITO) ──
  -- _parseMetodo:
  --   '' / POR_COBRAR / CREDITO / ANULADO -> {0,0}
  --   EFECTIVO -> {efe:total}
  --   VIRTUAL  -> {vir:total}
  --   MIXTO*   -> VIR:n / EFE:n (si falta EFE => round(total-vir,2))
  --   default  -> {vir:total}
  with cob as (
    select t->>'metodo' as metodo, (t->>'total')::numeric as total
    from jsonb_array_elements(v_cobrados) t
    where t->>'metodo' not in ('CREDITO','PLANILLA')   -- [617] PLANILLA no entra al arqueo
  ),
  parsed as (
    select
      case
        when upper(btrim(metodo)) = 'EFECTIVO' then total
        when upper(btrim(metodo)) = 'VIRTUAL'  then 0
        when upper(btrim(metodo)) like 'MIXTO%' then
          case
            when (regexp_match(metodo, 'EFE:([0-9.]+)', 'i')) is not null
              then ((regexp_match(metodo, 'EFE:([0-9.]+)', 'i'))[1])::numeric
            else round((total - coalesce(((regexp_match(metodo,'VIR:([0-9.]+)','i'))[1])::numeric, 0)) * 100) / 100
          end
        else 0  -- default rama -> efe 0
      end as efe,
      case
        when upper(btrim(metodo)) = 'EFECTIVO' then 0
        when upper(btrim(metodo)) = 'VIRTUAL'  then total
        when upper(btrim(metodo)) like 'MIXTO%' then
          coalesce(((regexp_match(metodo,'VIR:([0-9.]+)','i'))[1])::numeric, 0)
        else total  -- default rama -> vir total
      end as vir
    from cob
  )
  select round(coalesce(sum(efe),0)*100)/100, round(coalesce(sum(vir),0)*100)/100
  into v_t_efectivo, v_t_virtual
  from parsed;

  -- ── 4c. Totales de extras por tipo ─────────────────────────
  select
    coalesce(sum(monto) filter (where tipo='INGRESO'),0),
    coalesce(sum(monto) filter (where tipo='EGRESO'),0),
    coalesce(sum(monto) filter (where tipo='INGRESO_VIRTUAL'),0),
    coalesce(sum(monto) filter (where tipo='EGRESO_VIRTUAL'),0)
  into v_ext_ing, v_ext_egr, v_ext_ing_v, v_ext_egr_v
  from (
    select t->>'tipo' as tipo, (t->>'monto')::numeric as monto
    from jsonb_array_elements(v_extras) t
  ) x;

  v_monto_final_efe := round((v_monto_ini + v_t_efectivo + v_ext_ing - v_ext_egr)*100)/100;
  v_virtual_final   := round((v_t_virtual + v_ext_ing_v - v_ext_egr_v)*100)/100;

  select coalesce(sum((t->>'total')::numeric),0) into v_t_credito  from jsonb_array_elements(v_creditos) t;
  select coalesce(sum((t->>'total')::numeric),0) into v_t_anul     from jsonb_array_elements(v_anulados) t;
  select coalesce(sum((t->>'total')::numeric),0) into v_t_sincob   from jsonb_array_elements(v_sincobrar) t;

  -- ── 5. Correlativos por tipo (noAnul = metodo<>ANULADO) ────
  select coalesce(jsonb_object_agg(tipodoc, arr), '{}'::jsonb)
  into v_corr
  from (
    select t->>'tipoDoc' as tipodoc,
           jsonb_agg((t->>'correlativo') order by ord) as arr
    from jsonb_array_elements(v_tickets) with ordinality as a(t,ord)
    where t->>'metodo' <> 'ANULADO'
      and coalesce(t->>'tipoDoc','') <> ''
      and coalesce(t->>'correlativo','') <> ''
    group by t->>'tipoDoc'
  ) g;

  -- ── 6. pMap (desempeño, noAnul) + pTotal ───────────────────
  select
    coalesce(jsonb_object_agg(nombre, jsonb_build_object('tks', tks, 'total', total)), '{}'::jsonb),
    coalesce(sum(total),0)
  into v_pmap, v_p_total
  from (
    select coalesce(nullif(t->>'vendedor',''),'Sin nombre') as nombre,
           count(*) as tks,
           sum((t->>'total')::numeric) as total
    from jsonb_array_elements(v_tickets) t
    where t->>'metodo' <> 'ANULADO'
    group by 1
  ) p;

  -- vendedoresList: vendedores noAnul, distintos del cajero, en orden de aparición
  select coalesce(jsonb_agg(vend order by ord), '[]'::jsonb)
  into v_vendedores
  from (
    select vend, min(ord) as ord
    from (
      select t->>'vendedor' as vend, ord
      from jsonb_array_elements(v_tickets) with ordinality as a(t,ord)
      where t->>'metodo' <> 'ANULADO'
        and coalesce(t->>'vendedor','') <> ''
        and t->>'vendedor' <> v_cajero
    ) s
    group by vend
  ) u;

  -- ── 7. IMPRESORAS (TICKET, activas, con printNodeId) + estación nombre ──
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',          coalesce(i.id_impresora,''),
      'nombre',      coalesce(i.nombre,''),
      'printNodeId', btrim(i.printnode_id),
      'zona',        coalesce(i.id_zona,''),
      'estacion',    coalesce(nullif(es.nombre,''), coalesce(i.id_estacion,''))
    ) order by i.id_impresora
  ), '[]'::jsonb)
  into v_impresoras
  from mos.impresoras i
  left join mos.estaciones es on es.id_estacion = i.id_estacion
  where (i.activo is true or lower(coalesce(i.activo::text,'')) in ('1','true'))
    and upper(coalesce(i.tipo,'')) = 'TICKET'
    and coalesce(btrim(i.printnode_id),'') <> '';

  -- ── 8. AUDITORÍAS del día filtradas por zona ───────────────
  if v_fecha_dia <> '' then
    select
      coalesce(jsonb_object_agg(vend, cnt), '{}'::jsonb),
      coalesce(jsonb_object_agg(lower(vend), cnt), '{}'::jsonb)
    into v_auditorias, v_audit_lower
    from (
      select btrim(a.vendedor) as vend, count(*) as cnt
      from me.auditorias a
      where to_char(a.fecha at time zone v_tz,'YYYY-MM-DD') = v_fecha_dia
        and coalesce(btrim(a.vendedor),'') <> ''
        and (
          btrim(coalesce(v_zona,'')) = ''
          or coalesce(upper(btrim(a.zona_id)),'') = ''
          or upper(btrim(a.zona_id)) = upper(btrim(v_zona))
        )
      group by btrim(a.vendedor)
    ) z;
  end if;

  -- ── ACTORES DE LA ZONA ─────────────────────────────────────
  -- Union: keys(pMap) + cajero + keys(auditorias) + JORNADAS(dia/zona/appOrigen=ME)
  -- Dedup case-insensitive preservando capitalización (primera vista), sort asc.
  with src as (
    select jsonb_object_keys(v_pmap) as nombre
    union all
    select v_cajero
    union all
    select jsonb_object_keys(v_auditorias)
    union all
    select j.nombre
    from mos.jornadas j
    where v_fecha_dia <> ''
      and to_char(j.fecha at time zone v_tz,'YYYY-MM-DD') = v_fecha_dia
      and (coalesce(upper(j.app_origen),'') = '' or upper(j.app_origen) = 'ME')
      and (
        btrim(coalesce(v_zona,'')) = ''
        or coalesce(upper(btrim(j.zona)),'') = ''
        or upper(btrim(j.zona)) = upper(btrim(v_zona))
      )
  ),
  cleaned as (
    select btrim(nombre) as nombre
    from src
    where coalesce(btrim(nombre),'') <> ''
  ),
  dedup as (
    select distinct on (lower(nombre)) nombre
    from cleaned
    order by lower(nombre)
  )
  select coalesce(jsonb_agg(nombre order by lower(nombre)), '[]'::jsonb)
  into v_actores
  from dedup;

  -- ── META DIARIA + COMISIÓN (politica_json por zona, sin fallback) ──
  if coalesce(btrim(v_zona),'') <> '' then
    select z.politica_json into v_pol from mos.zonas z where z.id_zona = v_zona limit 1;
    if v_pol is not null then
      if (v_pol->>'metaDiaria') is not null and (v_pol->>'metaDiaria')::numeric > 0 then
        v_meta_diaria := (v_pol->>'metaDiaria')::numeric;
      end if;
      if (v_pol->>'comisionExcedentePct') is not null and (v_pol->>'comisionExcedentePct')::numeric >= 0 then
        v_comision_pct := (v_pol->>'comisionExcedentePct')::numeric;
      end if;
      if (v_pol->>'metaAuditorias') is not null and (v_pol->>'metaAuditorias')::numeric > 0 then
        v_meta_audit := (v_pol->>'metaAuditorias')::numeric;
      end if;
      if v_meta_diaria > 0 then v_configurada := true; end if;
    end if;
  end if;

  v_total_cobrado  := round((v_t_efectivo + v_t_virtual)*100)/100;
  v_meta_lograda   := v_total_cobrado >= v_meta_diaria;
  v_excedente      := greatest(0, round((v_total_cobrado - v_meta_diaria)*100)/100);
  v_comision_total := round(v_excedente * v_comision_pct)/100;

  -- pMapCobrado (cobrados, sin CREDITO) → comisión por vendedor
  with cob as (
    select coalesce(nullif(t->>'vendedor',''),'Sin nombre') as nombre,
           (t->>'total')::numeric as total
    from jsonb_array_elements(v_cobrados) t
    where t->>'metodo' not in ('CREDITO','PLANILLA')   -- [617] PLANILLA no entra al arqueo
  ),
  agg as (
    select nombre, count(*) as tks, sum(total) as total
    from cob group by nombre
  ),
  tot as ( select coalesce(sum(total),0) as tt from agg )
  select coalesce(sum(agg.total),0) into v_total_cob_pmap from agg;

  with cob as (
    select coalesce(nullif(t->>'vendedor',''),'Sin nombre') as nombre,
           (t->>'total')::numeric as total
    from jsonb_array_elements(v_cobrados) t
    where t->>'metodo' not in ('CREDITO','PLANILLA')   -- [617] PLANILLA no entra al arqueo
  ),
  agg as (
    select nombre, sum(total) as total
    from cob group by nombre
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'nombre',  nombre,
      'venta',   round(total*100)/100,
      'pct',     round(pctv*1000)/10,
      'comision', case when v_comision_total > 0 then round(v_comision_total * pctv * 100)/100 else 0 end
    ) order by total desc, nombre
  ), '[]'::jsonb)
  into v_comision_vend
  from (
    select nombre, total,
           case when v_total_cob_pmap > 0 then total / v_total_cob_pmap else 0 end as pctv
    from agg
  ) s;

  v_meta := jsonb_build_object(
    'configurada',  v_configurada,
    'metaDiaria',   v_meta_diaria,
    'comisionPct',  v_comision_pct,
    'totalCobrado', v_total_cobrado,
    'metaLograda',  v_meta_lograda,
    'excedente',    v_excedente,
    'faltante',     case when v_meta_lograda then 0 else round((v_meta_diaria - v_total_cobrado)*100)/100 end,
    'progresoPct',  case when v_meta_diaria > 0 then round(v_total_cobrado / v_meta_diaria * 1000)/10 else 0 end,
    'comisionTotal', v_comision_total,
    'comisionPorVendedor', v_comision_vend
  );

  -- ── Salida ─────────────────────────────────────────────────
  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'caja',           v_caja,
      'tickets',        v_tickets,
      'anulados',       v_anulados,
      'sinCobrar',      v_sincobrar,
      'creditos',       v_creditos,
      'cobrados',       v_cobrados,
      'extras',         v_extras,
      'corrPorTipo',    v_corr,
      'vendedores',     v_vendedores,
      'pMap',           v_pmap,
      'pTotal',         v_p_total,
      'impresoras',     v_impresoras,
      'auditorias',     v_auditorias,
      'auditoriasLower', v_audit_lower,
      'actoresZona',    v_actores,
      -- [855] cierre: cuánto de lo cobrado por VIRTUAL tiene su Yape verificado
      'yapes', (
        select jsonb_build_object(
          'verificados',      count(*) filter (where mos._venta_cubierta(v.id_venta)),
          'sinVerificar',     count(*) filter (where not mos._venta_cubierta(v.id_venta)),
          'montoVerificado',  coalesce(sum(v.total) filter (where mos._venta_cubierta(v.id_venta)),0),
          'montoSinVerificar',coalesce(sum(v.total) filter (where not mos._venta_cubierta(v.id_venta)),0),
          'ambiguos', (select count(*) from mos.yapes_entrantes ya
                        where ya.estado='AMBIGUO'
                          and ya.dia = (select max((v2.fecha at time zone v_tz)::date)
                                          from me.ventas v2 where v2.id_caja = p_id_caja)),
          'sinUsar',  (select count(*) from mos.yapes_entrantes yn
                        where yn.estado='NUEVO' and yn.monto is not null
                          and yn.dia = (select max((v3.fecha at time zone v_tz)::date)
                                          from me.ventas v3 where v3.id_caja = p_id_caja)))
          from me.ventas v
         where v.id_caja = p_id_caja
           and me._monto_virtual(v.forma_pago, v.total) is not null),
      'metaAudit',      v_meta_audit,
      'meta',           v_meta,
      'totales', jsonb_build_object(
        'efectivo',             v_t_efectivo,
        'virtual',              v_t_virtual,
        'credito',              v_t_credito,
        'anulados',             v_t_anul,
        'sinCobrar',            v_t_sincob,
        'extrasIngreso',        v_ext_ing,
        'extrasEgreso',         v_ext_egr,
        'extrasIngresoVirtual', v_ext_ing_v,
        'extrasEgresoVirtual',  v_ext_egr_v,
        'montoFinalEfe',        v_monto_final_efe,
        'virtualFinal',         v_virtual_final
      )
    )
  );
end;
$function$;

-- ── me.estado_cajas() (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me.estado_cajas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
with
v as (
  select
    id_caja,
    coalesce(estado_envio,'COMPLETADO') as estado,   -- col-12 de VENTAS_CABECERA migró como estado_envio (NO existe me.ventas.estado)
    coalesce(forma_pago,'EFECTIVO')      as metodo,
    coalesce(tipo_doc,'NOTA_DE_VENTA')   as tipo_doc,
    coalesce(total,0)::numeric           as total
  from me.ventas
  where id_caja is not null and id_caja <> ''
),
vflag as (
  select v.*,
    (estado = 'ANULADO')                                   as is_anulado,
    (estado <> 'ANULADO' and metodo = 'POR_COBRAR')        as is_porcobrar,
    (estado <> 'ANULADO' and metodo <> 'POR_COBRAR')       as is_normal,
    case when estado <> 'ANULADO' and metodo <> 'POR_COBRAR' then
      case when metodo = 'EFECTIVO' then total
           when metodo like 'MIXTO%' then coalesce(substring(metodo from 'EFE:([0-9.]+)')::numeric, 0)
           else 0 end
    else 0 end as efe_part,
    case when estado <> 'ANULADO' and metodo <> 'POR_COBRAR' then
      case when metodo like 'MIXTO%' then
              coalesce(substring(metodo from 'VIR:([0-9.]+)')::numeric,
                       total - coalesce(substring(metodo from 'EFE:([0-9.]+)')::numeric, 0))
           when metodo = 'EFECTIVO' then 0
           else total end
    else 0 end as otros_part
  from v
),
vcaja as (
  select id_caja,
    sum(case when is_normal then total else 0 end) as total,
    sum(case when is_anulado then 0 else 1 end)    as tickets,
    sum(efe_part)                                  as efectivo,
    sum(otros_part)                                as otros,
    sum(case when is_anulado then 1 else 0 end)    as anulados,
    sum(case when is_porcobrar then 1 else 0 end)  as sin_cobrar
  from vflag group by id_caja
),
vmetodo as (
  select id_caja, jsonb_object_agg(metodo, s) as by_metodo
  from (select id_caja, metodo, sum(total) as s from vflag where is_normal group by id_caja, metodo) t
  group by id_caja
),
vdoc as (
  select id_caja, jsonb_object_agg(tipo_doc, s) as by_doc
  from (select id_caja, tipo_doc, sum(total) as s from vflag where is_normal group by id_caja, tipo_doc) t
  group by id_caja
),
ex as (
  select id_caja,
    sum(case when tipo='INGRESO' then monto else 0 end) as entradas,
    sum(case when tipo='EGRESO'  then monto else 0 end) as salidas
  from (
    select coalesce(tipo,'EGRESO') as tipo, coalesce(monto,0)::numeric as monto, id_caja
    from me.movimientos_extra where id_caja is not null and id_caja <> ''
  ) m group by id_caja
),
cajas_filt as (
  select c.id_caja, c.vendedor, c.estacion, c.zona_id, c.estado,
    c.fecha_apertura, c.fecha_cierre,
    coalesce(c.monto_inicial,0)::numeric as monto_inicial,
    coalesce(c.monto_final,0)::numeric   as monto_final,
    coalesce(vc.total,0)        as v_total,
    coalesce(vc.tickets,0)      as v_tickets,
    coalesce(vc.efectivo,0)     as v_efectivo,
    coalesce(vc.otros,0)        as v_otros,
    coalesce(vc.anulados,0)     as v_anulados,
    coalesce(vc.sin_cobrar,0)   as v_sincobrar,
    coalesce(vm.by_metodo,'{}'::jsonb) as v_bymetodo,
    coalesce(vd.by_doc,'{}'::jsonb)    as v_bydoc,
    coalesce(ex.entradas,0)     as e_entradas,
    coalesce(ex.salidas,0)      as e_salidas
  from me.cajas c
  left join vcaja   vc on vc.id_caja = c.id_caja
  left join vmetodo vm on vm.id_caja = c.id_caja
  left join vdoc    vd on vd.id_caja = c.id_caja
  left join ex         on ex.id_caja = c.id_caja
  where not (c.estado = 'CERRADA' and (c.fecha_cierre is null or c.fecha_cierre < now() - interval '30 days'))
),
obj as (
  select estado,
    jsonb_build_object(
      'idCaja',        id_caja,
      'vendedor',      coalesce(vendedor,''),
      'estacion',      coalesce(estacion,''),
      'zona',          coalesce(zona_id,''),
      'estado',        coalesce(estado,''),
      'fechaApertura', case when fecha_apertura is not null then to_char(fecha_apertura at time zone 'America/Lima','YYYY-MM-DD HH24:MI') else '' end,
      'fechaCierre',   case when fecha_cierre   is not null then to_char(fecha_cierre   at time zone 'America/Lima','YYYY-MM-DD HH24:MI') else '' end,
      'montoInicial',  monto_inicial,
      'montoFinal',    monto_final,
      'totalVentas',   round(v_total,2),
      'tickets',       v_tickets,
      'efectivo',      round(v_efectivo,2),
      'otros',         round(v_otros,2),
      'anulados',      v_anulados,
      'sinCobrar',     v_sincobrar,
      'byMetodo',      v_bymetodo,
      'byDoc',         v_bydoc,
      'entradas',      e_entradas,
      'salidas',       e_salidas,
      'efectivoEsperado', round(monto_inicial + v_efectivo + e_entradas - e_salidas, 2),
      'diferencia',    case when estado='CERRADA'
                            then round(monto_final - (monto_inicial + v_efectivo + e_entradas - e_salidas), 2)
                            else null end
    ) as caja
  from cajas_filt
)
select jsonb_build_object(
  'status','success',
  'kpis', jsonb_build_object(
     'cajasAbiertas', (select count(*) from obj where estado='ABIERTA'),
     'cajasCerradas', (select count(*) from obj where estado<>'ABIERTA'),
     'totalDia',      (select coalesce(sum((caja->>'totalVentas')::numeric),0) from obj),
     'ticketsDia',    (select coalesce(sum((caja->>'tickets')::int),0)        from obj),
     'anuladosDia',   (select coalesce(sum((caja->>'anulados')::int),0)       from obj),
     'sinCobrarDia',  (select coalesce(sum((caja->>'sinCobrar')::int),0)      from obj)
  ),
  'abiertas', coalesce((select jsonb_agg(caja) from obj where estado='ABIERTA'),  '[]'::jsonb),
  'cerradas', coalesce((select jsonb_agg(caja) from obj where estado<>'ABIERTA'), '[]'::jsonb)
);
$function$;

-- ── mos.resumen_dia(date,text) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.resumen_dia(p_fecha date, p_id_personal text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

-- ── mos.resumen_todos_dia(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.resumen_todos_dia(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
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
$function$;

-- ── me.meta_progreso_zona(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me.meta_progreso_zona(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_dia   date := (now() at time zone 'America/Lima')::date;
  v_meta  numeric;
  v_total numeric := 0;
begin
  if v_zona = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere zona');
  end if;

  -- [729/730] meta de la política de la zona, vigencia por día, SIN default global.
  v_meta := mos._meta_zona(v_zona, v_dia);

  select coalesce(sum(v.total), 0) into v_total
    from me.ventas v
   where upper(coalesce(v.zona_id, '')) = v_zona
     and (v.fecha at time zone 'America/Lima')::date = v_dia
     and upper(coalesce(v.forma_pago, '')) not in ('ANULADO','POR_COBRAR','CREDITO');

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'zona',       v_zona,
    'dia',        to_char(v_dia, 'YYYY-MM-DD'),
    'tieneMeta',  coalesce(v_meta, 0) > 0,
    'metaDiaria', round(coalesce(v_meta, 0) * 100) / 100,
    'lleva',      round(v_total * 100) / 100,
    'faltan',     case when coalesce(v_meta,0) > 0 then greatest(0, round((v_meta - v_total)*100)/100) else 0 end,
    'pct',        case when coalesce(v_meta,0) > 0 then round(v_total / v_meta * 1000) / 10 else 0 end
  ));
exception when others then
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$function$;

-- ── me.tributario_ventas_mes(integer,integer) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me.tributario_ventas_mes(p_mes integer DEFAULT NULL::integer, p_anio integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'me', 'public'
AS $function$
declare
  v_mes  int := p_mes;
  v_anio int := p_anio;
  r record;
begin
  if v_mes is null or v_mes = 0 or v_anio is null or v_anio = 0 then
    v_mes  := extract(month from (now() at time zone 'America/Lima'))::int;
    v_anio := extract(year  from (now() at time zone 'America/Lima'))::int;
  end if;

  select
    coalesce(round(sum(
      case
        when v.tipo_doc in ('BOLETA','FACTURA') then coalesce(v.total,0)
        when v.tipo_doc = 'NOTA_DE_VENTA'
             and coalesce(v.forma_pago,'') not in ('POR_COBRAR','CREDITO')
             then coalesce(v.total,0)
        else 0
      end
    ), 2), 0) as total_ventas,
    coalesce(round(sum(
      case when v.tipo_doc in ('BOLETA','FACTURA')
           then me._igv_venta(v.id_venta, v.total)
           else 0 end
    ), 2), 0) as total_igv,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA'))                                                as cpe_total,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA') and v.nf_estado = 'EMITIDO')                    as cpe_emitidos,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA')
                       and ( v.nf_estado in ('RECHAZADO','RECHAZADO_SUNAT','ERROR')
                          or ( coalesce(v.nf_hash,'') = ''
                               and coalesce(v.nf_estado,'PENDIENTE') in ('PENDIENTE','','NA')
                               and extract(epoch from (now() - v.fecha))/60 >
                                   (case when v.tipo_doc = 'FACTURA' then 20 else 1500 end) ) ))              as cpe_errores,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA')
                       and coalesce(v.nf_estado,'') in ('PENDIENTE','','NA')
                       and not ( coalesce(v.nf_hash,'') = ''
                                 and extract(epoch from (now() - v.fecha))/60 >
                                     (case when v.tipo_doc = 'FACTURA' then 20 else 1500 end) ))              as cpe_pendientes
  into r
  from me.ventas v
  where (v.fecha at time zone 'America/Lima') >= make_timestamp(v_anio, v_mes, 1, 0, 0, 0)
    and (v.fecha at time zone 'America/Lima') <  (make_timestamp(v_anio, v_mes, 1, 0, 0, 0) + interval '1 month')
    and coalesce(v.estado_envio,'') <> 'HUERFANA_LIMPIADA'
    and coalesce(v.forma_pago,'')   <> 'ANULADO';

  return jsonb_build_object(
    'status',          'success',
    'mes',             v_mes,
    'anio',            v_anio,
    'totalVentas',     coalesce(r.total_ventas, 0),
    'totalIGVEmitido', coalesce(r.total_igv, 0),
    'cpeTotal',        coalesce(r.cpe_total, 0),
    'cpeEmitidos',     coalesce(r.cpe_emitidos, 0),
    'cpePendientes',   coalesce(r.cpe_pendientes, 0),
    'cpeErrores',      coalesce(r.cpe_errores, 0),
    'cpeAnulados',     0
  );
end;
$function$;

-- ── me.analitica_pos(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me.analitica_pos(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cb    text := upper(btrim(coalesce(p->>'codigoBarra','')));
  v_zona  text := upper(btrim(coalesce(p->>'zona','')));
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_lun   date := date_trunc('week', (now() at time zone 'America/Lima'))::date;
  v_desde date;
  v_prod  mos.productos%rowtype;
  v_canon mos.productos%rowtype;
  v_sku   text;
  v_data  jsonb;
begin
  if not (me._claim_zona_ok() or mos._claim_ok()) then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_cb = '' or v_zona = '' then
    return jsonb_build_object('ok', false, 'error', 'Requiere codigoBarra y zona');
  end if;
  v_desde := v_lun - 28;

  select * into v_prod from mos.productos where upper(codigo_barra) = v_cb limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'PRODUCTO_NO_ENCONTRADO');
  end if;
  v_sku := coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto);
  select * into v_canon from mos.productos
   where (nullif(btrim(sku_base),'') = v_sku or id_producto = v_sku)
     and coalesce(nullif(factor_conversion,0),1) = 1
     and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
   order by (id_producto = v_sku) desc, id_producto limit 1;
  if v_canon.id_producto is null then v_canon := v_prod; end if;

  with grupo as (
    select upper(codigo_barra) as cb, coalesce(nullif(factor_conversion,0),1) as f
      from mos.productos
     where nullif(btrim(sku_base),'') = v_sku or id_producto = v_sku or upper(codigo_barra) = v_cb
    union
    select upper(e.codigo_barra), 1 from mos.equivalencias e
     where e.sku_base = v_sku and coalesce(e.activo, true)
  ),
  ventas_all as (
    -- [532] ventana completa, TODAS las zonas (se parte adentro)
    select upper(coalesce(v.zona_id,'')) as zona,
           (v.fecha at time zone 'America/Lima')::date as dia,
           sum(coalesce(vd.cantidad,0) * g.f) as u
      from me.ventas v
      join me.ventas_detalle vd on vd.id_venta = v.id_venta
      join grupo g on upper(coalesce(vd.cod_barras,'')) = g.cb
     where (v.fecha at time zone 'America/Lima')::date >= v_desde
       and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
     group by 1, 2
  ),
  ventas_dia as (
    select dia, sum(u) as u from ventas_all where zona = v_zona group by 1
  ),
  otras as (
    select zona, sum(u) as u from ventas_all where zona <> v_zona and zona <> '' group by 1
  ),
  hist as (
    select d::date as dia,
           extract(isodow from d)::int as dow,
           ((d::date - v_desde) / 7)::int as w,
           coalesce(vd.u, 0) as u
      from generate_series(v_desde, v_lun - 1, interval '1 day') d
      left join ventas_dia vd on vd.dia = d::date
  ),
  pron as (
    select dow, ceil(avg(u))::numeric as pron from hist group by dow
  ),
  sem as (
    select w, max(u) as pico, sum(u) as vol from hist group by w
  ),
  tend as (
    select case
             when coalesce(sum(vol),0) <= 0 then 'NULA'
             when avg(pico) > 0 and (case when var_pop(w) > 0 then regr_slope(pico, w) else 0 end) / avg(pico) >=  0.10 then 'CRECIENTE'
             when avg(pico) > 0 and (case when var_pop(w) > 0 then regr_slope(pico, w) else 0 end) / avg(pico) <= -0.10 then 'DECRECIENTE'
             else 'ESTABLE'
           end as tendencia,
           coalesce(sum(vol),0) as vol4
      from sem
  ),
  actual as (
    select d::date as dia, extract(isodow from d)::int as dow,
           case when d::date <= v_hoy then coalesce(vd.u, 0) else null end as u,
           coalesce(pr.pron, 0) as pron
      from generate_series(v_lun, v_lun + 6, interval '1 day') d
      left join ventas_dia vd on vd.dia = d::date
      left join pron pr on pr.dow = extract(isodow from d)::int
  ),
  stocks as (
    select
      (select coalesce(sum(s.cantidad_disponible),0) from wh.stock s
        where upper(coalesce(s.cod_producto,'')) in (select cb from grupo)) as alm,
      (select coalesce(sum(sz.cantidad),0) from me.stock_zonas sz
        where upper(btrim(sz.zona_id)) = v_zona
          and upper(coalesce(sz.cod_barras,'')) in (select cb from grupo)) as zon,
      (select to_char(min(zl.fecha_vencimiento) at time zone 'America/Lima','YYYY-MM-DD')
         from me.zona_lotes zl
        where zl.zona_id = v_zona and coalesce(zl.cant_restante,0) > 0
          and (zl.sku_base = v_sku or upper(coalesce(zl.cod_barras,'')) in (select cb from grupo))) as venc
  )
  select jsonb_build_object(
    'ok', true,
    'producto', jsonb_build_object(
      'nombre', v_canon.descripcion, 'codigoBarra', v_canon.codigo_barra,
      'skuBase', v_sku, 'foto', coalesce(v_canon.foto_url,''),
      'esPadreDe', case when upper(coalesce(v_canon.codigo_barra,'')) <> v_cb then v_prod.descripcion else '' end),
    'zona', v_zona,
    'hoy', to_char(v_hoy,'YYYY-MM-DD'),
    'tendencia', (select tendencia from tend),
    'volumen4sem', (select vol4 from tend),
    'historial', (select coalesce(jsonb_agg(jsonb_build_object(
        'fecha', to_char(dia,'YYYY-MM-DD'), 'dow', dow, 'sem', w + 1, 'u', u) order by dia), '[]'::jsonb) from hist),
    'semanaActual', (select coalesce(jsonb_agg(jsonb_build_object(
        'fecha', to_char(dia,'YYYY-MM-DD'), 'dow', dow, 'u', u, 'pron', pron,
        'esHoy', dia = v_hoy) order by dia), '[]'::jsonb) from actual),
    'pronSemana', (select coalesce(sum(pron),0) from actual),
    'vendidosSemana', (select coalesce(sum(u),0) from actual where u is not null),
    'stockAlmacen', (select alm from stocks),
    'stockZona', (select zon from stocks),
    'vencProxZona', coalesce((select venc from stocks),''),
    'otrasZonas', (select coalesce(sum(u),0) from otras),
    'otrasZonasDetalle', (select coalesce(jsonb_agg(jsonb_build_object('zona', zona, 'u', u) order by u desc), '[]'::jsonb) from otras)
  ) into v_data;

  return v_data;
end; $function$;

-- ── mos.analitica_producto(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.analitica_producto(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id_in    text := nullif(btrim(coalesce(p->>'idProducto','')), '');
  v_cb_in    text := nullif(btrim(coalesce(p->>'codigoBarra','')), '');
  v_sku_in   text := nullif(btrim(coalesce(p->>'skuBase','')), '');
  v_dias     int;
  v_desde    date;
  v_hoy      date := (now() at time zone 'America/Lima')::date;

  v_prod     mos.productos%rowtype;
  v_sku_base text;
  v_costo    numeric;
  v_precio   numeric;

  v_total_u  numeric := 0;
  v_total_i  numeric := 0;
  v_me_ok    boolean := false;
  v_wh_ok    boolean := false;
  v_stock    numeric := 0;

  v_data     jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Requiere al menos un identificador (paridad: !idProducto && !codigoBarra && !skuBase → error).
  if v_id_in is null and v_cb_in is null and v_sku_in is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere idProducto');
  end if;

  -- dias = parseInt(params.dias) || 30. Clamp defensivo.
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  -- GAS: desde = hoy - dias*86400000 (ms); aquí corte por DÍA Lima (= hoy - dias). Borde ≤1 día parcial (ver NOTA G).
  v_desde := v_hoy - v_dias;

  -- ── Resolver el producto (réplica del orden del GAS) ──────────────────────────────────────────
  -- 1) por idProducto; si es presentación (skuBase distinto del id) subir al base.
  if v_id_in is not null then
    select * into v_prod from mos.productos where id_producto = v_id_in limit 1;
    -- [428 FIX catálogo v4] el climb viejo asumía sku_base = id del padre; en la data real
    -- sku_base es el CÓDIGO DE GRUPO (ej LEV149) → el select vacío ANULABA v_prod y devolvía
    -- 'Producto no encontrado' para 2373 productos. Ahora: solo sube si es PRESENTACIÓN,
    -- busca el CANÓNICO del grupo, y si no lo halla CONSERVA el producto original.
    if found and coalesce(nullif(v_prod.factor_conversion,0),1) <> 1
       and coalesce(nullif(btrim(v_prod.codigo_producto_base),''),'') = ''
       and nullif(btrim(v_prod.sku_base),'') is not null then
      declare v_base428 mos.productos%rowtype;
      begin
        select * into v_base428 from mos.productos
         where (id_producto = v_prod.sku_base or nullif(btrim(sku_base),'') = v_prod.sku_base)
           and coalesce(nullif(factor_conversion,0),1) = 1
           and coalesce(nullif(btrim(codigo_producto_base),''),'') = ''
         order by (id_producto = v_prod.sku_base) desc, id_producto limit 1;
        if v_base428.id_producto is not null then v_prod := v_base428; end if;
      end;
    end if;
  end if;
  -- 2) si no hubo match y hay codigoBarra, por codigoBarra.
  if v_prod.id_producto is null and v_cb_in is not null then
    select * into v_prod from mos.productos where codigo_barra = v_cb_in limit 1;
  end if;
  -- 3) (extensión defensiva — el GAS solo prueba idProducto/codigoBarra, pero acepta skuBase como param)
  --    si aún no hay match y vino skuBase, resolver el producto base de ese sku.
  if v_prod.id_producto is null and v_sku_in is not null then
    select * into v_prod from mos.productos
     where id_producto = v_sku_in
        or (nullif(btrim(sku_base),'') = v_sku_in)
     order by (id_producto = v_sku_in) desc, id_producto
     limit 1;
  end if;

  if v_prod.id_producto is null then
    return jsonb_build_object('ok', false, 'error', 'Producto no encontrado');
  end if;

  v_sku_base := coalesce(nullif(btrim(v_prod.sku_base),''), v_prod.id_producto);  -- GAS: prod.skuBase || prod.idProducto
  v_costo    := coalesce(v_prod.precio_costo, 0);
  v_precio   := coalesce(v_prod.precio_venta, 0);

  -- ── Grupo: todos los codigosBarra del grupo (base + presentaciones). GAS: productos donde
  --    skuBase===skuBase OR idProducto===skuBase → map(codigoBarra) filter Boolean. ─────────────
  with
  grupo_prod as (
    select pr.id_producto, nullif(btrim(pr.codigo_barra),'') as cb
    from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base
       or pr.id_producto = v_sku_base
  ),
  -- cbGrupo del GAS = solo codigoBarra de presentaciones (NO incluye equivalencias). Replicado fiel:
  cb_grupo as (
    select distinct cb from grupo_prod where cb is not null
  ),
  -- ── VENTAS N días: cabeceras no anuladas en rango → mapa id_venta→fecha; detalle match por
  --    SKU===skuBase OR cbGrupo contiene Cod_Barras OR cbGrupo contiene SKU. (GAS exacto.) ──────
  cab as (
    select v.id_venta, (v.fecha at time zone 'America/Lima')::date as f
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      -- ⚠ GAS analitica filtra anulación por FormaPago !== 'ANULADO' (NO Estado_Envio). Ver NOTA A.
      and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
  ),
  det as (
    select c.f as fecha,
           coalesce(d.cantidad, 0)::numeric as qty,
           -- precio = Precio || prod.precioVenta; subtotal = Subtotal || qty*precio
           coalesce(d.subtotal, coalesce(d.cantidad,0) * coalesce(d.precio, v_precio))::numeric as imp
    from me.ventas_detalle d
    join cab c on c.id_venta = d.id_venta
    where (
            nullif(btrim(d.sku),'') = v_sku_base
         or nullif(btrim(d.cod_barras),'') in (select cb from cb_grupo)
         or nullif(btrim(d.sku),'')        in (select cb from cb_grupo)
          )
  ),
  ventas_dia as (
    select fecha, sum(qty) as u, sum(imp) as imp
    from det group by fecha
  )
  select coalesce(sum(u),0), coalesce(sum(imp),0), (count(*) >= 0)
    into v_total_u, v_total_i, v_me_ok
  from ventas_dia;
  -- meConectado: el GAS lo pone true al leer las hojas ME. La sombra siempre "existe" → true.
  v_me_ok := true;

  -- ── STOCK desde wh.stock: GAS filtra getStockWarehouse por codigoProducto===idProducto OR
  --    skuBase===skuBase. wh.stock NO tiene zona → "zonas" = filas de stock del grupo. ─────────
  v_wh_ok := true;
  select coalesce(sum(coalesce(s.cantidad_disponible,0)),0)
    into v_stock
  from wh.stock s
  where s.cod_producto = v_prod.id_producto
     or s.cod_producto in (
          select pr.id_producto from mos.productos pr
          where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base
        );

  -- ── ENSAMBLE del data (mismo árbol que el return del GAS) ──────────────────────────────────────
  with
  grupo_prod as (
    select pr.id_producto from mos.productos pr
    where coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base
       or pr.id_producto = v_sku_base
  ),
  cb_grupo as (
    select distinct nullif(btrim(pr.codigo_barra),'') as cb
    from mos.productos pr
    where (coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) = v_sku_base or pr.id_producto = v_sku_base)
      and nullif(btrim(pr.codigo_barra),'') is not null
  ),
  -- serie de ventas (re-derivada para el JSON, idéntico filtro que arriba)
  cab as (
    select v.id_venta, (v.fecha at time zone 'America/Lima')::date as f
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.forma_pago,'')) <> 'ANULADO'
  ),
  det as (
    select c.f as fecha,
           coalesce(d.cantidad,0)::numeric as qty,
           coalesce(d.subtotal, coalesce(d.cantidad,0) * coalesce(d.precio, v_precio))::numeric as imp
    from me.ventas_detalle d
    join cab c on c.id_venta = d.id_venta
    where ( nullif(btrim(d.sku),'') = v_sku_base
         or nullif(btrim(d.cod_barras),'') in (select cb from cb_grupo)
         or nullif(btrim(d.sku),'')        in (select cb from cb_grupo) )
  ),
  ventas_dia as (
    select fecha, sum(qty) as u, sum(imp) as imp from det group by fecha
  ),
  -- serie completa con ceros para los `dias` días [desde .. desde+dias-1] (GAS: for d in 0..dias).
  serie as (
    select gs::date as f,
           coalesce(vd.u, 0)   as u,
           coalesce(vd.imp, 0) as imp
    from generate_series(v_desde, v_desde + (v_dias - 1), interval '1 day') gs
    left join ventas_dia vd on vd.fecha = gs::date
    order by gs
  ),
  serie_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha', to_char(s.f,'YYYY-MM-DD'), 'u', s.u, 'imp', s.imp
           ) order by s.f), '[]'::jsonb) as arr
    from serie s
  ),
  -- zonas de stock (filas de wh.stock del grupo) — paridad: stockRes.data.filter(...).
  stock_zonas as (
    select jsonb_build_object(
             'codigoProducto', s.cod_producto,
             'cantidadDisponible', coalesce(s.cantidad_disponible,0)
           ) as z
    from wh.stock s
    where s.cod_producto = v_prod.id_producto
       or s.cod_producto in (select id_producto from grupo_prod)
  ),
  stock_zonas_json as (
    select coalesce(jsonb_agg(z), '[]'::jsonb) as arr from stock_zonas
  ),
  -- historial de precios: el GAS filtra por (idProducto OR skuBase). mos.historial_precios NO tiene
  -- id_producto (04:42) → matcheamos por sku_base = skuBase (rama principal) y, como proxy del idProducto,
  -- por codigo_barra = prod.codigo_barra. Ver NOTA P. Orden fecha asc, últimas 20.
  hist_rows as (
    select h.fecha, h.precio_anterior, h.precio_nuevo, h.usuario, h.motivo, h.sku_base, h.codigo_barra
    from mos.historial_precios h
    where coalesce(nullif(btrim(h.sku_base),''),'') = v_sku_base
       or coalesce(nullif(btrim(h.codigo_barra),''),'') = coalesce(v_prod.codigo_barra,'__none__')
    order by h.fecha asc nulls first
  ),
  hist_last20 as (
    select * from (
      select hr.*, row_number() over (order by hr.fecha asc nulls first) as rn,
             count(*) over () as tot
      from hist_rows hr
    ) z where z.rn > greatest(z.tot - 20, 0)
    order by z.fecha asc nulls first
  ),
  hist_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha', to_char(h.fecha at time zone 'America/Lima','YYYY-MM-DD'),
             'precioAnterior', h.precio_anterior,
             'precioNuevo', h.precio_nuevo,
             'usuario', h.usuario,
             'motivo', h.motivo,
             'skuBase', h.sku_base,
             'codigoBarra', h.codigo_barra
           ) order by h.fecha asc nulls first), '[]'::jsonb) as arr
    from hist_last20 h
  ),
  -- pedidos de proveedor que incluyen el producto: items jsonb → buscar item con
  -- idProducto===prod.idProducto OR skuBase===skuBase OR codigoBarra ∈ cbGrupo.
  ped as (
    select pp.id_pedido, pp.id_proveedor, pp.estado,
           (pp.fecha_creacion at time zone 'America/Lima')::date as fecha,
           it.item
    from mos.pedidos_proveedor pp
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(pp.items) = 'array' then pp.items else '[]'::jsonb end
    ) as it(item)
    where (it.item->>'idProducto') = v_prod.id_producto
       or (it.item->>'skuBase')    = v_sku_base
       or (it.item->>'codigoBarra') in (select cb from cb_grupo)
  ),
  ped_norm as (
    select id_pedido, id_proveedor, estado, fecha,
           coalesce((item->>'cantidad')::numeric, 0) as cantidad,
           coalesce(
             (item->>'costoUnitario')::numeric,
             (item->>'costo')::numeric,
             (item->>'precio')::numeric, 0) as costo
    from ped
  ),
  ped_top20 as (
    select * from ped_norm order by fecha desc nulls last limit 20
  ),
  ped_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'idPedido', pn.id_pedido,
             'idProveedor', pn.id_proveedor,
             'fecha', to_char(pn.fecha,'YYYY-MM-DD'),
             'cantidad', pn.cantidad,
             'costo', pn.costo,
             'estado', pn.estado
           ) order by pn.fecha desc nulls last), '[]'::jsonb) as arr
    from ped_top20 pn
  ),
  prov_json as (
    select coalesce(jsonb_agg(distinct jsonb_build_object(
             'idProveedor', pr.id_proveedor,
             'nombre', pr.nombre,
             'formaPago', pr.forma_pago
           )), '[]'::jsonb) as arr
    from mos.proveedores pr
    where pr.id_proveedor in (select distinct id_proveedor from ped_norm where id_proveedor is not null)
  )
  select jsonb_build_object(
    'producto', jsonb_build_object(
      'idProducto',  v_prod.id_producto,
      'descripcion', coalesce(nullif(v_prod.descripcion,''), '—'),
      'codigoBarra', coalesce(v_prod.codigo_barra,''),
      'skuBase',     v_sku_base,
      'precioVenta', v_precio,
      'precioCosto', v_costo,
      'stockMinimo', coalesce(v_prod.stock_minimo,0),
      'stockMaximo', coalesce(v_prod.stock_maximo,0),
      'unidad',      coalesce(nullif(v_prod.unidad,''), 'UND'),
      'idCategoria', coalesce(v_prod.id_categoria,'')
    ),
    'periodo', jsonb_build_object('dias', v_dias, 'desde', to_char(v_desde,'YYYY-MM-DD')),
    'ventas', jsonb_build_object(
      'serie',         (select arr from serie_json),
      'totalUnidades', v_total_u,
      'totalImporte',  v_total_i,
      'promDia',       case when v_dias > 0 then v_total_u / v_dias else 0 end
    ),
    'stock', jsonb_build_object(
      'total',  v_stock,
      'zonas',  (select arr from stock_zonas_json),
      'minimo', coalesce(v_prod.stock_minimo,0),
      'maximo', coalesce(v_prod.stock_maximo,0)
    ),
    'financiero', jsonb_build_object(
      'margenPct',     case when v_precio > 0 then (v_precio - v_costo) / v_precio * 100 else 0 end,
      'utilidadBruta', v_total_i - v_total_u * v_costo,
      'precioVenta',   v_precio,
      'precioCosto',   v_costo
    ),
    'compras', jsonb_build_object(
      'pedidos',     (select arr from ped_json),
      'proveedores', (select arr from prov_json)
    ),
    'historialPrecios', (select arr from hist_json),
    'proyeccion', jsonb_build_object(
      'promDia',        case when v_dias > 0 then v_total_u / v_dias else 0 end,
      'unidades30dias', ceil((case when v_dias > 0 then v_total_u / v_dias else 0 end) * 30)::int,
      'coberturaDias',  case when (case when v_dias>0 then v_total_u/v_dias else 0 end) > 0
                             then round(v_stock / (v_total_u / v_dias))::int else null end,
      'sugerirComprar', greatest(0, ceil((case when v_dias>0 then v_total_u/v_dias else 0 end) * 30)::int - v_stock)
    ),
    'conexiones', jsonb_build_object('me', v_me_ok, 'wh', v_wh_ok)
  )
  into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$;

-- ── mos.fin_rentabilidad_zonas(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.fin_rentabilidad_zonas(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '25s'
AS $function$
declare
  v_desde date := coalesce(nullif(btrim(coalesce(p->>'desde','')),'')::date, '2026-01-01');
  v_hasta date := coalesce(nullif(btrim(coalesce(p->>'hasta','')),'')::date, (now() at time zone 'America/Lima')::date);
  v_diario jsonb; v_met jsonb; v_anul jsonb; v_top jsonb;
begin
  -- líneas con costo (real o fallback 15%) — base de todo
  create temp table _rz_lin on commit drop as
    select coalesce(v.zona_id,'SIN_ZONA') zona,
           (v.fecha at time zone 'America/Lima')::date dia,
           v.id_venta, d.nombre, d.cod_barras,
           d.cantidad, (d.cantidad*d.precio) rev,
           case when coalesce(pr.precio_costo,0)>0 then d.cantidad*pr.precio_costo else d.cantidad*d.precio*0.85 end costo,
           (coalesce(pr.precio_costo,0)>0) con_costo
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    left join lateral (
      select p2.precio_costo from mos.productos p2
       where p2.codigo_barra = d.cod_barras or p2.id_producto = d.sku
          or p2.id_producto = (select e.sku_base from mos.equivalencias e
                                where e.codigo_barra = d.cod_barras and coalesce(e.activo,true) limit 1)
       order by (p2.codigo_barra = d.cod_barras) desc, (p2.id_producto = d.sku) desc limit 1
    ) pr on true
    where v.forma_pago <> 'ANULADO'
      and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hasta;

  select coalesce(jsonb_agg(x order by x->>'z', x->>'dia'),'[]'::jsonb) into v_diario from (
    select jsonb_build_object('z', zona, 'dia', dia, 'rev', round(sum(rev),2), 'costo', round(sum(costo),2),
      'rcr', round(sum(case when con_costo then rev else 0 end),2), 'n', count(distinct id_venta)) x
    from _rz_lin group by zona, dia) q;

  select coalesce(jsonb_agg(jsonb_build_object('z', z, 'mes', mes, 'fp', fp, 'tot', tot)),'[]'::jsonb) into v_met from (
    select coalesce(v.zona_id,'SIN_ZONA') z,
      to_char((v.fecha at time zone 'America/Lima')::date,'YYYY-MM') mes,
      case when v.forma_pago like 'MIXTO%' then 'MIXTO' else v.forma_pago end fp,
      round(sum(v.total),2) tot
    from me.ventas v
    where v.forma_pago <> 'ANULADO'
      and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hasta
    group by 1, 2, 3) q;

  select coalesce(jsonb_agg(jsonb_build_object('z', z, 'n', n, 'tot', tot)),'[]'::jsonb) into v_anul from (
    select coalesce(v.zona_id,'SIN_ZONA') z, count(*) n, round(sum(v.total),2) tot
    from me.ventas v
    where v.forma_pago = 'ANULADO'
      and (v.fecha at time zone 'America/Lima')::date between v_desde and v_hasta
    group by 1) q;

  select coalesce(jsonb_agg(jsonb_build_object('z', z, 'nombre', nombre, 'und', und, 'rev', rev,
    'uti', uti, 'mpct', mpct, 'con_costo', con_costo)),'[]'::jsonb) into v_top from (
    select zona z, nombre, round(sum(cantidad)::numeric,1) und, round(sum(rev),2) rev,
      round(sum(rev-costo),2) uti, round((sum(rev-costo)/nullif(sum(rev),0)*100)::numeric,1) mpct,
      bool_or(con_costo) con_costo
    from _rz_lin
    group by zona, nombre
    order by sum(rev-costo) desc limit 60) q;

  return jsonb_build_object('ok', true, 'desde', v_desde, 'hasta', v_hasta,
    'diario', v_diario, 'metodos', v_met, 'anuladas', v_anul, 'top', v_top,
    'generado', to_char(now() at time zone 'America/Lima','YYYY-MM-DD HH24:MI'));
end; $function$;

-- ── mos.eco_status(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.eco_status(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_now  timestamptz := now();
  v_hoy  date         := (v_now at time zone 'America/Lima')::date;
  v_me   jsonb;
  v_wh   jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- helper inline para "hace N min / Nh" (replica exacto la fórmula del GAS contra v_now)
  -- diffMin = round((now - ts)/60000ms);  <60 → 'hace N min'  ; else → 'hace round(N/60)h'
  --   (se usa abajo vía expresión repetida porque plpgsql no permite función anidada).

  -- ── ZONAS_CONFIG derivado (mapas serie→zona y estacion(nombre)→zona) ──────────────────────
  with
  serie_zona as (
    -- distinct-on(serie): primera (id_estacion menor) gana, igual semántica que "primera fila de la hoja gana"
    select distinct on (sd.serie)
           btrim(sd.serie) as serie, sd.id_zona as zona
    from mos.series_documentales sd
    where coalesce(sd.activo, false) = true
      and nullif(btrim(sd.serie), '') is not null
      and nullif(btrim(sd.id_zona), '') is not null
    order by sd.serie, sd.id_estacion
  ),
  est_zona as (
    -- estZonaMap[Estacion_Nombre] → Zona_ID ; primera (id_estacion menor) gana
    select distinct on (btrim(e.nombre))
           btrim(e.nombre) as nombre, e.id_zona as zona
    from mos.estaciones e
    where nullif(btrim(e.nombre), '') is not null
      and nullif(btrim(e.id_zona), '') is not null
    order by btrim(e.nombre), e.id_estacion
  ),

  -- ════════════════════ MosExpress ════════════════════
  -- Ventas de HOY no anuladas (GAS: estado === 'ANULADO' se salta; comparación case-sensitive exacta).
  ventas_hoy as (
    select
      v.total,
      v.fecha,
      -- zona: primero por correlativo (split('-')[0] → serie → zona), luego estZonaMap[estacion], luego 'Sin zona'
      coalesce(
        (select sz.zona from serie_zona sz
          where sz.serie = btrim(split_part(coalesce(v.correlativo,''), '-', 1))
            and nullif(btrim(coalesce(v.correlativo,'')), '') is not null),
        (select ez.zona from est_zona ez where ez.nombre = btrim(coalesce(v.estacion,''))),
        'Sin zona'
      ) as zona
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date = v_hoy
      and coalesce(v.estado_envio,'') <> 'ANULADO'
  ),
  ventas_tot as (
    select
      count(*)                         as ventas_hoy,
      coalesce(sum(total), 0)          as total_hoy,
      max(fecha)                       as ultima_venta
    from ventas_hoy
  ),
  -- agregado por zona (ordenado por total desc como el GAS)
  zonas_agg as (
    select
      zona,
      count(*)                         as ventas,
      round(coalesce(sum(total),0), 2) as total,
      max(fecha)                       as ultima_venta
    from ventas_hoy
    group by zona
  ),
  zonas_arr as (
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'zona',        za.zona,
               'ventas',      za.ventas,
               'total',       za.total,
               'ultimaVenta',
                 case when za.ultima_venta is null then 'Sin ventas'
                      when round(extract(epoch from (v_now - za.ultima_venta))/60.0) < 60
                        then 'hace ' || round(extract(epoch from (v_now - za.ultima_venta))/60.0)::int || ' min'
                      else 'hace ' || round(round(extract(epoch from (v_now - za.ultima_venta))/60.0)/60.0)::int || 'h'
                 end,
               'ultimaVentaTs', mos._iso_z(za.ultima_venta)
             )
             order by za.total desc
           ), '[]'::jsonb) as arr
    from zonas_agg za
  ),
  -- Personal del día = todas las cajas abiertas hoy (por fecha_apertura en Lima).
  -- estado: ABIERTA → 'activo', resto → 'cerrado'. desde=HH:mm apertura, hasta=HH:mm cierre (o '').
  -- zona: zona_id directa → estZonaMap[estacion] → '—'. Orden: activos primero, luego por 'desde' asc.
  personal_rows as (
    select
      coalesce(nullif(btrim(c.vendedor),''), '—')                        as nombre,
      btrim(coalesce(c.estacion,''))                                     as estacion,
      coalesce(
        nullif(btrim(coalesce(c.zona_id,'')), ''),
        (select ez.zona from est_zona ez where ez.nombre = btrim(coalesce(c.estacion,''))),
        '—'
      )                                                                  as zona,
      case when upper(coalesce(c.estado,'')) = 'ABIERTA' then 'activo' else 'cerrado' end as estado,
      to_char(c.fecha_apertura at time zone 'America/Lima', 'HH24:MI')   as desde,
      case when c.fecha_cierre is not null
           then to_char(c.fecha_cierre at time zone 'America/Lima', 'HH24:MI')
           else '' end                                                   as hasta
    from me.cajas c
    where c.fecha_apertura is not null
      and (c.fecha_apertura at time zone 'America/Lima')::date = v_hoy
  ),
  personal_arr as (
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'nombre',   pr.nombre,
               'estacion', pr.estacion,
               'zona',     pr.zona,
               'estado',   pr.estado,
               'desde',    pr.desde,
               'hasta',    pr.hasta
             )
             order by (case when pr.estado = 'activo' then 0 else 1 end), pr.desde
           ), '[]'::jsonb) as arr,
           bool_or(pr.estado = 'activo') as algun_activo
    from personal_rows pr
  ),

  -- ════════════════════ warehouseMos ════════════════════
  -- Guías de HOY: tipo contiene ENTRADA o INGRESO → entradasHoy; resto → salidasHoy.
  guias_hoy as (
    select
      (upper(coalesce(g.tipo,'')) like '%ENTRADA%' or upper(coalesce(g.tipo,'')) like '%INGRESO%') as es_entrada,
      g.fecha
    from wh.guias g
    where g.fecha is not null
      and (g.fecha at time zone 'America/Lima')::date = v_hoy
  ),
  guias_tot as (
    select
      count(*) filter (where es_entrada)        as entradas_hoy,
      count(*) filter (where not es_entrada)    as salidas_hoy,
      max(fecha)                                as ultima_guia
    from guias_hoy
  ),
  -- Sesión ACTIVA (GAS toma la primera ACTIVA recorriendo de abajo hacia arriba → la última fila ACTIVA).
  -- Resolvemos usuario/rol vía mos.personal (la sombra no trae usuario/rol/entrada). Ver GAP G1.
  sesion_act as (
    select
      coalesce(
        nullif(btrim(concat_ws(' ', pe.nombre, pe.apellido)), ''),
        s.id_personal
      )                                          as usuario,
      coalesce(pe.rol, '')                       as rol,
      coalesce(substr(btrim(s.hora_inicio), 1, 5), '--:--') as desde
    from wh.sesiones s
    left join mos.personal pe on pe.id_personal = s.id_personal
    where upper(coalesce(s.estado,'')) = 'ACTIVA'
    order by s.fecha_inicio desc nulls last, s.id_sesion desc
    limit 1
  ),
  -- stockCritico: filas de wh.stock con cantidad < stock_minimo (resuelto desde mos.productos). Paridad alertaMinimo (113).
  prod_by_id as (
    select pr.id_producto as k, pr.stock_minimo from mos.productos pr
  ),
  prod_by_sku as (
    select distinct on (pr.sku_base) pr.sku_base as k, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.sku_base),'') is not null
    order by pr.sku_base, pr.id_producto
  ),
  prod_by_cb as (
    select distinct on (pr.codigo_barra) pr.codigo_barra as k, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
    order by pr.codigo_barra, pr.id_producto
  ),
  stock_crit as (
    select count(*) as n
    from wh.stock s
    left join prod_by_id  pid on pid.k = s.cod_producto
    left join prod_by_sku psk on psk.k = s.cod_producto
    left join prod_by_cb  pcb on pcb.k = s.cod_producto
    where coalesce(s.cantidad_disponible, 0)
          < coalesce(pid.stock_minimo, psk.stock_minimo, pcb.stock_minimo, 0)
  )

  -- ── ARMADO FINAL ──────────────────────────────────────────────────────────────────────────
  select
    jsonb_build_object(
      'color',
        case when vt.ventas_hoy > 0 or pa.algun_activo then 'green' else 'yellow' end,
      'ventasHoy',   vt.ventas_hoy,
      'totalHoy',    round(vt.total_hoy, 2),
      'ultimaVenta',
        case when vt.ultima_venta is not null then
               case when round(extract(epoch from (v_now - vt.ultima_venta))/60.0) < 60
                      then 'hace ' || round(extract(epoch from (v_now - vt.ultima_venta))/60.0)::int || ' min'
                    else 'hace ' || round(round(extract(epoch from (v_now - vt.ultima_venta))/60.0)/60.0)::int || 'h'
               end
             when vt.ventas_hoy > 0 then 'hoy'
             else 'Sin ventas hoy' end,
      'ultimaVentaTs', mos._iso_z(vt.ultima_venta),
      'zonas',       za.arr,
      'personal',    pa.arr,
      'error',       null
    ) as me,
    jsonb_build_object(
      'color',
        case when gt.entradas_hoy > 0 or gt.salidas_hoy > 0 or sa.usuario is not null
             then 'green' else 'yellow' end,
      'entradasHoy', gt.entradas_hoy,
      'salidasHoy',  gt.salidas_hoy,
      'ultimaGuia',
        case when gt.ultima_guia is not null then
               case when round(extract(epoch from (v_now - gt.ultima_guia))/60.0) < 60
                      then 'hace ' || round(extract(epoch from (v_now - gt.ultima_guia))/60.0)::int || ' min'
                    else 'hace ' || round(round(extract(epoch from (v_now - gt.ultima_guia))/60.0)/60.0)::int || 'h'
               end
             when (gt.entradas_hoy + gt.salidas_hoy) > 0 then 'hoy'
             else 'Sin guías hoy' end,
      'ultimaGuiaTs', mos._iso_z(gt.ultima_guia),
      'sesionActiva',
        case when sa.usuario is null then null
             else jsonb_build_object('usuario', sa.usuario, 'rol', sa.rol, 'desde', sa.desde) end,
      'stockCritico', sc.n,
      'error',        null
    ) as wh
  into v_me, v_wh
  from ventas_tot vt
  cross join zonas_arr za
  cross join personal_arr pa
  cross join guias_tot gt
  cross join stock_crit sc
  left join lateral (select * from sesion_act) sa on true;

  return jsonb_build_object(
           'ok', true,
           'data', jsonb_build_object(
             'ok', true,
             'me', v_me,
             'wh', v_wh
           )
         ) || mos._frescura_sombra();
end;
$function$;

-- ── me.radio_ventas() (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me.radio_ventas()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'me', 'public'
AS $function$
declare
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_prod  jsonb;
  v_skus  jsonb;
  v_rango text;
  v_fb    boolean;
begin
  -- SKUs de la tienda: vendidos en 30d; fallback "alguna vez" si 30d vacío.
  select coalesce(jsonb_agg(sku), '[]'::jsonb) into v_skus
  from (
    select distinct d.sku
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    where v.fecha is not null
      and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
      and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
      and (v.fecha at time zone 'America/Lima')::date >= v_hoy - 29
  ) x;
  if v_skus = '[]'::jsonb then
    select coalesce(jsonb_agg(sku), '[]'::jsonb) into v_skus
    from (
      select distinct d.sku
      from me.ventas v
      join me.ventas_detalle d on d.id_venta = v.id_venta
      where v.fecha is not null
        and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
        and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
    ) x;
    v_rango := 'alguna_vez';
  else
    v_rango := '30d';
  end if;

  -- ¿Hay ventas HOY? Si no, el top cae a 7d (es_fallback_7d=true).
  select not exists (
    select 1
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    where v.fecha is not null
      and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
      and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
      and (v.fecha at time zone 'America/Lima')::date = v_hoy
  ) into v_fb;

  -- Top 20 productos por cantidad vendida (hoy, o últimos 7 días si hoy vacío).
  select coalesce(jsonb_agg(to_jsonb(t) order by t.vendidos desc), '[]'::jsonb) into v_prod
  from (
    select d.sku,
           max(d.nombre)        as nombre,
           sum(d.cantidad)::float8 as vendidos
    from me.ventas v
    join me.ventas_detalle d on d.id_venta = v.id_venta
    where v.fecha is not null
      and coalesce(v.estado_envio,'COMPLETADO') not in ('ANULADO','HUERFANA_LIMPIADA')
      and d.sku is not null and btrim(d.sku) <> '' and coalesce(d.cantidad,0) > 0
      and (v.fecha at time zone 'America/Lima')::date >= case when v_fb then v_hoy - 6 else v_hoy end
      and (v.fecha at time zone 'America/Lima')::date <= v_hoy
    group by d.sku
    order by vendidos desc
    limit 20
  ) t;

  return jsonb_build_object(
    'status',            'ok',
    'fecha',             to_char(v_hoy,'YYYY-MM-DD'),
    'es_fallback_7d',    v_fb,
    'productos',         v_prod,
    'skus_de_la_tienda', v_skus,
    'rango_filtro',      v_rango
  );
end;
$function$;

-- ── mos.productos_proveedor_stock(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.productos_proveedor_stock(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_dias  int;
  v_desde date;
  v_data  jsonb;
begin
  -- Gate de app (service_role/GAS o claim app='MOS'); cualquier otro → rechazo.
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- Paridad GAS: idProveedor requerido.
  if v_prov is null then
    return jsonb_build_object('ok', false, 'error', 'idProveedor requerido');
  end if;

  -- rangoDias: parseInt || 30 (paridad). Clamp defensivo (1..3650) para no romper divisiones/intervalos.
  v_dias := coalesce(nullif(btrim(coalesce(p->>'rangoDias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;

  -- Ventana de ventas: hoy(Lima) - rangoDias. GAS usa milisegundos exactos; aquí usamos límite por DÍA Lima,
  -- equivalente operativo (la sombra ME guarda fecha como timestamptz). Ver NOTA "ventana de ventas".
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  -- ── 1) Productos del proveedor (activos). Paridad: activa truthy. ──────────────────────────────────────
  pp as (
    select t.id_pp, t.id_proveedor, t.sku_base, t.codigo_barra, t.descripcion,
           coalesce(t.precio_referencia, 0) as precio_referencia,
           coalesce(t.minimo_compra, 0)     as minimo_compra,
           coalesce(t.dias_entrega, 0)      as dias_entrega,
           t.notas,
           greatest(coalesce(t.unidades_por_bulto, 1), 1)::int as unidades_por_bulto
    from mos.proveedores_productos t
    where t.id_proveedor = v_prov
      and coalesce(t.activa, false) = true
  ),

  -- ── 2) Master por sku_base: base (factor=1 o id=sku), conteo de presentaciones, todos los ids/barras. ──
  --    base = primer producto cuyo id_producto = sku_base, si no el de factor_conversion=1, si no el 1ro.
  prod_grp as (
    select
      coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
      count(*) as count_presentaciones,
      -- base elegido con prioridad determinista (igual criterio que GAS, orden estable por id_producto)
      (array_agg(pr.id_producto order by
          (pr.id_producto = coalesce(nullif(pr.sku_base,''), pr.id_producto)) desc,
          (coalesce(pr.factor_conversion,1) = 1) desc,
          pr.id_producto))[1] as base_id
    from mos.productos pr
    group by coalesce(nullif(pr.sku_base,''), pr.id_producto)
  ),
  base_prod as (
    select g.sku, g.count_presentaciones, b.id_producto, b.descripcion, b.codigo_barra,
           coalesce(b.stock_minimo, 0) as stock_minimo,
           coalesce(b.stock_maximo, 0) as stock_maximo
    from prod_grp g
    join mos.productos b on b.id_producto = g.base_id
  ),
  -- mapa codigo_barra → sku (incluye barras del master + equivalencias activas). Para resolver ventas/zonas.
  cb_to_sku as (
    select distinct coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           nullif(btrim(pr.codigo_barra),'') as cb,
           greatest(coalesce(nullif(pr.factor_conversion,0), 1), 0)::numeric as factor  -- [626b]
    from mos.productos pr
    where nullif(btrim(pr.codigo_barra),'') is not null
    union
    -- la equivalencia es el MISMO producto con otro código: factor 1 por definición
    select distinct e.sku_base as sku, nullif(btrim(e.codigo_barra),'') as cb, 1::numeric
    from mos.equivalencias e
    where coalesce(e.activo, true) = true
      and nullif(btrim(e.sku_base),'') is not null
      and nullif(btrim(e.codigo_barra),'') is not null
  ),
  -- mapa id_producto → sku (para resolver ventas por SKU directo) y codigo_barra → sku via master/prodById.
  id_to_sku as (
    select pr.id_producto as id, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
           -- [626] factor a unidades del canónico (una bolsa de 500g de un producto
           -- que se compra por kilo vale 0.5, no 1)
           greatest(coalesce(nullif(pr.factor_conversion,0), 1), 0)::numeric as factor
    from mos.productos pr
  ),
  -- conteo de equivalencias por sku (countEquivalencias = equiv.porSku[sku].length)
  equiv_cnt as (
    select e.sku_base as sku, count(*) as n
    from mos.equivalencias e
    where coalesce(e.activo, true) = true
      and nullif(btrim(e.sku_base),'') is not null
    group by e.sku_base
  ),

  -- ── 3) Zonas registradas (tabla ZONAS activa): id_zona UPPER → nombre. ────────────────────────────────
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null
      and coalesce(z.estado, true) = true
  ),

  -- ── 3b) Zona resolver: mapea cualquier identificador (id_zona / estacion / id_estacion) → zona canónica. ─
  --    Canon id = UPPER(trim(idZona)). Para estaciones, el padre es su id_zona. Lookup por variantes
  --    (raw upper trim). GAS además normaliza espacios/guiones; aquí cubrimos el caso real (IDs sin espacios)
  --    con UPPER(TRIM(.)). Ver NOTA "resolver de zonas".
  zona_resolver as (
    -- desde ZONAS: el propio id_zona y el nombre apuntan a sí mismo
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id,
           coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union
    select upper(btrim(z.nombre)) as raw, upper(btrim(z.id_zona)) as canon_id,
           coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union
    -- desde ESTACIONES: id_estacion/nombre → id_zona padre (nombre de la zona si existe, si no el id_zona crudo)
    select upper(btrim(es.id_estacion)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union
    select upper(btrim(es.nombre)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union
    select upper(btrim(es.id_zona)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  -- de-dup del resolver: una fila por raw (preferir entrada de ZONAS sobre ESTACIONES no es crítico — el
  -- canon_id es igual; el nombre de ZONAS ya gana en la subquery de estaciones). distinct on raw.
  zona_resolver_u as (
    select distinct on (raw) raw, canon_id, canon_nombre
    from zona_resolver
    order by raw, canon_nombre nulls last
  ),

  -- ── 5) Stock WH agregado por sku (resolver cod_producto via id o codigo_barra → sku). ─────────────────
  wh_by_sku as (
    select coalesce(i.sku, c.sku) as sku, sum(coalesce(s.cantidad_disponible, 0)) as q
    from wh.stock s
    left join id_to_sku i on i.id = s.cod_producto
    left join cb_to_sku c on c.cb = s.cod_producto
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),

  -- ── 6) Stock por zona (canon-resolved) por sku. Resolver cb → sku, zona → canónica. ───────────────────
  stock_zonas_raw as (
    select c.sku as sku,
           r.canon_id     as zid,
           r.canon_nombre as znombre,
           sum(coalesce(z.cantidad, 0)) as cantidad
    from me.stock_zonas z
    join cb_to_sku c on c.cb = nullif(btrim(z.cod_barras),'')
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(z.zona_id)))        as canon_id,
             coalesce(zr.canon_nombre, btrim(z.zona_id))           as canon_nombre
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(z.zona_id))
    ) r
    where nullif(btrim(z.zona_id),'') is not null
    group by c.sku, r.canon_id, r.canon_nombre
  ),

  -- ── 7) Ventas en rango: cabeceras válidas (no anuladas, fecha >= desde Lima) → detalle por sku/zona. ──
  ventas_validas as (
    select v.id_venta, nullif(btrim(v.estacion),'') as estacion
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  ventas_lineas as (
    select coalesce(i.sku, c.sku) as sku,
           vv.estacion,
           -- [626] antes era `coalesce(d.cantidad,0)`: sumaba unidades de
           -- presentaciones distintas como si fueran la misma cosa.
           (coalesce(d.cantidad, 0) * coalesce(i.factor, c.factor, 1))::numeric as cant
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join id_to_sku i on i.id = nullif(btrim(d.sku),'')
    left join cb_to_sku c on c.cb = nullif(btrim(d.cod_barras),'')
    where coalesce(i.sku, c.sku) is not null
  ),
  -- ventas totales por sku
  ventas_by_sku as (
    select sku, sum(cant) as ventas
    from ventas_lineas
    group by sku
  ),
  -- ventas por sku + zona canónica (solo líneas con estacion → resoluble)
  ventas_by_sku_zona as (
    select vl.sku,
           r.canon_id     as zid,
           r.canon_nombre as znombre,
           sum(vl.cant)   as ventas
    from ventas_lineas vl
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(vl.estacion)))  as canon_id,
             coalesce(zr.canon_nombre, btrim(vl.estacion))     as canon_nombre
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(vl.estacion))
    ) r
    where vl.estacion is not null
    group by vl.sku, r.canon_id, r.canon_nombre
  ),

  -- ── 8) Por cada (sku, zid) unir stock + ventas; clasificar registrada vs huérfana. ───────────────────
  zona_keys as (
    select sku, zid, znombre from stock_zonas_raw
    union all
    select sku, zid, znombre from ventas_by_sku_zona
  ),
  -- nombre legible por (sku,zid): el más frecuente/cualquiera no nulo (las fuentes coinciden en la práctica)
  zona_nombre as (
    select sku, zid, max(znombre) as znombre
    from zona_keys
    group by sku, zid
  ),
  zona_merged as (
    select
      k.sku,
      k.zid,
      -- nombre: si registrada usa nombre de tabla ZONAS; si no, el que vino de stock/ventas
      coalesce(zr.nombre, zn.znombre, k.zid) as nombre,
      (zr.zid is not null) as registrada,
      coalesce(sz.cantidad, 0)  as cantidad,
      coalesce(vz.ventas, 0)    as ventas_rango
    from (select distinct sku, zid from zona_keys) k
    left join stock_zonas_raw    sz on sz.sku = k.sku and sz.zid = k.zid
    left join ventas_by_sku_zona vz on vz.sku = k.sku and vz.zid = k.zid
    left join zona_nombre        zn on zn.sku = k.sku and zn.zid = k.zid
    left join zonas_reg          zr on zr.zid = k.zid
  ),
  -- chips de zona REGISTRADA por sku (array)
  zonas_chips as (
    select sku,
           jsonb_agg(
             jsonb_build_object(
               'idZona',      zid,
               'nombre',      nombre,
               'cantidad',    cantidad,
               'ventasRango', ventas_rango,
               'rotacionDia', round((ventas_rango / v_dias)::numeric, 1)
             )
             order by cantidad desc
           ) as zonas,
           sum(cantidad)     as zonas_reg_stock,
           sum(ventas_rango) as zonas_reg_ventas
    from zona_merged
    where registrada
    group by sku
  ),
  -- agregados HUÉRFANOS por sku (zonas no registradas)
  huerfanas_agg as (
    select sku,
           sum(cantidad)     as h_cantidad,
           sum(ventas_rango) as h_ventas
    from zona_merged
    where not registrada
    group by sku
  ),

  -- ── 9) Enriquecer cada pp ────────────────────────────────────────────────────────────────────────────
  enriquecido as (
    select
      pp.id_pp, pp.id_proveedor, pp.sku_base as sku,
      bp.id_producto, bp.descripcion as base_desc, bp.codigo_barra as base_cb,
      bp.stock_minimo, bp.stock_maximo, coalesce(bp.count_presentaciones, 1) as count_pres,
      coalesce(ec.n, 0) as count_equiv,
      pp.codigo_barra as pp_cb, pp.descripcion as pp_desc, pp.precio_referencia, pp.minimo_compra,
      pp.dias_entrega, pp.notas, pp.unidades_por_bulto,
      coalesce(wb.q, 0)                            as wh_q,
      coalesce(zc.zonas, '[]'::jsonb)              as zonas,
      coalesce(zc.zonas_reg_stock, 0)              as zonas_reg_stock,
      coalesce(ha.h_cantidad, 0)                   as huer_cant,
      coalesce(ha.h_ventas, 0)                     as huer_ventas,
      coalesce(vbs.ventas, 0)                      as ventas
    from pp
    left join base_prod bp on bp.sku = pp.sku_base
    left join equiv_cnt ec on ec.sku = pp.sku_base
    left join wh_by_sku wb on wb.sku = pp.sku_base
    left join zonas_chips zc on zc.sku = pp.sku_base
    left join huerfanas_agg ha on ha.sku = pp.sku_base
    left join ventas_by_sku vbs on vbs.sku = pp.sku_base
  ),
  calculado as (
    select
      e.*,
      (e.zonas_reg_stock + e.huer_cant)            as zonas_total,
      (e.wh_q + e.zonas_reg_stock + e.huer_cant)   as total,
      case when v_dias > 0 then e.ventas::numeric / v_dias else 0 end as rot_dia
    from enriquecido e
  ),
  final_rows as (
    select
      c.*,
      -- minimo/maximo del MASTER base (paridad: p.stockMinimo / p.stockMaximo)
      c.stock_minimo as minimo,
      c.stock_maximo as maximo,
      -- sugerencia + razón (replica exacta del árbol if/else del GAS)
      sug.sugerencia, sug.razon, sug.sug_bultos,
      -- alerta (refs a stock_minimo/stock_maximo de `calculado`; los alias minimo/maximo de este SELECT no son
      --         visibles en su propia lista — usar las columnas base)
      case
        when c.total < 0 then 'NEGATIVO'
        when c.stock_minimo > 0 and c.total < c.stock_minimo then 'BAJO_MINIMO'
        when c.rot_dia > 0 and c.total > 0 and (c.total / c.rot_dia) < 7 then 'AGOTAR_PRONTO'
        when c.stock_minimo > 0 and c.total < c.stock_minimo * 1.2 then 'CERCA_MINIMO'
        when c.total > 0 and c.ventas = 0 then 'SIN_ROTACION'
        else 'OK'
      end as alerta
    from calculado c
    cross join lateral (
      -- Paso A: sugerencia base + razón (sin bultos). objetivo = max>min ? max : min*2.
      with base as (
        select
          (case when c.stock_maximo > c.stock_minimo then c.stock_maximo else c.stock_minimo * 2 end) as objetivo
      ),
      sug_base as (
        select
          base.objetivo,
          case
            when c.stock_minimo > 0 and c.total < c.stock_minimo
              then greatest(0, ceil(base.objetivo - c.total))
            when c.rot_dia > 0
              then greatest(0, ceil(c.rot_dia * 14) - floor(c.total))
            else 0
          end as sug0,
          case
            when c.stock_minimo > 0 and c.total < c.stock_minimo
              then 'Reponer hasta ' || (case when c.stock_maximo > c.stock_minimo
                     then 'máx (' || trim(to_char(base.objetivo, 'FM999999990.######')) || ')'
                     else '2× mín (' || trim(to_char(base.objetivo, 'FM999999990.######')) || ')' end)
            when c.rot_dia > 0
              then (case when greatest(0, ceil(c.rot_dia * 14) - floor(c.total)) > 0
                     then 'Cobertura 14d (rot ' || to_char(c.rot_dia, 'FM990.0') || '/d)'
                     else 'Stock cubre 14d' end)
            when c.total <= 0 and c.stock_minimo = 0
              then 'Sin rotación · sin mín — define mínimo'
            else ''
          end as razon0
        from base
      ),
      -- Paso B: redondeo a múltiplo de bulto + sufijo de razón
      bultos as (
        select
          case
            when sug_base.sug0 > 0 and c.unidades_por_bulto > 1
              then ceil(sug_base.sug0 / c.unidades_por_bulto) * c.unidades_por_bulto
            else sug_base.sug0
          end as sugerencia,
          case
            when sug_base.sug0 > 0 and c.unidades_por_bulto > 1
              then ceil(sug_base.sug0 / c.unidades_por_bulto)
            when sug_base.sug0 > 0 and c.unidades_por_bulto = 1
              then sug_base.sug0
            else 0
          end as sug_bultos,
          case
            when sug_base.sug0 > 0 and c.unidades_por_bulto > 1
              then sug_base.razon0 || ' · ' || ceil(sug_base.sug0 / c.unidades_por_bulto)
                   || ' bulto' || (case when ceil(sug_base.sug0 / c.unidades_por_bulto) = 1 then '' else 's' end)
            else sug_base.razon0
          end as razon
        from sug_base
      )
      select bultos.sugerencia, bultos.razon, bultos.sug_bultos from bultos
    ) sug
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idPP',             fr.id_pp,
             'idProveedor',      fr.id_proveedor,
             'skuBase',          fr.sku,
             'idProducto',       coalesce(fr.id_producto, fr.sku),
             'descripcion',      coalesce(nullif(fr.pp_desc,''), fr.base_desc, fr.sku),
             'codigoBarra',      coalesce(nullif(fr.pp_cb,''), fr.base_cb, ''),
             'precioReferencia', fr.precio_referencia,
             'minimoCompra',     fr.minimo_compra,
             'diasEntrega',      fr.dias_entrega,
             'notas',            coalesce(fr.notas, ''),
             'unidadesPorBulto', fr.unidades_por_bulto,
             'stockWh',          fr.wh_q,
             'stockTienda',      fr.zonas_total,
             'stockTotal',       fr.total,
             'zonas',            fr.zonas,
             'zonasHuerfanas',   case when (fr.huer_cant > 0 or fr.huer_ventas > 0)
                                   then jsonb_build_object(
                                          'cantidad',    fr.huer_cant,
                                          'ventasRango', fr.huer_ventas,
                                          'rotacionDia', round((fr.huer_ventas / v_dias)::numeric, 1))
                                   else null end,
             'stockMinimo',      fr.minimo,
             'stockMaximo',      fr.maximo,
             'ventasRango',      fr.ventas,
             'rotacionDia',      round(fr.rot_dia::numeric, 1),
             'rangoDias',        v_dias,
             'sugerencia',       fr.sugerencia,
             'sugerenciaBultos', fr.sug_bultos,
             'razonSugerencia',  fr.razon,
             'alerta',           fr.alerta,
             'countPresentaciones', fr.count_pres,
             'countEquivalencias',  fr.count_equiv
           )
           order by
             case fr.alerta
               when 'NEGATIVO'      then 0
               when 'BAJO_MINIMO'   then 1
               when 'AGOTAR_PRONTO' then 2
               when 'CERCA_MINIMO'  then 3
               when 'SIN_ROTACION'  then 4
               when 'OK'            then 5
               else 9
             end,
             lower(coalesce(nullif(fr.pp_desc,''), fr.base_desc, fr.sku))
         ), '[]'::jsonb)
    into v_data
  from final_rows fr;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$;

-- ── mos.productos_proveedor_stock_v2(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.productos_proveedor_stock_v2(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_prov  text := nullif(btrim(coalesce(p->>'idProveedor','')), '');
  v_base  jsonb;
  v_items jsonb;
  v_out   jsonb := '[]'::jsonb;
  it      jsonb;
  v_sku   text;
  v_upb   numeric;
  v_barras text[];
  v_der   jsonb;
  v_der_stock_eq numeric;
  v_der_ven_dia  numeric;
  v_stock_pos numeric;
  v_tiene_neg boolean;
  v_rot_fam numeric;
  v_cob   numeric;
  v_sug_u numeric;
  v_sug_b numeric;
  v_costos jsonb;
  v_comp  jsonb;
  z       jsonb;
begin
  v_base := mos.productos_proveedor_stock(p);
  if coalesce((v_base->>'ok')::boolean, false) = false then return v_base; end if;
  v_items := coalesce(v_base->'data', '[]'::jsonb);

  for it in select * from jsonb_array_elements(v_items) loop
    v_sku := coalesce(it->>'skuBase','');
    v_upb := greatest(coalesce(nullif(it->>'unidadesPorBulto','')::numeric, 1), 1);

    -- barras de la familia canónica (master + equivalencias activas)
    select coalesce(array_agg(distinct cb), '{}') into v_barras from (
      select nullif(btrim(pr.codigo_barra),'') as cb from mos.productos pr
        where coalesce(nullif(pr.sku_base,''), pr.id_producto) = v_sku
      union
      select nullif(btrim(e.codigo_barra),'') from mos.equivalencias e
        where e.sku_base = v_sku and coalesce(e.activo, true) = true
    ) b where cb is not null;

    -- ── DERIVADOS del padre: stock (+eq) y ventas 30d (+eq/día) ──────────────
    select coalesce(jsonb_agg(jsonb_build_object(
             'sku', d.sku, 'nombre', d.descripcion,
             'stock', d.stock, 'factorEq', d.factor,
             'stockPadreEq', round((greatest(d.stock,0) * d.factor)::numeric, 2),
             'ventas30', d.ventas30,
             'ventasPadreEqDia', round((d.ventas30 / 30.0 * d.factor)::numeric, 3)
           ) order by d.stock desc), '[]'::jsonb),
           coalesce(sum(greatest(d.stock,0) * d.factor), 0),
           coalesce(sum(d.ventas30 / 30.0 * d.factor), 0)
      into v_der, v_der_stock_eq, v_der_ven_dia
    from (
      select coalesce(nullif(dp.sku_base,''), dp.id_producto) as sku,
             dp.descripcion,
             greatest(coalesce(dp.factor_conversion_base, 0), 0) as factor,
             coalesce((select sum(s.cantidad_disponible) from wh.stock s
                        where s.cod_producto = dp.id_producto or s.cod_producto = nullif(btrim(dp.codigo_barra),'')), 0)
             + coalesce((select sum(z1.cantidad) from me.stock_zonas z1
                        where z1.cod_barras = nullif(btrim(dp.codigo_barra),'')), 0) as stock,
             coalesce((select sum(vd.cantidad) from me.ventas_detalle vd
                        join me.ventas ve on ve.id_venta = vd.id_venta
                        where (nullif(btrim(vd.sku),'') = dp.id_producto or nullif(btrim(vd.cod_barras),'') = nullif(btrim(dp.codigo_barra),''))
                          and ve.fecha > now() - interval '30 days'
                          and upper(coalesce(ve.estado_envio,'')) <> 'ANULADO'), 0) as ventas30
      from mos.productos dp
      where dp.tipo_producto = 'DERIVADO'
        and nullif(btrim(dp.codigo_producto_base),'') = v_sku
    ) d;

    -- ── Σ FAMILIA sin negativos + flag ───────────────────────────────────────
    v_stock_pos := greatest(coalesce(nullif(it->>'stockWh','')::numeric,0), 0);
    v_tiene_neg := coalesce(nullif(it->>'stockWh','')::numeric,0) < 0;
    for z in select * from jsonb_array_elements(coalesce(it->'zonas','[]'::jsonb)) loop
      v_stock_pos := v_stock_pos + greatest(coalesce(nullif(z->>'cantidad','')::numeric,0), 0);
      if coalesce(nullif(z->>'cantidad','')::numeric,0) < 0 then v_tiene_neg := true; end if;
    end loop;
    if it->'zonasHuerfanas' is not null and jsonb_typeof(it->'zonasHuerfanas') = 'object' then
      v_stock_pos := v_stock_pos + greatest(coalesce(nullif(it->'zonasHuerfanas'->>'cantidad','')::numeric,0), 0);
      if coalesce(nullif(it->'zonasHuerfanas'->>'cantidad','')::numeric,0) < 0 then v_tiene_neg := true; end if;
    end if;
    v_stock_pos := v_stock_pos + v_der_stock_eq;

    -- ── rotación familia (sku total ya = Σ zonas; + derivados convertidos) ───
    v_rot_fam := coalesce(nullif(it->>'rotacionDia','')::numeric,0) + v_der_ven_dia;
    v_cob := case when v_rot_fam > 0 then round((v_stock_pos / (v_rot_fam * 7))::numeric, 2) else null end;
    v_sug_u := greatest(0, ceil(v_rot_fam * 7 * 1.2 - v_stock_pos));
    v_sug_b := case when v_sug_u > 0 then greatest(1, ceil(v_sug_u / v_upb)) else 0 end;

    -- ── últimos 3 costos reales de ESTE proveedor (guia_detalle) ────────────
    select coalesce(jsonb_agg(jsonb_build_object(
             'fecha', to_char(c.fecha at time zone 'America/Lima', 'DD Mon'),
             'costo', round(c.precio::numeric, 2)) order by c.fecha desc), '[]'::jsonb)
      into v_costos
    from (
      select g.fecha, gd.precio_unitario as precio
      from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
      where g.id_proveedor = v_prov and g.tipo = 'INGRESO_PROVEEDOR'
        and gd.cod_producto = any(v_barras) and coalesce(gd.precio_unitario,0) > 0
      order by g.fecha desc limit 3
    ) c;

    -- ── competencia: otros proveedores del mismo sku + su último costo ──────
    select coalesce(jsonb_agg(jsonb_build_object(
             'idProveedor', q.idp, 'proveedor', q.nombre,
             'costo', q.costo, 'fecha', q.f) order by q.costo nulls last), '[]'::jsonb)
      into v_comp
    from (
      select pp2.id_proveedor as idp, pv.nombre,
             (select round(gd.precio_unitario::numeric,2)
                from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
               where g.id_proveedor = pp2.id_proveedor and g.tipo='INGRESO_PROVEEDOR'
                 and gd.cod_producto = any(v_barras) and coalesce(gd.precio_unitario,0) > 0
               order by g.fecha desc limit 1) as costo,
             (select to_char(max(g.fecha) at time zone 'America/Lima','DD Mon')
                from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
               where g.id_proveedor = pp2.id_proveedor and g.tipo='INGRESO_PROVEEDOR'
                 and gd.cod_producto = any(v_barras) and coalesce(gd.precio_unitario,0) > 0) as f
      from mos.proveedores_productos pp2
      join mos.proveedores pv on pv.id_proveedor = pp2.id_proveedor
      where pp2.sku_base = v_sku and coalesce(pp2.activa,false) = true
        and pp2.id_proveedor <> v_prov
      limit 2
    ) q;

    v_out := v_out || (it || jsonb_build_object(
      'familia', jsonb_build_object(
        'stockPos',       round(v_stock_pos::numeric, 2),
        'tieneNegativos', v_tiene_neg,
        'derivados',      v_der,
        'rotFamiliaDia',  round(v_rot_fam::numeric, 3),
        'coberturaSem',   v_cob
      ),
      'sugerenciaV2', jsonb_build_object(
        'bultos', v_sug_b, 'unidades', v_sug_u,
        'razon', case
          when v_rot_fam <= 0 then 'sin rotación registrada'
          when v_sug_b = 0 then 'la familia cubre ' || coalesce(v_cob::text,'∞') || ' semanas'
          else 'cubrir 1 semana (+20%) · familia tiene ' || round(v_stock_pos::numeric,1) || ' y rota ' || round((v_rot_fam*7)::numeric,1) || '/sem'
        end
      ),
      'ultimosCostos', v_costos,
      'competencia',   v_comp
    ));
  end loop;

  return (v_base - 'data') || jsonb_build_object('data', v_out, '_v2', true);
end;
$function$;

-- ── mos.rotacion_productos(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.rotacion_productos(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
declare
  v_mes        text := nullif(btrim(coalesce(p->>'mes','')), '');
  v_solo_aler  boolean := (coalesce(p->>'soloAlertas','') = 'true');
  v_mes_pref   text;
  v_data       jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  v_mes_pref := coalesce(v_mes, to_char((now() at time zone 'America/Lima'), 'YYYY-MM'));

  with
  prod_by_id as (
    select pr.id_producto as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr
  ),
  prod_by_sku as (
    select distinct on (pr.sku_base) pr.sku_base as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.sku_base),'') is not null
    order by pr.sku_base, pr.id_producto
  ),
  prod_by_cb as (
    select distinct on (pr.codigo_barra) pr.codigo_barra as k, pr.id_producto, pr.sku_base, pr.codigo_barra, pr.descripcion, pr.stock_minimo
    from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
    order by pr.codigo_barra, pr.id_producto
  ),
  -- ⭐ FIX FACTOR: lookups de factor por código (cb) y por sku/id, para normalizar cada línea a unidades base.
  --    factor null/0 → 1. Equivalentes → factor 1 (no aumentan presentación).
  fac_by_cb as (
    select distinct on (cb) cb, factor from (
      select upper(btrim(pr.codigo_barra)) as cb,
             case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor, 0 as ord
      from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)) as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e
      where coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  fac_by_id as (
    select upper(btrim(pr.id_producto)) as idk,
           case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor
    from mos.productos pr where nullif(btrim(pr.id_producto),'') is not null
  ),
  -- Ventas del MES por la clave SKU cruda del detalle (idéntico criterio de filtro que 113), pero la cantidad
  -- ya viene multiplicada por el factor del producto que matchea la línea (cb gana sobre id/sku).
  ventas_mes as (
    select nullif(btrim(d.sku),'') as sku,
           sum(coalesce(d.cantidad,0) * coalesce(fc.factor, fi.factor, 1)) as q
    from me.ventas_detalle d
    join me.ventas v on v.id_venta = d.id_venta
    left join fac_by_cb fc on fc.cb  = upper(btrim(nullif(btrim(d.cod_barras),'')))
    left join fac_by_id fi on fi.idk = upper(btrim(nullif(btrim(d.sku),'')))
    where v.fecha is not null
      and to_char((v.fecha at time zone 'America/Lima'), 'YYYY-MM') = v_mes_pref
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(d.sku),'') is not null
    group by nullif(btrim(d.sku),'')
  ),
  stock_rows as (
    select
      s.id_stock,
      s.cod_producto                                            as codigo_producto,
      coalesce(s.cantidad_disponible, 0)                        as cant,
      coalesce(pid.id_producto, psk.id_producto, pcb.id_producto) is not null as en_catalogo,
      coalesce(
        nullif(coalesce(pid.descripcion, psk.descripcion, pcb.descripcion), ''),
        case when coalesce(pid.id_producto, psk.id_producto, pcb.id_producto) is null
             then '⚠ Sin nombre · ' || s.cod_producto
             else s.cod_producto end
      )                                                         as descripcion,
      coalesce(nullif(coalesce(pid.sku_base, psk.sku_base, pcb.sku_base), ''), '') as sku_base,
      coalesce(pid.stock_minimo, psk.stock_minimo, pcb.stock_minimo, 0)            as stock_minimo
    from wh.stock s
    left join prod_by_id  pid on pid.k = s.cod_producto
    left join prod_by_sku psk on psk.k = s.cod_producto
    left join prod_by_cb  pcb on pcb.k = s.cod_producto
  ),
  con_ventas as (
    select
      sr.*,
      coalesce(
        (select vm.q from ventas_mes vm where vm.sku = sr.sku_base and nullif(sr.sku_base,'') is not null),
        (select vm.q from ventas_mes vm where vm.sku = sr.codigo_producto),
        0
      )                                                         as vendidas_mes,
      (sr.cant < sr.stock_minimo)                               as alerta_minimo
    from stock_rows sr
  ),
  calc as (
    select
      cv.*,
      case when cv.vendidas_mes > 0
           then round((cv.cant / cv.vendidas_mes) * 30)::int
           else null end                                        as dias_cobertura
    from con_ventas cv
    where (not v_solo_aler) or cv.alerta_minimo
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'codigoProducto', c.codigo_producto,
             'descripcion',    c.descripcion,
             'skuBase',        c.sku_base,
             'stockActual',    c.cant,
             'vendidasMes',    c.vendidas_mes,
             'diasCobertura',  c.dias_cobertura,
             'alertaMinimo',   c.alerta_minimo
           )
           order by coalesce(c.dias_cobertura, 9999), c.codigo_producto
         ), '[]'::jsonb)
    into v_data
  from calc c;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$;

-- ── mos.catalogo_stock_resumen(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.catalogo_stock_resumen(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
AS $function$
declare
  v_dias  int;
  v_desde date;
  v_prods jsonb;
  v_total int;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 7);
  if v_dias is null or v_dias <= 0 then v_dias := 7; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  prods as (
    select pr.* from mos.productos pr
    where coalesce(pr.estado, true) = true
  ),
  grp as (
    select
      coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku,
      count(*) as count_pres,
      (array_agg(pr.id_producto order by
          (pr.id_producto = coalesce(nullif(pr.sku_base,''), pr.id_producto)) desc,
          (coalesce(pr.factor_conversion,1) = 1) desc,
          pr.id_producto))[1] as base_id
    from prods pr
    group by coalesce(nullif(pr.sku_base,''), pr.id_producto)
  ),
  base_prod as (
    select g.sku, g.count_pres,
           b.id_producto, b.descripcion, b.codigo_barra, b.marca, b.id_categoria,
           coalesce(b.precio_venta,0) as precio_venta, coalesce(b.precio_costo,0) as precio_costo,
           coalesce(b.stock_minimo,0) as minimo, coalesce(b.stock_maximo,0) as maximo
    from grp g
    join mos.productos b on b.id_producto = g.base_id
  ),
  id_to_sku as (
    select pr.id_producto as id, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku
    from prods pr
  ),
  cb_to_sku as (
    select distinct nullif(btrim(pr.codigo_barra),'') as cb, coalesce(nullif(pr.sku_base,''), pr.id_producto) as sku
    from prods pr where nullif(btrim(pr.codigo_barra),'') is not null
    union
    select distinct nullif(btrim(e.codigo_barra),'') as cb, e.sku_base as sku
    from mos.equivalencias e
    where coalesce(e.activo, true) = true
      and nullif(btrim(e.sku_base),'') is not null
      and nullif(btrim(e.codigo_barra),'') is not null
      and exists (select 1 from grp g where g.sku = e.sku_base)
  ),
  -- ⭐ FIX FACTOR: factor por código de barra (cb) y por id de producto (sku idx1). Equivalentes → 1.
  fac_by_cb as (
    select distinct on (cb) cb, factor from (
      select nullif(btrim(pr.codigo_barra),'') as cb,
             case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor, 0 as ord
      from prods pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select nullif(btrim(e.codigo_barra),'') as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e
      where coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  fac_by_id as (
    select pr.id_producto as idk,
           case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor
    from prods pr
  ),
  equiv_cnt as (
    select e.sku_base as sku, count(*) as n
    from (
      select distinct e.sku_base, nullif(btrim(e.codigo_barra),'') as cb
      from mos.equivalencias e
      where coalesce(e.activo, true) = true
        and nullif(btrim(e.sku_base),'') is not null
        and nullif(btrim(e.codigo_barra),'') is not null
        and exists (select 1 from grp g where g.sku = e.sku_base)
        and not exists (
          select 1 from prods pr
          where coalesce(nullif(pr.sku_base,''), pr.id_producto) = e.sku_base
            and nullif(btrim(pr.codigo_barra),'') = nullif(btrim(e.codigo_barra),'')
        )
    ) e
    group by e.sku_base
  ),
  wh_by_sku as (
    select coalesce(i.sku, c.sku) as sku, sum(coalesce(s.cantidad_disponible,0)) as q
    from wh.stock s
    left join id_to_sku i on i.id = s.cod_producto
    left join cb_to_sku c on c.cb = s.cod_producto
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),
  zonas_by_sku as (
    select c.sku, sum(coalesce(z.cantidad,0)) as q
    from me.stock_zonas z
    join cb_to_sku c on c.cb = nullif(btrim(z.cod_barras),'')
    group by c.sku
  ),
  ventas_validas as (
    select v.id_venta
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  -- ⭐ FIX FACTOR: ventasRango por sku con cantidad × factor (mismo match id/cb que 113).
  ventas_by_sku as (
    select coalesce(i.sku, c.sku) as sku,
           sum(coalesce(d.cantidad,0) * coalesce(fcb.factor, fid.factor, 1)) as q
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join id_to_sku i on i.id = nullif(btrim(d.sku),'')
    left join cb_to_sku c on c.cb = nullif(btrim(d.cod_barras),'')
    left join fac_by_cb fcb on fcb.cb  = nullif(btrim(d.cod_barras),'')
    left join fac_by_id fid on fid.idk = nullif(btrim(d.sku),'')
    where coalesce(i.sku, c.sku) is not null
    group by coalesce(i.sku, c.sku)
  ),
  filas as (
    select
      bp.sku, bp.id_producto, bp.descripcion, bp.codigo_barra, bp.marca, bp.id_categoria,
      bp.precio_venta, bp.precio_costo, bp.minimo, bp.maximo, bp.count_pres,
      coalesce(ec.n, 0)              as count_equiv,
      coalesce(wb.q, 0)              as wh_q,
      coalesce(zb.q, 0)              as zonas_q,
      coalesce(wb.q,0) + coalesce(zb.q,0) as total,
      coalesce(vb.q, 0)              as ventas
    from base_prod bp
    left join equiv_cnt    ec on ec.sku = bp.sku
    left join wh_by_sku    wb on wb.sku = bp.sku
    left join zonas_by_sku zb on zb.sku = bp.sku
    left join ventas_by_sku vb on vb.sku = bp.sku
  ),
  calc as (
    select
      r.*,
      case when v_dias > 0 then r.ventas::numeric / v_dias else 0 end as rot_dia,
      case when (case when v_dias>0 then r.ventas::numeric/v_dias else 0 end) > 0 and r.total > 0
           then floor(r.total / (r.ventas::numeric / v_dias))::int
           else null end as dias_acabar
    from filas r
  ),
  clasif as (
    select
      c.*,
      case
        when c.total < 0                                                      then 'NEGATIVO'
        when c.minimo > 0 and c.total < c.minimo                              then 'BAJO_MINIMO'
        when c.rot_dia > 0 and c.dias_acabar is not null and c.dias_acabar < 7 then 'AGOTAR_PRONTO'
        when c.total > 0 and c.ventas = 0                                     then 'SIN_ROTACION'
        when c.minimo > 0 and c.total < c.minimo * 1.2                        then 'CERCA_MINIMO'
        else 'OK'
      end as alerta
    from calc c
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'skuBase',             cl.sku,
        'idProducto',          cl.id_producto,
        'descripcion',         coalesce(nullif(cl.descripcion,''), cl.sku),
        'codigoBarra',         coalesce(cl.codigo_barra, ''),
        'marca',               coalesce(cl.marca, ''),
        'idCategoria',         coalesce(cl.id_categoria, ''),
        'precioVenta',         cl.precio_venta,
        'precioCosto',         cl.precio_costo,
        'stockMinimo',         cl.minimo,
        'stockMaximo',         cl.maximo,
        'whCantidad',          cl.wh_q,
        'zonasCantidad',       cl.zonas_q,
        'totalCantidad',       cl.total,
        'ventasRango',         cl.ventas,
        'rotacionDia',         round(cl.rot_dia, 1),
        'diasParaAcabar',      cl.dias_acabar,
        'countPresentaciones', cl.count_pres,
        'countEquivalencias',  cl.count_equiv,
        'alerta',              cl.alerta
      )
      order by
        case cl.alerta
          when 'NEGATIVO'      then 0
          when 'BAJO_MINIMO'   then 1
          when 'AGOTAR_PRONTO' then 2
          when 'SIN_ROTACION'  then 3
          when 'CERCA_MINIMO'  then 4
          when 'OK'            then 5
          else 9
        end,
        lower(coalesce(nullif(cl.descripcion,''), cl.sku))
    ), '[]'::jsonb),
    count(*)::int
  into v_prods, v_total
  from clasif cl;

  return jsonb_build_object('ok', true,
    'data', jsonb_build_object('_almV', 2, 'productos', v_prods, 'total', coalesce(v_total,0), 'rangoDias', v_dias)
  ) || mos._frescura_sombra();
end;
$function$;

-- ── mos.stock_unificado(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.stock_unificado(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_key   text := coalesce(nullif(btrim(coalesce(p->>'skuBase','')), ''), nullif(btrim(coalesce(p->>'idProducto','')), ''));
  v_dias  int;
  v_desde date;
  v_sku   text;
  v_prod  record;
  v_data  jsonb;
  v_wh_cant numeric;
  v_wh_det  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_key is null then
    return jsonb_build_object('ok', false, 'error', 'Requiere skuBase o idProducto');
  end if;

  v_dias := coalesce(nullif(btrim(coalesce(p->>'rangoDias','')), '')::int, 7);
  if v_dias is null or v_dias <= 0 then v_dias := 7; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  select pr.id_producto, pr.sku_base, pr.descripcion, pr.codigo_barra,
         coalesce(pr.stock_minimo,0) as stock_minimo, coalesce(pr.stock_maximo,0) as stock_maximo,
         coalesce(pr.precio_costo,0) as precio_costo, coalesce(pr.precio_venta,0) as precio_venta
    into v_prod
    from mos.productos pr
   where pr.id_producto = v_key or pr.sku_base = v_key or pr.codigo_barra = v_key
   order by (pr.id_producto = v_key) desc, pr.id_producto
   limit 1;

  if not found then
    select coalesce(sum(coalesce(s.cantidad_disponible,0)),0),
           coalesce(jsonb_agg(jsonb_build_object(
             'codigoProducto', s.cod_producto, 'cantidad', coalesce(s.cantidad_disponible,0),
             'ultimaActualizacion', s.ultima_actualizacion)) filter (where s.cod_producto is not null), '[]'::jsonb)
      into v_wh_cant, v_wh_det
      from wh.stock s where s.cod_producto = v_key;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'producto', jsonb_build_object(
        'idProducto', v_key, 'skuBase', '',
        'descripcion', '⚠ ' || v_key || ' (no existe en catálogo MOS)',
        'codigoBarra', '', 'stockMinimo', 0, 'stockMaximo', 0, 'precioCosto', 0, 'precioVenta', 0),
      'wh', jsonb_build_object('cantidad', coalesce(v_wh_cant,0), 'detalle', coalesce(v_wh_det,'[]'::jsonb)),
      'zonas', '[]'::jsonb,
      'total', jsonb_build_object('cantidad', coalesce(v_wh_cant,0), 'rotacionDia', 0, 'ventasRango', 0,
                                  'diasParaAcabar', null, 'rangoDiasConsultado', v_dias),
      'insights', jsonb_build_array(jsonb_build_object(
        'tipo','NO_EN_CATALOGO','severidad','ALTA',
        'mensaje','Este producto está en WH pero no en PRODUCTOS_MASTER de MOS',
        'accion','Crearlo en Catálogo MOS para activar tracking de zonas y rotación')),
      'sinCatalogo', true
    )) || mos._frescura_sombra();
  end if;

  v_sku := coalesce(nullif(v_prod.sku_base,''), v_prod.id_producto);

  with
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true
  ),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union
    select upper(btrim(z.nombre)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union
    select upper(btrim(es.id_estacion)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union
    select upper(btrim(es.nombre)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union
    select upper(btrim(es.id_zona)) as raw, upper(btrim(es.id_zona)) as canon_id,
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) as canon_nombre
    from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (
    select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last
  ),
  presentaciones as (
    select pr.id_producto, pr.codigo_barra, pr.descripcion,
           case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor
    from mos.productos pr
    where coalesce(nullif(pr.sku_base,''), pr.id_producto) = v_sku
  ),
  ids_pres as (select id_producto from presentaciones),
  barras_info as (
    select distinct on (cb) cb, tipo, descripcion from (
      select nullif(btrim(pr.codigo_barra),'') as cb, 'principal'::text as tipo, coalesce(pr.descripcion,'') as descripcion, 0 as ord
      from presentaciones pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select nullif(btrim(e.codigo_barra),'') as cb, 'equivalencia'::text as tipo, coalesce(e.descripcion,'') as descripcion, 1 as ord
      from mos.equivalencias e
      where e.sku_base = v_sku and coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  barras_pres as (select cb from barras_info),
  -- ⭐ FIX FACTOR: factor por código (presentación propia) y por id (línea de venta por sku=id_producto).
  --    Equivalentes → factor 1. cb gana sobre id.
  fac_cb as (
    select distinct on (cb) cb, factor from (
      select nullif(btrim(pr.codigo_barra),'') as cb, pr.factor, 0 as ord from presentaciones pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select nullif(btrim(e.codigo_barra),'') as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e where e.sku_base = v_sku and coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),
  fac_id as (
    select pr.id_producto as idk, pr.factor from presentaciones pr
  ),
  equiv_cnt as (
    select count(*) as n from mos.equivalencias e
    where e.sku_base = v_sku and coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
  ),
  wh_rows as (
    select s.cod_producto, coalesce(s.cantidad_disponible,0) as cant, s.ultima_actualizacion
    from wh.stock s
    where s.cod_producto in (select id_producto from ids_pres)
       or s.cod_producto in (select cb from barras_pres)
  ),
  wh_total as (select coalesce(sum(cant),0) as q from wh_rows),
  wh_por_cb as (select cod_producto as cb, sum(cant) as q from wh_rows group by cod_producto),
  sz_raw as (
    select nullif(btrim(z.cod_barras),'') as cb,
           r.canon_id as zid, r.canon_nombre as znombre,
           coalesce(z.cantidad,0) as cant
    from me.stock_zonas z
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(z.zona_id))) as canon_id,
             coalesce(zr.canon_nombre, btrim(z.zona_id))     as canon_nombre
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(z.zona_id))
    ) r
    where nullif(btrim(z.cod_barras),'') in (select cb from barras_pres)
  ),
  zona_acum as (
    select zid, max(znombre) as znombre, sum(cant) as cantidad
    from sz_raw where nullif(btrim(zid),'') is not null group by zid
  ),
  sz_por_cb as (select cb, sum(cant) as q from sz_raw group by cb),
  matriz as (
    select cb, jsonb_object_agg(zid, cant) as porzona
    from (select cb, zid, sum(cant) as cant from sz_raw where nullif(btrim(zid),'') is not null group by cb, zid) m
    group by cb
  ),
  ventas_validas as (
    select v.id_venta, nullif(btrim(v.estacion),'') as estacion
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(v.estacion),'') is not null
  ),
  -- ⭐ FIX FACTOR: ventas por zona con cantidad × factor (mismo predicado de match sku/cb que 117).
  ventas_zona as (
    select r.canon_id as zid,
           sum(coalesce(d.cantidad,0) * coalesce(fc.factor, fi.factor, 1)) as ventas
    from me.ventas_detalle d
    join ventas_validas vv on vv.id_venta = d.id_venta
    left join fac_cb fc on fc.cb  = upper(btrim(nullif(btrim(d.cod_barras),'')))
    left join fac_id fi on fi.idk = nullif(btrim(d.sku),'')
    cross join lateral (
      select coalesce(zr.canon_id, upper(btrim(vv.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zr on zr.raw = upper(btrim(vv.estacion))
    ) r
    where nullif(btrim(d.sku),'') in (select id_producto from ids_pres)
       or nullif(btrim(d.cod_barras),'') in (select cb from barras_pres)
    group by r.canon_id
  ),
  zonas_universo as (
    select zid, nombre from zonas_reg
    union
    select za.zid, coalesce(za.znombre, za.zid) as nombre from zona_acum za
    union
    select vz.zid, vz.zid as nombre from ventas_zona vz
  ),
  zonas_universo_u as (
    select zid, max(nombre) as nombre from zonas_universo where nullif(btrim(zid),'') is not null group by zid
  ),
  zonas_arr as (
    select
      zu.zid,
      coalesce((select zr.nombre from zonas_reg zr where zr.zid = zu.zid), zu.nombre, zu.zid) as nombre,
      coalesce(za.cantidad, 0) as cantidad,
      coalesce(vz.ventas, 0)   as ventas_rango,
      (za.zid is not null)     as tiene_reg_stock,
      (vz.zid is not null)     as tiene_reg_venta
    from zonas_universo_u zu
    left join zona_acum   za on za.zid = zu.zid
    left join ventas_zona vz on vz.zid = zu.zid
  ),
  zonas_calc as (
    select
      za.*,
      (case when v_dias > 0 then za.ventas_rango::numeric / v_dias else 0 end) as rot_dia
    from zonas_arr za
  ),
  tot as (
    select
      (select q from wh_total) + coalesce(sum(zc.cantidad),0)                          as total_cant,
      coalesce(sum(round(zc.rot_dia,1)),0)                                             as total_rot,
      coalesce(sum(zc.ventas_rango),0)                                                 as total_ventas
    from zonas_calc zc
  )
  select jsonb_build_object(
    'producto', jsonb_build_object(
      'idProducto', v_prod.id_producto, 'skuBase', v_sku,
      'descripcion', v_prod.descripcion, 'codigoBarra', v_prod.codigo_barra,
      'stockMinimo', v_prod.stock_minimo, 'stockMaximo', v_prod.stock_maximo,
      'precioCosto', v_prod.precio_costo, 'precioVenta', v_prod.precio_venta),
    'codigosBarra', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'codigoBarra', bi.cb, 'tipo', bi.tipo, 'descripcion', bi.descripcion,
        'stockWh',    coalesce((select q from wh_por_cb w where w.cb = bi.cb), 0),
        'stockZonas', coalesce((select q from sz_por_cb  z where z.cb = bi.cb), 0),
        'stockTotal', coalesce((select q from wh_por_cb w where w.cb = bi.cb), 0) + coalesce((select q from sz_por_cb z where z.cb = bi.cb), 0),
        'porZona',    coalesce((select porzona from matriz m where m.cb = bi.cb), '{}'::jsonb)
      )), '[]'::jsonb) from barras_info bi),
    'countEquivalencias', (select n from equiv_cnt),
    'wh', jsonb_build_object(
      'cantidad', (select q from wh_total),
      'detalle', (select coalesce(jsonb_agg(jsonb_build_object(
                    'codigoProducto', wr.cod_producto, 'cantidad', wr.cant,
                    'ultimaActualizacion', wr.ultima_actualizacion)), '[]'::jsonb) from wh_rows wr)),
    'zonas', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'idZona', zc.zid, 'nombre', zc.nombre, 'cantidad', zc.cantidad,
        'ventasRango', zc.ventas_rango, 'rotacionDia', round(zc.rot_dia,1),
        'diasParaAcabar', case when zc.rot_dia > 0 and zc.cantidad > 0 then floor(zc.cantidad / zc.rot_dia)::int else null end,
        'tieneRegistroStock', zc.tiene_reg_stock, 'tieneRegistroVenta', zc.tiene_reg_venta,
        'sinStock', zc.cantidad <= 0, 'sinVentas', zc.ventas_rango <= 0)
        order by (case when zc.cantidad > 0 or zc.ventas_rango > 0 then 1 else 0 end) desc, zc.ventas_rango desc
      ), '[]'::jsonb) from zonas_calc zc),
    'total', jsonb_build_object(
      'cantidad', (select total_cant from tot),
      'rotacionDia', round((select total_rot from tot), 1),
      'ventasRango', (select total_ventas from tot),
      'diasParaAcabar', (select case when total_rot > 0 and total_cant > 0 then floor(total_cant / total_rot)::int else null end from tot),
      'rangoDiasConsultado', v_dias),
    'insights', (
      select coalesce(jsonb_agg(ins), '[]'::jsonb) from (
        select jsonb_build_object(
          'tipo','REPONER_ZONA','severidad','ALTA',
          'mensaje','Zona ' || zc.nombre || ' consume ' || round(zc.rot_dia,1) || '/d, alcanza ' || floor(zc.cantidad/zc.rot_dia)::int || ' días',
          'idZona', zc.zid,
          'accion','Trasladar desde WH (' || (select q from wh_total) || 'u disponibles)') as ins
        from zonas_calc zc
        where zc.rot_dia > 0 and zc.cantidad > 0 and floor(zc.cantidad/zc.rot_dia)::int < 7
        union all
        select jsonb_build_object(
          'tipo','SIN_ROTACION','severidad','MEDIA',
          'mensaje','Sin ventas en últimos ' || v_dias || ' días con ' || (select total_cant from tot) || 'u en stock',
          'accion','Considerar promo/descuento para rotar')
        where (select total_rot from tot) = 0 and (select total_cant from tot) > 0
        union all
        select jsonb_build_object(
          'tipo','BAJO_MINIMO','severidad','CRITICA',
          'mensaje','Stock total (' || (select total_cant from tot) || ') por debajo del mínimo (' || v_prod.stock_minimo || ')',
          'accion','Generar pedido de reposición')
        where v_prod.stock_minimo > 0 and (select total_cant from tot) < v_prod.stock_minimo
      ) z)
  )
  into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$;

-- ── mos.ranking_zonas(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.ranking_zonas(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dias  int;
  v_desde date;
  v_data  jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true
  ),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre
    from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)), coalesce(z.nombre, z.id_zona) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)),
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona)
           from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)),
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona)
           from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)),
           coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona)
           from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last),

  ventas as (
    select
      r.canon_id as zid,
      coalesce(v.total,0) as monto,
      nullif(btrim(v.vendedor),'') as vendedor,
      (zr.zid is not null) as registrada
    from me.ventas v
    cross join lateral (
      select coalesce(zru.canon_id, upper(btrim(v.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zru on zru.raw = upper(btrim(v.estacion))
    ) r
    left join zonas_reg zr on zr.zid = r.canon_id
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= v_desde
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(v.estacion),'') is not null
  ),
  tot as (
    select coalesce(sum(monto),0) as total_ventas, count(*)::int as total_tickets,
           coalesce(sum(monto) filter (where not registrada),0) as otras_ventas,
           count(*) filter (where not registrada)::int           as otras_tickets
    from ventas
  ),
  por_zona as (
    select zid, coalesce(sum(monto),0) as ventas, count(*)::int as tickets,
           count(distinct vendedor) filter (where vendedor is not null)::int as vendedores
    from ventas where registrada group by zid
  ),
  -- todas las registradas (aunque 0 ventas)
  filas as (
    select zr.zid, zr.nombre,
           coalesce(pz.ventas,0) as ventas, coalesce(pz.tickets,0) as tickets, coalesce(pz.vendedores,0) as vendedores
    from zonas_reg zr left join por_zona pz on pz.zid = zr.zid
  )
  select jsonb_build_object(
    '_almV', 2,
    'zonas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'idZona', f.zid, 'nombre', coalesce(f.nombre, f.zid),
        'ventas', round(f.ventas,2), 'tickets', f.tickets,
        'ticketProm', case when f.tickets > 0 then round(f.ventas / f.tickets, 2) else 0 end,
        'vendedores', f.vendedores,
        'pctTotal', case when (select total_ventas from tot) > 0 then round((f.ventas / (select total_ventas from tot)) * 1000)/10 else 0 end)
        order by f.ventas desc) from filas f), '[]'::jsonb),
    'totalVentas', round((select total_ventas from tot), 2),
    'totalTickets', (select total_tickets from tot),
    'rangoDias', v_dias,
    'ticketProm', case when (select total_tickets from tot) > 0 then round((select total_ventas from tot) / (select total_tickets from tot), 2) else 0 end,
    'ventasFueraDeZonasRegistradas', round((select otras_ventas from tot), 2),
    'ticketsFueraDeZonasRegistradas', (select otras_tickets from tot)
  ) into v_data;

  return jsonb_build_object('ok', true, 'data', v_data) || mos._frescura_sombra();
end;
$function$;

-- ── mos.insights_stock(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos.insights_stock(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dias  int;
  v_desde date;
  v_ins   jsonb;
  v_total int;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  v_dias := coalesce(nullif(btrim(coalesce(p->>'dias','')), '')::int, 30);
  if v_dias is null or v_dias <= 0 then v_dias := 30; end if;
  if v_dias > 3650 then v_dias := 3650; end if;
  v_desde := (now() at time zone 'America/Lima')::date - v_dias;

  with
  canonicos as (
    select pr.id_producto, pr.sku_base, pr.descripcion, pr.codigo_barra, coalesce(pr.stock_minimo,0) as stock_minimo
    from mos.productos pr
    where coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1)
  ),
  canon_by_id  as (select upper(btrim(c.id_producto)) as k, c.id_producto from canonicos c where nullif(btrim(c.id_producto),'') is not null),
  canon_by_sku as (select distinct on (upper(btrim(c.sku_base))) upper(btrim(c.sku_base)) as k, c.id_producto from canonicos c where nullif(btrim(c.sku_base),'') is not null order by upper(btrim(c.sku_base)), c.id_producto),
  prod_canon as (
    select pr.id_producto, pr.codigo_barra,
      case
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') = '' and (pr.factor_conversion is null or pr.factor_conversion = 1) then pr.id_producto
        when coalesce(nullif(btrim(pr.codigo_producto_base),''),'') <> '' then coalesce(cbi_b.id_producto, cbs_b.id_producto)
        when nullif(btrim(pr.sku_base),'') is not null then cbs_s.id_producto
        else null
      end as canon_id
    from mos.productos pr
    left join canon_by_id  cbi_b on cbi_b.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_b on cbs_b.k = upper(btrim(pr.codigo_producto_base))
    left join canon_by_sku cbs_s on cbs_s.k = upper(btrim(pr.sku_base))
  ),
  mapa as (
    select upper(btrim(pc.id_producto)) as k, pc.canon_id from prod_canon pc where pc.canon_id is not null and nullif(btrim(pc.id_producto),'') is not null
    union select upper(btrim(pc.codigo_barra)), pc.canon_id from prod_canon pc where pc.canon_id is not null and nullif(btrim(pc.codigo_barra),'') is not null
    union select upper(btrim(e.codigo_barra)), cbs.id_producto from mos.equivalencias e join canon_by_sku cbs on cbs.k = upper(btrim(e.sku_base)) where coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null
  ),
  mapa_u as (select distinct on (k) k, canon_id from mapa order by k, canon_id),
  -- ⭐ FIX FACTOR: factor por código de barra (presentación propia) — equivalentes → 1, cb gana sobre equiv.
  fac_by_cb as (
    select distinct on (cb) cb, factor from (
      select upper(btrim(pr.codigo_barra)) as cb,
             case when coalesce(pr.factor_conversion,0)=0 then 1 else pr.factor_conversion end as factor, 0 as ord
      from mos.productos pr where nullif(btrim(pr.codigo_barra),'') is not null
      union all
      select upper(btrim(e.codigo_barra)) as cb, 1::numeric as factor, 1 as ord
      from mos.equivalencias e where coalesce(e.activo,true)=true and nullif(btrim(e.codigo_barra),'') is not null
    ) t order by cb, ord
  ),

  zonas_reg as (select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id, coalesce(z.nombre, z.id_zona) as canon_nombre from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)), coalesce(z.nombre, z.id_zona) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)), coalesce((select zr.nombre from zonas_reg zr where zr.zid = upper(btrim(es.id_zona))), es.id_zona) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (select distinct on (raw) raw, canon_id, canon_nombre from zona_resolver order by raw, canon_nombre nulls last),
  stock_raw as (
    select m.canon_id, r.canon_id as zid, r.canon_nombre as znombre, coalesce(z.cantidad,0) as cant
    from me.stock_zonas z
    join mapa_u m on m.k = upper(btrim(z.cod_barras))
    cross join lateral (
      select coalesce(zru.canon_id, upper(btrim(z.zona_id))) as canon_id, coalesce(zru.canon_nombre, btrim(z.zona_id)) as canon_nombre
      from (select 1) _ left join zona_resolver_u zru on zru.raw = upper(btrim(z.zona_id))
    ) r
    where coalesce(z.cantidad,0) > 0 and m.canon_id is not null
  ),
  stock_canon_total as (select canon_id, sum(cant) as total from stock_raw group by canon_id),
  stock_canon_zona  as (select canon_id, zid, max(znombre) as znombre, sum(cant) as cant from stock_raw group by canon_id, zid),
  ventas_meta as (
    select v.id_venta, r.canon_id as zid
    from me.ventas v
    cross join lateral (
      select coalesce(zru.canon_id, upper(btrim(v.estacion))) as canon_id
      from (select 1) _ left join zona_resolver_u zru on zru.raw = upper(btrim(v.estacion))
    ) r
    where v.fecha is not null and (v.fecha at time zone 'America/Lima')::date >= v_desde and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  ),
  -- ⭐ FIX FACTOR: cantidad × factor del cod_barras (mismo resolver canónico que 117).
  ventas_canon_zona as (
    select mu.canon_id, vm.zid,
           sum(coalesce(d.cantidad,0) * coalesce(fb.factor, 1)) as cant
    from me.ventas_detalle d
    join ventas_meta vm on vm.id_venta = d.id_venta
    left join mapa_u mu on mu.k = upper(btrim(d.cod_barras))
    left join fac_by_cb fb on fb.cb = upper(btrim(d.cod_barras))
    where nullif(btrim(d.cod_barras),'') is not null
    group by mu.canon_id, vm.zid
  ),
  vcz as (select canon_id, zid, sum(cant) as cant from ventas_canon_zona where canon_id is not null group by canon_id, zid),
  ventas_canon_total as (select canon_id, sum(cant) as total from vcz group by canon_id),
  zona_nombre as (
    select zid, max(nombre) as nombre from (
      select zid, znombre as nombre from stock_canon_zona
      union all select zr.zid, zr.nombre from zonas_reg zr
      union all select scz.zid, scz.znombre from stock_canon_zona scz
    ) z where nullif(btrim(zid),'') is not null group by zid
  ),
  wh_por_canon as (
    select m.canon_id, sum(coalesce(s.cantidad_disponible,0)) as q
    from wh.stock s join mapa_u m on m.k = upper(btrim(s.cod_producto))
    where nullif(btrim(s.cod_producto),'') is not null group by m.canon_id
  ),
  ins1 as (
    select jsonb_build_object(
      'tipo','SIN_ROTACION','severidad','MEDIA',
      'producto', coalesce(nullif(c.descripcion,''), c.id_producto),
      'codigoBarra', coalesce(nullif(c.codigo_barra,''), c.id_producto),
      'idProducto', c.id_producto, 'skuBase', coalesce(c.sku_base,''),
      'stock', sct.total,
      'mensaje', coalesce(c.descripcion,'') || ' tiene ' || sct.total || 'u sin venta en ' || v_dias || ' días',
      'accion','Lanzar promo o trasladar a otra zona') as obj
    from stock_canon_total sct join canonicos c on c.id_producto = sct.canon_id
    where sct.total >= 10 and coalesce((select total from ventas_canon_total v where v.canon_id = sct.canon_id),0) = 0
  ),
  base2 as (
    select
      vcz.canon_id, vcz.zid as zona_vend, vcz.cant as ventas,
      coalesce((select cant from stock_canon_zona scz where scz.canon_id = vcz.canon_id and scz.zid = vcz.zid),0) as stock_en_esa,
      (vcz.cant::numeric / v_dias) as rot_dia,
      coalesce((select q from wh_por_canon w where w.canon_id = vcz.canon_id),0) as wh_disp
    from vcz
    where vcz.zid in (select zid from zonas_reg)
  ),
  base2b as (
    select b.*,
      (b.stock_en_esa / nullif(b.rot_dia,0)) as dias_restantes,
      ceil(b.rot_dia * 14)::int as cant_sugerida,
      c.descripcion, c.id_producto, c.sku_base, c.codigo_barra
    from base2 b join canonicos c on c.id_producto = b.canon_id
    where b.rot_dia > 0
  ),
  base2c as (
    select * from base2b
    where dias_restantes is not null and dias_restantes < 7 and dias_restantes >= 0
  ),
  ins2a as (
    select b.canon_id, b.zona_vend, jsonb_build_object(
      'tipo','DESPACHAR_DESDE_WH',
      'severidad', case when b.dias_restantes < 3 then 'CRITICA' else 'ALTA' end,
      'producto', coalesce(nullif(b.descripcion,''), coalesce(nullif(b.codigo_barra,''), b.canon_id)),
      'codigoBarra', coalesce(nullif(b.codigo_barra,''), b.canon_id),
      'idProducto', b.id_producto, 'skuBase', coalesce(b.sku_base,''),
      'mensaje', 'Despachar de 🏭 WH → ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_vend), b.zona_vend)
                 || ': ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_vend), b.zona_vend)
                 || ' tiene ' || b.stock_en_esa || 'u (alcanza ' || floor(b.dias_restantes)::int || 'd) y vende '
                 || round(b.rot_dia,1) || '/d. WH dispone de ' || b.wh_disp || 'u (todas las variantes).',
      'accion','Despachar ' || b.cant_sugerida || 'u (cobertura 2 semanas)',
      'desde','WH','hacia', b.zona_vend, 'cantidadSugerida', b.cant_sugerida, 'stockWh', b.wh_disp) as obj
    from base2c b
    where b.wh_disp >= b.cant_sugerida
  ),
  ins2b_cands as (
    select b.canon_id, b.zona_vend, b.ventas, b.rot_dia, b.dias_restantes, b.cant_sugerida,
           b.descripcion, b.id_producto, b.sku_base, b.codigo_barra,
           scz.zid as zona_origen, scz.cant as stock_origen,
           coalesce((select cant from vcz v where v.canon_id = b.canon_id and v.zid = scz.zid),0) as ventas_otra
    from base2c b
    join stock_canon_zona scz on scz.canon_id = b.canon_id
    where b.wh_disp < b.cant_sugerida
      and scz.zid <> b.zona_vend
      and scz.zid in (select zid from zonas_reg)
      and scz.cant >= 5
      and coalesce((select cant from vcz v where v.canon_id = b.canon_id and v.zid = scz.zid),0) < b.ventas / 3.0
  ),
  ins2b_best as (
    select distinct on (canon_id, zona_vend) *
    from ins2b_cands order by canon_id, zona_vend, stock_origen desc, zona_origen
  ),
  ins2b as (
    select b.canon_id, b.zona_vend, jsonb_build_object(
      'tipo','TRASLADAR','severidad','MEDIA',
      'producto', coalesce(nullif(b.descripcion,''), coalesce(nullif(b.codigo_barra,''), b.canon_id)),
      'codigoBarra', coalesce(nullif(b.codigo_barra,''), b.canon_id),
      'idProducto', b.id_producto, 'skuBase', coalesce(b.sku_base,''),
      'mensaje', '🏭 WH sin stock — Trasladar de ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_origen), b.zona_origen)
                 || ' (' || b.stock_origen || 'u, sin venta) → ' || coalesce((select nombre from zona_nombre zn where zn.zid = b.zona_vend), b.zona_vend)
                 || ' (vende ' || round(b.rot_dia,1) || '/d, alcanza ' || floor(b.dias_restantes)::int || 'd)',
      'accion','Mover ' || least(b.stock_origen, b.cant_sugerida) || 'u entre zonas (operación manual)',
      'desde', b.zona_origen, 'hacia', b.zona_vend, 'cantidadSugerida', least(b.stock_origen, b.cant_sugerida)) as obj
    from ins2b_best b
  ),
  ins3 as (
    select jsonb_build_object(
      'tipo','REPOSICION','severidad','CRITICA',
      'producto', c.descripcion, 'idProducto', c.id_producto, 'skuBase', coalesce(c.sku_base,''),
      'stock', coalesce(sct.total,0) + coalesce(wpc.q,0), 'minimo', c.stock_minimo,
      'mensaje', c.descripcion || ' total ' || (coalesce(sct.total,0) + coalesce(wpc.q,0)) || 'u (todas variantes) < mínimo ' || c.stock_minimo,
      'accion','Generar pedido al proveedor') as obj
    from canonicos c
    left join stock_canon_total sct on sct.canon_id = c.id_producto
    left join wh_por_canon      wpc on wpc.canon_id = c.id_producto
    where c.stock_minimo > 0 and (coalesce(sct.total,0) + coalesce(wpc.q,0)) < c.stock_minimo
  ),
  todos as (
    select obj, 3 as prio_tipo from ins1
    union all select obj, 1 from ins2a
    union all select obj, 2 from ins2b
    union all select obj, 0 from ins3
  ),
  ordenados as (
    select obj,
      (case obj->>'severidad' when 'CRITICA' then 0 when 'ALTA' then 1 when 'MEDIA' then 2 when 'BAJA' then 3 else 9 end) as prio_sev,
      prio_tipo
    from todos
  )
  select
    coalesce((select jsonb_agg(o.obj order by o.prio_sev, o.prio_tipo) from (select * from ordenados order by prio_sev, prio_tipo limit 20) o), '[]'::jsonb),
    (select count(*)::int from ordenados)
  into v_ins, v_total;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    '_almV', 2, 'insights', v_ins, 'total', coalesce(v_total,0), 'rangoDias', v_dias
  )) || mos._frescura_sombra();
end;
$function$;

-- ── me._riz_ventas_base(date,date) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me._riz_ventas_base(p_desde date, p_hasta date)
 RETURNS TABLE(sku_base text, zona_id text, dia date, unidades_base numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with
  -- ── Resolver de zona (idéntico patrón a 117) ──────────────────────────────────────────────────────────────
  zonas_reg as (
    select upper(btrim(z.id_zona)) as zid, coalesce(z.nombre, z.id_zona) as nombre
    from mos.zonas z
    where nullif(btrim(z.id_zona),'') is not null and coalesce(z.estado, true) = true
  ),
  zona_resolver as (
    select upper(btrim(z.id_zona)) as raw, upper(btrim(z.id_zona)) as canon_id from mos.zonas z where nullif(btrim(z.id_zona),'') is not null
    union select upper(btrim(z.nombre)), upper(btrim(z.id_zona)) from mos.zonas z where nullif(btrim(z.nombre),'') is not null
    union select upper(btrim(es.id_estacion)), upper(btrim(es.id_zona)) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.id_estacion),'') is not null
    union select upper(btrim(es.nombre)), upper(btrim(es.id_zona)) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null and nullif(btrim(es.nombre),'') is not null
    union select upper(btrim(es.id_zona)), upper(btrim(es.id_zona)) from mos.estaciones es where nullif(btrim(es.id_zona),'') is not null
  ),
  zona_resolver_u as (
    select distinct on (raw) raw, canon_id from zona_resolver order by raw, canon_id
  ),
  -- ── Mapa cod_barra → (skuBase, factor). Presentaciones propias (cada una con su factor) + equivalentes (f=1). ─
  --    Para un cod_barra repetido entre principal y equivalencia, gana el principal (ord 0).
  cb_map as (
    select distinct on (cb) cb, sku, factor from (
      select upper(btrim(p.codigo_barra)) as cb,
             coalesce(nullif(btrim(p.sku_base),''), p.id_producto) as sku,
             case when coalesce(p.factor_conversion,0) = 0 then 1 else p.factor_conversion end as factor,
             0 as ord
      from mos.productos p where nullif(btrim(p.codigo_barra),'') is not null
      union all
      -- también se puede vender por id_producto (algunos detalles traen sku = id_producto)
      select upper(btrim(p.id_producto)) as cb,
             coalesce(nullif(btrim(p.sku_base),''), p.id_producto) as sku,
             case when coalesce(p.factor_conversion,0) = 0 then 1 else p.factor_conversion end as factor,
             1 as ord
      from mos.productos p where nullif(btrim(p.id_producto),'') is not null
      union all
      select upper(btrim(e.codigo_barra)) as cb,
             e.sku_base as sku,
             1::numeric as factor,
             2 as ord
      from mos.equivalencias e
      where coalesce(e.activo, true) = true and nullif(btrim(e.codigo_barra),'') is not null and nullif(btrim(e.sku_base),'') is not null
    ) t
    order by cb, ord
  ),
  -- ── Ventas válidas en rango (día de negocio Lima, no anuladas). Zona = zona_id si viene, si no estacion. ──
  ventas_val as (
    select v.id_venta,
           (v.fecha at time zone 'America/Lima')::date as dia,
           upper(btrim(coalesce(nullif(btrim(v.zona_id),''), v.estacion))) as raw_zona
    from me.ventas v
    where v.fecha is not null
      and (v.fecha at time zone 'America/Lima')::date >= p_desde
      and (v.fecha at time zone 'America/Lima')::date <= p_hasta
      and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
      and nullif(btrim(coalesce(nullif(btrim(v.zona_id),''), v.estacion)),'') is not null
  ),
  -- ── Detalle normalizado: une por sku o cod_barras al cb_map; aplica factor. ──
  detalle as (
    select
      coalesce(zr.canon_id, vv.raw_zona) as zona_id,
      cm.sku as sku_base,
      vv.dia,
      coalesce(d.cantidad,0) * cm.factor as base
    from me.ventas_detalle d
    join ventas_val vv on vv.id_venta = d.id_venta
    join cb_map cm on cm.cb = upper(btrim(coalesce(nullif(btrim(d.cod_barras),''), d.sku)))
    left join zona_resolver_u zr on zr.raw = vv.raw_zona
    where coalesce(d.cantidad,0) <> 0
  )
  select sku_base, zona_id, dia, sum(base) as unidades_base
  from detalle
  where nullif(btrim(zona_id),'') is not null and nullif(btrim(sku_base),'') is not null
  group by sku_base, zona_id, dia;
$function$;

-- ── mos._minmax_recalcular_core(integer) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos._minmax_recalcular_core(p_dias integer DEFAULT 28)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dias    int     := greatest(7, least(120, coalesce(p_dias, 28)));
  v_semanas numeric := v_dias / 7.0;
  v_desde   timestamptz := now() - make_interval(days => v_dias);
  v_res     jsonb;
begin
  with sales as (
    select d.sku, btrim(coalesce(d.cod_barras,'')) as cb, sum(coalesce(d.cantidad,0)) as qty
      from me.ventas_detalle d
      join me.ventas v on v.id_venta = d.id_venta
     where v.fecha >= v_desde
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
     group by d.sku, btrim(coalesce(d.cod_barras,''))
  ),
  -- cada línea → sku canónico: id_producto=sku → cb=codigo_barra → equivalencia cb→sku_base (idéntico a 379)
  resolved as (
    select coalesce(
      (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where pr.id_producto = s.sku limit 1),
      (select coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) from mos.productos pr where s.cb <> '' and pr.codigo_barra = s.cb limit 1),
      (select e.sku_base from mos.equivalencias e where s.cb <> '' and e.codigo_barra = s.cb and coalesce(e.activo,true) limit 1)
    ) as sku_canon, s.qty
    from sales s
  ),
  agg as (
    select sku_canon, sum(qty) as total from resolved where sku_canon is not null group by sku_canon
  ),
  -- fila canónica por sku (réplica rowCanonBySku): id==sku, luego factor=1 sin base, luego factor=1, luego id.
  canon as (
    select x.id_producto, x.canon
      from (select pr.id_producto,
                   coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto) as canon,
                   row_number() over (
                     partition by coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto)
                     order by (pr.id_producto = coalesce(nullif(btrim(pr.sku_base),''), pr.id_producto)) desc,
                              (coalesce(pr.factor_conversion,1) = 1 and btrim(coalesce(pr.codigo_producto_base,'')) = '') desc,
                              (coalesce(pr.factor_conversion,1) = 1) desc,
                              pr.id_producto) as rn
              from mos.productos pr) x
     where x.rn = 1
  ),
  calc as (
    select a.sku_canon, a.total, c.id_producto,
           case when a.total > 0 then ceil(a.total / v_semanas)::int end        as nmin,
           case when a.total > 0 then ceil((a.total / v_semanas) * 1.2)::int end as nmax
      from agg a
      left join canon c on c.canon = a.sku_canon
  ),
  upd as (
    update mos.productos p
       set stock_minimo = k.nmin, stock_maximo = k.nmax
      from calc k
     where k.total > 0
       and k.id_producto is not null
       and p.id_producto = k.id_producto
       and (coalesce(p.stock_minimo,0) <> k.nmin or coalesce(p.stock_maximo,0) <> k.nmax)
    returning k.sku_canon, k.nmin, k.nmax
  )
  select jsonb_build_object(
           'actualizados', (select count(*) from upd),
           'sinCambio',    (select count(*) from calc where total > 0 and id_producto is not null) - (select count(*) from upd),
           'sinVentas',    (select count(*) from calc where coalesce(total,0) <= 0),
           'errores',      (select count(*) from calc where total > 0 and id_producto is null),
           'ventana',      v_dias || ' días',
           'sample',       coalesce((select jsonb_agg(jsonb_build_object('sku', u.sku_canon, 'min', u.nmin, 'max', u.nmax))
                                       from (select * from upd order by sku_canon limit 20) u), '[]'::jsonb))
    into v_res;
  return v_res;
end;
$function$;

-- ── me._kardex_reconstruir(text,text[]) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION me._kardex_reconstruir(v_zona text, v_codes text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_movs   jsonb := '[]'::jsonb;
  v_ev     me._kardex_evento[];
  v_e      me._kardex_evento;
  v_run    numeric(20,3);
  v_antes  numeric(20,3);
  v_sal    numeric(20,3);
  v_acc    jsonb := '[]'::jsonb;
  v_saldo_final numeric(20,3);
  v_stock_zonas numeric(20,3);
  v_base   numeric(20,3);
begin
  if v_codes is null or coalesce(array_length(v_codes,1),0) = 0 then
    return jsonb_build_object('totalMovimientos',0,'saldoFinal',0,'stockZonas',0,'cuadra',true,'movimientos','[]'::jsonb);
  end if;

  with
  dias_reconc as (
    select distinct date(gc.fecha at time zone 'America/Lima') as dia
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and gc.tipo = 'SALIDA_VENTAS' and upper(btrim(gd.cod_barras)) = any(v_codes)
  ),
  eventos as (
    -- AJUSTE manual (SET-ABSOLUTO real)
    select al.ts as fecha, 'AJUSTE'::text as tipo, al.delta as delta, al.stock_despues as saldo_set,
           true as es_set, true as aplicado, coalesce(al.usuario,'—') as usuario, '' as id_guia, 'ajuste' as fuente
      from me.zona_ajuste_log al
     where al.zona_id = v_zona and upper(btrim(al.cod_barras)) = any(v_codes)
    union all
    -- AUDITORIA (SET-ABSOLUTO)
    select a.fecha, 'AUDITORIA'::text, (a.cant_real - a.cant_sistema), a.cant_real,
           true, true, coalesce(a.vendedor,'—'), '', 'auditoria'
      from me.auditorias a
     where a.zona_id = v_zona and upper(btrim(a.cod_barras)) = any(v_codes)
    union all
    -- GUÍAS (entradas +, salidas −)
    select gc.fecha,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then 'TRASLADO_IN'
                when gc.tipo = 'SALIDA_VENTAS' then 'SALIDA_VENTA'
                when gc.tipo = 'SALIDA_JEFA' then 'SALIDA_JEFA'
                when gc.tipo like 'SALIDA%' then 'TRASLADO_OUT'
                else 'SALIDA_JEFA' end,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then gd.cantidad else -gd.cantidad end,
           null::numeric, false, true, coalesce(gc.vendedor,'—'), gc.id_guia, 'guia'
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = v_zona and upper(btrim(gd.cod_barras)) = any(v_codes)
    union all
    -- VENTAS (tickets, no anuladas)
    select v.fecha, 'SALIDA_VENTA'::text, -vd.cantidad, null::numeric, false,
           (date(v.fecha at time zone 'America/Lima') not in (select dia from dias_reconc)) as aplicado,
           coalesce(v.vendedor,'—'), v.id_venta,
           case when date(v.fecha at time zone 'America/Lima') in (select dia from dias_reconc)
                then 'venta' else 'venta-pendiente' end
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where v.zona_id = v_zona and upper(btrim(vd.cod_barras)) = any(v_codes)
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
    union all
    -- [960] RECEPCIONES por escaneo WH→ME (me.stock_movimientos 'TRASLADO-WH:'; NO crean me.guias).
    --   DEDUP: se excluye si ya hay una guía ENTRADA para el mismo código en el mismo día (para no duplicar
    --   las recepciones que sí generaron guía). id_guia del evento = idGuiaWH (split del ref_id) → abrible.
    select sm.fecha,
           case when sm.delta >= 0 then 'TRASLADO_IN' else 'TRASLADO_OUT' end,
           sm.delta, null::numeric, false, true,
           coalesce(sm.usuario,'—'), split_part(sm.ref_id, ':', 2), 'recepcion'
      from me.stock_movimientos sm
     where sm.ambito = 'ZONA' and upper(btrim(sm.zona_id)) = v_zona
       and upper(btrim(sm.cod_barra)) = any(v_codes)
       and sm.ref_id like 'TRASLADO-WH:%'
       and coalesce(sm.delta,0) <> 0
       and not exists (
         select 1 from me.guias_detalle gd2
           join me.guias_cabecera gc2 on gc2.id_guia = gd2.id_guia
          where gc2.zona_id = v_zona
            and upper(btrim(gd2.cod_barras)) = upper(btrim(sm.cod_barra))
            and (gc2.tipo like 'ENTRADA%' or gc2.tipo like 'TRASLADO_IN%')
            and date(gc2.fecha at time zone 'America/Lima') = date(sm.fecha at time zone 'America/Lima'))
  )
  select array_agg(
           row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
           order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
         into v_ev
    from eventos e;

  select coalesce(sum(cantidad),0) into v_stock_zonas
    from me.stock_zonas where upper(btrim(cod_barras)) = any(v_codes) and upper(btrim(zona_id)) = v_zona;

  v_run := 0;
  if v_ev is not null then
    foreach v_e in array v_ev loop
      v_antes := v_run;
      if (v_e).es_set then
        v_run := (v_e).saldo_set; v_sal := v_run;
      elsif (v_e).aplicado then
        v_run := v_run + (v_e).delta; v_sal := v_run;
      else
        v_sal := v_run;
      end if;
      v_acc := v_acc || jsonb_build_object(
        'idGuia',(v_e).id_guia,'fecha',(v_e).fecha,'tipo',me._kardex_label((v_e).tipo,(v_e).delta),
        'tipoOperacion',(v_e).tipo,'esIngreso',((v_e).delta > 0),'cantidad',abs((v_e).delta),
        'saldo',v_sal,'stockAntes',v_antes,'usuario',(v_e).usuario,'origen','',
        'estado',case when (v_e).fuente = 'venta-pendiente' then 'ABIERTA' else 'CERRADA' end,
        'pendiente',((v_e).fuente = 'venta-pendiente'),
        'fuente',case when (v_e).tipo in ('AJUSTE','AUDITORIA') then 'ajuste'
                      when (v_e).fuente = 'venta-pendiente' then 'venta' else (v_e).fuente end,
        'aplicado',(v_e).aplicado,'idLote',null);
    end loop;
  end if;

  v_base := round(v_stock_zonas - v_run, 3);
  if v_base <> 0 then
    v_antes := v_run;
    v_run := v_stock_zonas;
    v_acc := v_acc || jsonb_build_object(
      'idGuia','','fecha',now(),
      'tipo','CUADRE con stock real (saldo histórico previo)','tipoOperacion','AJUSTE',
      'esIngreso',(v_base > 0),'cantidad',abs(v_base),
      'saldo',v_run,'stockAntes',v_antes,'usuario','sistema-cuadre','origen','',
      'estado','CERRADA','pendiente',false,'fuente','ajuste','aplicado',true,'idLote',null);
  end if;

  select coalesce(jsonb_agg(elem order by ord desc), '[]'::jsonb) into v_movs
    from jsonb_array_elements(v_acc) with ordinality as t(elem, ord);

  v_saldo_final := v_run;

  return jsonb_build_object(
    'totalMovimientos', jsonb_array_length(v_movs),
    'saldoFinal',       v_saldo_final,
    'stockZonas',       v_stock_zonas,
    'cuadra',           (round(v_saldo_final,3) = round(v_stock_zonas,3)),
    'movimientos',      v_movs);
end;
$function$;

-- ── mos._recon_teorico_zona(text,text[]) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION mos._recon_teorico_zona(p_zona text, p_codes text[])
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ev    me._kardex_evento[];
  v_e     me._kardex_evento;
  v_run   numeric(20,3) := 0;
begin
  with eventos as (
    -- AUDITORIA (set absoluto → re-ancla a cant_real)
    select a.fecha, 'AUDITORIA'::text as tipo, (a.cant_real - a.cant_sistema) as delta,
           a.cant_real as saldo_set, true as es_set, true as aplicado,
           coalesce(a.vendedor,'—') as usuario, ''::text as id_guia, 'auditoria'::text as fuente
      from me.auditorias a
     where a.zona_id = p_zona and a.cod_barras = any(p_codes)
    union all
    -- GUÍAS (SALIDA_VENTAS informativa: no suma; ventas_detalle es la fuente real de la salida por venta)
    select gc.fecha,
           case
             when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%' then 'TRASLADO_IN'
             when gc.tipo = 'SALIDA_JEFA' then 'SALIDA_JEFA'
             when gc.tipo like '%MOVIMIENTO%' or gc.tipo like 'TRASLADO%' then 'TRASLADO_OUT'
             when gc.tipo = 'SALIDA_VENTAS' then 'SALIDA_VENTA'
             else 'SALIDA_JEFA'
           end as tipo,
           case when gc.tipo like 'ENTRADA%' or gc.tipo like 'TRASLADO_IN%'
                then gd.cantidad else -gd.cantidad end as delta,
           null::numeric as saldo_set, false as es_set,
           (gc.tipo <> 'SALIDA_VENTAS') as aplicado,           -- guías de venta NO suman (anti-doble-conteo)
           coalesce(gc.vendedor,'—') as usuario, gc.id_guia as id_guia, 'guia'::text as fuente
      from me.guias_detalle gd
      join me.guias_cabecera gc on gc.id_guia = gd.id_guia
     where gc.zona_id = p_zona and gd.cod_barras = any(p_codes)
    union all
    -- VENTAS (no anuladas) = SALIDA_VENTA
    select v.fecha, 'SALIDA_VENTA'::text as tipo, -vd.cantidad as delta,
           null::numeric as saldo_set, false as es_set, true as aplicado,
           coalesce(v.vendedor,'—') as usuario, v.id_venta as id_guia, 'venta'::text as fuente
      from me.ventas_detalle vd
      join me.ventas v on v.id_venta = vd.id_venta
     where v.zona_id = p_zona and vd.cod_barras = any(p_codes)
       and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
  )
  select array_agg(
           row((e).fecha,(e).tipo,(e).delta,(e).saldo_set,(e).es_set,(e).aplicado,(e).usuario,(e).id_guia,(e).fuente)::me._kardex_evento
           order by (e).fecha asc, case when (e).es_set then 1 else 0 end, (e).tipo)
         into v_ev
    from eventos e;

  if v_ev is not null then
    foreach v_e in array v_ev loop
      if (v_e).es_set then
        v_run := (v_e).saldo_set;                 -- re-ancla
      elsif (v_e).aplicado then
        v_run := v_run + (v_e).delta;             -- acumula
      end if;                                      -- informativo (aplicado=false) → no mueve el saldo
    end loop;
  end if;
  return coalesce(v_run, 0);
end;
$function$;

-- ── wh.rebasar_acumulada(jsonb) (definición viva pre-1046) ──
CREATE OR REPLACE FUNCTION wh.rebasar_acumulada(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_zona text:=coalesce(nullif(btrim(coalesce(p->>'zona',p->>'id_zona','')),''),'');
  v_bucket date:=wh._bucket_despacho((now() at time zone 'America/Lima')::date); v_acum_id text; v_items jsonb;
begin
  if v_zona='' then return jsonb_build_object('ok',false,'error','Requiere zona'); end if;
  v_acum_id:='PCK-ACU-'||v_zona||'-'||to_char(v_bucket,'YYYY-MM-DD');
  with ped as (  -- pedido = Σ ventas del bucket (por cierre de caja de la zona) resuelto al canónico
    select cv.sku_base sku, sum(cv.cant) sol
    from me.cajas cj join me.ventas v on v.id_caja=cj.id_caja
    join me.ventas_detalle vd on vd.id_venta=v.id_venta
    cross join lateral mos._venta_canonico(vd.cod_barras, vd.cantidad::numeric, vd.unidad_medida) cv
    where coalesce(cj.zona_id,'')=v_zona and upper(coalesce(v.forma_pago,''))<>'ANULADO'
      and wh._bucket_venta((coalesce(cj.fecha_cierre,cj.fecha_apertura) at time zone 'America/Lima')::date)=v_bucket
      and coalesce(cv.sku_base,'')<>''
    group by cv.sku_base having sum(cv.cant)>0
  ),
  desp as (  -- despacho = Σ guías SALIDA_ZONA DESDE pickup ([pickup:]) resuelto al canónico
    select coalesce(
        (select pr.sku_base from mos.productos pr where pr.codigo_barra=gd.cod_producto limit 1),
        (select e.sku_base from mos.equivalencias e where e.codigo_barra=gd.cod_producto and e.activo limit 1),
        gd.cod_producto) sku,
      sum(coalesce(gd.cant_recibida,gd.cantidad_aplicada,0)) d
    from wh.guias g join wh.guia_detalle gd on gd.id_guia=g.id_guia
    where g.tipo='SALIDA_ZONA' and g.comentario like '%[pickup:%' and coalesce(g.id_zona,'')=v_zona
      and wh._bucket_despacho((g.fecha at time zone 'America/Lima')::date)=v_bucket group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('skuBase',ped.sku,
    'nombre',coalesce((select pp.descripcion from mos.productos pp where pp.sku_base=ped.sku order by (pp.codigo_producto_base is null) desc limit 1),ped.sku),
    'solicitado',ped.sol,'despachado',least(ped.sol,coalesce(desp.d,0)),
    'codigosOriginales',coalesce((select jsonb_agg(distinct cod) from (
       select pp.codigo_barra cod from mos.productos pp where pp.sku_base=ped.sku and coalesce(pp.codigo_barra,'')<>'' and coalesce(nullif(pp.factor_conversion,0),1)=1
       union select e.codigo_barra from mos.equivalencias e where e.sku_base=ped.sku and e.activo and coalesce(e.codigo_barra,'')<>'') q),'[]'::jsonb)
  ) order by ped.sku),'[]'::jsonb) into v_items from ped left join desp on desp.sku=ped.sku;
  update wh.pickups set items=v_items, ultima_actividad=now() where id_pickup=v_acum_id;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('acum',v_acum_id,'items',jsonb_array_length(v_items)));
end;$function$;

commit;
