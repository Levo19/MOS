-- 32_wh_crear_preingreso.sql — [PASO 4 · sesión 3] Escritura directa: crear preingreso (NO toca stock).
-- ⚠️ INERTE: gateada por mos.config.WH_CREAR_PREINGRESO_DIRECTO (default '0').
-- Replica crearPreingreso (Productos.gs): inserta 1 fila en wh.preingresos estado PENDIENTE.
-- cargadores = JSON string (ya limpiado por GAS). snapshot_aviso queda null al crear. Idempotente por id_preingreso.

insert into mos.config (clave, valor, descripcion) values
  ('WH_CREAR_PREINGRESO_DIRECTO','0','WH: crear preingreso directo a Supabase (RPC wh.crear_preingreso). Validar antes de prender.')
on conflict (clave) do nothing;

create or replace function wh._num(t text) returns numeric language sql immutable as $$
  select case when t is null then 0
    when btrim(replace(t, ',', '.')) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(replace(t, ',', '.'))::numeric
    else 0 end;
$$;
create or replace function wh._ts(t text, dflt timestamptz) returns timestamptz language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return dflt; end if;
  return t::timestamptz;
exception when others then return dflt;
end;
$$;

create or replace function wh.crear_preingreso(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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

  return jsonb_build_object('ok',true,'dedup',false,'id_preingreso',v_id);
end;
$fn$;

revoke all on function wh.crear_preingreso(jsonb) from public;
grant execute on function wh.crear_preingreso(jsonb) to service_role, authenticated;
