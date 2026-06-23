-- 227_pagos_jornal_bridge.sql — Puente para cablear pago de jornales MOS directo (cero GAS).
-- (a) marcar_pagos: acepta `fechas[]` (lo que manda el front) además de `dias[]`. Si vienen fechas[], reconstruye
--     el snapshot LEYÉNDOLO de mos.liquidaciones_dia (server-truth: monto_base/pago_envasado/bono_meta/sancion/
--     total_dia) → el cliente NO puede falsear montos. RECHAZA si alguna fecha no está materializada (jamás paga
--     de menos). Resto de la lógica money-crítica (idempotencia localId, doble-guarda anti-doble-pago, 3 tablas
--     atómicas, gasto) INTACTA.
-- (b) anular_pago: verifica claveAdmin server-side (antes confiaba en el frontend).

create or replace function mos.marcar_pagos(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_localid text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_pagpor  text := coalesce(nullif(btrim(coalesce(p->>'pagadoPor','')),''), 'admin');
  v_coment  text := coalesce(p->>'comentario','');
  v_nombre  text := coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), '');
  v_rol     text := upper(coalesce(p->>'rol',''));
  v_appo    text := coalesce(p->>'appOrigen','');
  v_dias    jsonb := coalesce(p->'dias','[]'::jsonb);
  -- [227] soporte fechas[] → reconstruir dias[] desde liquidaciones_dia (server-truth)
  v_fechas  jsonb := case when jsonb_typeof(p->'fechas')='array' then p->'fechas' else null end;
  v_fs      text; v_row mos.liquidaciones_dia%rowtype; v_built jsonb := '[]'::jsonb;
  v_id_pago text;
  v_id_gasto text;
  v_now     timestamptz := clock_timestamp();
  v_total   numeric := 0;
  v_n       int := 0;
  v_existe_gasto record;
  d         jsonb;
  v_fecha_s text;
  v_fecha   timestamptz;
  v_id_dia  text;
  v_mb numeric; v_pe numeric; v_bm numeric; v_sa numeric; v_td numeric;
  v_dia_estado text; v_dia_idpago text; v_led_idpago text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PAGOS_JORNAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PAGOS_JORNAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPersonal'); end if;
  if v_localid is null then return jsonb_build_object('ok',false,'error','Requiere localId (idempotencia DINERO)'); end if;

  -- [227] Si no vino dias[] pero sí fechas[], construir dias[] desde la materializada (server-truth).
  --       RECHAZA si alguna fecha no está en liquidaciones_dia → nunca paga de menos (el front debe refrescar).
  if (jsonb_typeof(v_dias) <> 'array' or jsonb_array_length(v_dias) = 0) and v_fechas is not null then
    for v_fs in select jsonb_array_elements_text(v_fechas) loop
      v_fs := nullif(btrim(v_fs),'');
      if v_fs is null then continue; end if;
      select * into v_row from mos.liquidaciones_dia where id_dia = mos._liqdia_key(v_idp, left(v_fs,10)) limit 1;
      if not found then
        return jsonb_build_object('ok',false,'error','Día no materializado (refrescá liquidación): '||v_fs,'fecha',v_fs);
      end if;
      v_built := v_built || jsonb_build_object(
        'fecha', left(v_fs,10),
        'montoBase', coalesce(v_row.monto_base,0),
        'pagoEnvasado', coalesce(v_row.pago_envasado,0),
        'bonoMeta', coalesce(v_row.bono_meta,0),
        'sancion', coalesce(v_row.sancion,0),
        'totalDia', coalesce(v_row.total_dia, mos._liqdia_total(v_row.monto_base,v_row.pago_envasado,v_row.bono_meta,0,v_row.sancion)));
      if v_nombre = '' then v_nombre := coalesce(v_row.nombre,''); end if;
      if v_rol = '' then v_rol := upper(coalesce(v_row.rol,'')); end if;
      if v_appo = '' then v_appo := coalesce(v_row.app_origen,''); end if;
    end loop;
    v_dias := v_built;
  end if;

  if jsonb_typeof(v_dias) <> 'array' or jsonb_array_length(v_dias) = 0 then
    return jsonb_build_object('ok',false,'error','Requiere dias[] o fechas[]');
  end if;

  v_id_pago := 'LIQ-' || v_localid;

  select id_gasto, monto into v_existe_gasto from mos.gastos where local_id = v_localid limit 1;
  if found then
    select count(*) into v_n from mos.liquidaciones_pagos where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';
    return jsonb_build_object('ok',true,'dedup',true,'data',
      jsonb_build_object('idPago',v_id_pago,'idGasto',v_existe_gasto.id_gasto,'dias',v_n,'total',mos._r2(v_existe_gasto.monto)));
  end if;

  for d in select * from jsonb_array_elements(v_dias) loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    if v_fecha_s is null then return jsonb_build_object('ok',false,'error','Día sin fecha'); end if;
    v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
    select upper(coalesce(estado,'')), coalesce(id_pago,'') into v_dia_estado, v_dia_idpago
      from mos.liquidaciones_dia where id_dia = v_id_dia for update;
    if found and v_dia_estado = 'PAGADA' and v_dia_idpago <> v_id_pago then
      return jsonb_build_object('ok',false,'error','Día ya pagado: '||v_fecha_s,'fecha',v_fecha_s,'idPagoExistente',v_dia_idpago);
    end if;
    select id_pago into v_led_idpago from mos.liquidaciones_pagos
     where id_personal = v_idp and upper(coalesce(estado,'')) = 'PAGADA'
       and to_char(fecha,'YYYY-MM-DD') = v_fecha_s and id_pago <> v_id_pago limit 1;
    if found then
      return jsonb_build_object('ok',false,'error','Día ya pagado: '||v_fecha_s,'fecha',v_fecha_s,'idPagoExistente',v_led_idpago);
    end if;
  end loop;

  for d in select * from jsonb_array_elements(v_dias) loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;
    v_mb := coalesce(mos._numn(d->>'montoBase'),0);
    v_pe := coalesce(mos._numn(d->>'pagoEnvasado'),0);
    v_bm := coalesce(mos._numn(d->>'bonoMeta'),0);
    v_sa := coalesce(mos._numn(d->>'sancion'),0);
    v_td := mos._numn(d->>'totalDia');
    if v_td is null then v_td := mos._liqdia_total(v_mb, v_pe, v_bm, 0, v_sa); end if;
    v_total := v_total + v_td;
    insert into mos.liquidaciones_pagos (
      id_pago, id_personal, fecha, nombre, rol, app_origen,
      monto_base, pago_envasado, bono_meta, sancion, total_dia,
      ticket_job_id, pagado_por, pagado_ts, estado, comentario, id_gasto_generado
    ) values (
      v_id_pago, v_idp, v_fecha, v_nombre, v_rol, v_appo,
      v_mb, v_pe, v_bm, v_sa, v_td, '', v_pagpor, v_now, 'PAGADA', v_coment, ''
    ) on conflict (id_pago, id_personal, fecha) do nothing;
    update mos.liquidaciones_dia set estado='PAGADA', id_pago=v_id_pago, ts_actualizado=v_now
     where id_dia = mos._liqdia_key(v_idp, v_fecha_s);
  end loop;

  v_total := mos._r2(v_total);
  v_id_gasto := 'GAS-' || v_localid;
  insert into mos.gastos (id_gasto, fecha, categoria, tipo, descripcion, monto, comprobante, registrado_por, local_id)
  values (
    v_id_gasto, (select min(fecha) from mos.liquidaciones_pagos where id_pago = v_id_pago),
    'JORNALES', 'FIJO',
    'Liquidación '||v_id_pago||' · '||coalesce(nullif(v_nombre,''),v_idp)||' · '
      ||(select count(*) from mos.liquidaciones_pagos where id_pago=v_id_pago and upper(coalesce(estado,''))='PAGADA')::text||' día(s)',
    v_total, '', v_pagpor, v_localid
  ) on conflict (local_id) where local_id is not null do nothing;

  update mos.liquidaciones_pagos set id_gasto_generado = v_id_gasto
   where id_pago = v_id_pago and coalesce(id_gasto_generado,'') = '';
  select count(*) into v_n from mos.liquidaciones_pagos where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';

  return jsonb_build_object('ok',true,'dedup',false,'data',
    jsonb_build_object('idPago',v_id_pago,'idGasto',v_id_gasto,'dias',v_n,'total',v_total));
end;
$function$;

-- (b) anular_pago con verificación de clave admin server-side.
create or replace function mos.anular_pago(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_idpago text := nullif(btrim(coalesce(p->>'idPago','')), '');
  v_quien  text := coalesce(nullif(btrim(coalesce(p->>'anuladoPor','')),''), 'admin');
  v_clave  text := nullif(btrim(coalesce(p->>'claveAdmin','')), '');
  v_now    timestamptz := clock_timestamp();
  v_id_gasto text; v_nombre text := ''; v_anuladas int := 0; v_dias_rev int := 0; v_gasto_del int := 0;
  v_sello text; v_auth jsonb;
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

  return jsonb_build_object('ok',true,'data',
    jsonb_build_object('idPago',v_idpago,'nombre',v_nombre,'anuladas',v_anuladas,
                       'diasRevertidos',v_dias_rev,'gastoBorrado',(v_gasto_del>0),'anuladoPor',v_quien));
end;
$function$;
