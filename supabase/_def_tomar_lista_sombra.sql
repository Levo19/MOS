CREATE OR REPLACE FUNCTION wh.tomar_lista_sombra(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_forzar boolean := coalesce((p->>'forzar')::boolean, false);
  v_row wh.listas_sombra%rowtype;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null or v_user is null then return jsonb_build_object('ok',false,'error','idLista y usuario requeridos'); end if;
  select * into v_row from wh.listas_sombra where id_lista = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  if upper(coalesce(v_row.estado,'')) = 'COMPLETADA' then return jsonb_build_object('ok',false,'error','YA_COMPLETADA'); end if;
  if upper(coalesce(v_row.estado,'')) = 'EN_USO' and coalesce(btrim(v_row.usuario_tomada),'') <> ''
     and btrim(v_row.usuario_tomada) <> v_user and not v_forzar then
    return jsonb_build_object('ok',false,'error','EN_USO_POR_OTRO','mensaje','Tomada por: '||v_row.usuario_tomada); end if;
  update wh.listas_sombra set estado='EN_USO', usuario_tomada=v_user, fecha_tomada=now() where id_lista = v_id;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'items', coalesce(v_row.items,'[]'::jsonb), 'dueno', v_user));
end;
$function$
