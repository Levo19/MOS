-- 256 · REPARACIÓN #9 (Etapa 2) — me.set_cpe_nf persiste nf_qr (QR SUNAT) para el ticket
-- Al emitir un CPE por el path DIRECTO (emitir-cpe Edge → set_cpe_nf), guardamos también la
-- cadena_para_codigo_qr de NubeFact en me.ventas.nf_qr → la (re)impresión del ticket muestra el
-- QR SUNAT real (antes solo se persistía hash/enlace). Aditivo, idempotente, mismas validaciones.
create or replace function me.set_cpe_nf(p_ref_local text, p_nf jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := me.jwt_app();
  v_ref  text := nullif(btrim(coalesce(p_ref_local,'')),'');
  v_new  text := upper(coalesce(p_nf->>'nf_estado',''));
  v_cur  me.ventas%rowtype;
  v_n    int;
begin
  if v_app <> 'mosExpress' then return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA'); end if;
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
         nf_qr     = coalesce(nullif(p_nf->>'nf_qr',''), nullif(p_nf->>'qr',''), nullif(p_nf->>'qrString',''), nf_qr)
   where ref_local = v_ref;
  get diagnostics v_n = row_count;
  return jsonb_build_object('status','success','actualizadas', v_n);
end;
$fn$;
revoke all on function me.set_cpe_nf(text, jsonb) from public;
grant execute on function me.set_cpe_nf(text, jsonb) to authenticated, service_role;
notify pgrst, 'reload schema';
