-- 62_wh_actualizar_foto_guia.sql — [PASO 5 · B5] Actualiza la URL de foto de una guía (tras subir a Storage).
-- Pieza del wiring de fotos: el front sube a Storage (máxima calidad) → URL → esta RPC setea guias.foto. INERTE (flag).
-- Idempotente por naturaleza (setea la URL; reintento setea la misma). Gate wh._claim_ok().

insert into mos.config (clave, valor, descripcion) values
  ('WH_ACTUALIZAR_FOTO_GUIA_DIRECTO','0','WH: actualizar foto de guia directo (wiring fotos Storage).')
on conflict (clave) do nothing;

create or replace function wh.actualizar_foto_guia(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_foto text := coalesce(p->>'foto','');
  v_n    int;
begin
  if coalesce((select valor from mos.config where clave='WH_ACTUALIZAR_FOTO_GUIA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_ACTUALIZAR_FOTO_GUIA_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  update wh.guias set foto = v_foto where id_guia = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','GUIA_NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true,'id_guia',v_id,'foto',v_foto);
end;
$fn$;

revoke all on function wh.actualizar_foto_guia(jsonb) from public;
grant execute on function wh.actualizar_foto_guia(jsonb) to service_role, authenticated;
