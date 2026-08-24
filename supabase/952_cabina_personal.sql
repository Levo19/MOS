-- [952] CABINA · PLANILLA SEMANAL de personal — al abrir la card de Personal, el detalle de TODO el
-- personal que trabajó la semana, día por día, con sueldo base, envasado, comisión (bono_meta),
-- bonificaciones y descuentos (sanción), agrupado por Almacén / Zona-01 / Zona-02. Para saber el gasto
-- de planilla y a quién se liquida. Fuente: mos.liquidaciones_dia (una fila por persona-turno-día).
create or replace function mos.cabina_personal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_off int := coalesce(nullif(p->>'offset','')::int, 0);
  v_hoy date := (now() at time zone 'America/Lima')::date;
  v_lun date := (v_hoy - (extract(isodow from v_hoy)::int - 1)) + (v_off * 7);
  v_dom date := v_lun + 6;
  v_grupos jsonb; v_tot jsonb;
begin
  with liq as (
    select l.id_personal, l.nombre, l.rol, l.fecha::date fecha,
           coalesce(l.presente, false) presente,
           coalesce(l.monto_base,0) base, coalesce(l.pago_envasado,0) envasado,
           coalesce(l.bono_meta,0) comision, coalesce(l.bonificacion,0) bonif,
           coalesce(l.sancion,0) sancion, coalesce(l.total_dia,0) total,
           case when coalesce(l.zona,'') ~* 'almac' or coalesce(l.rol,'') ~* 'almacen|envasa|cargad' then 'ALMACEN'
                when nullif(btrim(coalesce(l.zona,'')),'') is not null then upper(btrim(l.zona))
                else 'ALMACEN' end grp
      from mos.liquidaciones_dia l
     where l.fecha::date between v_lun and v_dom
  ),
  persona as (
    select grp, id_personal, max(nombre) nombre, max(rol) rol,
           count(*) filter (where presente) dias,
           round(sum(base),2) base, round(sum(envasado),2) envasado, round(sum(comision),2) comision,
           round(sum(bonif),2) bonif, round(sum(sancion),2) sancion, round(sum(total),2) total,
           jsonb_agg(jsonb_build_object(
             'fecha', to_char(fecha,'YYYY-MM-DD'), 'dow', trim(to_char(fecha,'Dy')),
             'base', round(base,2), 'comision', round(comision,2), 'bonif', round(bonif,2),
             'sancion', round(sancion,2), 'total', round(total,2), 'presente', presente) order by fecha) pordia
      from liq group by grp, id_personal
  ),
  grupos as (
    select grp,
           jsonb_build_object('base',round(sum(base),2),'envasado',round(sum(envasado),2),'comision',round(sum(comision),2),
                              'bonif',round(sum(bonif),2),'sancion',round(sum(sancion),2),'total',round(sum(total),2),'personas',count(*)) subtotal,
           jsonb_agg(jsonb_build_object(
             'nombre', initcap(lower(coalesce(nullif(btrim(nombre),''), split_part(split_part(id_personal,':',2),'|',1), id_personal))),
             'rol', rol, 'dias', dias, 'base', base, 'envasado', envasado, 'comision', comision,
             'bonif', bonif, 'sancion', sancion, 'total', total, 'porDia', pordia) order by total desc) personas
      from persona group by grp
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object('zona', grp, 'subtotal', subtotal, 'personas', personas)
       order by case grp when 'ALMACEN' then 0 when 'ZONA-01' then 1 when 'ZONA-02' then 2 else 9 end), '[]'::jsonb) from grupos),
    (select jsonb_build_object('base',round(sum(base),2),'envasado',round(sum(envasado),2),'comision',round(sum(comision),2),
                               'bonif',round(sum(bonif),2),'sancion',round(sum(sancion),2),'total',round(sum(total),2),
                               'personas',count(*),'dias',sum(dias)) from persona)
    into v_grupos, v_tot;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'semana', jsonb_build_object('inicio', to_char(v_lun,'YYYY-MM-DD'), 'fin', to_char(v_dom,'YYYY-MM-DD'),
       'label', to_char(v_lun,'DD') || ' – ' || to_char(v_dom,'DD Mon')),
    'grupos', v_grupos, 'totales', coalesce(v_tot, '{}'::jsonb) ));
end $function$;
grant execute on function mos.cabina_personal(jsonb) to authenticated, anon, service_role;

select 'cabina_personal listo' ok;
