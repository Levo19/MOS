-- [953] CABINA · mapa de calor POR DÍA de la semana (lun→dom). El reloj de la card promedia toda la
-- semana; esto abre el detalle: para cada día, la actividad hora×zona (tickets+venta), con una escala
-- de color común (maxVenta de la semana) para que los días sean comparables entre sí.
create or replace function mos.cabina_heat_dias(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_off int := coalesce(nullif(p->>'offset','')::int, 0);
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_lun date := (v_hoy - (extract(isodow from v_hoy)::int - 1)) + (v_off * 7);
  v_dom date := v_lun + 6;
  v_fin date := least(v_dom, v_hoy);
  v_max numeric; v_dias jsonb;
begin
  create temporary table _hb on commit drop as
    select (v.fecha at time zone 'America/Lima')::date dia,
           v.zona_id zona,
           extract(hour from (v.fecha at time zone 'America/Lima'))::int hr,
           count(*) tk, round(sum(v.total)) vt
      from me.ventas v
     where (v.fecha at time zone 'America/Lima')::date between v_lun and v_fin
       and coalesce(v.zona_id,'') in ('ZONA-01','ZONA-02')
       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
       and extract(hour from (v.fecha at time zone 'America/Lima')) between 7 and 21
     group by 1,2,3;

  select coalesce(max(vt),1) into v_max from _hb;

  select jsonb_agg(jsonb_build_object(
           'fecha', to_char(gs.d,'YYYY-MM-DD'),
           'dow', trim(to_char(gs.d,'Dy')),
           'futuro', gs.d > v_hoy,
           'total', coalesce((select round(sum(vt)) from _hb where dia = gs.d::date), 0),
           'tickets', coalesce((select sum(tk) from _hb where dia = gs.d::date), 0),
           'heat', coalesce((
              select jsonb_agg(jsonb_build_object('zona', zona,
                       'horas', (select jsonb_agg(jsonb_build_object('h', hr, 'tk', tk, 'venta', vt) order by hr)
                                   from _hb b2 where b2.dia = gs.d::date and b2.zona = z.zona)) order by zona)
                from (select distinct zona from _hb where dia = gs.d::date) z
           ), '[]'::jsonb)
         ) order by gs.d) into v_dias
    from generate_series(v_lun, v_dom, interval '1 day') gs(d);

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'semana', jsonb_build_object('inicio', to_char(v_lun,'YYYY-MM-DD'), 'fin', to_char(v_dom,'YYYY-MM-DD'),
       'label', to_char(v_lun,'DD') || ' – ' || to_char(v_dom,'DD Mon')),
    'maxVenta', v_max, 'dias', coalesce(v_dias, '[]'::jsonb) ));
end $function$;
grant execute on function mos.cabina_heat_dias(jsonb) to authenticated, anon, service_role;

select 'cabina_heat_dias listo' ok;
