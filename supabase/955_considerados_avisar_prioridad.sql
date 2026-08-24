-- [955] CONSIDERADOS v3 — notificación por PRIORIDAD + ROTATIVA. Reescribe mos.cron_considerados_avisar:
--  · reconcilia primero (estados frescos), ordena los pendientes por prioridad balanceada
--    (deuda + stock + antigüedad), y NOTIFICA una ventana ROTATIVA de 3 ("considera enviar A,B,C… y N más").
--  · La ventana rota por corrida (día del año × 2 slots) → a lo largo de los días surgen todos, no siempre los mismos.
--  · Audiencia: Admins (incluye ascendidos por rol) · operadores WH (almaceneros, app warehouseMos) · ME.
--  · p:{dry:true} → NO envía push, solo devuelve el cuerpo (para probar sin spamear).
drop function if exists mos.cron_considerados_avisar();   -- la vieja sin args → evitar ambigüedad con la nueva (default)
create or replace function mos.cron_considerados_avisar(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_dry boolean := coalesce((p->>'dry')::boolean, false);
  v_nombres text[]; v_n int; v_nwin int; v_win int; v_slice text[]; v_cuerpo text;
begin
  perform wh.considerados_reconciliar();   -- estados frescos (atendido/imposible)

  with cm as (
    select c.id, coalesce(nullif(btrim(c.nombre),''), c.sku_base) nombre,
           coalesce((select sum((zz->>'pend')::numeric) from jsonb_array_elements(case when jsonb_typeof(c.zonas)='array' then c.zonas else '[]'::jsonb end) zz),0) deuda,
           wh._alm_stock_sku(c.sku_base) stock,
           greatest(0, extract(epoch from (now()-c.creado))/86400.0) dias
      from wh.considerados c where c.estado='ACTIVO'
  ), mx as (select greatest(max(deuda),1) d, greatest(max(stock),1) s, greatest(max(dias),1) di from cm)
  select array_agg(upper(nombre) order by (deuda/mx.d + stock/mx.s + dias/mx.di) desc, nombre), count(*)
    into v_nombres, v_n
    from cm cross join mx;

  if coalesce(v_n,0) = 0 then return jsonb_build_object('ok', true, 'enviado', false); end if;

  -- ventana rotativa de 3 SOLO entre los de mayor prioridad (top 24 → ciclo ~4 días), no entre los 300+
  v_nwin := greatest(1, ceil(least(v_n, 24) / 3.0)::int);
  v_win  := (extract(doy from (now() at time zone 'America/Lima'))::int * 2
             + case when extract(hour from (now() at time zone 'America/Lima')) >= 18 then 1 else 0 end) % v_nwin;
  v_slice := v_nombres[v_win*3 + 1 : v_win*3 + 3];
  v_cuerpo := array_to_string(v_slice, ', ') || case when v_n > 3 then '… y ' || (v_n - 3) || ' más' else '' end;

  if v_dry then
    return jsonb_build_object('ok', true, 'dry', true, 'total', v_n, 'ventana', v_win, 'ventanas', v_nwin, 'cuerpo', v_cuerpo, 'top', to_jsonb(v_nombres[1:6]));
  end if;

  -- Admins (incluye ascendidos por rol): verificar que se despache.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN','ASCENDIDO')),
    'titulo', '📦 Considerados por despachar',
    'cuerpo', v_n || ' pendientes (por prioridad): ' || v_cuerpo || ' — verifica que se envíen.',
    'data', jsonb_build_object('tipo','considerados')));

  -- Operadores WH (almaceneros): considera enviar, por prioridad.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('warehouseMos')),
    'titulo', '🚚 Considera enviar (prioridad)',
    'cuerpo', 'Despacha por prioridad: ' || v_cuerpo || '.',
    'data', jsonb_build_object('tipo','considerados')));

  -- ME (por app): llegó lo que no le trajeron.
  perform mos.emitir_push(jsonb_build_object(
    'audiencia', jsonb_build_object('apps', jsonb_build_array('mosExpress')),
    'titulo', '🎁 Llegó lo que no te trajeron',
    'cuerpo', 'Atenta: ' || v_cuerpo || ' (deuda de semanas pasadas).',
    'data', jsonb_build_object('tipo','considerados')));

  return jsonb_build_object('ok', true, 'enviado', true, 'total', v_n, 'ventana', v_win, 'cuerpo', v_cuerpo);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

select 'considerados avisar v3 listo' ok;
