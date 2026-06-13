-- 33_wh_actualizar_preingreso.sql — [PASO 4 · sesión 3b] PATCH de campos editables de un preingreso.
-- ⚠️ INERTE: gateada por mos.config.WH_ACTUALIZAR_PREINGRESO_DIRECTO (default '0').
-- Replica _actualizarPreingresoImpl (Productos.gs): whitelist de campos editables (NO toca estado/id_guia),
-- y propaga id_proveedor+comentario a la guía vinculada (los campos del spec wh.guias). Solo patchea lo presente.

insert into mos.config (clave, valor, descripcion) values
  ('WH_ACTUALIZAR_PREINGRESO_DIRECTO','0','WH: actualizar preingreso directo a Supabase (RPC wh.actualizar_preingreso). Validar antes de prender.')
on conflict (clave) do nothing;

create or replace function wh._num(t text) returns numeric language sql immutable as $$
  select case when t is null then 0
    when btrim(replace(t, ',', '.')) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(replace(t, ',', '.'))::numeric
    else 0 end;
$$;

create or replace function wh.actualizar_preingreso(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id     text := nullif(btrim(coalesce(p->>'id_preingreso','')), '');
  v_idguia text;
begin
  if coalesce((select valor from mos.config where clave='WH_ACTUALIZAR_PREINGRESO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ACTUALIZAR_PREINGRESO_DIRECTO_OFF');
  end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  select id_guia into v_idguia from wh.preingresos where id_preingreso = v_id limit 1;
  if not found then return jsonb_build_object('ok',false,'error','PREINGRESO_NO_ENCONTRADO'); end if;

  -- PATCH solo de los campos presentes (whitelist editable; NO estado/id_guia/fecha/usuario)
  update wh.preingresos set
    id_proveedor   = case when p ? 'id_proveedor'   then coalesce(p->>'id_proveedor','')   else id_proveedor   end,
    monto          = case when p ? 'monto'          then wh._num(p->>'monto')                              else monto end,
    comentario     = case when p ? 'comentario'     then coalesce(p->>'comentario','')     else comentario     end,
    fotos          = case when p ? 'fotos'          then coalesce(p->>'fotos','')          else fotos          end,
    cargadores     = case when p ? 'cargadores'     then coalesce(p->>'cargadores','')     else cargadores     end,
    snapshot_aviso = case when p ? 'snapshot_aviso' then (p->'snapshot_aviso')             else snapshot_aviso end
  where id_preingreso = v_id;

  -- propagar a la guía vinculada (solo los campos que existen en el spec wh.guias)
  if coalesce(v_idguia,'') <> '' then
    update wh.guias set
      id_proveedor = case when p ? 'id_proveedor' then coalesce(p->>'id_proveedor','') else id_proveedor end,
      comentario   = case when p ? 'comentario'   then coalesce(p->>'comentario','')   else comentario   end
    where id_guia = v_idguia;
  end if;

  return jsonb_build_object('ok',true,'id_preingreso',v_id,'id_guia',coalesce(v_idguia,''));
end;
$fn$;

revoke all on function wh.actualizar_preingreso(jsonb) from public;
grant execute on function wh.actualizar_preingreso(jsonb) to service_role;
