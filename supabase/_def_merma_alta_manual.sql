CREATE OR REPLACE FUNCTION wh.merma_alta_manual(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id   text := nullif(btrim(coalesce(p->>'id_merma','')), '');
  v_cod  text := nullif(btrim(coalesce(p->>'cod_producto','')), '');
  v_cant numeric := wh._num(p->>'cantidad');
  v_foto text := coalesce(p->>'foto','');
  v_usr  text := coalesce(p->>'usuario','');
  v_mot  text := coalesce(p->>'motivo','hallado dañado en almacén');
begin
  if not wh._claim_ok() and not mos._claim_ok() then
    return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_cant <= 0 then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_foto = '' then return jsonb_build_object('ok',false,'error','FOTO_OBLIGATORIA'); end if;
  if exists (select 1 from wh.mermas where id_merma = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_merma',v_id); end if;

  update wh.stock set cantidad_disponible = coalesce(cantidad_disponible,0) - v_cant,
                      ultima_actualizacion = now()
   where upper(cod_producto) = upper(v_cod);

  insert into wh.mermas (id_merma, fecha_ingreso, origen, cod_producto, id_lote, cantidad_original,
    cantidad_pendiente, motivo, usuario, id_guia, estado, responsable, cantidad_reparada,
    cantidad_desechada, foto, culpa, costo_unitario, stock_descontado)
  values (v_id, now(), 'ALMACEN', v_cod, '', v_cant, v_cant, v_mot, v_usr, '', 'EN_PROCESO',
    'ALMACEN', 0, 0, v_foto, 'ALMACEN', wh._num(p->>'costo'), true);

  return jsonb_build_object('ok',true,'id_merma',v_id);
end; $function$
