-- 342b: agrega push best-effort a me.escalar_cobros_vencidos (avisa a admins de cobros vencidos, cero-GAS).
-- El bloque begin/exception NUNCA rompe la escalación (money-logic idéntico). Reemplaza el push GAS #4.
create or replace function me.escalar_cobros_vencidos()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_recon int := 0; v_exp int := 0;
begin
  if coalesce((select valor from mos.config where clave='ME_COBRO_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',true,'skipped','COBRO_OFF');
  end if;
  with venc as (
    select c.id_cobro from me.creditos_cobro_asignado c join me.ventas v on v.id_venta = c.id_venta
     where upper(coalesce(c.estado,'')) = 'ASIGNADO'
       and now() > coalesce(c.fecha_vencimiento, c.fecha_asig + (coalesce(c.horas_ttl,1) || ' hours')::interval)
       and upper(coalesce(v.forma_pago,'')) not in ('CREDITO','POR_COBRAR'))
  update me.creditos_cobro_asignado c set estado='COBRADO', fecha_res=now(), razon='Cobrado fuera del flujo · auto-reconciliado'
    from venc where c.id_cobro = venc.id_cobro and upper(coalesce(c.estado,''))='ASIGNADO';
  get diagnostics v_recon = row_count;
  with venc as (
    select c.id_cobro, c.id_venta from me.creditos_cobro_asignado c join me.ventas v on v.id_venta = c.id_venta
     where upper(coalesce(c.estado,'')) = 'ASIGNADO'
       and now() > coalesce(c.fecha_vencimiento, c.fecha_asig + (coalesce(c.horas_ttl,1) || ' hours')::interval)
       and upper(coalesce(v.forma_pago,'')) in ('CREDITO','POR_COBRAR')
  ), upd as (
    update me.creditos_cobro_asignado c set estado='EXPIRADO', fecha_res=now(), razon='Vencido sin cobrarse · cliente no llegó'
      from venc where c.id_cobro = venc.id_cobro and upper(coalesce(c.estado,''))='ASIGNADO'
      returning venc.id_venta)
  update me.ventas v set forma_pago='CREDITO'
   where v.id_venta in (select id_venta from upd) and upper(coalesce(v.forma_pago,'')) in ('CREDITO','POR_COBRAR');
  get diagnostics v_exp = row_count;

  -- [CERO-GAS push #4] aviso a admins/master de cobros vencidos. Best-effort: NUNCA rompe la escalación.
  begin
    if v_exp > 0 then
      perform mos.emitir_push(jsonb_build_object(
        'audiencia', jsonb_build_object('roles', jsonb_build_array('MASTER','ADMINISTRADOR','ADMIN')),
        'titulo', '⏰ Cobros vencidos',
        'cuerpo', v_exp || ' cobro(s) vencieron sin cobrarse · volvieron al pool de crédito',
        'data', jsonb_build_object('tipo','cobro_vencido')));
    end if;
  exception when others then null;
  end;

  return jsonb_build_object('ok',true,'reconciliados',v_recon,'expirados',v_exp);
end;
$function$;
