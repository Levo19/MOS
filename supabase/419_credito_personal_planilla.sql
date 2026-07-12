-- ════════════════════════════════════════════════════════════════════════════
-- 419 · LÍNEA DE CRÉDITO DEL PERSONAL — descuento por PLANILLA en la liquidación
--       (diseño DISENO_envasado_colab_y_credito_personal.md · decisiones del dueño)
-- ════════════════════════════════════════════════════════════════════════════
-- Reglas del dueño (2026-07-11):
--   · mos.personal lleva `documento` (ID de TEXTO exacto — ceros a la izquierda
--     JAMÁS se descartan). Jorgenis OP001 = '008539040' (CE).
--   · Cuentan SOLO tickets me.ventas con forma_pago='CREDITO' y cliente_doc
--     EXACTO al documento registrado.
--   · Al PAGAR la liquidación se descuentan los tickets elegidos; el NETO puede
--     quedar NEGATIVO (sin tope, sin arrastre).
--   · Money-safe: descuento + pago = UNA transacción (mos.marcar_pagos). El
--     ticket descontado pasa a forma_pago='PLANILLA' (sale de cuentas por
--     cobrar, no entra a ninguna caja — se compensó contra jornal) + fila
--     puente mos.creditos_planilla + historial en el ticket. Si el pago se
--     ANULA (anular_pago), los tickets REVIERTEN a CREDITO (la deuda no se
--     esfuma con un pago anulado).
--
-- Piezas (verbatim de la versión viva + cambio quirúrgico):
--   1. mos.personal + documento (+ seed Jorgenis)
--   2. mos.actualizar_personal: acepta documento; al setearlo hace upsert a
--      me.clientes_frecuentes (así el cajero lo encuentra al instante)
--   3. mos.creditos_personal(p): tickets CREDITO pendientes de una persona
--   4. tabla mos.creditos_planilla (+ índice parcial para el matching)
--   5. mos.marcar_pagos: param creditos[] → valida+descuenta EN LA MISMA TX
--   6. mos.anular_pago: revierte PLANILLA→CREDITO de ese id_pago
--   7. mos.liquidaciones_pendientes / mos.personal_dia_lista: exponen
--      envasadosColab/pagoEnvasadoColab (418) y créditos pendientes
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) documento en personal ──────────────────────────────────────────────────
alter table mos.personal add column if not exists documento text not null default '';
update mos.personal set documento = '008539040' where id_personal = 'OP001' and documento = '';

-- índice parcial para el matching de créditos (la RPC y las vistas filtran así)
create index if not exists idx_me_ventas_credito_doc
  on me.ventas (cliente_doc) where upper(forma_pago) = 'CREDITO';

-- ── 2) actualizar_personal + documento (verbatim + campo + upsert frecuentes) ─
create or replace function mos.actualizar_personal(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id text := nullif(btrim(coalesce(p->>'idPersonal','')),''); v_pin text := nullif(btrim(coalesce(p->>'pin','')),''); v_n int;
  v_doc text; v_nomfull text;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_id is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  update mos.personal set
    nombre      = coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), nombre),
    apellido    = coalesce(p->>'apellido', apellido),
    tipo        = coalesce(p->>'tipo', tipo),
    app_origen  = coalesce(p->>'appOrigen', app_origen),
    rol         = coalesce(p->>'rol', rol),
    pin         = coalesce(v_pin, pin),
    pin_hash    = case when v_pin is not null then extensions.crypt(v_pin, extensions.gen_salt('bf')) else pin_hash end,
    color       = coalesce(p->>'color', color),
    tarifa_hora = coalesce(nullif(btrim(coalesce(p->>'tarifaHora','')),'')::numeric, tarifa_hora),
    monto_base  = coalesce(nullif(btrim(coalesce(p->>'montoBase','')),'')::numeric, monto_base),
    estado      = coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, estado),
    -- [419] documento = ID de TEXTO exacto (ceros a la izquierda se respetan).
    -- Solo se toca si la clave viene en el payload (permite limpiar con '').
    documento   = case when p ? 'documento' then btrim(coalesce(p->>'documento','')) else documento end
   where id_personal = v_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok',false,'error','personal no encontrado'); end if;
  -- [419] documento nuevo no-vacío → el empleado queda buscable como cliente
  -- frecuente al instante (tipo inferido solo si es inequívoco; CE/Pasaporte se
  -- ajusta desde ME o queda '' sin bloquear nada — factura ya la gata el tipo+RUC real).
  if (p ? 'documento') and btrim(coalesce(p->>'documento','')) <> '' then
    v_doc := btrim(p->>'documento');
    select btrim(nombre||' '||coalesce(apellido,'')) into v_nomfull from mos.personal where id_personal = v_id;
    insert into me.clientes_frecuentes (documento, nombre, tipo_doc, tipo_id, direccion)
    values (v_doc, upper(coalesce(v_nomfull,'')), '',
            case when v_doc ~ '^\d{8}$' then '1'
                 when v_doc ~ '^(10|15|16|17|20)\d{9}$' then '6'
                 else '' end, '')
    on conflict (documento) do update
      set nombre  = case when btrim(coalesce(me.clientes_frecuentes.nombre,''))='' then excluded.nombre else me.clientes_frecuentes.nombre end,
          tipo_id = case when btrim(excluded.tipo_id) <> '' and btrim(coalesce(me.clientes_frecuentes.tipo_id,''))=''
                         then excluded.tipo_id else me.clientes_frecuentes.tipo_id end;
  end if;
  return jsonb_build_object('ok',true,'cambios',v_n);
end; $function$;

revoke all on function mos.actualizar_personal(jsonb) from public;
grant execute on function mos.actualizar_personal(jsonb) to authenticated;

-- ── 3) créditos pendientes de una persona ─────────────────────────────────────
create or replace function mos.creditos_personal(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare
  v_idp text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_doc text; v_arr jsonb; v_total numeric;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_idp is null then return jsonb_build_object('ok',false,'error','idPersonal requerido'); end if;
  select btrim(coalesce(documento,'')) into v_doc from mos.personal where id_personal = v_idp;
  if v_doc is null then return jsonb_build_object('ok',false,'error','personal no encontrado'); end if;
  if v_doc = '' then
    return jsonb_build_object('ok',true,'documento','','total',0,'n',0,'tickets','[]'::jsonb,'_fresh',true);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'idVenta', v.id_venta,
           'fecha', to_char((v.fecha at time zone 'America/Lima')::date,'YYYY-MM-DD'),
           'correlativo', coalesce(v.correlativo,''),
           'total', coalesce(v.total,0)
         ) order by v.fecha), '[]'::jsonb),
         coalesce(round(sum(coalesce(v.total,0))::numeric,2),0)
    into v_arr, v_total
    from me.ventas v
   where upper(v.forma_pago) = 'CREDITO'
     and btrim(coalesce(v.cliente_doc,'')) = v_doc;
  return jsonb_build_object('ok',true,'documento',v_doc,'total',v_total,
    'n', jsonb_array_length(v_arr), 'tickets', v_arr, '_fresh', true);
end; $fn$;
revoke all on function mos.creditos_personal(jsonb) from public, anon;
grant execute on function mos.creditos_personal(jsonb) to authenticated, service_role;

-- ── 4) tabla puente (auditoría del descuento) ─────────────────────────────────
create table if not exists mos.creditos_planilla (
  id_venta       text primary key,
  id_pago        text not null,
  id_personal    text not null,
  monto          numeric not null default 0,
  correlativo    text not null default '',
  fecha_venta    timestamptz,
  descontado_por text not null default '',
  descontado_ts  timestamptz not null default now(),
  estado         text not null default 'DESCONTADO',   -- DESCONTADO | REVERTIDO
  revertido_ts   timestamptz
);
create index if not exists idx_creditos_planilla_pago on mos.creditos_planilla (id_pago);
alter table mos.creditos_planilla enable row level security;

-- ── 5) marcar_pagos + creditos[] (verbatim + bloque de descuento EN LA MISMA TX) ─
create or replace function mos.marcar_pagos(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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
  -- [419] créditos a descontar por planilla (array de idVenta elegidos por el admin)
  v_creds   jsonb := case when jsonb_typeof(p->'creditos')='array' then p->'creditos' else '[]'::jsonb end;
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

  -- [419] VALIDAR + DESCONTAR créditos elegidos — misma tx que el pago (o TODO o NADA).
  if jsonb_array_length(v_creds) > 0 then
    select btrim(coalesce(documento,'')) into v_docp from mos.personal where id_personal = v_idp;
    if coalesce(v_docp,'') = '' then
      return jsonb_build_object('ok',false,'error','La persona no tiene documento registrado (Personal → documento) — no se pueden descontar créditos');
    end if;
    for v_vid in select distinct jsonb_array_elements_text(v_creds) loop
      v_vid := nullif(btrim(v_vid),'');
      if v_vid is null then continue; end if;
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
    -- [500x M2 · SERVER-TRUTH] los montos SIEMPRE se leen de mos.liquidaciones_dia, NUNCA del
    -- cliente. Sin esto, un caller malicioso mandando dias[] con montos inflados pagaba de más
    -- (el front manda fechas[], pero el branch dias[] era explotable). total_dia es el autoritativo.
    select coalesce(monto_base,0), coalesce(pago_envasado,0), coalesce(bono_meta,0),
           coalesce(sancion,0), coalesce(total_dia,0)
      into v_mb, v_pe, v_bm, v_sa, v_td
      from mos.liquidaciones_dia where id_dia = mos._liqdia_key(v_idp, v_fecha_s);
    if v_td is null then v_td := 0; end if;   -- fila inexistente → nada que pagar (guard previo ya filtró)
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
  v_desc  := mos._r2(v_desc);
  -- [419] NETO = jornal − créditos descontados. PUEDE ser negativo (decisión del
  -- dueño: sin tope ni arrastre — el gasto de caja refleja lo que realmente sale).
  v_neto  := mos._r2(v_total - v_desc);
  v_id_gasto := 'GAS-' || v_localid;
  insert into mos.gastos (id_gasto, fecha, categoria, tipo, descripcion, monto, comprobante, registrado_por, local_id)
  values (
    v_id_gasto, (select min(fecha) from mos.liquidaciones_pagos where id_pago = v_id_pago),
    'JORNALES', 'FIJO',
    'Liquidación '||v_id_pago||' · '||coalesce(nullif(v_nombre,''),v_idp)||' · '
      ||(select count(*) from mos.liquidaciones_pagos where id_pago=v_id_pago and upper(coalesce(estado,''))='PAGADA')::text||' día(s)'
      ||case when v_ncred > 0 then ' · −S/'||to_char(v_desc,'FM999999990.00')||' ('||v_ncred||' crédito(s) por planilla)' else '' end,
    v_neto, '', v_pagpor, v_localid
  ) on conflict (local_id) where local_id is not null do nothing;

  update mos.liquidaciones_pagos set id_gasto_generado = v_id_gasto
   where id_pago = v_id_pago and coalesce(id_gasto_generado,'') = '';
  select count(*) into v_n from mos.liquidaciones_pagos where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';

  return jsonb_build_object('ok',true,'dedup',false,'data',
    jsonb_build_object('idPago',v_id_pago,'idGasto',v_id_gasto,'dias',v_n,'total',v_total,
                       'descuentoCreditos',v_desc,'creditosDescontados',v_ncred,'neto',v_neto));
end;
$function$;

revoke all on function mos.marcar_pagos(jsonb) from public;
grant execute on function mos.marcar_pagos(jsonb) to authenticated;

-- ── 6) anular_pago: revierte los créditos PLANILLA de ese pago ────────────────
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

revoke all on function mos.anular_pago(jsonb) from public;
grant execute on function mos.anular_pago(jsonb) to authenticated;

-- ── 7a) liquidaciones_pendientes: + envasadosColab/pagoEnvasadoColab (418) ────
create or replace function mos.liquidaciones_pendientes(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_hasta text := coalesce(nullif(btrim(coalesce(p->>'hasta','')), ''),
                           to_char((now() at time zone 'America/Lima')::date, 'YYYY-MM-DD'));
  v_desde text;
  v_arr   jsonb;
  v_fr    jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  v_desde := coalesce(nullif(btrim(coalesce(p->>'desde','')), ''),
                      to_char(v_hasta::date - 29, 'YYYY-MM-DD'));
  v_fr := mos._frescura_sombra();

  with filtrado as (
    select
      coalesce(d.id_personal,'')                                       as id_personal,
      coalesce(d.nombre,'')                                            as nombre,
      upper(coalesce(d.rol,''))                                        as rol,
      coalesce(d.app_origen,'')                                        as app_origen,
      (lower(coalesce(d.virtual,'false')) = 'true'
        or coalesce(d.id_personal,'') like 'MEX:%')                    as virtual,
      to_char((d.fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD') as f,
      coalesce(d.auditado, false)                                      as auditado,
      coalesce(d.monto_base, 0)                                        as monto_base,
      coalesce(d.pago_envasado, 0)                                     as pago_envasado,
      coalesce(d.bono_meta, 0)                                         as bono_meta,
      coalesce(d.bonificacion, 0)                                      as bonificacion,
      coalesce(d.sancion, 0)                                           as sancion,
      coalesce(d.total_dia, 0)                                         as total_dia,
      coalesce(d.score_final, 0)                                       as score_final,
      coalesce(d.evaluaciones_count, 0)::int                           as evaluaciones_count,
      coalesce(d.tarifa_envasado, 0)                                   as tarifa_envasado,
      coalesce(d.bonificacion_motivo,'')                               as bonificacion_motivo,
      coalesce(d.sancion_motivo,'')                                    as sancion_motivo,
      coalesce(d.productos_envasados, 0)                               as productos_envasados,
      coalesce(d.envasados_colab, 0)                                   as envasados_colab,
      coalesce(d.pago_envasado_colab, 0)                               as pago_envasado_colab
    from mos.liquidaciones_dia d
    where upper(coalesce(d.estado,'')) = 'PENDIENTE'
      and to_char((d.fecha at time zone 'America/Lima')::date, 'YYYY-MM-DD') between v_desde and v_hasta
  ),
  por_persona as (
    select
      id_personal,
      max(nombre)     filter (where true) as nombre,
      max(rol)        as rol,
      max(app_origen) as app_origen,
      bool_or(virtual) as virtual,
      jsonb_agg(
        jsonb_build_object(
          'fecha',             f,
          'presente',          true,
          'auditado',          auditado,
          'montoBase',         monto_base,
          'pagoEnvasado',      pago_envasado,
          'bonoMeta',          bono_meta,
          'bonificacion',      bonificacion,
          'sancion',           sancion,
          'totalDia',          total_dia,
          'scoreFinal',        score_final,
          'evaluacionesCount', evaluaciones_count,
          'tarifaEnvasado',    tarifa_envasado,
          'bonificacionMotivo', bonificacion_motivo,
          'sancionMotivo',      sancion_motivo,
          'productosEnvasados', productos_envasados,
          'envasadosColab',     envasados_colab,
          'pagoEnvasadoColab',  pago_envasado_colab
        ) order by f
      )                                                  as dias,
      round(sum(total_dia)::numeric, 2)                  as total,
      count(*)::int                                      as cantidad_dias
    from filtrado
    group by id_personal
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'idPersonal',   id_personal,
             'nombre',       nombre,
             'rol',          rol,
             'appOrigen',    app_origen,
             'virtual',      virtual,
             'dias',         dias,
             'total',        total,
             'cantidadDias', cantidad_dias
           )
           order by total desc, nombre asc
         ), '[]'::jsonb)
    into v_arr
  from por_persona
  where cantidad_dias > 0;

  return jsonb_build_object(
           'ok',    true,
           'data',  v_arr,
           'rango', jsonb_build_object('desde', v_desde, 'hasta', v_hasta),
           'fast',  true
         ) || v_fr;
end;
$function$;

revoke all on function mos.liquidaciones_pendientes(jsonb) from public;
grant execute on function mos.liquidaciones_pendientes(jsonb) to authenticated;

-- ── 7b) personal_dia_lista: + colab + créditos pendientes por persona ─────────
create or replace function mos.personal_dia_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_fecha text := coalesce(nullif(btrim(coalesce(p->>'fecha','')), ''),
                           to_char((now() at time zone 'America/Lima')::date, 'YYYY-MM-DD'));
  v_arr jsonb;
  v_fr  jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();

  select coalesce(jsonb_agg(obj order by clasi, nombre_ord), '[]'::jsonb) into v_arr
  from (
    select
      case when upper(coalesce(d.rol,'')) in ('CAJERO','VENDEDOR') then 1
           when upper(coalesce(d.rol,'')) in ('ALMACENERO','ENVASADOR') then 2
           else 3 end                                   as clasi,
      coalesce(d.nombre,'')                              as nombre_ord,
      jsonb_build_object(
        'idPersonal',         coalesce(d.id_personal,''),
        'nombre',             coalesce(d.nombre,''),
        'rol',                upper(coalesce(d.rol,'')),
        'appOrigen',          coalesce(d.app_origen,''),
        'virtual',            (lower(coalesce(d.virtual,'false')) = 'true'),
        'fecha',              v_fecha,
        'presente',           true,
        'horaIngreso',        d.hora_ingreso,
        'ultimaConexion',     d.ultima_conexion,
        'horaSalida',         d.hora_salida,
        'estadoSesion',       coalesce(d.estado_sesion,''),
        'minutosActivos',     coalesce(d.minutos_activos,0)::int,
        'reconexiones',       coalesce(d.reconexiones,0)::int,
        'zonaSesion',         coalesce(d.zona,''),
        'deviceId',           coalesce(d.device_id,''),
        'auditado',           coalesce(d.auditado, false),
        'evaluacionesCount',  coalesce(d.evaluaciones_count, 0)::int,
        'scoreFinal',         coalesce(d.score_final, 0),
        'montoBase',          coalesce(d.monto_base, 0),
        'pagoEnvasado',       coalesce(d.pago_envasado, 0),
        'bonoMeta',           coalesce(d.bono_meta, 0),
        'bonificacion',       coalesce(d.bonificacion, 0),
        'sancion',            coalesce(d.sancion, 0),
        'bonificacionMotivo', coalesce(d.bonificacion_motivo, ''),
        'sancionMotivo',      coalesce(d.sancion_motivo, ''),
        'totalDia',           coalesce(d.total_dia, 0),
        'tarifaEnvasado',     coalesce(nullif(d.tarifa_envasado, 0), 0.1),
        'unidadesEnvasadas',  coalesce(nullif(d.productos_envasados, 0),
                                       round(coalesce(d.pago_envasado, 0) / coalesce(nullif(d.tarifa_envasado, 0), 0.1))),
        -- [418] 🤝 colaborativo (unidades + S/ de mitades, informativo)
        'envasadosColab',     coalesce(d.envasados_colab, 0),
        'pagoEnvasadoColab',  coalesce(d.pago_envasado_colab, 0),
        -- [419] 🧾 notas de crédito vivas de la persona (doc exacto, tickets CREDITO)
        'creditosPend',       coalesce(cred.obj, jsonb_build_object('total',0,'n',0)),
        'documento',          coalesce(per.documento,''),
        'liqEstado',          upper(coalesce(d.estado, 'PENDIENTE')),
        'vetada',             (upper(coalesce(d.estado, '')) = 'VETADA'),
        'idPago',             coalesce(d.id_pago, ''),
        -- [v2.43.384 · mega tabla = única fuente] KPIs reales desde las columnas de
        -- liquidaciones_dia (poblados por mos.recomputar_dia), NO stubs en 0. Así el
        -- modal de Auditar muestra ventas/meta/comisión/envasados consistentes (cero GAS).
        'kpis',   jsonb_build_object(
                    'ventasReales',     coalesce(d.venta_cobrada, 0),
                    'ventaZona',        coalesce(d.venta_zona, 0),
                    'ventasPct',        coalesce(d.progreso_venta_pct, 0),
                    'metaVenta',        coalesce(d.meta_zona, 0),
                    'zonaPrincipal',    coalesce(nullif(d.zona, ''), ''),
                    'auditoriasHechas', coalesce(d.auditorias_hechas, 0)::int,
                    'auditMeta',        coalesce(nullif(d.meta_auditorias, 0), 0)::int,
                    'auditPct',         case when coalesce(d.meta_auditorias, 0) > 0
                                             then round(coalesce(d.auditorias_hechas, 0)::numeric / d.meta_auditorias * 100, 1)
                                             else 0 end,
                    'envasados',        coalesce(d.productos_envasados, 0),
                    'comision',         coalesce(d.bono_meta, 0),
                    'guias', 0),
        'manual', jsonb_build_object('limpiezaPct',0,'limpiezaProfPct',0,'checksAcum',jsonb_build_object(),
                                     'checkCount',0,'checkTotal',0,'controlPct',0,'comentarios','')
      ) as obj
    from mos.liquidaciones_dia d
    left join mos.personal per on per.id_personal = d.id_personal
    left join lateral (
      select jsonb_build_object('total', round(coalesce(sum(v.total),0)::numeric,2), 'n', count(*)::int) as obj
        from me.ventas v
       where btrim(coalesce(per.documento,'')) <> ''
         and upper(v.forma_pago) = 'CREDITO'
         and btrim(coalesce(v.cliente_doc,'')) = btrim(per.documento)
    ) cred on true
    where (d.fecha at time zone 'America/Lima')::date = v_fecha::date
  ) s;

  return jsonb_build_object('ok', true, 'data', v_arr, 'fast', true, 'fecha', v_fecha) || v_fr;
end;
$function$;

revoke all on function mos.personal_dia_lista(jsonb) from public;
grant execute on function mos.personal_dia_lista(jsonb) to authenticated;

-- ── 7d) crear_personal: + documento (verbatim + columna) ─────────────────────
create or replace function mos.crear_personal(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_nom text := nullif(btrim(coalesce(p->>'nombre','')),'');
  v_id  text := nullif(btrim(coalesce(p->>'idPersonal','')),'');
  v_pin text := nullif(btrim(coalesce(p->>'pin','')),'');
  v_est boolean := coalesce(nullif(btrim(coalesce(p->>'estado','')),'')::boolean, true);
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  if v_nom is null then return jsonb_build_object('ok',false,'error','nombre requerido'); end if;
  if v_id is null then v_id := 'PER' || to_char(clock_timestamp(),'YYMMDDHH24MISSMS') || substr(md5(random()::text),1,3); end if;
  insert into mos.personal (id_personal, nombre, apellido, tipo, app_origen, rol, pin, pin_hash, color,
    tarifa_hora, monto_base, estado, fecha_ingreso, foto, documento)
  values (v_id, v_nom, coalesce(p->>'apellido',''), coalesce(p->>'tipo',''), coalesce(p->>'appOrigen',''),
    coalesce(p->>'rol',''), coalesce(v_pin,''),
    case when v_pin is not null then extensions.crypt(v_pin, extensions.gen_salt('bf')) else null end,
    coalesce(p->>'color',''),
    nullif(btrim(coalesce(p->>'tarifaHora','')),'')::numeric, nullif(btrim(coalesce(p->>'montoBase','')),'')::numeric,
    v_est, now(), coalesce(p->>'foto',''),
    btrim(coalesce(p->>'documento','')))   -- [419] ID de TEXTO exacto
  on conflict (id_personal) do nothing;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('idPersonal',v_id));
end; $function$;

revoke all on function mos.crear_personal(jsonb) from public;
grant execute on function mos.crear_personal(jsonb) to authenticated;

-- ── 7c) personal_master_lista: + documento (editor de Personal en MOS) ────────
create or replace function mos.personal_master_lista(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_tipo text := nullif(btrim(coalesce(p->>'tipo','')), '');
  v_app  text := nullif(btrim(coalesce(p->>'appOrigen','')), '');
  v_est  text := nullif(btrim(coalesce(p->>'estado','')), '');
  v_arr jsonb; v_fr jsonb;
begin
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;
  v_fr := mos._frescura_sombra();
  select coalesce(jsonb_agg(jsonb_build_object(
    'idPersonal', coalesce(x.id_personal,''), 'nombre', coalesce(x.nombre,''), 'apellido', coalesce(x.apellido,''),
    'tipo', coalesce(x.tipo,''), 'appOrigen', coalesce(x.app_origen,''), 'rol', coalesce(x.rol,''),
    'pin', coalesce(x.pin,''), 'color', coalesce(x.color,''), 'tarifaHora', coalesce(x.tarifa_hora,0),
    'montoBase', coalesce(x.monto_base,0), 'estado', case when coalesce(x.estado,false) then '1' else '0' end,
    'fechaIngreso', mos._iso_z(x.fecha_ingreso::timestamptz), 'foto', coalesce(x.foto,''),
    'documento', coalesce(x.documento,''),
    'Ultima_Conexion', mos._iso_z(x.ultima_conexion)
  ) order by x.nombre, x.apellido), '[]'::jsonb) into v_arr
  from mos.personal x
  where (v_tipo is null or x.tipo = v_tipo)
    and (v_app  is null or x.app_origen = v_app)
    and (v_est  is null or (case when coalesce(x.estado,false) then '1' else '0' end) = v_est);
  return jsonb_build_object('ok',true,'data',v_arr) || v_fr;
end; $function$;

revoke all on function mos.personal_master_lista(jsonb) from public;
grant execute on function mos.personal_master_lista(jsonb) to authenticated;

notify pgrst, 'reload schema';
