-- 39_wh_marcar_preingreso_procesado.sql — [PASO 4] Pieza de aprobar_preingreso: marca PROCESADO + id_guia.
-- ⚠️ INERTE: flag WH_MARCAR_PREINGRESO_PROCESADO_DIRECTO. Replica el UPDATE final de aprobarPreingreso
-- (Productos.gs): set estado='PROCESADO', id_guia=X. Idempotente: si ya PROCESADO con guía, dedup.

insert into mos.config (clave, valor, descripcion) values
  ('WH_MARCAR_PREINGRESO_PROCESADO_DIRECTO','0','WH: marcar preingreso PROCESADO directo (pieza de aprobar_preingreso).')
on conflict (clave) do nothing;

create or replace function wh.marcar_preingreso_procesado(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'id_preingreso','')), '');
  v_guia text := nullif(btrim(coalesce(p->>'id_guia','')), '');
  v_estado text;
  v_guia_actual text;
begin
  if coalesce((select valor from mos.config where clave='WH_MARCAR_PREINGRESO_PROCESADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_MARCAR_PREINGRESO_PROCESADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;  -- [B2]
  if v_id is null or v_guia is null then return jsonb_build_object('ok',false,'error','FALTAN_PARAMS'); end if;

  select estado, id_guia into v_estado, v_guia_actual from wh.preingresos where id_preingreso = v_id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'error','PREINGRESO_NO_ENCONTRADO'); end if;

  -- idempotencia: ya procesado con guía → dedup (igual que aprobarPreingreso)
  if upper(coalesce(v_estado,'')) = 'PROCESADO' and coalesce(v_guia_actual,'') <> '' then
    return jsonb_build_object('ok',true,'dedup',true,'id_preingreso',v_id,'id_guia',v_guia_actual);
  end if;

  update wh.preingresos set estado = 'PROCESADO', id_guia = v_guia where id_preingreso = v_id;
  return jsonb_build_object('ok',true,'dedup',false,'id_preingreso',v_id,'id_guia',v_guia);
end;
$fn$;

revoke all on function wh.marcar_preingreso_procesado(jsonb) from public;
grant execute on function wh.marcar_preingreso_procesado(jsonb) to service_role, authenticated;
