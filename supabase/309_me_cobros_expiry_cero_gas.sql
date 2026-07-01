-- ============================================================================
-- 309_me_cobros_expiry_cero_gas.sql — Auto-expiración cero-GAS de cobros vencidos
-- ----------------------------------------------------------------------------
-- Paridad con gas/Creditos.gs::escalarCobrosVencidos (trigger 5min). Sin esto, un
-- cobro ASIGNADO no cobrado bloquearía su venta para siempre (YA_ASIGNADO). Replica:
--  - guard anti-falso-positivo: si la venta YA se pagó por otra vía (forma_pago ya no
--    es CREDITO/POR_COBRAR) → el cobro se marca COBRADO (reconciliado), NO expira ni
--    revierte (preserva la trazabilidad del cobro real);
--  - si sigue en crédito → EXPIRADO + la venta vuelve a CREDITO (re-asignable).
-- Gateado por ME_COBRO_DIRECTO: mientras el cutover esté OFF, el GAS sigue expirando y
-- este job no toca nada. pg_cron cada 5 min. 100% Supabase.
-- ============================================================================

-- [100x MED] índice único parcial: backstop de la idempotencia por local_id
-- (además del advisory-lock por venta). local_id NULL (empty→null) queda fuera.
create unique index if not exists uq_me_cobro_localid
  on me.creditos_cobro_asignado (local_id) where local_id is not null;

create or replace function me.escalar_cobros_vencidos()
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_recon int := 0; v_exp int := 0;
begin
  -- mientras el cutover esté OFF, el GAS es dueño de la expiración → no hacer nada.
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',true,'skipped','COBRO_OFF');
  end if;

  -- 1) RECONCILIAR: cobro ASIGNADO vencido cuya venta YA se pagó por otra vía →
  --    COBRADO (no expira, no revierte). Guard anti-falso-positivo.
  with venc as (
    select c.id_cobro
      from me.creditos_cobro_asignado c
      join me.ventas v on v.id_venta = c.id_venta
     where upper(coalesce(c.estado,'')) = 'ASIGNADO'
       and now() > coalesce(c.fecha_vencimiento, c.fecha_asig + (coalesce(c.horas_ttl,1) || ' hours')::interval)
       and upper(coalesce(v.forma_pago,'')) not in ('CREDITO','POR_COBRAR')
  )
  update me.creditos_cobro_asignado c
     set estado='COBRADO', fecha_res=now(), razon='Cobrado fuera del flujo · auto-reconciliado'
    from venc where c.id_cobro = venc.id_cobro
      and upper(coalesce(c.estado,''))='ASIGNADO';   -- [500x] re-check bajo lock de fila: no pisa un COBRADO/CANCELADO concurrente
  get diagnostics v_recon = row_count;

  -- 2) EXPIRAR: cobro ASIGNADO vencido cuya venta sigue en crédito → EXPIRADO +
  --    revertir la venta a CREDITO (vuelve al pool re-asignable).
  with venc as (
    select c.id_cobro, c.id_venta
      from me.creditos_cobro_asignado c
      join me.ventas v on v.id_venta = c.id_venta
     where upper(coalesce(c.estado,'')) = 'ASIGNADO'
       and now() > coalesce(c.fecha_vencimiento, c.fecha_asig + (coalesce(c.horas_ttl,1) || ' hours')::interval)
       and upper(coalesce(v.forma_pago,'')) in ('CREDITO','POR_COBRAR')
  ), upd as (
    update me.creditos_cobro_asignado c
       set estado='EXPIRADO', fecha_res=now(), razon='Vencido sin cobrarse · cliente no llegó'
      from venc where c.id_cobro = venc.id_cobro
        and upper(coalesce(c.estado,''))='ASIGNADO'   -- [500x] no expira un cobro que un confirmar concurrente ya marcó COBRADO
      returning venc.id_venta
  )
  update me.ventas v set forma_pago='CREDITO'
   where v.id_venta in (select id_venta from upd)
     and upper(coalesce(v.forma_pago,'')) in ('CREDITO','POR_COBRAR');   -- idempotente
  get diagnostics v_exp = row_count;

  return jsonb_build_object('ok',true,'reconciliados',v_recon,'expirados',v_exp);
end;
$fn$;
revoke all on function me.escalar_cobros_vencidos() from public;
grant execute on function me.escalar_cobros_vencidos() to authenticated, service_role;

-- pg_cron cada 5 min (idempotente: desprograma antes de re-crear).
do $$ begin perform cron.unschedule('me-escalar-cobros'); exception when others then null; end $$;
select cron.schedule('me-escalar-cobros', '*/5 * * * *', $$select me.escalar_cobros_vencidos();$$);
