-- ════════════════════════════════════════════════════════════════════════════
-- 541 · Cierre TARDÍO de lista sombra resucita una vencida por TTL
-- ════════════════════════════════════════════════════════════════════════════
-- Carrera que cierra (complemento del 540): el cierre viaja por la cola offline
-- del equipo (write-ahead, WH 2.13.477). Si el equipo vuelve a tener línea
-- DESPUÉS de 24h, el cron TTL ya anuló la lista ('[vencida...]') y el guard de
-- idempotencia del cierre la ignoraba → contabilidad perdida PESE a que la guía
-- física existió. Ahora: un cierre que llega sobre una lista ANULADA cuya nota
-- contiene '[vencida' la RESUCITA (COMPLETADA + contabilidad normal). Las
-- anuladas MANUALMENTE (✕ del operador, sin esa marca) siguen muertas: un cierre
-- tardío sobre ellas mantiene el skip idempotente.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function wh.cerrar_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_items jsonb := p->'items';
  v_row  record;
  v_final jsonb;
  v_pick jsonb;
  v_now  timestamptz := now();
begin
  if v_items is not null and jsonb_typeof(v_items) = 'string' then
    begin v_items := (p->>'items')::jsonb; exception when others then v_items := null; end;
  end if;
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;

  select * into v_row from wh.listas_sombra where id_lista = v_id for update;
  if not found then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  -- Idempotencia: COMPLETADA no se re-contabiliza. ANULADA manual tampoco.
  -- [541] ANULADA por VENCIMIENTO ('[vencida') + llega el cierre real → RESUCITAR:
  -- la guía física existió, la contabilidad debe entrar.
  if upper(coalesce(v_row.estado,'')) = 'COMPLETADA' then
    return jsonb_build_object('ok',true,'idempotente',true); end if;
  if upper(coalesce(v_row.estado,'')) = 'ANULADA' and position('[vencida' in coalesce(v_row.nota,'')) = 0 then
    return jsonb_build_object('ok',true,'idempotente',true,'anuladaManual',true); end if;

  v_final := case when v_items is not null and jsonb_typeof(v_items)='array' then v_items else v_row.items end;
  update wh.listas_sombra
     set items = coalesce(v_final, items), estado='COMPLETADA', fecha_completada=v_now,
         nota = case when upper(coalesce(v_row.estado,''))='ANULADA'
                     then coalesce(v_row.nota,'') || ' [541: resucitada por cierre tardío]'
                     else nota end
   where id_lista = v_id;

  -- [540] deuda_nueva = max(0, deuda + pedido − despachado) vía pickup PCK-LSC.
  if coalesce(btrim(v_row.zona),'') <> '' and v_final is not null and jsonb_typeof(v_final)='array' then
    begin
      select coalesce(jsonb_agg(jsonb_build_object(
               'skuBase',    it->>'skuBase',
               'nombre',     coalesce(nullif(btrim(coalesce(it->>'nombreMaster','')),''), it->>'nombre', it->>'skuBase'),
               'solicitado', wh._num(coalesce(it->>'cantidad','0')),
               'despachado', wh._num(coalesce(it->>'cantidadEscaneada','0'))
             )), '[]'::jsonb)
        into v_pick
        from jsonb_array_elements(v_final) it
       where coalesce(btrim(it->>'skuBase'),'') <> ''
         and (wh._num(coalesce(it->>'cantidad','0')) > 0 or wh._num(coalesce(it->>'cantidadEscaneada','0')) > 0);
      if v_pick is not null and jsonb_array_length(v_pick) > 0 then
        insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
        values ('PCK-LSC-'||v_id, 'LISTA_IA', 'PENDIENTE', v_pick, btrim(v_row.zona),
                'Cierre lista IA '||v_id||' · pedido−despachado → acumulado', coalesce(v_row.usuario_tomada, v_row.usuario_creador, 'sistema'), v_now, v_now)
        on conflict (id_pickup) do nothing;
      end if;
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

revoke all on function wh.cerrar_lista_sombra(jsonb) from public;
grant execute on function wh.cerrar_lista_sombra(jsonb) to authenticated, service_role;
