-- 603_wh_acumulador_cuenta_corriente.sql — [WH · EL ACUMULADOR ES CUENTA CORRIENTE: SIEMPRE VISIBLE]
-- Modelo del dueño (2026-08-01, caso caja Mia / zona02): la lista de la zona es una CUENTA
-- CORRIENTE viva — cada cierre de caja le suma lo vendido, cada despacho le resta, y despachar
-- UNA PARTE jamás la esconde: lo debido sigue apareciendo en WH hasta saldarse (o hasta el corte
-- semanal → REZAGADO, que se mantiene igual).
--
-- ANTES: cerrar el despacho del acumulador con deuda restante lo dejaba en 'PARCIAL' → invisible
-- para WH (el feed lista PENDIENTE/EN_PROCESO) hasta que el PRÓXIMO cierre de caja lo revivía
-- (consolidar_pickup_zona resetea PARCIAL→PENDIENTE). Ventana ciega de horas ("no hay lista de
-- zona02"). Peor: cerrar con CERO despachado lo dejaba 'CANCELADO' = cuenta muerta.
--
-- AHORA: si fuente='ACUMULADO_SEMANAL' y queda deuda (v_no_desp>0) → estado 'PENDIENTE' SIEMPRE
-- (visible y re-despachable de inmediato; cada despacho genera su propia guía GPCK con timestamp,
-- el anti-retry es la ventana de 90 min del NIVEL 2 — sin cambios). Los pickups sueltos
-- (RIZ / cierre de caja) conservan su semántica PARCIAL/CANCELADO: viven poco, el consolidador
-- los absorbe igual (214 absorbe PENDIENTE y PARCIAL).
-- + DATA FIX: los acumuladores hoy atorados en PARCIAL vuelven a PENDIENTE (zona02 reaparece ya).

CREATE OR REPLACE FUNCTION wh.cerrar_pickup_con_despacho(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '20s'
AS $function$
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
  select id_guia into v_guia_prev
  from wh.guias
  where comentario like '%[pickup:' || v_idp || ']%'
    and fecha > v_now - interval '90 minutes'
  order by fecha desc
  limit 1;
  if v_guia_prev is not null then
    -- [603] el reintento tampoco debe DESAPARECER un acumulador con deuda: si es
    -- ACUMULADO_SEMANAL queda PENDIENTE (cuenta corriente), no COMPLETADO a ciegas.
    update wh.pickups
       set estado           = case
                                when upper(coalesce(estado,'')) not in ('PENDIENTE','EN_PROCESO','') then estado
                                when coalesce(fuente,'') = 'ACUMULADO_SEMANAL'
                                     and exists (select 1 from jsonb_array_elements(coalesce(items,'[]'::jsonb)) e
                                                  where wh._num(coalesce(e->>'solicitado','0')) > wh._num(coalesce(e->>'despachado','0')))
                                  then 'PENDIENTE'
                                else 'COMPLETADO' end,
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

  -- [603] CUENTA CORRIENTE: el acumulador semanal con deuda restante queda PENDIENTE
  -- (siempre visible/re-despachable). Antes: PARCIAL (oculto) o CANCELADO (cuenta muerta).
  v_nuevo_estado := case
    when v_no_desp = 0 then 'COMPLETADO'
    when coalesce(v_pickup.fuente,'') = 'ACUMULADO_SEMANAL' then 'PENDIENTE'
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

  -- ── Actualizar pickup ──
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
$function$;

-- ── DATA FIX: acumuladores del bucket VIGENTE atorados en PARCIAL → PENDIENTE (reaparecen ya).
-- Solo el bucket actual (los de semanas pasadas son REZAGADO por diseño y no se tocan).
update wh.pickups
   set estado = 'PENDIENTE', ultima_actividad = now()
 where fuente = 'ACUMULADO_SEMANAL'
   and upper(coalesce(estado,'')) = 'PARCIAL'
   and right(id_pickup, 10) ~ '^\d{4}-\d{2}-\d{2}$'
   and to_date(right(id_pickup, 10), 'YYYY-MM-DD') = wh._bucket_dom((now() at time zone 'America/Lima')::date);
