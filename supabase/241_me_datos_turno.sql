-- ============================================================
-- 241_me_datos_turno.sql
-- Port FIEL y MONEY-EXACTO de GAS datosTurno(params) (Cajas.gs:309)
-- Ticket Z de cierre de turno (POS / warehouse).
-- 100% Supabase: lee me.cajas/ventas/ventas_detalle/movimientos_extra/
-- auditorias + mos.estaciones/impresoras/jornadas/zonas.
-- Salida: { ok:true, data:{...} } con el MISMO shape que consume turno.html render().
-- ============================================================

create or replace function me.datos_turno(p_id_caja text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
    where t->>'metodo' <> 'CREDITO'
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
    where t->>'metodo' <> 'CREDITO'
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
    where t->>'metodo' <> 'CREDITO'
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
$$;

revoke all on function me.datos_turno(text) from public;
grant execute on function me.datos_turno(text) to authenticated, service_role;

notify pgrst, 'reload schema';
