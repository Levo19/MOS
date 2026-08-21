-- [932] mos.cpe_estado_uno — estado de UN CPE por id_venta (para el auto-reimprimir con QR de NV→CPE).
-- Devuelve el estado nf + si el QR ya está listo, para que el front no imprima sin QR y auto-imprima
-- apenas SUNAT confirme. Solo lectura.
create or replace function mos.cpe_estado_uno(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_id text := btrim(coalesce(p->>'idVenta',''));
  r record;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id = '' then return jsonb_build_object('ok',false,'error','idVenta requerido'); end if;
  select correlativo,
         upper(coalesce(nf_estado,'')) as est,
         (nf_qr is not null and length(nf_qr) > 0) as qr,
         nf_enlace, nf_aceptada_sunat, nf_sunat_code, nf_sunat_desc
    into r
    from me.ventas where id_venta = v_id limit 1;
  if not found then return jsonb_build_object('ok',true,'encontrado',false); end if;
  return jsonb_build_object('ok',true,'encontrado',true,
    'estado', r.est, 'qrListo', r.qr, 'correlativo', r.correlativo,
    'enlace', r.nf_enlace, 'aceptada', r.nf_aceptada_sunat, 'sunatCode', r.nf_sunat_code, 'sunatDesc', r.nf_sunat_desc);
end $function$;
grant execute on function mos.cpe_estado_uno(jsonb) to authenticated, anon, service_role;

select mos.cpe_estado_uno('{"idVenta":"V-1787317820121-54915ebb"}'::jsonb) as muestra;
