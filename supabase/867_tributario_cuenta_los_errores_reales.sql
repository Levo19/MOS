-- 867 · La franja de alerta de Tributario nunca se encendió, con 56 comprobantes trabados.
--
-- me.tributario_ventas_mes contaba como error solo `nf_estado in ('RECHAZADO_SUNAT','ERROR')`.
-- Esos dos estados NO EXISTEN en los datos: cuando NubeFact rechaza, la venta se queda en
-- PENDIENTE. Así que `cpeErrores` daba 0 siempre, la franja de alerta no aparecía y el
-- subtítulo del card decía "50 pendientes" como si fuera lo normal.
--
-- El criterio nuevo es el MISMO del vigilante que manda el push (me.cpe_pendientes_viejos):
-- es un error lo que no llegó a NubeFact pasada su ventana. Que la pantalla y la notificación
-- cuenten distinto es peor que no contar: uno de los dos miente y no se sabe cuál.
--
--   FACTURA  → 20 min (van una por una, se aceptan en segundos)
--   BOLETA   → 25 h  (viajan en el resumen diario; antes de eso PENDIENTE es lo normal)
--
-- Una boleta que ya tiene hash está en NubeFact esperando a SUNAT: eso no es un error, es el
-- camino normal, y sigue contando como pendiente.

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'me' and p.proname = 'tributario_ventas_mes';

  v_new := replace(v_def,
$old$    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA') and v.nf_estado in ('RECHAZADO_SUNAT','ERROR')) as cpe_errores,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA')
                       and coalesce(v.nf_estado,'') in ('PENDIENTE','','NA'))                                 as cpe_pendientes$old$,
$new$    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA')
                       and ( v.nf_estado in ('RECHAZADO','RECHAZADO_SUNAT','ERROR')
                          or ( coalesce(v.nf_hash,'') = ''
                               and coalesce(v.nf_estado,'PENDIENTE') in ('PENDIENTE','','NA')
                               and extract(epoch from (now() - v.fecha))/60 >
                                   (case when v.tipo_doc = 'FACTURA' then 20 else 1500 end) ) ))              as cpe_errores,
    count(*) filter (where v.tipo_doc in ('BOLETA','FACTURA')
                       and coalesce(v.nf_estado,'') in ('PENDIENTE','','NA')
                       and not ( coalesce(v.nf_hash,'') = ''
                                 and extract(epoch from (now() - v.fecha))/60 >
                                     (case when v.tipo_doc = 'FACTURA' then 20 else 1500 end) ))              as cpe_pendientes$new$);

  if v_new = v_def then raise exception '867: no calzó el bloque de cpe_errores'; end if;
  execute v_new;
end $mig$;

-- comprobación en vivo: hoy no debe haber errores (los 56 ya se emitieron)
select (me.tributario_ventas_mes(8, 2026)->>'cpeErrores')   errores,
       (me.tributario_ventas_mes(8, 2026)->>'cpePendientes') pendientes,
       (me.tributario_ventas_mes(8, 2026)->>'cpeEmitidos')   emitidos;
