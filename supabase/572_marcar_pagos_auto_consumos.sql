-- ════════════════════════════════════════════════════════════════════════════
-- 572 · marcar_pagos · CONSUMOS AUTOMÁTICOS (server-truth) + neto por día
-- ════════════════════════════════════════════════════════════════════════════
-- Decisión del dueño (2026-07-27): los consumos a crédito deben descontarse
-- AUTOMÁTICO al liquidar (sin paso manual), cargándose al día/empleado que
-- corresponde. Antes el front mandaba `creditos:[]` elegidos a mano.
-- FIX: nuevo flag `autoConsumos:true` → el SERVIDOR arma la lista = TODOS los
-- tickets CREDITO vivos de la persona (por su documento) cuya fecha Lima cae en
-- los días que se pagan. Ignora cualquier lista del cliente → no se puede evadir
-- deuda desde el front, y coincide EXACTO con el consumo por día de 422
-- (mismo match: documento + (fecha at TZ Lima)::date).
-- Idéntica a 571 salvo el bloque [572]. Mantiene compat: sin el flag, usa creditos[].
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION mos.marcar_pagos(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_localid text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_pagpor  text := coalesce(nullif(btrim(coalesce(p->>'pagadoPor','')),''), 'admin');
  v_coment  text := coalesce(p->>'comentario','');
  v_nombre  text := coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), '');
  v_rol     text := upper(coalesce(p->>'rol',''));
  v_appo    text := coalesce(p->>'appOrigen','');
  v_dias    jsonb := coalesce(p->'dias','[]'::jsonb);
  v_fechas  jsonb := case when jsonb_typeof(p->'fechas')='array' then p->'fechas' else null end;
  v_creds   jsonb := case when jsonb_typeof(p->'creditos')='array' then p->'creditos' else '[]'::jsonb end;
  v_auto_cons boolean := coalesce((p->>'autoConsumos')::boolean, false);   -- [572]
  v_docp    text; v_vid text; v_vrow record; v_desc numeric := 0; v_ncred int := 0; v_neto numeric;
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

  if (jsonb_typeof(v_dias) <> 'array' or jsonb_array_length(v_dias) = 0) and v_fechas is not null then
    for v_fs in select jsonb_array_elements_text(v_fechas) loop
      v_fs := nullif(btrim(v_fs),'');
      if v_fs is null then continue; end if;
      select * into v_row from mos.liquidaciones_dia where id_dia = mos._liqdia_resolver(v_idp, v_fs) limit 1;
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

  if exists (select 1 from mos.liquidaciones_pagos where id_pago = v_id_pago) then
    return jsonb_build_object('ok',true,'dedup',true,'data',
      jsonb_build_object('idPago',v_id_pago,'reusado',true,'total',0,'dias',0));
  end if;

  for d in select * from jsonb_array_elements(v_dias) e order by e->>'fecha' loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    if v_fecha_s is null then return jsonb_build_object('ok',false,'error','Día sin fecha'); end if;
    v_id_dia := coalesce(mos._liqdia_resolver(v_idp, v_fecha_s), mos._liqdia_key(v_idp, v_fecha_s));
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

  -- ════════════════════════════════════════════════════════════════════════
  -- [572] CONSUMOS AUTOMÁTICOS (server-truth). Si autoConsumos=true, el servidor
  -- arma v_creds = TODOS los tickets CREDITO vivos de la persona (por su documento)
  -- cuya fecha Lima cae en los días que se pagan. Ignora la lista del cliente →
  -- imposible evadir deuda desde el front. Mismo match exacto que 422 (consumoDia).
  -- ════════════════════════════════════════════════════════════════════════
  -- UNE (no reemplaza) los del período con lo que el admin haya marcado aparte
  -- (p.ej. "deuda de otras fechas" opcional). El loop dedup por `distinct`.
  if v_auto_cons then
    select btrim(coalesce(documento,'')) into v_docp from mos.personal where id_personal = v_idp;
    if coalesce(v_docp,'') <> '' then                           -- sin documento → nada que atar
      v_creds := v_creds || coalesce((
        select jsonb_agg(to_jsonb(v.id_venta))
          from me.ventas v
         where btrim(coalesce(v.cliente_doc,'')) = v_docp
           and upper(coalesce(v.forma_pago,'')) = 'CREDITO'
           and (v.fecha at time zone 'America/Lima')::date::text in (
                 select e->>'fecha' from jsonb_array_elements(v_dias) e)
      ), '[]'::jsonb);
    end if;
  end if;

  -- [419] VALIDAR + DESCONTAR créditos (elegidos por el admin O automáticos [572]) —
  -- misma tx que el pago (o TODO o NADA).
  if jsonb_array_length(v_creds) > 0 then
    select btrim(coalesce(documento,'')) into v_docp from mos.personal where id_personal = v_idp;
    if coalesce(v_docp,'') = '' then
      return jsonb_build_object('ok',false,'error','La persona no tiene documento registrado (Personal → documento) — no se pueden descontar créditos');
    end if;
    for v_vid in select distinct v from unnest(array(select jsonb_array_elements_text(v_creds))) v order by v loop
      v_vid := nullif(btrim(v_vid),'');
      if v_vid is null then continue; end if;
      perform pg_advisory_xact_lock(hashtext('cobro:'||v_vid));
      select id_venta, upper(coalesce(forma_pago,'')) as fp, btrim(coalesce(cliente_doc,'')) as doc,
             coalesce(total,0) as total, coalesce(correlativo,'') as correlativo, fecha, historial_cambios
        into v_vrow from me.ventas where id_venta = v_vid for update;
      if not found then
        return jsonb_build_object('ok',false,'error','Crédito no encontrado: '||v_vid);
      end if;
      if v_vrow.fp <> 'CREDITO' then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||' ya no está en CRÉDITO ('||v_vrow.fp||') — refrescá y reintentá');
      end if;
      if v_vrow.doc <> v_docp then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||' no pertenece al documento '||v_docp);
      end if;
      if exists (select 1 from mos.creditos_planilla cp where cp.id_venta = v_vid and cp.estado = 'DESCONTADO') then
        return jsonb_build_object('ok',false,'error','El ticket '||coalesce(nullif(v_vrow.correlativo,''),v_vid)||' ya fue descontado por planilla');
      end if;
      update me.ventas set
          forma_pago = 'PLANILLA',
          historial_cambios = me._venta_hist_append(v_vrow.historial_cambios, jsonb_build_object(
            'ts', to_jsonb(v_now), 'usuario', v_pagpor, 'rol', 'ADMIN',
            'source', 'MOS_MARCAR_PAGOS', 'accion', 'descuento_planilla',
            'cambios', jsonb_build_array(jsonb_build_object('campo','FormaPago','antes','CREDITO','despues','PLANILLA')),
            'motivo', 'Descontado en liquidación '||v_id_pago)),
          updated_at = v_now
        where id_venta = v_vid;
      insert into mos.creditos_planilla (id_venta, id_pago, id_personal, monto, correlativo, fecha_venta, descontado_por)
      values (v_vid, v_id_pago, v_idp, v_vrow.total, v_vrow.correlativo, v_vrow.fecha, v_pagpor)
      on conflict (id_venta) do update
        set id_pago = excluded.id_pago, id_personal = excluded.id_personal, monto = excluded.monto,
            correlativo = excluded.correlativo, fecha_venta = excluded.fecha_venta,
            descontado_por = excluded.descontado_por, descontado_ts = now(),
            estado = 'DESCONTADO', revertido_ts = null;
      v_desc := v_desc + coalesce(v_vrow.total,0);
      v_ncred := v_ncred + 1;
    end loop;
  end if;

  for d in select * from jsonb_array_elements(v_dias) loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;
    -- [571 · FIX RAÍZ] recomputar v_id_dia por cada día.
    v_id_dia := coalesce(mos._liqdia_resolver(v_idp, v_fecha_s), mos._liqdia_key(v_idp, v_fecha_s));
    select coalesce(monto_base,0), coalesce(pago_envasado,0), coalesce(bono_meta,0),
           coalesce(sancion,0), coalesce(total_dia,0)
      into v_mb, v_pe, v_bm, v_sa, v_td
      from mos.liquidaciones_dia where id_dia = v_id_dia;
    if v_td is null then v_td := 0; end if;
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
     where id_dia = v_id_dia;
  end loop;

  v_total := mos._r2(v_total);
  v_desc  := mos._r2(v_desc);
  v_neto  := mos._r2(v_total - v_desc);
  v_id_gasto := 'GAS-' || v_localid;
  insert into mos.gastos (id_gasto, fecha, categoria, tipo, descripcion, monto, comprobante, registrado_por, local_id)
  values (
    v_id_gasto, (select min(fecha) from mos.liquidaciones_pagos where id_pago = v_id_pago),
    'JORNALES', 'FIJO',
    'Liquidación '||v_id_pago||' · '||coalesce(nullif(v_nombre,''),v_idp)||' · '
      ||(select count(*) from mos.liquidaciones_pagos where id_pago=v_id_pago and upper(coalesce(estado,''))='PAGADA')::text||' día(s)'
      ||case when v_ncred > 0 then ' · −S/'||to_char(v_desc,'FM999999990.00')||' ('||v_ncred||' consumo(s) por planilla)' else '' end,
    v_neto, '', v_pagpor, v_localid
  ) on conflict (local_id) where local_id is not null do nothing;

  update mos.liquidaciones_pagos set id_gasto_generado = v_id_gasto
   where id_pago = v_id_pago and coalesce(id_gasto_generado,'') = '';
  select count(*) into v_n from mos.liquidaciones_pagos where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';

  return jsonb_build_object('ok',true,'dedup',false,'data',
    jsonb_build_object('idPago',v_id_pago,'idGasto',v_id_gasto,'dias',v_n,'total',v_total,
                       'descuentoCreditos',v_desc,'creditosDescontados',v_ncred,'neto',v_neto));
end;
$function$
;
revoke all on function mos.marcar_pagos(jsonb) from public, anon;
grant execute on function mos.marcar_pagos(jsonb) to service_role;
notify pgrst, 'reload schema';
