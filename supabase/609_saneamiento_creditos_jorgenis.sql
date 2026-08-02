-- 609 · Saneamiento créditos de Jorgenis (pre-572) + normalización de documento.
--
-- CONTEXTO: el descuento automático de créditos del personal en la liquidación
-- (572, autoConsumos server-truth) existe desde el 07/07/2026. Los tickets
-- CREDITO de Jorgenis ANTERIORES (15/05–26/06, S/ 169.20 en 26 tickets) quedaron
-- huérfanos: sus semanas ya se liquidaron y el barrido solo mira días que se
-- pagan ahora. Luis confirmó (02/08/2026): "dalos por liquidados".
--
-- Además: 2 tickets tienen el documento SIN los ceros iniciales ('8539040',
-- '08539040') — el match de planilla es exacto contra mos.personal.documento
-- ('008539040'), así que esos escapaban a todo. Se normalizan PRIMERO para que
-- el barrido PLANILLA los alcance y para que el futuro autoConsumos los vea.
--
-- Idempotente: ambos updates filtran por el estado que corrigen.

do $$
declare
  v_doc_master text;
  v_n_doc int;
  v_n_liq int;
begin
  -- Documento canónico desde personal MASTER (no hardcodear por si cambia)
  select btrim(documento) into v_doc_master
    from mos.personal where nombre ilike '%jorgenis%' limit 1;
  if v_doc_master is null or v_doc_master = '' then
    raise exception 'No se encontró documento de Jorgenis en mos.personal';
  end if;

  -- 1) Normalizar variantes de documento en TODOS sus tickets (cualquier forma_pago):
  --    misma persona, doc = master sin ceros a la izquierda → doc master exacto.
  update me.ventas v
     set cliente_doc = v_doc_master,
         updated_at  = now()
   where v.cliente_nombre ilike '%jorgenis%'
     and btrim(coalesce(v.cliente_doc,'')) <> v_doc_master
     and ltrim(btrim(coalesce(v.cliente_doc,'')), '0') = ltrim(v_doc_master, '0')
     and btrim(coalesce(v.cliente_doc,'')) <> '';
  get diagnostics v_n_doc = row_count;

  -- 2) Dar por liquidados los CREDITO del 15/05 al 26/06 (fechas Lima, inclusive)
  update me.ventas v
     set forma_pago = 'PLANILLA',
         historial_cambios = me._venta_hist_append(v.historial_cambios, jsonb_build_object(
           'ts', to_jsonb(now()), 'usuario', 'Luis', 'rol', 'MASTER',
           'source', 'MOS_SANEAMIENTO_PRE572', 'accion', 'descuento_planilla',
           'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','CREDITO','despues','PLANILLA')),
           'motivo', 'Saneamiento: créditos 15/05–26/06 dados por liquidados (anteriores al descuento automático 572) — orden de Luis 02/08/2026')),
         updated_at = now()
   where btrim(coalesce(v.cliente_doc,'')) = v_doc_master
     and upper(coalesce(v.forma_pago,'')) = 'CREDITO'
     and (v.fecha at time zone 'America/Lima')::date between date '2026-05-15' and date '2026-06-26';
  get diagnostics v_n_liq = row_count;

  raise notice '609: documentos normalizados=% · créditos saneados a PLANILLA=%', v_n_doc, v_n_liq;
end $$;
