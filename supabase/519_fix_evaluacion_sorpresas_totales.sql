-- 519_fix_evaluacion_sorpresas_totales.sql — FIX revisión 100x: evaluar por TOTALES por código
-- ════════════════════════════════════════════════════════════════════════════════════════════
-- BUG (hallado en revisión adversarial): me.recibir_guia_wh_cerrar (146) AGREGA el detalle por
-- código (sum(cant_recibida) group by cod_producto) → el 'escaneado' de la verificación es el
-- TOTAL del código. El trigger de 516 comparaba contra la LÍNEA corregida: en guías con el
-- mismo producto en 2+ líneas (5+3=8; sorpresa −1 → real 7) el operador honesto (7) recibía
-- DISCREPANCIA falsa. FIX: comparar contra el TOTAL corregido del código en la guía
-- (sum de líneas, ya corregidas) y el TOTAL original (= corregido − Σ deltas ESPERANDO del
-- código). Varias sorpresas del mismo código en la misma guía comparten baseline y veredicto.
create or replace function wh._evaluar_sorpresas_de_verificacion()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare
  v_guia text;
  s record;
  v_lin jsonb;
  v_esc numeric;
  v_res text;
  v_tot_corr numeric;   -- total del código en la guía (líneas YA corregidas)
  v_tot_orig numeric;   -- total como decía el papel (corregido − Σ deltas pendientes del código)
begin
  if new.id_guia not like 'WH:%' then return new; end if;
  v_guia := substring(new.id_guia from 4);
  for s in select * from wh.sorpresas where id_guia = v_guia and estado = 'ESPERANDO' loop
    -- baseline por TOTALES del código (146 agrega por cod_producto)
    select coalesce(sum(d.cant_recibida),0) into v_tot_corr
      from wh.guia_detalle d
     where d.id_guia = v_guia and upper(d.cod_producto) = upper(s.cod_producto)
       and upper(coalesce(d.observacion,'')) <> 'ANULADO';
    -- Σ deltas del código: las ESPERANDO + las evaluadas EN ESTA MISMA corrida (ts_resultado=now(),
    -- estable por transacción) — si no, la 2ª sorpresa del mismo código calcularía mal el original.
    select v_tot_corr - coalesce(sum(x.delta),0) into v_tot_orig
      from wh.sorpresas x
     where x.id_guia = v_guia and upper(x.cod_producto) = upper(s.cod_producto)
       and (x.estado = 'ESPERANDO' or x.ts_resultado = now());

    select l into v_lin from jsonb_array_elements(coalesce(new.detalle,'[]'::jsonb)) l
     where upper(coalesce(l->>'codBarra','')) = upper(s.cod_producto) limit 1;
    if v_lin is null then
      v_esc := null; v_res := 'DISCREPANCIA';
    else
      v_esc := wh._num(v_lin->>'escaneado');
      v_res := case when v_esc = v_tot_corr then 'PASO'
                    when v_esc = v_tot_orig then 'FALLO'
                    else 'DISCREPANCIA' end;
    end if;
    update wh.sorpresas
       set estado = v_res, operador_evaluado = new.usuario,
           cant_registrada = v_esc, ts_resultado = now()
     where id_sorpresa = s.id_sorpresa;
    begin
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMIN')),
        'titulo', case v_res when 'PASO' then '🎯✅ Sorpresa PASADA'
                             when 'FALLO' then '🎯❌ Sorpresa FALLADA'
                             else '🎯⚠️ Sorpresa con discrepancia' end,
        'cuerpo', coalesce(new.usuario,'operador') || ' registró ' || coalesce(v_esc::text,'—')
                  || ' de ' || s.cod_producto || ' (papel: ' || v_tot_orig
                  || ' · real: ' || v_tot_corr || ') · ' || coalesce(new.zona_id,''),
        'data', jsonb_build_object('tipo','sorpresa','idSorpresa',s.id_sorpresa,'resultado',v_res)));
    exception when others then null; end;
  end loop;
  return new;
end; $fn$;
