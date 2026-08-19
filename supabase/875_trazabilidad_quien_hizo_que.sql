-- 875 · Tributario: cada comprobante dice QUIÉN lo emitió y trae su historial
-- (quién cobró, quién anuló, quién cambió la forma de pago, quién dio crédito, cuándo y por qué).
-- Todo ya existía en me.ventas (vendedor, historial_cambios); solo no viajaba al card.
-- De paso, las líneas del comprobante para el voucher-imagen completo.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'cpe_trazabilidad';
  v_new := replace(v_def,
$old$      'zona', v.zona_id, 'vendedor', v.vendedor$old$,
$new$      'zona', v.zona_id, 'vendedor', v.vendedor,
      'formaPago', v.forma_pago, 'estacion', v.estacion, 'idCaja', v.id_caja,
      'tipoDocCliente', v.tipo_doc_cliente,
      -- el historial: lo que le pasó a la venta después de emitirse, con su autor
      'historial', coalesce((
        select jsonb_agg(jsonb_build_object(
            'ts', h->>'ts', 'accion', h->>'accion', 'usuario', h->>'usuario',
            'motivo', h->>'motivo', 'autorizadoPor', h->>'autorizadoPor',
            'de', (h->'cambios'->0->>'antes'), 'a', (h->'cambios'->0->>'despues'))
          order by (h->>'ts'))
        from jsonb_array_elements(case when jsonb_typeof(v.historial_cambios)='array' then v.historial_cambios else '[]'::jsonb end) h
      ), '[]'::jsonb),
      'lineas', coalesce((
        select jsonb_agg(jsonb_build_object('nombre', d.nombre, 'cantidad', d.cantidad, 'precio', d.precio,
                                            'subtotal', d.subtotal, 'um', coalesce(d.unidad_medida,'NIU'), 'tipoIgv', d.tipo_igv)
                         order by d.linea)
        from me.ventas_detalle d where d.id_venta = v.id_venta
      ), '[]'::jsonb)$new$);
  if v_new = v_def then raise exception '875: no calzó cpe_trazabilidad'; end if;
  execute v_new;
end $mig$;
select 'ok' r;
