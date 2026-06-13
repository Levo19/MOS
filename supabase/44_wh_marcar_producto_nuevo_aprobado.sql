-- 44_wh_marcar_producto_nuevo_aprobado.sql — [PASO 4] Parte WH de aprobar_producto_nuevo: marca el PN APROBADO.
-- ⚠️ INERTE: flag WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO. Replica el marcado de aprobarProductoNuevo
-- (Productos.gs): estado='APROBADO', aprobado_por, fecha_aprobacion, observacion=tipoLabel. Idempotente.
-- La CREACIÓN del producto en el catálogo (mos.productos) NO va acá → se delega a MOS (integración aparte).
-- Opcion A: la sombra wh.producto_nuevo no tenia observacion (tipoLabel NUEVO/EQUIVALENTE).
alter table wh.producto_nuevo add column if not exists observacion text;

insert into mos.config (clave, valor, descripcion) values
  ('WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO','0','WH: marcar producto_nuevo APROBADO (parte WH de aprobar_producto_nuevo).')
on conflict (clave) do nothing;

create or replace function wh.marcar_producto_nuevo_aprobado(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'id_producto_nuevo','')), '');
  v_por  text := coalesce(nullif(p->>'aprobado_por',''),'MOS');
  v_obs  text := coalesce(p->>'observacion','NUEVO');
  v_estado text;
begin
  if coalesce((select valor from mos.config where clave='WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_MARCAR_PRODUCTO_NUEVO_APROBADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;
  select estado into v_estado from wh.producto_nuevo where id_producto_nuevo = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','PRODUCTO_NUEVO_NO_ENCONTRADO'); end if;
  if upper(coalesce(v_estado,'')) = 'APROBADO' then
    return jsonb_build_object('ok',true,'dedup',true,'id_producto_nuevo',v_id);
  end if;
  update wh.producto_nuevo set estado='APROBADO', aprobado_por=v_por, fecha_aprobacion=now(), observacion=v_obs
   where id_producto_nuevo = v_id;
  return jsonb_build_object('ok',true,'dedup',false,'id_producto_nuevo',v_id);
end;
$fn$;
revoke all on function wh.marcar_producto_nuevo_aprobado(jsonb) from public;
grant execute on function wh.marcar_producto_nuevo_aprobado(jsonb) to service_role, authenticated;
