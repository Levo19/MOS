-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- 505 · ANULAR CPE = reversa de pago inmediata + baja fiscal automática (auto-baja al aceptar)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- Contexto: al "dar de baja" un CPE hoy solo se comunica la baja a SUNAT (y exige EMITIDO), pero NO se
-- reversa el pago → la caja no cuadra si la venta no se finalizó. Y en demo/producción los CPE quedan
-- PENDIENTE hasta que SUNAT los acepta, así que no se puede comunicar la baja de inmediato.
--
-- Modelo elegido (confirmado por el dueño): "auto-baja al aceptar".
--   • PAGO: se reversa AL MOMENTO, siempre (forma_pago='ANULADO' vía me.anular_venta → caja + stock + pickup).
--   • FISCAL: automático según estado —
--       - EMITIDO (aceptado por SUNAT)        → se comunica la baja YA (Edge op=baja).
--       - PENDIENTE (aún sin CDR de SUNAT)     → nf_estado='ANULADO_PEND_BAJA'; la reconciliación manda la
--                                                baja SOLA apenas SUNAT lo acepte (cubre "sin internet").
--       - RECHAZADO (SUNAT lo rechazó)         → nf_estado='ANULADO'; no hay nada que dar de baja.
--   La reconciliación se apoya en forma_pago='ANULADO' como señal maestra (robusto aunque el Edge fiscal
--   no haya corrido: p.ej. anulación offline que solo encoló la reversa de pago).
--
-- Este archivo: (1) amplía el whitelist de estados de me.set_cpe_nf + relaja el guard de EMITIDO para
-- permitir EMITIDO→BAJA*/ANULADO*; (2) crea me.cpe_recon_candidatos() que devuelve las ventas que la
-- reconciliación debe revisar (pendientes normales + anuladas que aún deben comunicar baja).
-- Idempotente (create or replace). No activa nada por sí solo.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

-- ── (1) me.set_cpe_nf: aceptar los estados de baja/anulación + permitir EMITIDO→BAJA*/ANULADO* ──
create or replace function me.set_cpe_nf(p_ref_local text, p_nf jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_app  text := me.jwt_app();
  v_role text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb)->>'role','');
  v_ref  text := nullif(btrim(coalesce(p_ref_local,'')),'');
  v_new  text := upper(coalesce(p_nf->>'nf_estado',''));
  v_cur  me.ventas%rowtype;
  v_n    int;
  v_acep boolean := case when p_nf ? 'aceptada' then (p_nf->>'aceptada')::boolean
                         when p_nf ? 'nf_aceptada_sunat' then (p_nf->>'nf_aceptada_sunat')::boolean
                         else null end;
begin
  if v_app not in ('mosExpress','MOS') and v_role <> 'service_role' then
    return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA');
  end if;
  if not me._cpe_directo_on() then return jsonb_build_object('status','error','error','CPE_DIRECTO_DESACTIVADO'); end if;
  if v_ref is null then return jsonb_build_object('status','error','error','REF_LOCAL_REQUERIDO'); end if;
  -- [505] whitelist ampliado: además de los estados de emisión, los de baja/anulación local.
  if v_new <> '' and v_new not in ('PENDIENTE','EMITIDO','RECHAZADO','BAJA',
                                   'BAJA_ACEPTADA','BAJA_SOLICITADA','BAJA_ERROR',
                                   'ANULADO','ANULADO_PEND_BAJA') then
    return jsonb_build_object('status','error','error','NF_ESTADO_INVALIDO');
  end if;

  select * into v_cur from me.ventas where ref_local = v_ref limit 1;
  if not found then return jsonb_build_object('status','success','actualizadas',0); end if;
  if v_cur.tipo_doc not in ('BOLETA','FACTURA') then
    return jsonb_build_object('status','error','error','NO_ES_CPE');
  end if;
  -- [505] EMITIDO no se degrada a PENDIENTE/RECHAZADO, pero SÍ puede pasar a BAJA*/ANULADO* (anulación).
  if coalesce(v_cur.nf_estado,'') = 'EMITIDO' and v_new <> '' and v_new <> 'EMITIDO'
     and v_new not like 'BAJA%' and v_new not like 'ANULADO%' then
    return jsonb_build_object('status','error','error','EMITIDO_NO_DEGRADABLE');
  end if;

  update me.ventas
     set nf_estado = case when v_new <> '' then v_new else nf_estado end,
         nf_hash   = coalesce(nullif(p_nf->>'nf_hash',''),   nf_hash),
         nf_enlace = coalesce(nullif(p_nf->>'nf_enlace',''), nf_enlace),
         nf_qr     = coalesce(nullif(p_nf->>'nf_qr',''), nullif(p_nf->>'qr',''), nullif(p_nf->>'qrString',''), nf_qr),
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
$function$;

-- ── (2) me.cpe_recon_candidatos: filas que la reconciliación debe revisar ──
-- Devuelve pendientes normales (sin CDR de SUNAT aún) + anuladas que todavía deben comunicar la baja.
-- El Edge decide por fila usando `anulada`:
--   anulada + aceptada  → generar_anulacion (baja)
--   anulada + rechazado → ANULADO (terminal, nada que dar de baja)
--   anulada + pendiente → ANULADO_PEND_BAJA (espera)
--   normal              → EMITIDO / RECHAZADO / sigue PENDIENTE
create or replace function me.cpe_recon_candidatos(p_dias int default 45, p_limite int default 80)
 returns table(ref_local text, id_venta text, correlativo text, tipo_doc text,
               nf_estado text, forma_pago text, anulada boolean)
 language sql
 security definer
 set search_path to ''
as $function$
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
$function$;

revoke all on function me.cpe_recon_candidatos(int,int) from public, anon, authenticated;
grant execute on function me.cpe_recon_candidatos(int,int) to service_role;

-- ── nota operativa (no ejecuta): para producción encender la reconciliación ──
--   update mos.config set valor='1' where clave='CPE_RECON_ON';
-- y pegar el token real:  supabase secrets set NUBEFACT_TOKEN=<prod> NUBEFACT_RUTA=<prod>
