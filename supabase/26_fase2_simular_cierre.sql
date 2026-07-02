-- 26_fase2_simular_cierre.sql — [Camino a cierre-directo · PASO 1: GATE de validación, SOLO LECTURA]
-- El cierre de caja (arqueo diario) es la operación más money-critical. Antes de migrarlo a una RPC que
-- ESCRIBA, validamos que la MATEMÁTICA del arqueo es reproducible desde Supabase comparándola contra los
-- cierres reales (metodología idéntica al gate de paridad que usamos para flipear la lectura directa).
-- Esta función NO escribe nada: solo recomputa el monto_final_auto que GAS calcularía, desde me.ventas +
-- me.movimientos_extra, con la MISMA fórmula que _cerrarCajaAtomicoCore (Caja.gs):
--   monto_final_auto = monto_inicial + efectivo_ventas + ingresos_efe - egresos_efe
-- donde efectivo_ventas = Σ(EFECTIVO.total) + Σ(parte EFE de los MIXTO).  VIRTUAL no suma efectivo.
create or replace function me.simular_cierre_caja(p_id_caja text)
returns jsonb language sql stable security definer set search_path = '' as $fn$
  with caja as (
    select monto_inicial, monto_final, estado, vendedor, zona_id
    from me.cajas where id_caja = p_id_caja limit 1
  ),
  efe as (
    select coalesce(sum(
      case
        when upper(v.forma_pago) = 'EFECTIVO' then v.total
        when upper(v.forma_pago) like 'MIXTO%' then coalesce((regexp_match(v.forma_pago, 'EFE:([0-9.]+)'))[1]::numeric, 0)
        else 0
      end
    ), 0) as efectivo_ventas
    from me.ventas v where v.id_caja = p_id_caja
      -- [fix doble-conteo] excluye ventas cobradas vía cobro (su plata es el INGRESO 'Abono deuda')
      and not exists (select 1 from me.movimientos_extra m
                       where m.concepto = 'Abono deuda' and position(v.id_venta in coalesce(m.obs,'')) > 0)
  ),
  mov as (
    select
      coalesce(sum(case when tipo = 'INGRESO' then monto else 0 end), 0) as ingresos_efe,
      coalesce(sum(case when tipo = 'EGRESO'  then monto else 0 end), 0) as egresos_efe
    from me.movimientos_extra where id_caja = p_id_caja
  )
  select jsonb_build_object(
    'id_caja', p_id_caja,
    'estado', (select estado from caja),
    'monto_inicial', (select monto_inicial from caja),
    'efectivo_ventas', (select efectivo_ventas from efe),
    'ingresos_efe', (select ingresos_efe from mov),
    'egresos_efe', (select egresos_efe from mov),
    'monto_final_auto_simulado',
      round((select coalesce(monto_inicial,0) from caja)
            + (select efectivo_ventas from efe)
            + (select ingresos_efe from mov)
            - (select egresos_efe from mov), 2),
    'monto_final_real', (select monto_final from caja)   -- lo que GAS guardó (puede ser declarado por el cajero)
  );
$fn$;
revoke all on function me.simular_cierre_caja(text) from public;
grant execute on function me.simular_cierre_caja(text) to authenticated;
