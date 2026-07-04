-- 344: push best-effort WH merma+preingreso (#33 -> admins). Cero-GAS.
CREATE OR REPLACE FUNCTION wh.registrar_merma(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id      text := nullif(btrim(coalesce(p->>'id_merma','')), '');
  v_cod     text := nullif(btrim(coalesce(p->>'codigo_producto','')), '');
  v_cant    numeric := wh._num(p->>'cantidad');
  v_motivo  text := coalesce(p->>'motivo','');
  v_usuario text := coalesce(p->>'usuario','');
  -- [A2] prioridad igual a GAS: responsable || origen || ALMACEN
  v_origen  text := coalesce(nullif(btrim(p->>'responsable'),''), nullif(btrim(p->>'origen'),''), 'ALMACEN');
  v_resp    text := coalesce(p->>'responsable','');
  v_lote    text := coalesce(p->>'id_lote','');
  v_foto    text := coalesce(p->>'foto','');
  v_fecha   timestamptz := wh._ts(p->>'fecha', now());
begin
  if coalesce((select valor from mos.config where clave='WH_REGISTRAR_MERMA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_REGISTRAR_MERMA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null or v_cod is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  if v_cant <= 0  then return jsonb_build_object('ok',false,'error','CANTIDAD_INVALIDA'); end if;
  if v_foto = ''  then return jsonb_build_object('ok',false,'error','FOTO_OBLIGATORIA'); end if;

  -- idempotencia (reintento/doble-tap no duplica la merma)
  if exists (select 1 from wh.mermas where id_merma = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_merma',v_id);
  end if;

  insert into wh.mermas (id_merma, fecha_ingreso, origen, cod_producto, id_lote, cantidad_original,
    cantidad_pendiente, motivo, usuario, estado, responsable, cantidad_reparada, cantidad_desechada, foto)
  values (v_id, v_fecha, v_origen, v_cod, v_lote, v_cant, v_cant, v_motivo, v_usuario, 'EN_PROCESO', v_resp, 0, 0, v_foto);

    begin perform mos.emitir_push(jsonb_build_object('audiencia',jsonb_build_object('roles',jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),'titulo','📉 Merma registrada','cuerpo',coalesce(nullif(v_cod,''),'producto')||' · '||coalesce(v_cant::text,'')||' · '||coalesce(nullif(v_motivo,''),''),'data',jsonb_build_object('tipo','wh_merma'))); exception when others then null; end;
  return jsonb_build_object('ok',true,'dedup',false,'id_merma',v_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION wh.crear_preingreso(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id     text := nullif(btrim(coalesce(p->>'id_preingreso','')), '');
  v_prov   text := coalesce(p->>'id_proveedor','');
  v_carg   text := coalesce(p->>'cargadores','');
  v_usuario text := coalesce(p->>'usuario','');
  v_monto  numeric := wh._num(p->>'monto');
  v_fotos  text := coalesce(p->>'fotos','');
  v_coment text := coalesce(p->>'comentario','');
  v_fecha  timestamptz := wh._ts(p->>'fecha', now());
begin
  if coalesce((select valor from mos.config where clave='WH_CREAR_PREINGRESO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_CREAR_PREINGRESO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  -- idempotencia (retry/doble-tap no duplica el preingreso)
  if exists (select 1 from wh.preingresos where id_preingreso = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'id_preingreso',v_id);
  end if;

  insert into wh.preingresos (id_preingreso, fecha, id_proveedor, cargadores, usuario, monto, fotos, comentario, estado, id_guia)
  values (v_id, v_fecha, v_prov, v_carg, v_usuario, v_monto, v_fotos, v_coment, 'PENDIENTE', '');

    begin perform mos.emitir_push(jsonb_build_object('audiencia',jsonb_build_object('roles',jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),'titulo','📦 Preingreso nuevo','cuerpo',coalesce(nullif(v_prov,''),'proveedor')||' · S/ '||coalesce(v_monto::text,'0'),'data',jsonb_build_object('tipo','wh_preingreso'))); exception when others then null; end;
  return jsonb_build_object('ok',true,'dedup',false,'id_preingreso',v_id);
end;
$function$
;

