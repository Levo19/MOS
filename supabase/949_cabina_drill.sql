-- [949] Detalle (drill-down) de la Cabina Semanal — cierra los 3 pendientes con datos REALES:
--   tipo='dia'  → comisión repartida ESE día por vendedor (liquidaciones_dia.bono_meta).
--   tipo='hora' → quién estuvo activo a esa hora en esa zona en la semana (me.ventas por vendedor).
--   tipo='zona' → lista de productos ESTANCADOS (bcg=PERRO) de la zona, con su stock en zona.
create or replace function mos.cabina_drill(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_tipo text := coalesce(p->>'tipo','');
  v_zona text := coalesce(p->>'zona','');
  v_off  int  := coalesce(nullif(p->>'offset','')::int, 0);
  v_hoy  date := (now() at time zone 'America/Lima')::date;
  v_lun  date := (v_hoy - (extract(isodow from v_hoy)::int - 1)) + (v_off * 7);
  v_fin  date := least(v_lun + 6, v_hoy);
  v_hr   int  := coalesce(nullif(p->>'hora','')::int, -1);
  v_fecha date;
  v_out jsonb;
begin
  -- nombre legible de una clave de crédito ("MEX:NOMBRE|ZONA" | id_personal | nombre)
  -- (se usa abajo inline)
  if v_tipo = 'dia' then
    begin v_fecha := (p->>'fecha')::date; exception when others then return jsonb_build_object('ok',false,'error','fecha inválida'); end;
    select coalesce(jsonb_agg(jsonb_build_object(
             'nombre', initcap(lower(coalesce(
                (select btrim(pe.nombre||' '||coalesce(pe.apellido,'')) from mos.personal pe where pe.id_personal = l.id_personal),
                nullif(btrim(split_part(split_part(l.id_personal,':',2),'|',1)),''), l.id_personal))),
             'zona', coalesce(nullif(split_part(l.id_personal,'|',2),''), l.zona),
             'rol', l.rol, 'vendido', round(coalesce(l.venta_cobrada,0),2), 'comision', round(coalesce(l.bono_meta,0),2)
           ) order by l.bono_meta desc, l.venta_cobrada desc), '[]'::jsonb)
      into v_out
      from mos.liquidaciones_dia l
     where l.fecha::date = v_fecha and coalesce(l.bono_meta,0) > 0;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('fecha', to_char(v_fecha,'YYYY-MM-DD'), 'comisiones', v_out));

  elsif v_tipo = 'hora' then
    select coalesce(jsonb_agg(jsonb_build_object('nombre', vendedor, 'tickets', tk, 'venta', vt) order by tk desc), '[]'::jsonb)
      into v_out
      from ( select coalesce(nullif(btrim(v.vendedor),''),'(sin nombre)') vendedor, count(*) tk, round(sum(v.total)) vt
               from me.ventas v
              where (v.fecha at time zone 'America/Lima')::date between v_lun and v_fin
                and coalesce(v.zona_id,'') = v_zona
                and extract(hour from (v.fecha at time zone 'America/Lima'))::int = v_hr
                and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
              group by 1 order by count(*) desc limit 12 ) q;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('zona', v_zona, 'hora', v_hr, 'quienes', v_out));

  elsif v_tipo = 'zona' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'nombre', coalesce(nom.nombre, ze.sku_base), 'sku', ze.sku_base,
             'vol4sem', round(coalesce(ze.volumen_4sem,0)::numeric, 2),
             'tendencia', ze.tendencia,
             'stock', coalesce(st.u, 0)
           ) order by coalesce(ze.volumen_4sem,0) asc), '[]'::jsonb)
      into v_out
      from me.zona_esperado ze
      left join lateral ( select (array_agg(pr.descripcion order by length(coalesce(pr.descripcion,'')) desc))[1] nombre
                            from mos.productos pr where pr.sku_base = ze.sku_base and nullif(btrim(coalesce(pr.descripcion,'')),'') is not null ) nom on true
      left join lateral ( select round(sum(sz.cantidad)) u from me.stock_zonas sz
                           join mos.productos pr2 on btrim(pr2.codigo_barra) = btrim(sz.cod_barras)
                          where sz.zona_id = ze.zona_id and pr2.sku_base = ze.sku_base and sz.cantidad between 0 and 1000000 ) st on true
     where ze.zona_id = v_zona and upper(coalesce(ze.bcg,'')) = 'PERRO'
     limit 40;
    return jsonb_build_object('ok',true,'data', jsonb_build_object('zona', v_zona, 'estancados', v_out));
  end if;
  return jsonb_build_object('ok',false,'error','tipo inválido');
end $function$;
grant execute on function mos.cabina_drill(jsonb) to authenticated, anon, service_role;

select 'cabina_drill listo' ok;
