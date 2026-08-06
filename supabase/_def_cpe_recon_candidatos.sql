CREATE OR REPLACE FUNCTION me.cpe_recon_candidatos(p_dias integer DEFAULT 45, p_limite integer DEFAULT 80)
 RETURNS TABLE(ref_local text, id_venta text, correlativo text, tipo_doc text, nf_estado text, forma_pago text, anulada boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select v.ref_local, v.id_venta, v.correlativo, v.tipo_doc,
         coalesce(v.nf_estado,'') as nf_estado,
         coalesce(v.forma_pago,'') as forma_pago,
         (upper(coalesce(v.forma_pago,'')) like 'ANULADO%') as anulada
    from me.ventas v
   where v.tipo_doc in ('BOLETA','FACTURA')
     and coalesce(v.correlativo,'') <> ''
     and v.fecha >= (current_date - make_interval(days => greatest(1, least(coalesce(p_dias,45), 90))))
     and (
           -- normal: aún esperando el CDR de SUNAT
           coalesce(v.nf_estado,'') in ('','PENDIENTE','EMITIENDO')
           -- anulada que aún debe comunicar (o reintentar) la baja
           or ( upper(coalesce(v.forma_pago,'')) like 'ANULADO%'
                and coalesce(v.nf_estado,'') in ('EMITIDO','ANULADO_PEND_BAJA','BAJA_SOLICITADA','BAJA_ERROR') )
         )
   order by v.fecha desc
   limit greatest(1, least(coalesce(p_limite,80), 200))
$function$
