-- 868 · Tributario decía S/3,480.36 de IGV en contra. Lo declarado a SUNAT es S/3,332.42.
--
-- me.tributario_ventas_mes calculaba el IGV como total × 18/118 de CADA comprobante, como si
-- todo fuera gravado. Desde que hay 158 productos exonerados eso sobrestima: en agosto,
-- S/147.86 de más (4.4%), verificado contra el Excel de NubeFact (gravada S/18,488.08 ·
-- exonerada S/994.70 · IGV S/3,332.42). Y crece con cada venta con un exonerado.
--
-- El dato correcto ya existe: me.ventas_detalle guarda tipo_igv por línea. El IGV es la
-- suma de (subtotal − subtotal/1.18) SOLO de las líneas gravadas. Y acá hay una sutileza
-- que vale la pena dejar escrita: entre el 14 y el 18 de agosto un tipo_igv=9 significaba
-- exonerado, y desde el 866 significa inafecto — pero da igual para este cálculo, porque
-- lo único gravado al 18% en las dos épocas es el 1. Las líneas con tipo_igv null (antes del
-- 8 de abril) eran todas gravadas y se tratan como 1.
--
-- Lo mismo se expone en me.cpe_trazabilidad como 'igv' por comprobante: la lista dejará de
-- decir "≈" y de derivarlo del total.

begin;

-- el IGV real de una venta, por sus líneas
create or replace function me._igv_venta(p_id_venta text, p_total numeric)
returns numeric
language sql
stable
set search_path to ''
as $$
  select coalesce(
    -- MISMA aritmética que emitir-cpe / NubeFact: cada línea redondea su valor de venta a 2
    -- decimales y su IGV a 2 decimales, y recién se suma. Sumar y redondear al final daba
    -- S/3.82 de diferencia en el mes: centavos por línea que se acumulan sobre 444 documentos.
    (select sum(case
              when coalesce(d.tipo_igv, 1) = 1  then round(d.subtotal - round(d.subtotal / 1.18, 2), 2)
              when d.tipo_igv = 17               then round(d.subtotal - round(d.subtotal / 1.04, 2), 2)
              else 0 end)
       from me.ventas_detalle d where d.id_venta = p_id_venta),
    -- sin detalle (ventas muy viejas): la estimación de siempre
    round(coalesce(p_total, 0) - coalesce(p_total, 0) / 1.18, 2));
$$;

commit;

do $mig$
declare v_def text; v_new text;
begin
  -- A) el total del mes
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'tributario_ventas_mes';
  v_new := replace(v_def,
$old$      case when v.tipo_doc in ('BOLETA','FACTURA')
           then round(coalesce(v.total,0) - (coalesce(v.total,0) / 1.18), 2)
           else 0 end$old$,
$new$      case when v.tipo_doc in ('BOLETA','FACTURA')
           then me._igv_venta(v.id_venta, v.total)
           else 0 end$new$);
  if v_new = v_def then raise exception '868: no calzó total_igv'; end if;
  execute v_new;

  -- B) el IGV por comprobante en la lista
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'cpe_trazabilidad';
  v_new := replace(v_def,
$old$      'tipo', v.tipo_doc, 'fecha', v.fecha, 'total', v.total,$old$,
$new$      'tipo', v.tipo_doc, 'fecha', v.fecha, 'total', v.total,
      'igv', me._igv_venta(v.id_venta, v.total),$new$);
  if v_new = v_def then raise exception '868: no calzó cpe_trazabilidad'; end if;
  execute v_new;
end $mig$;

-- comprobación: tiene que acercarse a los S/3,332.42 de NubeFact (agosto, sin anulados)
select (me.tributario_ventas_mes(8, 2026)->>'totalIGVEmitido') igv_tributario_ahora;
