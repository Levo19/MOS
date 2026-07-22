-- ============================================================================
-- 538_wh_lista_sombra_items_string.sql — Listas sombra: aceptar items como STRING JSON
-- ----------------------------------------------------------------------------
-- BUG (reportado por el dueño, 2 días seguidos): "No se pudo subir al equipo: sin items".
-- El frontend WH SIEMPRE envió items como JSON.stringify(...) (string). El GAS viejo
-- hacía JSON.parse y funcionaba; al cortar GAS (listas sombra 100% directo, "sin GAS
-- detrás" en api.js), el error de la RPC quedó expuesto:
--   · crear_lista_sombra (294):  jsonb_typeof(items) <> 'array' → 'sin items'  (bloquea subir al feed)
--   · actualizar_progreso (216): 'items debe ser array' → el avance del picker NO se guardaba (silencioso)
--   · cerrar_lista_sombra (216): cerraba pero DESCARTABA los items finales (silencioso)
--
-- FIX: normalizar v_items — si llega como string jsonb, parsearlo (con guarda de
-- excepción). Server-side para que TODAS las tablets (incluidas las de app.js cacheado
-- viejo) queden arregladas al instante. El frontend también se corrige aparte (manda
-- array real), pero esta RPC queda tolerante a ambas formas para siempre.
-- Clona la lógica vigente EXACTA: crear = 294 (acumula+zona), progreso/cerrar = 216.
-- ============================================================================

-- ── CREAR (base 294: zona + acumulador LISTA_IA) ────────────────────────────
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
  -- [538] items puede venir como STRING JSON (frontend histórico) → parsear.
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

-- ── ACTUALIZAR PROGRESO (base 216) ──────────────────────────────────────────
create or replace function wh.actualizar_progreso_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLista','')), ''); v_items jsonb := p->'items'; v_n int;
begin
  -- [538] items string → parsear
  if v_items is not null and jsonb_typeof(v_items) = 'string' then
    begin v_items := (p->>'items')::jsonb; exception when others then v_items := null; end;
  end if;
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;
  if v_items is null or jsonb_typeof(v_items) <> 'array' then return jsonb_build_object('ok',false,'error','items debe ser array'); end if;
  update wh.listas_sombra set items = v_items where id_lista = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

-- ── CERRAR (base 216: COMPLETADA + items finales opcionales) ────────────────
create or replace function wh.cerrar_lista_sombra(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_id text := nullif(btrim(coalesce(p->>'idLista','')), ''); v_items jsonb := p->'items'; v_n int;
begin
  -- [538] items string → parsear (antes se DESCARTABAN los items finales en silencio)
  if v_items is not null and jsonb_typeof(v_items) = 'string' then
    begin v_items := (p->>'items')::jsonb; exception when others then v_items := null; end;
  end if;
  if coalesce((select valor from mos.config where clave='WH_LISTA_SOMBRA_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_LISTA_SOMBRA_DIRECTO_OFF'); end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idLista requerido'); end if;
  update wh.listas_sombra
     set items = case when v_items is not null and jsonb_typeof(v_items)='array' then v_items else items end,
         estado='COMPLETADA', fecha_completada=now()
   where id_lista = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','NO_ENCONTRADA'); end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

revoke all on function wh.crear_lista_sombra(jsonb), wh.actualizar_progreso_lista_sombra(jsonb), wh.cerrar_lista_sombra(jsonb) from public;
grant execute on function wh.crear_lista_sombra(jsonb), wh.actualizar_progreso_lista_sombra(jsonb), wh.cerrar_lista_sombra(jsonb) to authenticated, service_role;
