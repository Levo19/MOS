-- 600_cpe_recon_rechazo_transitorio.sql — [CPE · RECHAZADO transitorio SE AUTO-SANA]
-- Incidente FM02-11 (2026-07-30, S/209 FLORES QUISPE): SUNAT respondió soap-env:Server.0140
-- ("Existe un Documento igual en Proceso") — congestión de SUNAT, NO un rechazo del comprobante.
-- El primer envío SÍ quedó registrado (el reintento devuelve 1033 "informado anteriormente").
-- Nuestro lado la marcó nf_estado='RECHAZADO' (code 'PEN') y me.cpe_recon_candidatos EXCLUYE los
-- RECHAZADO → quedó congelada para siempre (ult. consulta 07-30 12:59).
--
-- Fix: los RECHAZADO cuyo nf_sunat_code NO es un rechazo real de SUNAT vuelven a la cola del
-- reconciliador (cron cada ciclo, ventana 45d). Taxonomía SUNAT: 0100-0999 = excepción del sistema
-- (reintentable) · 1000-1999 = error de proceso/envío (1033 = ya registrado → al consultar aparece
-- aceptado) · 2000-3999 = RECHAZO real del comprobante (terminal) · 4000+ = aceptado con observación.
-- Solo 2000-3999 queda terminal; el resto ('PEN', '', 0140, 1033…) se re-consulta hasta resolverse
-- o hasta salir de la ventana de 45 días (autolimitado, ≤80 por pasada).

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
           -- [600] RECHAZADO con código TRANSITORIO (no 2000-3999) → re-consultar hasta sanar.
           -- Un 0140/1033/'PEN' no es rechazo: el doc suele estar registrado y solo falta el CDR.
           or ( coalesce(v.nf_estado,'') = 'RECHAZADO'
                and coalesce(v.nf_sunat_code,'') !~ '^0*[23][0-9]{3}$' )
           -- anulada que aún debe comunicar (o reintentar) la baja
           or ( upper(coalesce(v.forma_pago,'')) like 'ANULADO%'
                and coalesce(v.nf_estado,'') in ('EMITIDO','ANULADO_PEND_BAJA','BAJA_SOLICITADA','BAJA_ERROR') )
         )
   order by v.fecha desc
   limit greatest(1, least(coalesce(p_limite,80), 200))
$function$;
