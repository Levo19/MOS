-- 1024 · mos.crear_pn_manual: reenviar la FOTO (07-sep-2026).
--
-- BUG: al crear un Producto Nuevo desde MOS, la foto se veía en el formulario pero NUNCA aparecía en la
-- lista (quedaba vacía). Causa doble: (a) el cliente mandaba fotoBase64 a este RPC de SQL, que NO puede
-- subir a Storage; (b) este RPC ademas NI SIQUIERA reenviaba `foto` a wh.registrar_producto_nuevo (que sí
-- la guarda). Datos: PN de Jesús → foto len 0; PN de Sergio (via WH, upload-on-select) → URL Storage OK.
--
-- FIX cliente (api.js crearPNManual): sube la foto a Storage (bucket producto-fotos) y pasa `foto`=URL.
-- FIX servidor (este parche): reenviar p->>'foto' a wh.registrar_producto_nuevo. Idempotente.

CREATE OR REPLACE FUNCTION mos.crear_pn_manual(p jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb); v_res jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('app','warehouseMos'))::text, true);
  v_res := wh.registrar_producto_nuevo(jsonb_build_object(
    'codigoBarra', coalesce(p->>'codigoBarra', p->>'codigoFinal',''), 'idGuia', coalesce(p->>'idGuia',''),
    'cantidad', coalesce(p->>'cantidad','0'), 'descripcion', coalesce(p->>'descripcion',''),
    'fechaVencimiento', coalesce(p->>'fechaVencimiento',''), 'usuario', coalesce(p->>'usuario','MOS'),
    'foto', coalesce(p->>'foto','')));
  perform set_config('request.jwt.claims', v_claims::text, true);
  return v_res;
end; $function$;

select '1024 crear_pn_manual +foto listo' ok;
