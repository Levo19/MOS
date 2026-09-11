-- 1025 · mos.pn_set_foto: adjuntar la FOTO a un Producto Nuevo YA registrado (11-sep-2026).
--
-- CONTEXTO: el modal Producto Nuevo de MOS subía la foto ANTES de registrar (await con timeout 30s) →
--   el botón "se atoraba" y, si la subida fallaba, el catch la tragaba y el PN quedaba SIN foto.
-- FIX (cliente api.js crearPNManual): registrar PRIMERO (instantáneo) y subir la foto en 2º plano,
--   adjuntándola por id con esta RPC. NO se puede reusar crear_pn_manual para adjuntar: su dedup solo
--   aplica si hay guía (idGuia); el PN de MOS va sin guía → re-llamar INSERTARÍA un duplicado.
--
-- Seguridad: gate mos._claim_ok(); solo setea la foto si está VACÍA (idempotente, no pisa una existente).
-- No es dinero (catálogo pendiente de revisión).

CREATE OR REPLACE FUNCTION mos.pn_set_foto(p jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idProductoNuevo','')), '');
  v_foto text := nullif(btrim(coalesce(p->>'foto','')), '');
  v_n    int;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_foto is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  update wh.producto_nuevo
     set foto = v_foto
   where id_producto_nuevo = v_id
     and coalesce(nullif(btrim(coalesce(foto,'')),''),'') = '';   -- solo si estaba sin foto (no pisa una buena)
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idProductoNuevo',v_id,'actualizado',v_n));
end;
$function$;

grant execute on function mos.pn_set_foto(jsonb) to authenticated;

select '1025 mos.pn_set_foto listo' ok;
