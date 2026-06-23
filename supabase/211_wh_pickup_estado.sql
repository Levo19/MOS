-- ════════════════════════════════════════════════════════════════════════════
-- 211 · Estado/lock/progreso de pickup 100% Supabase
-- ════════════════════════════════════════════════════════════════════════════
-- Cierra la ASIMETRÍA que rompía al operador de WH: la lista (getPickups) se LEE
-- de wh.pickups, pero estas 3 escrituras seguían en GAS (Hoja):
--   actualizarPickup     (estado + lock atendido_por)
--   guardarProgresoPickup (autosave de lo escaneado, cada 4s)
--   liberarPickup        (soltar el pickup)
-- → el lock y el progreso NO viajaban al store que lee la lista → dos equipos del
--   mismo operador no veían lo mismo, RIZ fallaba ("no encontrado" tragado), y el
--   lock no servía. Migrarlas a Supabase hace funcionar el cross-device POR USUARIO
--   que el frontend ya soporta. NO tocan stock (eso vive solo en cerrar_pickup).
--
-- INERTE: flag único WH_PICKUP_ESTADO_DIRECTO='0'. *_OFF → frontend cae a GAS.
-- Un solo flag para las 3 (activación parcial reintroduciría la asimetría).
-- ════════════════════════════════════════════════════════════════════════════

insert into mos.config (clave, valor)
values ('WH_PICKUP_ESTADO_DIRECTO', '0')
on conflict (clave) do nothing;

-- Comparación de usuario normalizada (trim + lower + colapsar espacios internos).
-- Espejo de _sameUser_ (GAS): tolera mayúsculas/dobles espacios entre devices del
-- mismo operador. STABLE, sin efectos.
create or replace function wh._pickup_same_user(a text, b text)
returns boolean language sql immutable as $$
  select lower(regexp_replace(btrim(coalesce(a,'')), '\s+', ' ', 'g'))
       = lower(regexp_replace(btrim(coalesce(b,'')), '\s+', ' ', 'g'));
$$;

-- ── 1) wh.actualizar_pickup(p) ──────────────────────────────────────────────
-- p = { id_pickup, estado?, lock_usuario?, tomar_lock?, liberar_lock? }
create or replace function wh.actualizar_pickup(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_estado  text := nullif(btrim(coalesce(p->>'estado','')),'');
  v_lock    text := coalesce(p->>'lock_usuario', p->>'lockUsuario', '');
  v_tomar   boolean := coalesce((p->>'tomar_lock')::boolean, (p->>'tomarLock')::boolean, false);
  v_liberar boolean := coalesce((p->>'liberar_lock')::boolean, (p->>'liberarLock')::boolean, false);
  v_atp     text;
  v_now     timestamptz := now();
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select atendido_por into v_atp from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- Conflicto de lock: lo atiende OTRO usuario (no yo en otro device)
  if v_lock <> '' and coalesce(btrim(v_atp),'') <> '' and not wh._pickup_same_user(v_atp, v_lock) then
    return jsonb_build_object('ok',false,'error','Pickup atendido por '||v_atp,'atendidoPor',v_atp,'conflicto',true);
  end if;

  update wh.pickups
     set estado         = coalesce(v_estado, estado),
         fecha_atendido = case when v_estado = 'COMPLETADO' then v_now else fecha_atendido end,
         atendido_por   = case when v_liberar then ''
                               when v_tomar and v_lock <> '' then v_lock
                               else atendido_por end,
         ultima_actividad = v_now
   where id_pickup = v_idp;
  return jsonb_build_object('ok',true);
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$fn$;

-- ── 2) wh.guardar_progreso_pickup(p) ────────────────────────────────────────
-- p = { id_pickup, items: [...], lock_usuario? }   (autosave de lo escaneado)
create or replace function wh.guardar_progreso_pickup(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_idp   text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_lock  text := coalesce(p->>'lock_usuario', p->>'lockUsuario', '');
  v_items jsonb := p->'items';
  v_atp   text;
  v_est   text;
  v_now   timestamptz := now();
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select atendido_por, estado into v_atp, v_est from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- Conflicto de lock; si no había lock, tomarlo (autosave implica que estoy trabajando)
  if v_lock <> '' then
    if coalesce(btrim(v_atp),'') <> '' and not wh._pickup_same_user(v_atp, v_lock) then
      return jsonb_build_object('ok',false,'error','Pickup atendido por '||v_atp,'atendidoPor',v_atp,'conflicto',true);
    end if;
  end if;

  update wh.pickups
     set items            = case when jsonb_typeof(v_items) = 'array' then v_items else items end,
         atendido_por     = case when v_lock <> '' and coalesce(btrim(atendido_por),'')='' then v_lock else atendido_por end,
         estado           = case when upper(coalesce(estado,'')) = 'PENDIENTE' then 'EN_PROCESO' else estado end,
         ultima_actividad = v_now
   where id_pickup = v_idp;
  return jsonb_build_object('ok',true);
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$fn$;

-- ── 3) wh.liberar_pickup(p) ─────────────────────────────────────────────────
-- p = { id_pickup }   (operador "suelta"; si hay progreso queda EN_PROCESO)
create or replace function wh.liberar_pickup(p jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_idp   text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup','')),'');
  v_items jsonb;
  v_hay   boolean;
  v_now   timestamptz := now();
begin
  if coalesce((select valor from mos.config where clave='WH_PICKUP_ESTADO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','WH_PICKUP_ESTADO_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPickup'); end if;

  select items into v_items from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok',false,'error','Pickup no encontrado'); end if;

  -- ¿hay progreso? (algún item con despachado > 0)
  select exists (
    select 1 from jsonb_array_elements(case when jsonb_typeof(v_items)='array' then v_items else '[]'::jsonb end) e
    where wh._num(coalesce(e->>'despachado','0')) > 0
  ) into v_hay;

  update wh.pickups
     set atendido_por     = '',
         estado           = case when v_hay then estado else 'PENDIENTE' end,
         ultima_actividad = v_now
   where id_pickup = v_idp;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('hayProgreso', v_hay));
exception when others then
  return jsonb_build_object('ok',false,'error','EXCEPCION','detalle',SQLERRM);
end;
$fn$;

revoke all on function wh.actualizar_pickup(jsonb)        from public;
revoke all on function wh.guardar_progreso_pickup(jsonb)  from public;
revoke all on function wh.liberar_pickup(jsonb)           from public;
grant execute on function wh.actualizar_pickup(jsonb)       to service_role, authenticated;
grant execute on function wh.guardar_progreso_pickup(jsonb) to service_role, authenticated;
grant execute on function wh.liberar_pickup(jsonb)          to service_role, authenticated;
