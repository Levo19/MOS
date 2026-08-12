CREATE OR REPLACE FUNCTION wh.guardar_progreso_pickup(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp   text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_lock  text := coalesce(p->>'lock_usuario', p->>'lockUsuario', '');
  v_items jsonb := p->'items';
  v_atp   text;
  v_est   text;
  v_now   timestamptz := now();
  v_merge jsonb;
  v_env   jsonb := '{}'::jsonb;   -- [741] payload del dispositivo indexado por producto
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select atendido_por, estado into v_atp, v_est from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- [741] indexar lo que manda el dispositivo por clave de producto
  if jsonb_typeof(v_items) = 'array' then
    select coalesce(jsonb_object_agg(wh._pickup_item_key(e.value), e.value), '{}'::jsonb)
      into v_env from jsonb_array_elements(v_items) e;
  end if;

  -- Conflicto de lock; si no había lock, tomarlo (autosave implica que estoy trabajando)
  if v_lock <> '' then
    if coalesce(btrim(v_atp),'') <> '' and not wh._pickup_same_user(v_atp, v_lock) then
      return jsonb_build_object('ok',false,'error','Pickup atendido por '||v_atp,'atendidoPor',v_atp,'conflicto',true);
    end if;
  end if;

  -- [741] FUSIÓN por producto en vez de reemplazo. El dispositivo manda SU copia
  -- de la lista; si mientras la tenía abierta llegó un cierre de caja, la copia
  -- vieja borraba los productos nuevos (de ahí "a cada operador le aparece
  -- distinto" y "cero productos"). Ahora del payload solo se toma el PROGRESO
  -- (despachado y su hora) y los productos que el dispositivo no tenía se
  -- conservan intactos.
  if jsonb_typeof(v_items) = 'array' then
    select coalesce(jsonb_agg(
             case when v_env ? wh._pickup_item_key(base.value)
                  then base.value
                       -- El progreso lo manda quien tiene el candado (uno solo a la vez):
                       -- se toma su valor TAL CUAL, para que el boton "-" pueda corregir
                       -- hacia abajo. Lo que no puede es borrar productos: de eso se encarga
                       -- la fusion por clave.
                       || jsonb_build_object('despachado',
                            coalesce(((v_env -> wh._pickup_item_key(base.value))->>'despachado')::numeric,
                                     coalesce((base.value->>'despachado')::numeric,0)))
                       || case when (v_env -> wh._pickup_item_key(base.value)) ? 'tsDespacho'
                               then jsonb_build_object('tsDespacho', (v_env -> wh._pickup_item_key(base.value))->'tsDespacho')
                               else '{}'::jsonb end
                  else base.value end), '[]'::jsonb)
      into v_merge
      from wh.pickups pk, jsonb_array_elements(coalesce(pk.items,'[]'::jsonb)) base
     where pk.id_pickup = v_idp;

    -- productos que el dispositivo trae y en la base NO existen (raro, pero no se pierden)
    select v_merge || coalesce(jsonb_agg(nue.value), '[]'::jsonb)
      into v_merge
      from jsonb_array_elements(v_items) nue
     where not exists (
       select 1 from jsonb_array_elements(v_merge) b
        where wh._pickup_item_key(b.value) = wh._pickup_item_key(nue.value));
  end if;

  update wh.pickups
     set items            = coalesce(v_merge, items),
         atendido_por     = case when v_lock <> '' and coalesce(btrim(atendido_por),'')='' then v_lock else atendido_por end,
         estado           = case when upper(coalesce(estado,'')) = 'PENDIENTE' then 'EN_PROCESO' else estado end,
         ultima_actividad = v_now
   where id_pickup = v_idp;
  return jsonb_build_object('ok',true);
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$function$
