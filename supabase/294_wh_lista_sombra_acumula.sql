-- ============================================================================
-- 294_wh_lista_sombra_acumula.sql — La lista IA alimenta el acumulador de la zona
-- ----------------------------------------------------------------------------
-- Ahora que la lista sombra (IA) lleva ZONA (292), su DEMANDA debe acumularse en el
-- bucket-domingo de esa zona IGUAL que un pickup (lo pedido + lo que faltó). Reusa el
-- motor money-safe existente: al crear la lista, se inserta un pickup `LISTA_IA`
-- (PENDIENTE) con los ítems identificados → el trigger tg_pickup_consolidar lo
-- consolida en PCK-ACU-<zona>-<domingo> y lo marca ABSORBIDO (sin doble conteo).
--
-- ⚠️ MONEY/OPS-SAFE: el feed va en un bloque BEGIN/EXCEPTION → si algo falla, la lista
--    se crea igual (jamás se rompe el flujo del operador). Solo ítems con skuBase y
--    cantidad>0 acumulan (la consolidación ignora sku vacío). Cero-GAS.
-- ============================================================================

create or replace function wh.crear_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_items jsonb := p->'items';
  v_id   text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_comp boolean := coalesce((p->>'compartir')::boolean, false);
  v_zona text := btrim(coalesce(p->>'idZona', p->>'zona', ''));
  v_estado text;
  v_pick_items jsonb;
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

  -- [294] Acumular la demanda de la lista en el bucket de la zona (como un pickup).
  if v_zona <> '' then
    begin
      select coalesce(jsonb_agg(jsonb_build_object(
               'skuBase',    it->>'skuBase',
               'nombre',     coalesce(nullif(btrim(coalesce(it->>'nombreMaster','')),''), it->>'nombre', it->>'skuBase'),
               'solicitado', wh._num(coalesce(it->>'cantidad','0')),
               'despachado', 0
             )), '[]'::jsonb)
        into v_pick_items
        from jsonb_array_elements(v_items) it
       where coalesce(btrim(it->>'skuBase'),'') <> ''
         and wh._num(coalesce(it->>'cantidad','0')) > 0;
      if v_pick_items is not null and jsonb_array_length(v_pick_items) > 0 then
        insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
        values ('PCK-LSIA-'||v_id, 'LISTA_IA', 'PENDIENTE', v_pick_items, v_zona,
                'Demanda de lista IA '||v_id, v_user, now(), now())
        on conflict (id_pickup) do nothing;
      end if;
    exception when others then null;  -- nunca romper la creación de la lista
    end;
  end if;

  return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'estado', v_estado, 'zona', v_zona));
end;
$fn$;
revoke all on function wh.crear_lista_sombra(jsonb) from public;
grant execute on function wh.crear_lista_sombra(jsonb) to authenticated, service_role;
