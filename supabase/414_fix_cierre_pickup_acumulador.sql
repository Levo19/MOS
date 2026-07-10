-- ════════════════════════════════════════════════════════════════════════════
-- 414 · FIX cierre de pickup × acumulador semanal (incidente zona2 2026-07-08/10)
-- ════════════════════════════════════════════════════════════════════════════
-- CAUSA RAÍZ (datos verificados en prod):
--   El candado NIVEL 2 de wh.cerrar_pickup_con_despacho (SQL 210) buscaba una guía
--   con la marca [pickup:<id>] en TODO EL HISTÓRICO. Era un port de
--   _buscarGuiaPorPickupReciente (GAS) — nótese "Reciente": el original solo miraba
--   guías recientes (anti doble-tap). El port perdió la ventana temporal.
--   El acumulador semanal (fuente ACUMULADO_SEMANAL) usa UN id por zona por semana
--   y se despacha LEGÍTIMAMENTE varias veces esa semana → desde el 2º despacho, el
--   candado devolvía la guía del 1º ("idempotente"), marcaba COMPLETADO, no imprimía
--   y NO despachaba lo separado. Pasó Mié 08 16:17 y Jue 10 14:27 (huella:
--   atendido_por='' + cero kardex + guía devuelta = GPCK_ del lunes 06).
--   Segundo defecto acoplado: id_guia fijo 'GPCK_'||idPickup → aunque el candado
--   dejara pasar, el 2º despacho de la semana colisionaría con la guía del 1º
--   (crear_despacho_rapido dedupea por id).
--
-- FIX (2 cambios, el resto de la función queda byte-idéntico a 210/212):
--   1. NIVEL 2 con VENTANA de 90 minutos: sigue atrapando doble-tap/retry/timeout
--      y el cross-path espejo (su función real), y deja pasar los despachos
--      legítimos posteriores de la misma semana.
--   2. id_guia POR CIERRE: 'GPCK_'||idPickup||'_'||<fecha-hora Lima> → cada
--      despacho de la semana tiene guía propia. La protección anti-duplicado del
--      retry pasa a ser la ventana del NIVEL 2 (90 min cubre cualquier retry real).
--   El ticket NO se rompe: la Edge ticket-guia extrae el pickup del comentario
--   [pickup:...] (ticket-guia/index.ts:111), no del formato del id.
-- ════════════════════════════════════════════════════════════════════════════

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
  v_est_up := upper(coalesce(v_pickup.estado, ''));
  if v_est_up not in ('PENDIENTE', 'EN_PROCESO', '') then
    return jsonb_build_object('ok', false,
      'error', 'El pickup ya no es despachable (estado=' || v_est_up || ')', 'yaCerrado', true);
  end if;

  -- ── IDEMPOTENCIA NIVEL 2 (FIX 414): guía para este pickup en los ÚLTIMOS 90 MIN ──
  -- Anti doble-tap/retry/timeout + cross-path espejo (su función real). La ventana
  -- restaura la semántica de _buscarGuiaPorPickupReciente (GAS): "Reciente".
  -- SIN ventana, el 2º despacho legítimo de la semana del acumulador devolvía la
  -- guía del 1º (incidente zona2 2026-07-08/10) — el acumulador reusa el id toda
  -- la semana por diseño ("lo pedido + lo que faltó").
  select id_guia into v_guia_prev
  from wh.guias
  where comentario like '%[pickup:' || v_idp || ']%'
    and fecha > v_now - interval '90 minutes'
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

  -- Total despachado
  for v_it in select * from jsonb_array_elements(v_det) loop
    v_total_desp := v_total_desp + wh._num(coalesce(v_it->>'cantidad', '0'));
  end loop;

  -- No despachados: solicitado > despachado
  select count(*) into v_no_desp
  from jsonb_array_elements(v_items) e
  where wh._num(coalesce(e->>'solicitado', '0')) > wh._num(coalesce(e->>'despachado', '0'));

  v_nuevo_estado := case
    when v_no_desp = 0 then 'COMPLETADO'
    when v_total_desp > 0 then 'PARCIAL'
    else 'CANCELADO'
  end;

  -- ── Crear GUIA_SALIDA si hubo al menos un item despachado ──
  -- (FIX 414) id POR CIERRE: cada despacho de la semana del acumulador genera su
  -- guía propia. El anti-duplicado del retry es la ventana de 90 min del NIVEL 2.
  if v_total_desp > 0 then
    v_idguia := 'GPCK_' || v_idp || '_' || to_char(v_now at time zone 'America/Lima', 'YYYYMMDD_HH24MISS');
    v_desp_res := wh.crear_despacho_rapido(jsonb_build_object(
      'id_guia',    v_idguia,
      'tipo',       'SALIDA_ZONA',
      'id_zona',    coalesce(v_pickup.id_zona, ''),
      'usuario',    v_usuario,
      'comentario', '[pickup:' || v_idp || ']',
      'items',      v_det
    ));
    if coalesce((v_desp_res->>'ok'), 'false') <> 'true' then
      return jsonb_build_object('ok', false,
        'error', 'Falló GUIA_SALIDA: ' || coalesce(v_desp_res->>'error', '?'));
    end if;
    v_idguia := coalesce(v_desp_res->>'idGuia', v_idguia);
  end if;

  -- ── Actualizar pickup (terminal) ──
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
  return jsonb_build_object('ok', false, 'error', 'EXCEPCION', 'detalle', SQLERRM);
end;
$fn$;

revoke all on function wh.cerrar_pickup_con_despacho(jsonb) from public;
grant execute on function wh.cerrar_pickup_con_despacho(jsonb) to service_role, authenticated;

-- statement_timeout heredado del fix 409 se re-aplica (create or replace lo resetea)
alter function wh.cerrar_pickup_con_despacho(jsonb) set statement_timeout = '20s';

notify pgrst, 'reload schema';
