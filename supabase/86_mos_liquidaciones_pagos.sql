-- 86_mos_liquidaciones_pagos.sql — [MIGRACIÓN MOS · FASE 2 · LOTE PAGOS DE JORNALES (DINERO MÁXIMO)]
-- RPCs de ESCRITURA directa de PAGOS. Espejan gas/Liquidaciones.gs:
--   · marcarPagos (~199)  → mos.marcar_pagos(p jsonb)   [DINERO · transaccional · 3 tablas]
--   · anularPago  (~350)  → mos.anular_pago(p jsonb)     [DINERO · revierte 3 tablas]
--
-- ⚠️ DINERO MÁXIMO. Cada RPC es atómica (es una sola transacción server-side): o se escriben
--    las 3 tablas (liquidaciones_pagos + gastos + liquidaciones_dia) o NINGUNA.
--
-- ⚠️ NACE INERTE (idéntico a 81..85): (1) kill-switch server-side por flag mos.config
--    MOS_PAGOS_JORNAL_DIRECTO, default '0'; (2) nadie cablea js/api.js todavía; (3) MOS sigue
--    100% por GAS. Flag OFF → devuelve MOS_PAGOS_JORNAL_DIRECTO_OFF y el front cae a GAS.
--
-- ── PARIDAD ESQUEMA REAL (verificado con pg) ──────────────────────────────────────────────────────
--    mos.liquidaciones_pagos  PK (id_pago, id_personal, fecha). cols: id_pago id_personal fecha
--      nombre rol app_origen monto_base pago_envasado bono_meta sancion total_dia ticket_job_id
--      pagado_por pagado_ts(timestamptz) estado comentario id_gasto_generado.  (NO tiene local_id ni ts_creado.)
--      estado ∈ {PAGADA, ANULADA}.
--    mos.gastos  PK id_gasto. cols: id_gasto fecha(tstz) categoria tipo descripcion monto comprobante
--      registrado_por local_id.  ⚠️ NO tiene columna estado → "anular un gasto" = BORRAR la fila
--      (paridad gas/Finanzas.gs::eliminarGasto + _sbDelete mos.gastos). Idempotencia: unique parcial
--      ux_mos_gastos_localid (local_id) WHERE local_id IS NOT NULL.
--    mos.liquidaciones_dia  PK id_dia. estado ∈ {PENDIENTE,PAGADA,VETADA}, id_pago.
--
-- ── IDEMPOTENCIA ANTI-DOBLE-PAGO (lo MÁS crítico) ─────────────────────────────────────────────────
--   localId OBLIGATORIO. id_pago es DETERMINÍSTICO: 'LIQ-' || localId. Así:
--     · 2da llamada con el MISMO localId → el INSERT del gasto choca con ux_mos_gastos_localid → se
--       detecta replay → se devuelve el idPago/idGasto YA creado SIN re-insertar nada (no doble pago).
--     · los N renglones de liquidaciones_pagos deduplican además por su PK (id_pago,id_personal,fecha).
--   ANTI-DOBLE-PAGO POR FECHA: antes de escribir, si CUALQUIER fecha pedida ya está PAGADA en
--     liquidaciones_dia (con OTRO id_pago) → se RECHAZA el batch entero (paridad GAS mapaPag), salvo
--     que el id_pago PAGADO sea el de ESTE mismo localId (replay → idempotente).
--
-- ── MONTOS (DINERO exacto) ────────────────────────────────────────────────────────────────────────
--   El cliente pasa el snapshot YA calculado por fecha (montoBase/pagoEnvasado/bonoMeta/sancion/totalDia),
--   igual que GAS (que lee getResumenDia). La RPC NO recalcula actividad cross-app: solo persiste el
--   snapshot y suma total_dia para el gasto. Σ con numeric (sin float) + _r2 (round 2) → centavos exactos.

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 0) KILL-SWITCH (default '0' → INERTE). Sembrado idempotente.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
insert into mos.config (clave, valor, descripcion) values
  ('MOS_PAGOS_JORNAL_DIRECTO','0','MOS Fase 2: pago/anulación directa de jornales (liquidaciones_pagos+gastos+liquidaciones_dia, DINERO) a Supabase. OFF → front cae a GAS.')
on conflict (clave) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.marcar_pagos(p jsonb) — espeja marcarPagos.  ⚠️ DINERO · ATÓMICO 3 TABLAS · IDEMPOTENTE ⚠️
--    Entrada (p):
--      idPersonal (req), pagadoPor, comentario, localId (req),
--      nombre, rol, appOrigen (snapshot de identidad; opcionales),
--      dias: [ { fecha, montoBase, pagoEnvasado, bonoMeta, sancion, totalDia } , ... ]  (req, ≥1)
--    Devuelve: { ok, data:{ idPago, idGasto, dias:N, total } }  ·  dedup=true en replay.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.marcar_pagos(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idp     text := nullif(btrim(coalesce(p->>'idPersonal','')), '');
  v_localid text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_pagpor  text := coalesce(nullif(btrim(coalesce(p->>'pagadoPor','')),''), 'admin');
  v_coment  text := coalesce(p->>'comentario','');
  v_nombre  text := coalesce(nullif(btrim(coalesce(p->>'nombre','')),''), '');
  v_rol     text := upper(coalesce(p->>'rol',''));
  v_appo    text := coalesce(p->>'appOrigen','');
  v_dias    jsonb := coalesce(p->'dias','[]'::jsonb);
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
  -- anti-doble-pago
  v_dia_estado text;
  v_dia_idpago text;
  v_led_idpago text;
begin
  -- KILL-SWITCH antes del gate (paridad lote).
  if coalesce((select valor from mos.config where clave='MOS_PAGOS_JORNAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PAGOS_JORNAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idp is null then return jsonb_build_object('ok',false,'error','Requiere idPersonal'); end if;
  if v_localid is null then return jsonb_build_object('ok',false,'error','Requiere localId (idempotencia DINERO)'); end if;
  if jsonb_typeof(v_dias) <> 'array' or jsonb_array_length(v_dias) = 0 then
    return jsonb_build_object('ok',false,'error','Requiere dias[]');
  end if;

  v_id_pago := 'LIQ-' || v_localid;   -- DETERMINÍSTICO → retries colapsan al mismo pago.

  -- ── IDEMPOTENCIA (replay): ¿ya existe el gasto de este localId? ────────────────────────────────────
  --    Si sí, este batch YA se cobró. Devolvemos lo creado, NO re-insertamos (anti-doble-pago).
  select id_gasto, monto into v_existe_gasto
    from mos.gastos where local_id = v_localid limit 1;
  if found then
    select count(*) into v_n from mos.liquidaciones_pagos
      where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';
    return jsonb_build_object('ok',true,'dedup',true,'data',
      jsonb_build_object('idPago',v_id_pago,'idGasto',v_existe_gasto.id_gasto,
                         'dias',v_n,'total',mos._r2(v_existe_gasto.monto)));
  end if;

  -- ── ANTI-DOBLE-PAGO POR FECHA: ninguna fecha del batch puede estar ya PAGADA con OTRO id_pago ──────
  --    (paridad GAS: rechaza el batch entero). Lock de las filas día implicado contra carrera.
  --    DOS guardas (paridad GAS _liqMapaPagados, que escanea el LEDGER liquidaciones_pagos, NO la materializada):
  --      (a) liquidaciones_dia (la materializada, con lock de fila contra carrera), y
  --      (b) ⭐ el LEDGER liquidaciones_pagos (fuente de verdad de GAS): un renglón PAGADA de OTRO id_pago
  --          en esa misma persona+fecha BLOQUEA. Cierra el hueco de doble-pago cuando NO existe fila día
  --          (p.ej. virtual MEX: sin upsert previo, o replay sin materializar) — la guarda (a) sola no dispara.
  --          Match de fecha por to_char(fecha,'YYYY-MM-DD') (robusto: GAS guarda Lima-medianoche=05:00Z y la RPC
  --          UTC-medianoche=00:00Z; ambos dan el MISMO día-calendario para el string de entrada).
  for d in select * from jsonb_array_elements(v_dias) loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    if v_fecha_s is null then return jsonb_build_object('ok',false,'error','Día sin fecha'); end if;
    v_id_dia := mos._liqdia_key(v_idp, v_fecha_s);
    select upper(coalesce(estado,'')), coalesce(id_pago,'')
      into v_dia_estado, v_dia_idpago
      from mos.liquidaciones_dia where id_dia = v_id_dia for update;
    if found and v_dia_estado = 'PAGADA' and v_dia_idpago <> v_id_pago then
      return jsonb_build_object('ok',false,'error','Día ya pagado: '||v_fecha_s,'fecha',v_fecha_s,'idPagoExistente',v_dia_idpago);
    end if;
    -- (b) LEDGER guard (paridad GAS): renglón PAGADA de OTRO id_pago para esta persona+fecha → rechaza.
    select id_pago into v_led_idpago
      from mos.liquidaciones_pagos
     where id_personal = v_idp
       and upper(coalesce(estado,'')) = 'PAGADA'
       and to_char(fecha,'YYYY-MM-DD') = v_fecha_s
       and id_pago <> v_id_pago
     limit 1;
    if found then
      return jsonb_build_object('ok',false,'error','Día ya pagado: '||v_fecha_s,'fecha',v_fecha_s,'idPagoExistente',v_led_idpago);
    end if;
  end loop;

  -- ── ESCRITURA ATÓMICA (3 tablas). Calcula Σ total_dia mientras inserta los renglones. ────────────────
  for d in select * from jsonb_array_elements(v_dias) loop
    v_fecha_s := nullif(btrim(coalesce(d->>'fecha','')), '');
    begin v_fecha := (v_fecha_s || 'T00:00:00-05:00')::timestamptz; exception when others then v_fecha := v_now; end;  -- medianoche Lima (= _mosDate GAS)
    v_mb := coalesce(mos._numn(d->>'montoBase'),0);
    v_pe := coalesce(mos._numn(d->>'pagoEnvasado'),0);
    v_bm := coalesce(mos._numn(d->>'bonoMeta'),0);
    v_sa := coalesce(mos._numn(d->>'sancion'),0);
    -- totalDia: usa el snapshot del cliente si vino; si no, reconstruye capped≥0 (paridad invariante).
    v_td := mos._numn(d->>'totalDia');
    if v_td is null then v_td := mos._liqdia_total(v_mb, v_pe, v_bm, 0, v_sa); end if;
    v_total := v_total + v_td;

    -- 1.a) renglón snapshot inmutable en liquidaciones_pagos (PK id_pago,id_personal,fecha → dedup).
    insert into mos.liquidaciones_pagos (
      id_pago, id_personal, fecha, nombre, rol, app_origen,
      monto_base, pago_envasado, bono_meta, sancion, total_dia,
      ticket_job_id, pagado_por, pagado_ts, estado, comentario, id_gasto_generado
    ) values (
      v_id_pago, v_idp, v_fecha, v_nombre, v_rol, v_appo,
      v_mb, v_pe, v_bm, v_sa, v_td,
      '', v_pagpor, v_now, 'PAGADA', v_coment, ''   -- id_gasto_generado se backfillea abajo
    )
    on conflict (id_pago, id_personal, fecha) do nothing;
    get diagnostics v_n = row_count;
    v_n := 0; -- reset: contamos al final por SELECT real

    -- 1.b) materialización: marcar el día PAGADA + id_pago (UPDATE atómico por PK).
    update mos.liquidaciones_dia
       set estado='PAGADA', id_pago=v_id_pago, ts_actualizado=v_now
     where id_dia = mos._liqdia_key(v_idp, v_fecha_s);
  end loop;

  v_total := mos._r2(v_total);

  -- 1.c) GASTO JORNALES (1 por batch). local_id = localId → unique parcial = candado anti-doble-gasto.
  v_id_gasto := 'GAS-' || v_localid;
  insert into mos.gastos (
    id_gasto, fecha, categoria, tipo, descripcion, monto, comprobante, registrado_por, local_id
  ) values (
    v_id_gasto,
    (select min(fecha) from mos.liquidaciones_pagos where id_pago = v_id_pago),
    'JORNALES', 'FIJO',
    'Liquidación '||v_id_pago||' · '||coalesce(nullif(v_nombre,''),v_idp)||' · '
      ||(select count(*) from mos.liquidaciones_pagos where id_pago=v_id_pago and upper(coalesce(estado,''))='PAGADA')::text||' día(s)',
    v_total, '', v_pagpor, v_localid
  )
  on conflict (local_id) where local_id is not null do nothing;

  -- backfill id_gasto_generado en todos los renglones de este pago.
  update mos.liquidaciones_pagos set id_gasto_generado = v_id_gasto
   where id_pago = v_id_pago and coalesce(id_gasto_generado,'') = '';

  select count(*) into v_n from mos.liquidaciones_pagos
   where id_pago = v_id_pago and upper(coalesce(estado,'')) = 'PAGADA';

  return jsonb_build_object('ok',true,'dedup',false,'data',
    jsonb_build_object('idPago',v_id_pago,'idGasto',v_id_gasto,'dias',v_n,'total',v_total));
end;
$fn$;
revoke all on function mos.marcar_pagos(jsonb) from public;
grant execute on function mos.marcar_pagos(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.anular_pago(p jsonb) — espeja anularPago.  ⚠️ DINERO · REVIERTE 3 TABLAS · IDEMPOTENTE ⚠️
--    Entrada (p): idPago (req), anuladoPor (opc).
--    Hace (atómico):
--      · liquidaciones_pagos SET estado='ANULADA' (renglones de ese idPago, salta los ya ANULADA).
--      · gastos: BORRA la fila vinculada (id_gasto_generado) — paridad eliminarGasto (no hay col estado).
--      · liquidaciones_dia SET estado='PENDIENTE', id_pago=null (las que tenían ese id_pago).
--    Idempotente: si ya estaba todo ANULADA → anuladas=0, ok igual (no error de dinero).
--    NOTA: la verificación de clave admin (verificarClaveAdmin) queda en el cliente/GAS, NO en la RPC.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.anular_pago(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_idpago text := nullif(btrim(coalesce(p->>'idPago','')), '');
  v_quien  text := coalesce(nullif(btrim(coalesce(p->>'anuladoPor','')),''), 'admin');
  v_now    timestamptz := clock_timestamp();
  v_id_gasto text;
  v_nombre   text := '';
  v_anuladas int := 0;
  v_dias_rev int := 0;
  v_gasto_del int := 0;
  v_sello text;
begin
  if coalesce((select valor from mos.config where clave='MOS_PAGOS_JORNAL_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_PAGOS_JORNAL_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_idpago is null then return jsonb_build_object('ok',false,'error','Requiere idPago'); end if;

  -- ¿existe el pago? (cualquier estado). Capturamos gasto vinculado + nombre antes de mutar.
  select coalesce(nullif(id_gasto_generado,''), null), coalesce(nombre,'')
    into v_id_gasto, v_nombre
    from mos.liquidaciones_pagos
   where id_pago = v_idpago
   order by (upper(coalesce(estado,''))='ANULADA')  -- preferimos una fila NO anulada para el nombre/gasto
   limit 1;
  if not found then
    return jsonb_build_object('ok',false,'error','idPago no encontrado');
  end if;

  v_sello := '↺ ANULADO por '||v_quien||' ('||to_char(v_now,'YYYY-MM-DD')||')';

  -- 2.a) liquidaciones_pagos → ANULADA (salta los ya anulados; idempotente).
  update mos.liquidaciones_pagos set
       estado = 'ANULADA',
       comentario = case when coalesce(comentario,'')='' then v_sello else comentario||' · '||v_sello end
   where id_pago = v_idpago
     and upper(coalesce(estado,'')) <> 'ANULADA';
  get diagnostics v_anuladas = row_count;

  -- 2.b) gasto vinculado → BORRAR (paridad eliminarGasto / _sbDelete mos.gastos).
  if v_id_gasto is not null then
    delete from mos.gastos where id_gasto = v_id_gasto;
    get diagnostics v_gasto_del = row_count;
  end if;

  -- 2.c) liquidaciones_dia → PENDIENTE + id_pago null (las que apuntaban a este pago).
  update mos.liquidaciones_dia set
       estado = 'PENDIENTE', id_pago = null, ts_actualizado = v_now
   where id_pago = v_idpago;
  get diagnostics v_dias_rev = row_count;

  return jsonb_build_object('ok',true,'data',
    jsonb_build_object('idPago',v_idpago,'nombre',v_nombre,'anuladas',v_anuladas,
                       'diasRevertidos',v_dias_rev,'gastoBorrado',(v_gasto_del>0),'anuladoPor',v_quien));
end;
$fn$;
revoke all on function mos.anular_pago(jsonb) from public;
grant execute on function mos.anular_pago(jsonb) to service_role, authenticated;
