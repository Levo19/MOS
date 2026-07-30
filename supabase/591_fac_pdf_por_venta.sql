-- ════════════════════════════════════════════════════════════════════════════
-- 591_fac_pdf_por_venta.sql · Enlace del PDF (NubeFact) de un ticket de ME
-- ════════════════════════════════════════════════════════════════════════════
-- Contexto: en MOS (módulo Caja) el admin abre las acciones de un ticket y quiere
-- ver/compartir/imprimir el comprobante fiscal (boleta/factura). El objeto ticket
-- del front NO trae el PDF y el detalle (me_detalle_venta) solo expone nfEstado/hash/qr.
--
-- OJO: la emisión REAL de CPE de ME NO usa fac.comprobantes (esa tabla está vacía; el
-- camino fac.* single-token es incompatible con el multi-local por zona). El Edge
-- `emitir-cpe` devuelve enlace_del_pdf y el resultado se persiste en **me.ventas**:
--   nf_enlace (=PDF), nf_enlace_xml, nf_qr, nf_hash, nf_estado, nf_aceptada_sunat.
--
-- Esta RPC de SOLO LECTURA devuelve ese enlace por venta (por id_venta; fallback por
-- correlativo). 0 generación, 0 escritura. Gated a apps MOS/mosExpress por el claim JWT.

-- limpiar el borrador previo (apuntaba a fac.comprobantes, tabla vacía → inservible)
drop function if exists mos.fac_pdf_por_venta(jsonb);
drop function if exists fac.pdf_por_venta(jsonb);

create or replace function mos.me_cpe_pdf_por_venta(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_app  text := coalesce((nullif(current_setting('request.jwt.claims', true),'')::jsonb) ->> 'app', '');
  v_idv  text := nullif(btrim(coalesce(p->>'id_venta','')), '');
  v_corr text := nullif(btrim(coalesce(p->>'correlativo','')), '');
  v_r    record;
begin
  if v_app not in ('MOS','mosExpress') then
    return jsonb_build_object('status','error','error','APP_NO_AUTORIZADA');
  end if;
  if v_idv is null and v_corr is null then
    return jsonb_build_object('status','error','error','FALTAN_PARAMS');
  end if;

  -- match por id_venta (canónico) O correlativo (fallback), priorizando id_venta.
  -- Consulta única para no dejar el `record` sin asignar cuando solo viene correlativo.
  select id_venta, correlativo, tipo_doc, nf_estado, nf_enlace, nf_enlace_xml, nf_qr, nf_aceptada_sunat
    into v_r
    from me.ventas
   where (v_idv  is not null and id_venta   = v_idv)
      or (v_corr is not null and correlativo = v_corr)
   order by (case when v_idv is not null and id_venta = v_idv then 0 else 1 end)
   limit 1;

  if not found then
    return jsonb_build_object('status','success','encontrado', false);
  end if;

  return jsonb_build_object(
    'status','success','encontrado', true,
    'id_venta',    v_r.id_venta,
    'correlativo', v_r.correlativo,
    'tipo_doc',    v_r.tipo_doc,
    'estado',      v_r.nf_estado,
    'aceptada',    coalesce(v_r.nf_aceptada_sunat, false),
    'pdf',         nullif(v_r.nf_enlace, ''),
    'xml',         nullif(v_r.nf_enlace_xml, ''),
    'qr',          nullif(v_r.nf_qr, ''));
end;
$fn$;

revoke all on function mos.me_cpe_pdf_por_venta(jsonb) from public;
grant execute on function mos.me_cpe_pdf_por_venta(jsonb) to authenticated;
