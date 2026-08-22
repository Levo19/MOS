-- [948] CABINA SEMANAL — motor de datos del nuevo dashboard de MOS. UNA llamada devuelve la semana en
-- curso (o pasada, con offset) para los 5 grupos, TODO sobre datos reales:
--   💰 Dinero      = mos.finanzas_rango (venta/rentab/gastos) + META REAL (suma de metaDiaria por zona,
--                    versionada por fecha vía mos._meta_zona) + comisiones de mos.liquidaciones_dia.
--   📦 Productos   = top vendidos de me.ventas_detalle (semana, con ticket, no anulado, zona 1/2)
--                    + considerados activos + reposición media (tsDespacho-tsSolicitud de wh.pickups).
--   👥 Personal    = carga por hora×zona de me.ventas (pico real).
--   🗺️ Zonas       = estancados por zona (me.zona_esperado bcg=PERRO) + stock por zona.
--   ⚖️ Tributario  = mos.trib_resumen_mes (IGV a favor/emitido/balance del mes).
-- Semana = lunes→domingo, hora Lima. offset: 0=actual, -1=pasada, etc. Solo lectura/agregación.
create or replace function mos.cabina_semanal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_off   int  := coalesce(nullif(p->>'offset','')::int, 0);
  v_hoy   date := (now() at time zone 'America/Lima')::date;
  v_lun   date := (v_hoy - (extract(isodow from v_hoy)::int - 1)) + (v_off * 7);
  v_dom   date := v_lun + 6;
  v_fin   date := least(v_dom, v_hoy);
  v_fr jsonb; v_tr jsonb;
  v_acum numeric; v_util numeric; v_gastos numeric; v_rent numeric; v_com numeric; v_meta numeric; v_meta_dia numeric;
  v_dias jsonb; v_comtop jsonb; v_top jsonb; v_heat jsonb; v_zonas jsonb; v_repos numeric; v_cons int;
begin
  -- ═════ 💰 DINERO ═════
  v_fr := mos.finanzas_rango(to_char(v_lun,'YYYY-MM-DD'), to_char(v_fin,'YYYY-MM-DD'));
  v_acum   := coalesce((v_fr->'data'->'totales'->>'ventasNetas')::numeric, 0);
  v_util   := coalesce((v_fr->'data'->'totales'->>'utilidadNeta')::numeric, 0);
  v_gastos := coalesce((v_fr->'data'->'totales'->>'totalGastos')::numeric, 0);
  v_rent   := coalesce((v_fr->'data'->'totales'->>'margenBrutoPct')::numeric, 0);

  -- META REAL de la semana (completa lun..dom) y META AL DÍA (solo días transcurridos lun..v_fin, para el "ritmo")
  select coalesce(sum(mos._meta_zona(zz.id_zona, gs.d::date)), 0) into v_meta
    from mos.zonas zz cross join generate_series(v_lun, v_dom, interval '1 day') gs(d)
   where coalesce(zz.politica_json ? 'metaDiaria', false);
  select coalesce(sum(mos._meta_zona(zz.id_zona, gs.d::date)), 0) into v_meta_dia
    from mos.zonas zz cross join generate_series(v_lun, v_fin, interval '1 day') gs(d)
   where coalesce(zz.politica_json ? 'metaDiaria', false);

  -- días: venta real (de finanzas_rango) + meta real de ese día
  select jsonb_agg(jsonb_build_object(
      'fecha', to_char(gs.d,'YYYY-MM-DD'),
      'dow', trim(to_char(gs.d,'Dy')),
      'venta', coalesce((select (s->>'ventasNetas')::numeric from jsonb_array_elements(v_fr->'data'->'serie') s where s->>'fecha' = to_char(gs.d,'YYYY-MM-DD')), 0),
      'meta',  (select coalesce(sum(mos._meta_zona(zz.id_zona, gs.d::date)),0) from mos.zonas zz where zz.politica_json ? 'metaDiaria'),
      'futuro', gs.d > v_hoy
    ) order by gs.d) into v_dias
    from generate_series(v_lun, v_dom, interval '1 day') gs(d);

  -- comisiones de la semana + top personas (bono_meta = comisión por excedente sobre meta)
  select coalesce(sum(bono_meta),0) into v_com from mos.liquidaciones_dia where fecha between v_lun and v_fin;
  -- nombre legible: mos.personal → o extraer de la clave "MEX:NOMBRE|ZONA" → o el id crudo
  select coalesce(jsonb_agg(x order by (x->>'monto')::numeric desc), '[]'::jsonb) into v_comtop
    from ( select jsonb_build_object(
                    'nombre', initcap(lower(coalesce(
                       (select btrim(pe.nombre||' '||coalesce(pe.apellido,'')) from mos.personal pe where pe.id_personal = l.id_personal),
                       nullif(btrim(split_part(split_part(l.id_personal,':',2),'|',1)),''),
                       l.id_personal))),
                    'zona', nullif(split_part(l.id_personal,'|',2),''),
                    'monto', round(sum(l.bono_meta),2)) x
             from mos.liquidaciones_dia l
            where l.fecha between v_lun and v_fin and coalesce(l.bono_meta,0) > 0
            group by l.id_personal order by sum(l.bono_meta) desc limit 6 ) t;

  -- ═════ 📦 PRODUCTOS ═════
  select coalesce(jsonb_agg(x order by (x->>'u')::numeric desc), '[]'::jsonb) into v_top
    from ( select jsonb_build_object('nombre', max(dt.nombre), 'sku', dt.sku, 'u', round(sum(dt.cantidad),1)) x
             from me.ventas_detalle dt
             join me.ventas v on v.id_venta = dt.id_venta
            where (v.fecha at time zone 'America/Lima')::date between v_lun and v_fin
              and coalesce(v.zona_id,'') in ('ZONA-01','ZONA-02')
              and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
              and upper(coalesce(v.estado_envio,'')) <> 'ANULADO'
              and nullif(btrim(coalesce(dt.sku,'')),'') is not null
            group by dt.sku order by sum(dt.cantidad) desc limit 7 ) t;

  select count(*) into v_cons from wh.considerados where estado = 'ACTIVO';

  -- reposición media: horas desde que se pidió hasta que se despachó (items ya despachados, últimas 3 sem)
  select round(avg(extract(epoch from ((it->>'tsDespacho')::timestamptz - (it->>'tsSolicitud')::timestamptz))/3600.0)::numeric, 1)
    into v_repos
    from wh.pickups pk cross join lateral jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) it
   where nullif(it->>'tsDespacho','') is not null and nullif(it->>'tsSolicitud','') is not null
     and (it->>'tsDespacho')::timestamptz > now() - interval '21 days'
     and (it->>'tsDespacho')::timestamptz >= (it->>'tsSolicitud')::timestamptz;

  -- ═════ 👥 PERSONAL — carga por hora × zona (tickets + venta) ═════
  select coalesce(jsonb_agg(jsonb_build_object('zona', zona, 'horas', horas) order by zona), '[]'::jsonb) into v_heat
    from ( select q.zona_id zona,
                  jsonb_agg(jsonb_build_object('h', q.hr, 'tk', q.tk, 'venta', q.vt) order by q.hr) horas
             from ( select v.zona_id,
                           extract(hour from (v.fecha at time zone 'America/Lima'))::int hr,
                           count(*) tk, round(sum(v.total)) vt
                      from me.ventas v
                     where (v.fecha at time zone 'America/Lima')::date between v_lun and v_fin
                       and coalesce(v.zona_id,'') in ('ZONA-01','ZONA-02')
                       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
                       and extract(hour from (v.fecha at time zone 'America/Lima')) between 7 and 21
                     group by 1,2 ) q
            group by q.zona_id ) t;

  -- ═════ 🗺️ ZONAS — estancados (bcg=PERRO) + stock por zona ═════
  select coalesce(jsonb_agg(jsonb_build_object(
           'zona', ze.zona_id, 'estancados', ze.perro, 'skus', ze.skus, 'stockU', coalesce(sz.u,0)
         ) order by ze.zona_id), '[]'::jsonb) into v_zonas
    from ( select zona_id, count(*) filter (where upper(coalesce(bcg,''))='PERRO') perro, count(*) skus
             from me.zona_esperado where zona_id in ('ZONA-01','ZONA-02') group by zona_id ) ze
    left join ( select zona_id, round(sum(cantidad)) u from me.stock_zonas
                 where zona_id in ('ZONA-01','ZONA-02') and cantidad between 0 and 1000000 group by zona_id ) sz
      on sz.zona_id = ze.zona_id;

  -- ═════ ⚖️ TRIBUTARIO (mes en curso) ═════
  v_tr := mos.trib_resumen_mes(jsonb_build_object('mes', extract(month from v_hoy)::int, 'anio', extract(year from v_hoy)::int));

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'semana', jsonb_build_object('inicio', to_char(v_lun,'YYYY-MM-DD'), 'fin', to_char(v_dom,'YYYY-MM-DD'),
       'offset', v_off, 'esActual', (v_off = 0),
       'label', to_char(v_lun,'DD') || ' – ' || to_char(v_dom,'DD Mon')),
    'dinero', jsonb_build_object('dias', coalesce(v_dias,'[]'::jsonb), 'acumulado', v_acum, 'meta', v_meta,
       'metaAlDia', v_meta_dia, 'rentabilidad', v_rent, 'utilidad', v_util, 'gastos', v_gastos, 'comisiones', v_com,
       'comisionesTop', v_comtop),
    'productos', jsonb_build_object('top', v_top, 'considerados', v_cons, 'reposHoras', v_repos, 'reposMeta', 2),
    'personal', jsonb_build_object('heat', v_heat),
    'zonas', v_zonas,
    'tributario', coalesce(v_tr->'data','{}'::jsonb) ));
end $function$;
grant execute on function mos.cabina_semanal(jsonb) to authenticated, anon, service_role;

select 'cabina_semanal listo' ok;
