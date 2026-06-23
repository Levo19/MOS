-- ════════════════════════════════════════════════════════════════════════════
-- 210 · wh.cerrar_pickup_con_despacho(p) — DESPACHO DE PICKUP 100% SUPABASE
-- ════════════════════════════════════════════════════════════════════════════
-- PROBLEMA: la lista de pickups (🛒) ya vive en Supabase (wh.pickups: cierre-caja
-- espejado + RIZ/carrito "pedir almacén" nativo). WH la LEE de Supabase
-- (api.js getPickups → _sbLeerTablaWH('pickups')). Pero el DESPACHO ("Jalar")
-- seguía en GAS (cerrarPickupConDespacho → Hoja PICKUPS). Los pickups RIZ NUNCA
-- se escriben a la Hoja → "Pickup no encontrado" → quedaban atascados, no
-- despachables. Asimetría lectura-Supabase / escritura-GAS.
--
-- FIX: migrar el cierre a Supabase. Esta RPC es un ORQUESTADOR que reusa el
-- motor de dinero ya vivo wh.crear_despacho_rapido (SQL 160, flag
-- WH_CREAR_DESPACHO_RAPIDO_DIRECTO=ON) — NO reimplementa stock/kardex/FIFO.
-- Solo: lee el pickup, idempotencia, computa el despachoDetalle, crea la
-- GUIA_SALIDA vía crear_despacho_rapido, y marca el pickup terminal. Espejo
-- fiel de warehouseMos/gas/Guias.gs::_cerrarPickupConDespachoImpl.
--
-- INERTE: flag propio WH_CERRAR_PICKUP_DIRECTO='0' (default). Devuelve
-- *_OFF → el frontend cae a GAS. Cutover = poner el flag en '1' (SQL aparte).
-- Kill-switch instantáneo sin redeploy.
-- ════════════════════════════════════════════════════════════════════════════

-- Flag INERTE (no pisa si ya existe con otro valor)
insert into mos.config (clave, valor)
values ('WH_CERRAR_PICKUP_DIRECTO', '0')
on conflict (clave) do nothing;

create or replace function wh.cerrar_pickup_con_despacho(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'id_pickup', p->>'idPickup', '')), '');
  v_usuario text := coalesce(p->>'usuario', '');
  v_items   jsonb := coalesce(p->'items', '[]'::jsonb);
  v_det     jsonb := coalesce(p->'despacho_detalle', p->'despachoDetalle', '[]'::jsonb);
  v_pickup  record;
  v_est_up  text;
  v_it      jsonb;
  v_cod     text;
  v_qty     numeric;
  v_total_desp numeric := 0;
  v_no_desp int := 0;
  v_nuevo_estado text;
  v_idguia  text := null;
  v_guia_prev text;
  v_desp_res jsonb;
  v_now     timestamptz := now();
begin
  -- Gate propio (kill-switch). OFF → frontend cae a GAS.
  if coalesce((select valor from mos.config where clave = 'WH_CERRAR_PICKUP_DIRECTO' limit 1), '0') <> '1' then
    return jsonb_build_object('ok', false, 'error', 'WH_CERRAR_PICKUP_DIRECTO_OFF');
  end if;
  if not wh._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok', false, 'error', 'Requiere idPickup'); end if;

  -- Leer pickup con lock (serializa contra retry/doble-tap concurrente del mismo id)
  select * into v_pickup from wh.pickups where id_pickup = v_idp for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Pickup no encontrado'); end if;

  -- ── IDEMPOTENCIA NIVEL 1: solo PENDIENTE/EN_PROCESO son despachables ──
  -- Guard INCLUSIVO (endurecido SQL 212): cualquier OTRO estado (COMPLETADO/PARCIAL/
  -- CANCELADO/ELIMINADO/ABSORBIDO/ACUMULADO ya cerrado/futuros) bloquea el despacho.
  -- Crítico money: un pickup ELIMINADO (borrado admin) o ABSORBIDO (consolidado en la
  -- lista acumulada semanal) NUNCA debe poder despacharse → si no, se duplicaría el
  -- stock (el ítem ya vive en la acumulada). '' (estado en blanco anómalo) se permite.
  v_est_up := upper(coalesce(v_pickup.estado, ''));
  if v_est_up not in ('PENDIENTE', 'EN_PROCESO', '') then
    return jsonb_build_object('ok', false,
      'error', 'El pickup ya no es despachable (estado=' || v_est_up || ')', 'yaCerrado', true);
  end if;

  -- ── IDEMPOTENCIA NIVEL 2: ¿ya existe una guía para este pickup? ──
  -- Marca [pickup:idPickup] en el comentario. Cubre el caso money-critical:
  -- el pickup quedó PENDIENTE en wh.pickups (espejo viejo fallido / cross-path
  -- GAS↔Supabase) PERO su GUIA_SALIDA ya se creó (id distinto, p.ej. del path
  -- GAS legacy). Sin esta defensa, "Jalar" crearía una SEGUNDA guía = doble
  -- descuento de stock. Espejo de _buscarGuiaPorPickupReciente (GAS). Si la
  -- hay → reusar, forzar el pickup a terminal, NO crear duplicado.
  select id_guia into v_guia_prev
  from wh.guias
  where comentario like '%[pickup:' || v_idp || ']%'
  order by fecha desc
  limit 1;
  if v_guia_prev is not null then
    update wh.pickups
       set estado           = case when upper(coalesce(estado,'')) not in ('PENDIENTE','EN_PROCESO','')
                                     then estado else 'COMPLETADO' end,
           fecha_atendido   = coalesce(fecha_atendido, v_now),
           atendido_por     = '',
           ultima_actividad = v_now
     where id_pickup = v_idp;
    return jsonb_build_object('ok', true, 'data', jsonb_build_object(
      'idGuia', v_guia_prev, 'estado', 'COMPLETADO', 'yaCerrado', true, 'idempotente', true));
  end if;

  -- ── Derivar despachoDetalle desde items si no vino (codigosOriginales[0]) ──
  -- Regla de oro: NUNCA usar skuBase como codigoBarra. Solo codigosOriginales
  -- (canónico/equivalente). Item sin codigosOriginales → se salta (mejor perder
  -- ese item del despacho que romper el descuento de stock por codigoBarra).
  if jsonb_typeof(v_det) <> 'array' or jsonb_array_length(v_det) = 0 then
    v_det := '[]'::jsonb;
    for v_it in select * from jsonb_array_elements(v_items) loop
      v_qty := wh._num(coalesce(v_it->>'despachado', '0'));
      if v_qty <= 0 then continue; end if;
      v_cod := nullif(btrim(coalesce(v_it->'codigosOriginales'->>0, '')), '');
      if v_cod is null then continue; end if;
      v_det := v_det || jsonb_build_array(jsonb_build_object('codigo_barra', v_cod, 'cantidad', v_qty));
    end loop;
  end if;

  -- Total despachado (acepta codigo_barra / codigoBarra en cada línea)
  for v_it in select * from jsonb_array_elements(v_det) loop
    v_total_desp := v_total_desp + wh._num(coalesce(v_it->>'cantidad', '0'));
  end loop;

  -- No despachados: solicitado > despachado (para observación + estado)
  select count(*) into v_no_desp
  from jsonb_array_elements(v_items) e
  where wh._num(coalesce(e->>'solicitado', '0')) > wh._num(coalesce(e->>'despachado', '0'));

  v_nuevo_estado := case
    when v_no_desp = 0 then 'COMPLETADO'
    when v_total_desp > 0 then 'PARCIAL'
    else 'CANCELADO'
  end;

  -- ── Crear GUIA_SALIDA si hubo al menos un item despachado ──
  -- id_guia ESTABLE derivado del pickup → crear_despacho_rapido dedupea por id
  -- (un retro/retry NO duplica guía/stock/kardex). comentario [pickup:id] = la
  -- marca que el ticket usa para reconstruir las secciones.
  if v_total_desp > 0 then
    v_idguia := 'GPCK_' || v_idp;
    v_desp_res := wh.crear_despacho_rapido(jsonb_build_object(
      'id_guia',    v_idguia,
      'tipo',       'SALIDA_ZONA',
      'id_zona',    coalesce(v_pickup.id_zona, ''),
      'usuario',    v_usuario,
      'comentario', '[pickup:' || v_idp || ']',
      'items',      v_det
    ));
    if coalesce((v_desp_res->>'ok'), 'false') <> 'true' then
      -- crear_despacho_rapido NO commiteó (su tx hizo rollback en su EXCEPTION o
      -- devolvió *_OFF) → propagar el error SIN tocar el pickup (queda PENDIENTE,
      -- reintentable). Money-safe: no marcamos terminal sin guía.
      return jsonb_build_object('ok', false,
        'error', 'Falló GUIA_SALIDA: ' || coalesce(v_desp_res->>'error', '?'));
    end if;
    v_idguia := coalesce(v_desp_res->>'idGuia', v_idguia);
  end if;

  -- ── Actualizar pickup (terminal) ──
  -- items := snapshot recibido (con despachado por línea, igual que GAS).
  -- atendido_por := '' libera el lock de atención al cerrar.
  update wh.pickups
     set items            = v_items,
         estado           = v_nuevo_estado,
         fecha_atendido   = v_now,
         atendido_por     = '',
         ultima_actividad = v_now
   where id_pickup = v_idp;

  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'idGuia',        v_idguia,
    'estado',        v_nuevo_estado,
    'despachados',   jsonb_array_length(v_det),
    'noDespachados', v_no_desp
  ));
exception when others then
  -- Cualquier excepción de ESTA función (no de crear_despacho_rapido, que se
  -- maneja arriba) → reportar sin marcar el pickup. La tx entera hace rollback.
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$fn$;

revoke all on function wh.cerrar_pickup_con_despacho(jsonb) from public;
grant execute on function wh.cerrar_pickup_con_despacho(jsonb) to service_role, authenticated;
