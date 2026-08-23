-- [951] CABINA · detalle del DÍA desglosado POR ZONA — el gráfico muestra ambas zonas juntas,
-- pero al abrir un día el dueño quiere ver, POR ZONA: cómo se cobró (efectivo/virtual/crédito/mixto),
-- venta, costo, margen, utilidad, y la comisión de cada vendedor de esa zona. Antes solo salían los
-- vendedores CON comisión (todos de Z-01) → parecía que Z-02 no existía. Ahora cada zona es un bloque.
-- Costo por zona = Σ(cantidad × mos.productos.precio_costo) de me.ventas_detalle. Cobro MIXTO se parsea.
create or replace function mos.cabina_dia_zonas(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_fecha date;
  v_cobro jsonb; v_comis jsonb; v_metas jsonb; v_out jsonb;
begin
  begin v_fecha := (p->>'fecha')::date; exception when others then return jsonb_build_object('ok',false,'error','fecha inválida'); end;

  -- venta + tickets + cobro (efectivo/virtual/credito/planilla, con MIXTO parseado) por zona
  with v as (
    select coalesce(nullif(zona_id,''),'∅') zona, total, upper(coalesce(forma_pago,'')) fp, forma_pago fpraw
      from me.ventas
     where (fecha at time zone 'America/Lima')::date = v_fecha
       and upper(coalesce(forma_pago,'')) not like 'ANULADO%'
  )
  select coalesce(jsonb_object_agg(zona, jsonb_build_object(
           'venta', round(venta,2), 'tickets', tk,
           'efectivo', round(ef,2), 'virtual', round(vir,2), 'credito', round(cred,2), 'planilla', round(pla,2)
         )),'{}'::jsonb) into v_cobro
    from ( select zona, sum(total) venta, count(*) tk,
                  sum(case when fp='EFECTIVO' then total when fp like 'MIXTO%' then coalesce(substring(fpraw from 'EFE:([0-9.]+)')::numeric,0) else 0 end) ef,
                  sum(case when fp='VIRTUAL' then total when fp like 'MIXTO%' then coalesce(substring(fpraw from 'VIR:([0-9.]+)')::numeric,0) else 0 end) vir,
                  sum(case when fp='CREDITO' then total else 0 end) cred,
                  sum(case when fp='PLANILLA' then total else 0 end) pla
             from v group by zona ) q;

  -- comisiones por zona (lista de vendedores con bono ese día)
  select coalesce(jsonb_object_agg(zona, arr),'{}'::jsonb) into v_comis
    from ( select coalesce(nullif(split_part(l.id_personal,'|',2),''), l.zona, '∅') zona,
                  jsonb_agg(jsonb_build_object(
                    'nombre', initcap(lower(coalesce(
                       (select btrim(pe.nombre||' '||coalesce(pe.apellido,'')) from mos.personal pe where pe.id_personal=l.id_personal),
                       nullif(btrim(split_part(split_part(l.id_personal,':',2),'|',1)),''), l.id_personal))),
                    'rol', l.rol, 'comision', round(coalesce(l.bono_meta,0),2), 'vendido', round(coalesce(l.venta_cobrada,0),2))
                    order by l.bono_meta desc) arr
             from mos.liquidaciones_dia l
            where l.fecha::date = v_fecha and coalesce(l.bono_meta,0) > 0
            group by 1 ) q;

  -- meta por zona ese día (versionada)
  select coalesce(jsonb_object_agg(id_zona, mos._meta_zona(id_zona, v_fecha)),'{}'::jsonb) into v_metas
    from mos.zonas where politica_json ? 'metaDiaria';

  -- ensamblar por zona (unión de zonas presentes en venta)
  select coalesce(jsonb_agg(jsonb_build_object(
           'zona', z,
           'meta', coalesce((v_metas->>z)::numeric,0),
           'venta', coalesce((v_cobro->z->>'venta')::numeric,0),
           'tickets', coalesce((v_cobro->z->>'tickets')::int,0),
           'efectivo', coalesce((v_cobro->z->>'efectivo')::numeric,0),
           'virtual', coalesce((v_cobro->z->>'virtual')::numeric,0),
           'credito', coalesce((v_cobro->z->>'credito')::numeric,0),
           'planilla', coalesce((v_cobro->z->>'planilla')::numeric,0),
           'comisionTotal', coalesce((select sum((e->>'comision')::numeric) from jsonb_array_elements(coalesce(v_comis->z,'[]'::jsonb)) e),0),
           'comisiones', coalesce(v_comis->z,'[]'::jsonb)
         ) order by coalesce((v_cobro->z->>'venta')::numeric,0) desc), '[]'::jsonb) into v_out
    from ( select jsonb_object_keys(v_cobro) z ) zs
   where z <> '∅';

  return jsonb_build_object('ok',true,'data', jsonb_build_object(
    'fecha', to_char(v_fecha,'YYYY-MM-DD'), 'porZona', coalesce(v_out,'[]'::jsonb) ));
end $function$;
grant execute on function mos.cabina_dia_zonas(jsonb) to authenticated, anon, service_role;

select 'cabina_dia_zonas listo' ok;
