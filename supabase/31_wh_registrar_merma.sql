-- 31_wh_registrar_merma.sql — [PASO 4 · sesión 2] Escritura directa: registrar merma (NO toca stock).
-- ⚠️ INERTE: gateada por mos.config.WH_REGISTRAR_MERMA_DIRECTO (default '0').
-- Replica registrarMerma (Productos.gs): inserta 1 fila en wh.mermas en estado EN_PROCESO.
-- La foto la sube GAS a Drive y pasa la URL ya resuelta (la RPC solo persiste). Idempotente por id_merma.

insert into mos.config (clave, valor, descripcion) values
  ('WH_REGISTRAR_MERMA_DIRECTO','0','WH: registrar merma directo a Supabase (RPC wh.registrar_merma). Validar antes de prender.')
on conflict (clave) do nothing;

-- [40x A1] coerción numérica tolerante (idempotente; misma def que 30/35/36).
create or replace function wh._num(t text) returns numeric language sql immutable as $$
  select case when t is null then 0
    when btrim(replace(t, ',', '.')) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(replace(t, ',', '.'))::numeric
    else 0 end;
$$;
-- [40x A1] timestamp tolerante: ISO válido → ts; null/''/basura → default (no revienta la tx).
create or replace function wh._ts(t text, dflt timestamptz) returns timestamptz language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return dflt; end if;
  return t::timestamptz;
exception when others then return dflt;
end;
$$;

create or replace function wh.registrar_merma(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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

  return jsonb_build_object('ok',true,'dedup',false,'id_merma',v_id);
end;
$fn$;

revoke all on function wh.registrar_merma(jsonb) from public;
grant execute on function wh.registrar_merma(jsonb) to service_role;
