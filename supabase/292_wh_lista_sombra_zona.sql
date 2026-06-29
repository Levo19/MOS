-- ============================================================================
-- 292_wh_lista_sombra_zona.sql — Zona destino en la lista sombra (IA)
-- ----------------------------------------------------------------------------
-- El form de IA ahora deja elegir la ZONA a la que va la lista (botones Zona 1 /
-- Zona 2, default Zona 1). Aditivo: columna `zona` en wh.listas_sombra + crear_lista_sombra
-- la guarda (lee idZona|zona). Las demás RPC no cambian.
-- ============================================================================

alter table wh.listas_sombra add column if not exists zona text default '';

create or replace function wh.crear_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_items jsonb := p->'items';
  v_id   text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_comp boolean := coalesce((p->>'compartir')::boolean, false);
  v_zona text := btrim(coalesce(p->>'idZona', p->>'zona', ''));   -- [292] zona destino
  v_estado text;
begin
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_user is null then return jsonb_build_object('ok',false,'error','usuario requerido'); end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',false,'error','sin items'); end if;
  v_id := coalesce(v_id, 'LS'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
  -- idempotencia
  if exists (select 1 from wh.listas_sombra where id_lista = v_id) then
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'duplicado', true)); end if;
  v_estado := case when v_comp then 'DISPONIBLE' else 'EN_USO' end;
  insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, usuario_tomada, fecha_tomada, fecha_completada, nota, zona)
  values (v_id, now(), v_user, v_items, v_estado,
          case when v_comp then null else v_user end,
          case when v_comp then null else now() end,
          null, coalesce(p->>'nota',''), v_zona)
  on conflict (id_lista) do nothing;
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'estado', v_estado, 'zona', v_zona));
end;
$fn$;
revoke all on function wh.crear_lista_sombra(jsonb) from public;
grant execute on function wh.crear_lista_sombra(jsonb) to authenticated, service_role;
