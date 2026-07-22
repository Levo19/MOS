-- ════════════════════════════════════════════════════════════════════════════
-- 540 · Listas sombra v2 — la demanda entra al acumulado AL CERRAR, no al crear
-- ════════════════════════════════════════════════════════════════════════════
-- Diseño del dueño (2026-07-22). Problema del modelo 294 (acumular al CREAR):
--   1) infla el acumulado mientras la sombra está por despacharse (confunde), y
--   2) HUECO: la sombra despachada SOLA (guía propia) nunca saldaba esa demanda
--      → deuda fantasma permanente.
--
-- MODELO NUEVO — una sola fórmula, por producto, al CERRAR la sombra:
--     deuda_nueva = max(0, deuda_vieja + pedido_sombra − despachado_sombra)
--   · debe 10, pide 50, despacha 40 → debe 20 (el resto se suma).
--   · debe 10, pide 50, despacha 80 → debe 0 (el exceso MATA deuda, piso en 0:
--     jamás crédito negativo; coherente con el settle semanal — la semana
--     siguiente igual nace en cero tras el week-death → REZAGADO).
--   · El registro de lo despachado queda TRIPLE: guía de salida (detalle+kardex),
--     lista sombra COMPLETADA almacenada, y el item del acumulado muestra su
--     `despachado` (defensa ante reclamos: "sí te despaché al menos parte").
--
-- Mecánica: cerrar_lista_sombra inserta un pickup 'PCK-LSC-<id>' (fuente
-- LISTA_IA) con {solicitado: pedido, despachado: escaneado} por item identificado
-- → el trigger consolida al instante (o el cron horario si la acumulada está
-- EN_PROCESO). El settle (pendiente = max(0, sol−desp)) produce la fórmula.
-- consolidar_pickup_zona ahora MERGEA sol+desp para fuente LISTA_IA (los demás
-- siguen aportando solo el remanente, sin cambios).
--
-- TTL (regla del dueño): sombra NO despachada en 24h desde su creación → se
-- ELIMINA (ANULADA) sin acumular nada — puede ser un escaneo errado del
-- operador; acumularla inflaría demanda que no es real. Cron horario.
--
-- Money-safe: la guía sigue saliendo SOLO de lo escaneado (RPC 210/414 intacta);
-- aquí solo se mueve la DEMANDA. Cierre idempotente (guard COMPLETADA + id
-- determinista del PCK-LSC con on conflict do nothing → un retry no duplica).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) CREAR: igual que 538 (tolerante a items string) SIN el bloque acumulador de 294 ──
create or replace function wh.crear_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
  v_user text := nullif(btrim(coalesce(p->>'usuario','')), '');
  v_items jsonb := p->'items';
  v_id   text := nullif(btrim(coalesce(p->>'idLista','')), '');
  v_comp boolean := coalesce((p->>'compartir')::boolean, false);
  v_zona text := btrim(coalesce(p->>'idZona', p->>'zona', ''));
  v_estado text;
begin
  if v_items is not null and jsonb_typeof(v_items) = 'string' then
    begin v_items := (p->>'items')::jsonb; exception when others then v_items := null; end;
  end if;
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_user is null then return jsonb_build_object('ok',false,'error','usuario requerido'); end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok',false,'error','sin items'); end if;
  v_id := coalesce(v_id, 'LS'||(extract(epoch from clock_timestamp())*1000)::bigint::text);
  if exists (select 1 from wh.listas_sombra where id_lista = v_id) then
    return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'duplicado', true)); end if;
  v_estado := case when v_comp then 'DISPONIBLE' else 'EN_USO' end;
  insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, usuario_tomada, fecha_tomada, fecha_completada, nota, zona)
  values (v_id, now(), v_user, v_items, v_estado,
          case when v_comp then null else v_user end,
          case when v_comp then null else now() end,
          null, coalesce(p->>'nota',''), v_zona)
  on conflict (id_lista) do nothing;
  -- [540] El bloque [294] "acumular al crear" fue ELIMINADO: la demanda entra al CERRAR.
  return jsonb_build_object('ok',true,'data', jsonb_build_object('idLista', v_id, 'estado', v_estado, 'zona', v_zona));
end;
$fn$;

-- ── 2) CERRAR: COMPLETADA + contabilidad hacia el acumulado (fórmula del dueño) ──
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
  -- Idempotencia: un retry sobre una lista ya cerrada NO re-contabiliza.
  if upper(coalesce(v_row.estado,'')) in ('COMPLETADA','ANULADA') then
    return jsonb_build_object('ok',true,'idempotente',true); end if;

  v_final := case when v_items is not null and jsonb_typeof(v_items)='array' then v_items else v_row.items end;
  update wh.listas_sombra
     set items = coalesce(v_final, items), estado='COMPLETADA', fecha_completada=v_now
   where id_lista = v_id;

  -- [540] deuda_nueva = max(0, deuda + pedido − despachado): se materializa vía
  -- pickup PCK-LSC (sol=pedido, desp=escaneado) que el consolidador mergea.
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
    exception when others then null;  -- la contabilidad jamás rompe el cierre (cron repara)
    end;
  end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

-- ── 3) CONSOLIDAR: base 539 + merge sol&desp para fuente LISTA_IA ──
create or replace function wh.consolidar_pickup_zona(p_zona text, p_bucket date)
returns jsonb
language plpgsql security definer set search_path = '' as $fn$
declare
  v_acum_id   text := 'PCK-ACU-' || p_zona || '-' || to_char(p_bucket, 'YYYY-MM-DD');
  v_existing  jsonb;
  v_est       text;
  v_map       jsonb := '{}'::jsonb;
  v_it        jsonb;
  v_sku       text;
  v_pend      numeric;
  v_sol_add   numeric;
  v_desp_add  numeric;
  v_cand      record;
  v_items_out jsonb;
  v_abs       int := 0;
  v_rez       int := 0;
  v_lib       int := 0;
  v_now       timestamptz := now();
begin
  -- [539-A] ANTI-SECUESTRO 1h (ultima_actividad = último producto agregado, vía autosave)
  update wh.pickups
     set estado = 'PENDIENTE', atendido_por = '', ultima_actividad = v_now
   where coalesce(id_zona,'') = p_zona
     and upper(coalesce(estado,'')) = 'EN_PROCESO'
     and ultima_actividad < v_now - interval '1 hour';
  get diagnostics v_lib = row_count;

  select items, estado into v_existing, v_est
    from wh.pickups where id_pickup = v_acum_id for update;
  if v_est is not null and upper(v_est) = 'EN_PROCESO' then
    return jsonb_build_object('ok', true, 'skip', 'EN_PROCESO', 'acum', v_acum_id, 'liberados', v_lib);
  end if;

  -- SEED: pendiente = max(0, sol−desp), reset desp (aquí actúa el piso en 0 de la fórmula).
  if v_existing is not null and jsonb_typeof(v_existing) = 'array' then
    for v_it in select * from jsonb_array_elements(v_existing) loop
      v_sku := coalesce(v_it->>'skuBase', '');
      if v_sku = '' then continue; end if;
      v_pend := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
      if v_pend <= 0 then continue; end if;
      v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
        'skuBase', v_sku,
        'nombre', coalesce(v_it->>'nombre', v_sku),
        'solicitado', v_pend,
        'despachado', 0,
        'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)
      ), true);
    end loop;
  end if;

  -- [539-C] Absorber sueltos del bucket vigente o ANTERIORES.
  -- [540] fuente LISTA_IA (cierres de sombra): mergea sol Y desp → fórmula
  --       deuda = max(0, deuda + pedido − despachado) al próximo seed.
  --       Otras fuentes: solo el remanente (comportamiento intacto).
  for v_cand in
    select id_pickup, items, coalesce(fuente,'') as fuente from wh.pickups
    where coalesce(id_zona,'') = p_zona
      and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL')
      and coalesce(fuente,'') <> 'ACUMULADO_SEMANAL'
      and wh._bucket_dom((fecha_creado at time zone 'America/Lima')::date) <= p_bucket
    for update
  loop
    if jsonb_typeof(v_cand.items) = 'array' then
      for v_it in select * from jsonb_array_elements(v_cand.items) loop
        v_sku := coalesce(v_it->>'skuBase', '');
        if v_sku = '' then continue; end if;
        if v_cand.fuente = 'LISTA_IA' then
          v_sol_add  := wh._num(coalesce(v_it->>'solicitado','0'));
          v_desp_add := wh._num(coalesce(v_it->>'despachado','0'));
          if v_sol_add <= 0 and v_desp_add <= 0 then continue; end if;
        else
          v_sol_add  := greatest(0, wh._num(coalesce(v_it->>'solicitado','0')) - wh._num(coalesce(v_it->>'despachado','0')));
          v_desp_add := 0;
          if v_sol_add <= 0 then continue; end if;
        end if;
        if v_map ? v_sku then
          v_map := jsonb_set(v_map, array[v_sku,'solicitado'],
            to_jsonb(wh._num(coalesce(v_map->v_sku->>'solicitado','0')) + v_sol_add), true);
          if v_desp_add > 0 then
            v_map := jsonb_set(v_map, array[v_sku,'despachado'],
              to_jsonb(wh._num(coalesce(v_map->v_sku->>'despachado','0')) + v_desp_add), true);
          end if;
        else
          v_map := jsonb_set(v_map, array[v_sku], jsonb_build_object(
            'skuBase', v_sku,
            'nombre', coalesce(v_it->>'nombre', v_sku),
            'solicitado', v_sol_add,
            'despachado', v_desp_add,
            'codigosOriginales', coalesce(v_it->'codigosOriginales','[]'::jsonb)
          ), true);
        end if;
      end loop;
    end if;
    update wh.pickups
       set estado = 'ABSORBIDO',
           notas = coalesce(notas,'') || ' [abs:' || v_acum_id || ']',
           ultima_actividad = v_now
     where id_pickup = v_cand.id_pickup;
    v_abs := v_abs + 1;
  end loop;

  select coalesce(jsonb_agg(value), '[]'::jsonb) into v_items_out from jsonb_each(v_map);

  if v_existing is not null then
    update wh.pickups
       set items = v_items_out, ultima_actividad = v_now,
           estado = case when upper(coalesce(estado,'')) in ('PENDIENTE','EN_PROCESO') then estado else 'PENDIENTE' end
     where id_pickup = v_acum_id;
  elsif jsonb_array_length(v_items_out) > 0 then
    insert into wh.pickups (id_pickup, fuente, estado, items, id_zona, notas, creado_por, fecha_creado, ultima_actividad)
    values (v_acum_id, 'ACUMULADO_SEMANAL', 'PENDIENTE', v_items_out, p_zona,
            'ACUMULADO semana-domingo ' || to_char(p_bucket,'YYYY-MM-DD'), 'sistema', v_now, v_now);
  end if;

  -- [539-B] WEEK-DEATH implacable (incluye EN_PROCESO de buckets anteriores).
  update wh.pickups
     set estado = 'REZAGADO', atendido_por = '', ultima_actividad = v_now
   where coalesce(id_zona,'') = p_zona
     and fuente = 'ACUMULADO_SEMANAL'
     and upper(coalesce(estado,'')) in ('PENDIENTE','PARCIAL','EN_PROCESO')
     and id_pickup <> v_acum_id
     and id_pickup like 'PCK-ACU-' || p_zona || '-%'
     and right(id_pickup, 10) ~ '^\d{4}-\d{2}-\d{2}$'
     and to_date(right(id_pickup, 10), 'YYYY-MM-DD') < p_bucket;
  get diagnostics v_rez = row_count;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'acum', v_acum_id, 'absorbidos', v_abs, 'rezagados', v_rez, 'liberados', v_lib,
    'items', jsonb_array_length(v_items_out)));
end;
$fn$;

-- ── 4) TTL 24h: sombra no despachada se ELIMINA (no acumula — puede ser escaneo errado) ──
create or replace function wh.vencer_listas_sombra()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_disp int := 0; v_uso int := 0;
begin
  update wh.listas_sombra
     set estado='ANULADA', fecha_completada=now(),
         nota = coalesce(nota,'') || ' [vencida: 24h sin despachar]'
   where upper(coalesce(estado,'')) = 'DISPONIBLE'
     and fecha_creacion < now() - interval '24 hours';
  get diagnostics v_disp = row_count;
  update wh.listas_sombra
     set estado='ANULADA', fecha_completada=now(),
         nota = coalesce(nota,'') || ' [vencida: 24h jalada sin cerrar]'
   where upper(coalesce(estado,'')) = 'EN_USO'
     and coalesce(fecha_tomada, fecha_creacion) < now() - interval '24 hours';
  get diagnostics v_uso = row_count;
  return jsonb_build_object('ok',true,'vencidasDisponibles',v_disp,'vencidasEnUso',v_uso);
end;
$fn$;

revoke all on function wh.crear_lista_sombra(jsonb), wh.cerrar_lista_sombra(jsonb), wh.consolidar_pickup_zona(text,date), wh.vencer_listas_sombra() from public;
grant execute on function wh.crear_lista_sombra(jsonb), wh.cerrar_lista_sombra(jsonb) to authenticated, service_role;

select cron.schedule('wh-sombras-vencer', '20 * * * *', $$ select wh.vencer_listas_sombra(); $$);
