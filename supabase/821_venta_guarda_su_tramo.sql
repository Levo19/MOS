-- 821_venta_guarda_su_tramo.sql — [DUEÑO] "si se cambia alguna presentación o tramo no debe
-- afectar hoy lo que se vendió ayer, ¿no crees? Lo que me das ahora en el detalle es lo que
-- realmente vendiste en ese momento, aun sin mis ajustes que haga a futuro."
--
-- Tiene razón y es la diferencia entre un reporte y un registro. Hoy el tramo de cada venta se
-- RECONSTRUYE con los tramos vigentes: si mañana el ají panca pasa de +5.5% a +8%, las ventas de
-- ayer se re-atribuyen solas y la historia cambia. Un margen histórico que se mueve cuando tocás
-- una configuración no sirve para decidir nada.
--
-- FIX: la venta graba el tramo que se le aplicó, en el momento en que se aplicó.
--   · `segmento_id`     — el id del tramo (o vacío si se cobró al precio base)
--   · `segmento_nombre` — su etiqueta legible tal como estaba ese día
--   · `segmento_pct`    — el ajuste que se cobró, congelado
-- El POS ya conoce los tres cuando calcula el precio: solo hay que mandarlos.
--
-- Las ventas ANTERIORES a este cambio no tienen el dato. Para ellas se sigue reconstruyendo, y el
-- desglose lo dice: mejor una estimación etiquetada que un número que aparenta ser histórico.

alter table me.ventas_detalle add column if not exists segmento_id     text;
alter table me.ventas_detalle add column if not exists segmento_nombre text;
alter table me.ventas_detalle add column if not exists segmento_pct    numeric;

comment on column me.ventas_detalle.segmento_id is
  '[821] Tramo de precio aplicado en el MOMENTO de la venta. Vacío = se cobró al precio base. Congela la historia: cambiar los tramos después ya no reescribe lo vendido.';

-- ── Toda función que grabe líneas de venta debe persistirlo ──
do $$
declare
  r record; v_def text; v_new text; v_n int := 0;
  c_cols constant text := 'insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida)';
  c_cols_new constant text := 'insert into me.ventas_detalle (id_venta, linea, sku, nombre, cantidad, precio, subtotal,
                                   cod_barras, valor_unitario, tipo_igv, unidad_medida,
                                   segmento_id, segmento_nombre, segmento_pct)';
  c_vals constant text := 'coalesce((v_item->>''tipo_igv'')::int,1), coalesce(v_item->>''unidad_medida'',''NIU''))';
  c_vals_new constant text := 'coalesce((v_item->>''tipo_igv'')::int,1), coalesce(v_item->>''unidad_medida'',''NIU''),
            nullif(btrim(coalesce(v_item->>''segmento_id'','''')),''''),
            nullif(btrim(coalesce(v_item->>''segmento_nombre'','''')),''''),
            nullif(v_item->>''segmento_pct'','''')::numeric)';
begin
  for r in
    select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'me' and position(c_cols in p.prosrc) > 0
  loop
    v_def := pg_get_functiondef(r.oid);
    if position(c_cols in v_def) = 0 or position(c_vals in v_def) = 0 then
      raise warning '[821] me.%: no calzó el patrón, se omite', r.proname;
      continue;
    end if;
    v_new := replace(replace(v_def, c_cols, c_cols_new), c_vals, c_vals_new);
    execute v_new;
    v_n := v_n + 1;
    raise notice '[821] me.% ahora guarda el tramo', r.proname;
  end loop;
  if v_n = 0 then raise exception '[821] ninguna función quedó parcheada'; end if;
end $$;


-- ── El desglose prefiere lo GRABADO y solo reconstruye lo viejo ──
create or replace function mos.finanzas_dia_sku_tramos(p jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_fecha text := nullif(btrim(coalesce(p->>'fecha','')),'');
  v_sku   text := upper(btrim(coalesce(p->>'skuBase','')));
  v_d     date;
  v_tramos jsonb;
  v_base  numeric := 0;
  v_costo numeric := 0;
  v_margen numeric;
  v_out   jsonb;
  v_recon int := 0;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_sku = '' then return jsonb_build_object('ok',false,'error','Requiere skuBase'); end if;
  v_d := coalesce(v_fecha::date, (now() at time zone 'America/Lima')::date);

  select t.tramos into v_tramos from mos.precio_tramos t where upper(btrim(t.sku_base)) = v_sku;
  v_margen := coalesce((select nullif(btrim(valor),'')::numeric from mos.config where clave='finMargenDefault' limit 1), 15);

  select coalesce(pr.precio_venta,0), coalesce(pr.precio_costo,0) into v_base, v_costo
    from mos.productos pr
   where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
     and coalesce(nullif(pr.factor_conversion,0),1) = 1
   order by pr.codigo_barra limit 1;

  with vcobr as (
    select v.id_venta from me.ventas v
     where (v.fecha at time zone 'America/Lima')::date = v_d
       and upper(coalesce(v.forma_pago,'')) not like 'ANULADO%'
       and upper(coalesce(v.forma_pago,'')) not in ('POR_COBRAR','CREDITO')
  ),
  lin as (
    select coalesce(d.cantidad,0)::numeric as cant,
           coalesce(d.subtotal, d.precio*d.cantidad, 0)::numeric as ingreso,
           nullif(btrim(coalesce(d.segmento_id,'')),'')     as seg_id,
           nullif(btrim(coalesce(d.segmento_nombre,'')),'') as seg_nom,
           d.segmento_pct                                    as seg_pct,
           (d.segmento_id is not null)                       as grabado
      from me.ventas_detalle d
      join vcobr v on v.id_venta = d.id_venta
     where exists (
       select 1 from mos.productos pr
        where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
          and (upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.cod_barras,'')))
            or upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.sku,'')))
            or upper(btrim(coalesce(pr.id_producto,'')))  = upper(btrim(coalesce(d.sku,''))))
          and coalesce(nullif(pr.factor_conversion,0),1) = 1)
  ),
  clas as (
    -- [821] manda lo GRABADO. Solo si la venta es anterior al cambio se reconstruye con los
    -- tramos vigentes, y se cuenta aparte para poder avisarlo.
    select l.cant, l.ingreso, l.grabado,
           case when l.grabado then l.seg_id
                else (select s.value->>'id' from jsonb_array_elements(coalesce(v_tramos,'[]'::jsonb)) s
                       where (case when coalesce((s.value->>'minIncl')::boolean,true)
                                   then l.cant*1000 >= coalesce((s.value->>'min')::numeric,0)
                                   else l.cant*1000 >  coalesce((s.value->>'min')::numeric,0) end)
                         and (case when coalesce((s.value->>'maxIncl')::boolean,true)
                                   then l.cant*1000 <= coalesce((s.value->>'max')::numeric,1e12)
                                   else l.cant*1000 <  coalesce((s.value->>'max')::numeric,1e12) end)
                       limit 1) end as seg_id,
           case when l.grabado then l.seg_nom
                else (select coalesce(nullif(btrim(s.value->>'nombre'),''),
                             coalesce(s.value->>'min','0')||'–'||coalesce(s.value->>'max','∞')||' g')
                        from jsonb_array_elements(coalesce(v_tramos,'[]'::jsonb)) s
                       where (case when coalesce((s.value->>'minIncl')::boolean,true)
                                   then l.cant*1000 >= coalesce((s.value->>'min')::numeric,0)
                                   else l.cant*1000 >  coalesce((s.value->>'min')::numeric,0) end)
                         and (case when coalesce((s.value->>'maxIncl')::boolean,true)
                                   then l.cant*1000 <= coalesce((s.value->>'max')::numeric,1e12)
                                   else l.cant*1000 <  coalesce((s.value->>'max')::numeric,1e12) end)
                       limit 1) end as seg_nom,
           case when l.grabado then l.seg_pct
                else (select (s.value->>'ajustePct')::numeric from jsonb_array_elements(coalesce(v_tramos,'[]'::jsonb)) s
                       where (case when coalesce((s.value->>'minIncl')::boolean,true)
                                   then l.cant*1000 >= coalesce((s.value->>'min')::numeric,0)
                                   else l.cant*1000 >  coalesce((s.value->>'min')::numeric,0) end)
                         and (case when coalesce((s.value->>'maxIncl')::boolean,true)
                                   then l.cant*1000 <= coalesce((s.value->>'max')::numeric,1e12)
                                   else l.cant*1000 <  coalesce((s.value->>'max')::numeric,1e12) end)
                       limit 1) end as seg_pct
      from lin l
  ),
  grp as (
    select coalesce(c.seg_id,'__base__') as id,
           coalesce(c.seg_nom,'Sin tramo · precio base') as etiqueta,
           coalesce(c.seg_pct,0)   as ajuste,
           (c.seg_id is null)      as es_base,
           bool_and(c.grabado)     as todo_grabado,
           count(*)                as lineas,
           sum(c.cant)             as cantidad,
           mos._r2(sum(c.ingreso)) as ingreso
      from clas c group by 1,2,3,4
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id, 'etiqueta', g.etiqueta, 'ajustePct', g.ajuste, 'esBase', g.es_base,
           'grabado', g.todo_grabado,
           'lineas', g.lineas, 'cantidad', g.cantidad, 'ingreso', g.ingreso,
           'precioKg', case when g.cantidad > 0 then mos._r2(g.ingreso/g.cantidad) else 0 end,
           'precioEsperado', mos._r2(v_base * (1 + g.ajuste/100)),
           'costo', case when v_costo > 0 then mos._r2(g.cantidad * v_costo)
                         else mos._r2(g.ingreso * (1 - v_margen/100)) end,
           'esEstimado', (v_costo <= 0),
           'margenPct', case when v_costo > 0 and g.ingreso > 0
                             then round(((g.ingreso - g.cantidad*v_costo)/g.ingreso)*1000)/10.0 else null end
         ) order by g.es_base, g.ajuste desc), '[]'::jsonb)
    into v_out from grp g;

  select count(*)::int into v_recon
    from me.ventas_detalle d
    join me.ventas v on v.id_venta = d.id_venta
   where (v.fecha at time zone 'America/Lima')::date = v_d
     and d.segmento_id is null
     and exists (select 1 from mos.productos pr
                  where upper(btrim(coalesce(pr.sku_base,''))) = v_sku
                    and coalesce(nullif(pr.factor_conversion,0),1) = 1
                    and (upper(btrim(coalesce(pr.codigo_barra,''))) = upper(btrim(coalesce(d.cod_barras,'')))
                      or upper(btrim(coalesce(pr.id_producto,''))) = upper(btrim(coalesce(d.sku,'')))));

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'skuBase', v_sku,
    'tieneTramos', (v_tramos is not null and jsonb_typeof(v_tramos)='array' and jsonb_array_length(v_tramos) > 0)
                   or jsonb_array_length(coalesce(v_out,'[]'::jsonb)) > 1,
    'precioBase', v_base, 'costoUnit', v_costo, 'margenDefault', v_margen,
    'reconstruidas', v_recon,
    'tramos', coalesce(v_out,'[]'::jsonb)));
end;
$function$;

grant execute on function mos.finanzas_dia_sku_tramos(jsonb) to anon, authenticated, service_role;
