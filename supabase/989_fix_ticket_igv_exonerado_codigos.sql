-- [989] FIX ticket impreso: los codigos reales de tipo_igv son 1=gravado, 8=EXONERADO, 9=INAFECTO
--  (no 2/3). fac.ticket_comprobante clasificaba exon como in(2,3) → perdia los 8/9 → boletas exoneradas
--  mostraban solo TOTAL (sin OP. EXONERADA ni IGV 0). Se agregan 8,9 al set. Solo presentacion (el XML/CDR
--  en SUNAT ya lleva el tipo_igv correcto por linea).
CREATE OR REPLACE FUNCTION fac.ticket_comprobante(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idVenta','')), '');
  v_v    me.ventas%rowtype;
  v_cfg  fac.config%rowtype;
  v_cpe  fac.comprobantes%rowtype;
  v_items jsonb;
  v_qr   text;
  v_hash text;
  v_grav numeric;
  v_igv  numeric;
  v_exon numeric;
  v_grav_cigv numeric;
  v_es_cpe boolean;
begin
  -- [FIX seguridad] gate de claim: solo apps del ecosistema (mos._claim_ok permite '' service_role + 'MOS').
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'idVenta requerido'); end if;
  select * into v_v from me.ventas where id_venta = v_id limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'venta no encontrada'); end if;
  select * into v_cfg from fac.config where id = 1 limit 1;
  v_es_cpe := v_v.tipo_doc in ('BOLETA','FACTURA');

  begin
    select * into v_cpe from fac.comprobantes
     where (serie || '-' || numero) = v_v.correlativo or ref_externa = v_id
     order by creado_at desc nulls last limit 1;
  exception when others then v_cpe := null; end;

  -- [FIX QR] CPE: SOLO QR SUNAT real (fac.comprobantes o me.ventas.nf_qr). NUNCA el correlativo (no es QR válido).
  --          NV: el correlativo como QR es aceptable (no es comprobante electrónico).
  if v_es_cpe then
    v_qr := coalesce(nullif(v_cpe.nf_qr,''), nullif(v_v.nf_qr,''), '');
  else
    v_qr := coalesce(nullif(v_v.nf_qr,''), v_v.correlativo);
  end if;
  v_hash := coalesce(nullif(v_cpe.nf_hash,''), nullif(v_v.nf_hash,''), '');

  -- [FIX IGV] preferir el CPE fiel (fac.comprobantes). Si no, derivar POR LÍNEA según tipo_igv real:
  --   tipo_igv=1 (gravado) → base = subtotal/1.18, IGV = subtotal-base ; tipo_igv 2/3 (exo/inafecto) → sin IGV.
  if v_es_cpe then
    if v_cpe.total_igv is not null then
      v_grav := v_cpe.total_gravada; v_igv := v_cpe.total_igv;
      v_exon := coalesce(v_cpe.total_exonerada,0) + coalesce(v_cpe.total_inafecta,0);
    else
      select
        coalesce(sum(case when coalesce(d.tipo_igv,1)=1 then d.subtotal else 0 end),0),
        coalesce(sum(case when coalesce(d.tipo_igv,1) in (2,3,8,9) then d.subtotal else 0 end),0)
        into v_grav_cigv, v_exon
        from me.ventas_detalle d where d.id_venta = v_id;
      v_grav := round(v_grav_cigv / 1.18, 2);
      v_igv  := round(v_grav_cigv - v_grav, 2);
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
            'linea', d.linea, 'nombre', d.nombre, 'cantidad', d.cantidad,
            'precio', d.precio, 'subtotal', d.subtotal, 'unidadMedida', d.unidad_medida
          ) order by d.linea), '[]'::jsonb)
    into v_items from me.ventas_detalle d where d.id_venta = v_id;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'empresa', jsonb_build_object(
        'ruc', v_cfg.empresa_ruc, 'razonSocial', v_cfg.empresa_razon_social,
        'direccion', v_cfg.empresa_direccion, 'telefono', v_cfg.empresa_telefono, 'email', v_cfg.empresa_email),
    'idVenta', v_v.id_venta, 'tipoDoc', v_v.tipo_doc, 'correlativo', v_v.correlativo,
    'fecha', v_v.fecha, 'vendedor', v_v.vendedor, 'zonaId', v_v.zona_id,
    'clienteDoc', v_v.cliente_doc, 'clienteNombre', v_v.cliente_nombre, 'tipoDocCliente', v_v.tipo_doc_cliente,
    'total', v_v.total, 'formaPago', v_v.forma_pago, 'obs', v_v.obs,
    'nfEstado', v_v.nf_estado, 'nfHash', v_hash, 'nfQr', v_qr, 'esCPE', v_es_cpe,
    'totalGravada', v_grav, 'totalIgv', v_igv, 'totalExonerada', v_exon,
    'items', v_items
  ));
end;
$function$
;

select '989 fix ticket igv exonerado codigos listo' as ok;
