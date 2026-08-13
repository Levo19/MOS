CREATE OR REPLACE FUNCTION wh.guardar_ocr_guia(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idguia text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_n int;
begin
  if coalesce((select valor from mos.config where clave='WH_GUARDAR_OCR_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_GUARDAR_OCR_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idguia is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  update wh.guias set
    ocr_estado            = coalesce(nullif(btrim(coalesce(p->>'estado','')), ''), 'NO_COMPROBANTE'),
    ocr_tipo              = coalesce(nullif(btrim(coalesce(p->>'tipo_comprobante','')), ''), 'NO_COMPROBANTE'),
    ocr_ruc_emisor        = coalesce(p->>'ruc_emisor',''),
    ocr_razon_social      = coalesce(p->>'razon_social',''),
    ocr_serie             = coalesce(p->>'serie',''),
    ocr_numero            = coalesce(p->>'numero',''),
    ocr_fecha_comprobante = coalesce(p->>'fecha',''),
    ocr_total             = wh._num(p->>'total'),
    ocr_subtotal          = wh._num(p->>'subtotal'),
    igv_recuperable       = wh._num(p->>'igv_recuperable'),
    ocr_confidence        = wh._num(p->>'confidence'),
    ocr_notas             = coalesce(p->>'notas',''),
    ocr_fecha_proceso     = now()
  where id_guia = v_idguia;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA','id_guia',v_idguia); end if;

  return jsonb_build_object('ok',true,'id_guia',v_idguia,'estado',coalesce(p->>'estado','NO_COMPROBANTE'),
    'igv_recuperable',wh._num(p->>'igv_recuperable'));
end;
$function$
