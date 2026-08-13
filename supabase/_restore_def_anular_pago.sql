create or replace function mos.anular_pago(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_idpago text := nullif(btrim(coalesce(p->>'idPago','')), '');
  v_quien  text := coalesce(nullif(btrim(coalesce(p->>'anuladoPor','')),''), 'admin');
  v_clave  text := nullif(btrim(coalesce(p->>'claveAdmin','')), '');
  v_now    timestamptz := clock_timestamp();
  v_id_gasto text; v_nombre text := ''; v_anuladas int := 0; v_dias_rev int := 0; v_gasto_del int := 0;
  v_sello text; v_auth jsonb;
  v_cred record; v_cred_rev int := 0;   -- [419]
begin
  if coalesce((select valor from mos.config where clave='MOS_PAGOS_JORNAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PAGOS_JORNAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idpago is null then return jsonb_build_object('ok',false,'error','Requiere idPago'); end if;
  -- [227] anular pago de jornal = acción admin → exige clave admin válida (server-side, no se confía en el front).
  if v_clave is null then return jsonb_build_object('ok',false,'error','Requiere claveAdmin'); end if;
  v_auth := mos.verificar_clave_admin(v_clave, 'ANULAR_PAGO_JORNAL', v_idpago, 'MOS', null, null, 2, null);
  if coalesce((v_auth->>'autorizado')::boolean,false) <> true then
    return jsonb_build_object('ok',false,'error', coalesce(nullif(v_auth->>'error',''),'Clave admin incorrecta'));
  end if;

  select coalesce(nullif(id_gasto_generado,''), null), coalesce(nombre,'')
    into v_id_gasto, v_nombre from mos.liquidaciones_pagos
   where id_pago = v_idpago order by (upper(coalesce(estado,''))='ANULADA') limit 1;
  if not found then return jsonb_build_object('ok',false,'error','idPago no encontrado'); end if;

  v_sello := '↺ ANULADO por '||v_quien||' ('||to_char(v_now,'YYYY-MM-DD')||')';
  update mos.liquidaciones_pagos set estado='ANULADA',
       comentario = case when coalesce(comentario,'')='' then v_sello else comentario||' · '||v_sello end
   where id_pago = v_idpago and upper(coalesce(estado,'')) <> 'ANULADA';
  get diagnostics v_anuladas = row_count;
  if v_id_gasto is not null then
    delete from mos.gastos where id_gasto = v_id_gasto; get diagnostics v_gasto_del = row_count;
  end if;
  update mos.liquidaciones_dia set estado='PENDIENTE', id_pago=null, ts_actualizado=v_now where id_pago = v_idpago;
  get diagnostics v_dias_rev = row_count;

  -- [419] REVERTIR créditos descontados por este pago: PLANILLA → CREDITO (la
  -- deuda vuelve a estar viva; el ticket recupera su historial con la marca).
  for v_cred in select cp.id_venta from mos.creditos_planilla cp
                 where cp.id_pago = v_idpago and cp.estado = 'DESCONTADO'
  loop
    update me.ventas set
        forma_pago = 'CREDITO',
        historial_cambios = me._venta_hist_append(historial_cambios, jsonb_build_object(
          'ts', to_jsonb(v_now), 'usuario', v_quien, 'rol', 'ADMIN',
          'source', 'MOS_ANULAR_PAGO', 'accion', 'descuento_planilla_revertido',
          'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','PLANILLA','despues','CREDITO')),
          'motivo', 'Pago '||v_idpago||' anulado — la deuda vuelve a crédito')),
        updated_at = v_now
      where id_venta = v_cred.id_venta and upper(coalesce(forma_pago,'')) = 'PLANILLA';
    if found then
      update mos.creditos_planilla set estado='REVERTIDO', revertido_ts=v_now where id_venta = v_cred.id_venta;
      v_cred_rev := v_cred_rev + 1;
    end if;
  end loop;

  return jsonb_build_object('ok',true,'data',
    jsonb_build_object('idPago',v_idpago,'nombre',v_nombre,'anuladas',v_anuladas,
                       'diasRevertidos',v_dias_rev,'gastoBorrado',(v_gasto_del>0),'anuladoPor',v_quien,
                       'creditosRevertidos',v_cred_rev));
end;
$function$;