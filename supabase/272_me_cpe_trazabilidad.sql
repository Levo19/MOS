-- 272_me_cpe_trazabilidad.sql — Trazabilidad fiscal completa del CPE en Supabase (cero-GAS).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- PROBLEMA: hoy me.ventas solo guarda nf_estado/nf_hash/nf_enlace/nf_qr. No se puede DISTINGUIR
--   "aceptado por NubeFact" (NubeFact firmó+generó el XML, tiene hash/QR/PDF) de "aceptado por SUNAT"
--   (SUNAT devolvió el CDR de conformidad). El Edge emitir-cpe YA recibe de NubeFact: aceptada_por_sunat,
--   sunat_description, sunat_responsecode, enlace_del_xml, enlace_del_cdr, numero_de_orden_sunat — pero el
--   front los DESCARTA (solo arma 4 campos) y set_cpe_nf no tiene dónde guardarlos. La única trazabilidad
--   viva era el panel Tributario de MOS, que lee la Hoja vía GAS (viola cero-GAS).
--
-- VOCABULARIO DE ESTADO DE ENVÍO (nf_estado) — fuente única de verdad:
--   PENDIENTE  = generado y ACEPTADO POR NUBEFACT (hash/QR/PDF válidos), esperando el CDR de SUNAT.
--   EMITIDO    = ACEPTADO POR SUNAT (CDR recibido, aceptada_por_sunat=true). Comprobante 100% válido.
--   RECHAZADO  = SUNAT lo rechazó (aceptada_por_sunat=false + código/descripción de error).
--   BAJA       = anulado por comunicación de baja a SUNAT.
--   '' / NULL  = aún no se intentó emitir (no debería persistir para un CPE; crear_cpe_directo nace PENDIENTE).
-- Señales de trazabilidad para MOS:
--   · aceptado_por_nubefact = (nf_hash <> '')            → NubeFact firmó/generó el documento.
--   · aceptado_por_sunat    = nf_aceptada_sunat = true   → SUNAT emitió CDR de conformidad.
--   · nf_enlace_cdr         = constancia SUNAT (CDR) descargable; nf_enlace_xml = XML firmado.
--   · nf_sunat_code/desc    = respuesta literal de SUNAT (motivo de rechazo / observación).
--   · nf_ultima_consulta    = cuándo se reconcilió por última vez contra NubeFact (frescura del estado).
-- Additivo, idempotente, money/fiscal-safe (solo agrega columnas + amplía set_cpe_nf sin cambiar su
-- máquina de estados ni el guard EMITIDO_NO_DEGRADABLE). INERTE respecto a la operación.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1. Columnas de trazabilidad (additivas) ──
alter table me.ventas add column if not exists nf_aceptada_sunat boolean;
alter table me.ventas add column if not exists nf_sunat_code     text;
alter table me.ventas add column if not exists nf_sunat_desc     text;
alter table me.ventas add column if not exists nf_enlace_xml     text;
alter table me.ventas add column if not exists nf_enlace_cdr     text;
alter table me.ventas add column if not exists nf_orden_sunat    text;
alter table me.ventas add column if not exists nf_ultima_consulta timestamptz;

-- ── 2. set_cpe_nf v2: persiste el estado fiscal COMPLETO (sin degradar EMITIDO; whitelist intacta) ──
create or replace function me.set_cpe_nf(p_ref_local text, p_nf jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := me.jwt_app();
  v_ref  text := nullif(btrim(coalesce(p_ref_local,'')),'');
  v_new  text := upper(coalesce(p_nf->>'nf_estado',''));
  v_cur  me.ventas%rowtype;
  v_n    int;
  v_acep boolean := case when p_nf ? 'aceptada' then (p_nf->>'aceptada')::boolean
                         when p_nf ? 'nf_aceptada_sunat' then (p_nf->>'nf_aceptada_sunat')::boolean
                         else null end;
begin
  if v_app not in ('mosExpress','MOS') then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  if v_new <> '' and v_new not in ('PENDIENTE','EMITIDO','RECHAZADO','BAJA') then
    return jsonb_build_object('status','error','error','NF_ESTADO_INVALIDO');
  end if;

  select * into v_cur from me.ventas where ref_local = v_ref limit 1;
  if not found then return jsonb_build_object('status','success','actualizadas',0); end if;
  if v_cur.tipo_doc not in ('BOLETA','FACTURA') then
    return jsonb_build_object('status','error','error','NO_ES_CPE');
  end if;
  if coalesce(v_cur.nf_estado,'') = 'EMITIDO' and v_new <> '' and v_new <> 'EMITIDO' and v_new <> 'BAJA' then
    return jsonb_build_object('status','error','error','EMITIDO_NO_DEGRADABLE');
  end if;

  update me.ventas
     set nf_estado = case when v_new <> '' then v_new else nf_estado end,
         nf_hash   = coalesce(p_nf->>'nf_hash',   nf_hash),
         nf_enlace = coalesce(p_nf->>'nf_enlace', nf_enlace),
         nf_qr     = coalesce(nullif(p_nf->>'nf_qr',''), nullif(p_nf->>'qr',''), nullif(p_nf->>'qrString',''), nf_qr),
         -- trazabilidad (solo sobrescribe si vino un valor; nunca borra lo ya capturado)
         nf_aceptada_sunat = coalesce(v_acep, nf_aceptada_sunat),
         nf_sunat_code  = coalesce(nullif(p_nf->>'sunat_code',''), nullif(p_nf->>'nf_sunat_code',''), nf_sunat_code),
         nf_sunat_desc  = coalesce(nullif(p_nf->>'sunat_desc',''), nullif(p_nf->>'sunatDescription',''), nullif(p_nf->>'nf_sunat_desc',''), nf_sunat_desc),
         nf_enlace_xml  = coalesce(nullif(p_nf->>'enlace_xml',''), nullif(p_nf->>'nf_enlace_xml',''), nf_enlace_xml),
         nf_enlace_cdr  = coalesce(nullif(p_nf->>'enlace_cdr',''), nullif(p_nf->>'nf_enlace_cdr',''), nf_enlace_cdr),
         nf_orden_sunat = coalesce(nullif(p_nf->>'numero_orden_sunat',''), nullif(p_nf->>'nf_orden_sunat',''), nf_orden_sunat),
         nf_ultima_consulta = case when p_nf ? 'consultado' or v_acep is not null or coalesce(p_nf->>'nf_estado','')<>''
                                   then now() else nf_ultima_consulta end
   where ref_local = v_ref;
  get diagnostics v_n = row_count;
  return jsonb_build_object('status','success','actualizadas', v_n);
end;
$fn$;
revoke all on function me.set_cpe_nf(text, jsonb) from public;
grant execute on function me.set_cpe_nf(text, jsonb) to authenticated, service_role;

-- ── 3. Lector de trazabilidad para MOS (cero-GAS): lista CPE con estado fiscal completo + señales derivadas ──
-- Lo consume el panel Tributario de MOS (reemplaza tribIGVEmitidoMes que leía la Hoja por GAS).
-- Read-only. app MOS o mosExpress. Rango por fecha de NEGOCIO. Devuelve banderas claras NubeFact vs SUNAT.
create or replace function me.cpe_trazabilidad(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app   text := me.jwt_app();
  v_desde date := coalesce(nullif(p->>'desde','')::date, current_date - 30);
  v_hasta date := coalesce(nullif(p->>'hasta','')::date, current_date);
  v_estado text := upper(coalesce(p->>'estado',''));   -- filtro opcional
  v_rows jsonb;
begin
  if v_app not in ('MOS','mosExpress') then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  select coalesce(jsonb_agg(j order by (j->>'fecha') desc), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'idVenta', v.id_venta, 'refLocal', v.ref_local, 'correlativo', v.correlativo,
      'tipo', v.tipo_doc, 'fecha', v.fecha, 'total', v.total,
      'cliente', nullif(btrim(coalesce(v.cliente_nombre,'')),''), 'clienteDoc', v.cliente_doc,
      'nfEstado', coalesce(nullif(v.nf_estado,''),'(sin emitir)'),
      -- señales de trazabilidad
      'aceptadoNubefact', (coalesce(v.nf_hash,'') <> ''),
      'aceptadoSunat',    coalesce(v.nf_aceptada_sunat, v.nf_estado='EMITIDO'),
      'sunatCode', v.nf_sunat_code, 'sunatDesc', v.nf_sunat_desc,
      'enlacePdf', v.nf_enlace, 'enlaceXml', v.nf_enlace_xml, 'enlaceCdr', v.nf_enlace_cdr,
      'ordenSunat', v.nf_orden_sunat, 'qr', v.nf_qr,
      'ultimaConsulta', v.nf_ultima_consulta,
      'zona', v.zona_id, 'vendedor', v.vendedor
    ) j, v.fecha
    from me.ventas v
    where v.tipo_doc in ('BOLETA','FACTURA')
      and v.fecha::date between v_desde and v_hasta
      and (v_estado = '' or upper(coalesce(v.nf_estado,'')) = v_estado
           or (v_estado='SIN_SUNAT' and coalesce(v.nf_aceptada_sunat,false) is not true and coalesce(v.nf_estado,'') <> 'RECHAZADO'))
    order by v.fecha desc
  ) t;

  return jsonb_build_object('ok',true,'desde',v_desde,'hasta',v_hasta,
    'total', jsonb_array_length(v_rows),
    'pendientes_sunat', (select count(*) from me.ventas v where v.tipo_doc in ('BOLETA','FACTURA')
        and v.fecha::date between v_desde and v_hasta
        and coalesce(v.nf_aceptada_sunat,false) is not true and coalesce(v.nf_estado,'') not in ('RECHAZADO','BAJA','')),
    'cpe', v_rows);
end;
$fn$;
revoke all on function me.cpe_trazabilidad(jsonb) from public;
grant execute on function me.cpe_trazabilidad(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
