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

    begin perform mos.emitir_push(jsonb_build_object('audiencia',jsonb_build_object('roles',jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),'titulo','📦 Preingreso nuevo','cuerpo',coalesce(  (select nullif(btrim(pr.nombre),'') from mos.proveedores pr    where btrim(pr.id_proveedor) = btrim(v_prov) limit 1),  case when nullif(btrim(v_prov),'') is not null then 'prov. '||btrim(v_prov) else 'Proveedor sin identificar' end)||' · S/ '||to_char(coalesce(v_monto,0),'FM999999990.00')||case when nullif(btrim(v_usuario),'') is not null then ' · '||btrim(v_usuario) else '' end,'data',jsonb_build_object('tipo','wh_preingreso'))); exception when others then null; end;
  return jsonb_build_object('ok',true,'dedup',false,'id_preingreso',v_id);
end;
$function$
