-- 83_mos_gastos.sql — [MIGRACIÓN MOS · FASE 2 · LOTE GASTOS (DINERO, simple)]
-- RPCs de ESCRITURA directa para GASTOS operativos. Espeja gas/Finanzas.gs:
--   · registrarGasto(params)  → mos.crear_gasto(p jsonb)      (router gas/Code.gs case 'registrarGasto')
--   · eliminarGasto(params)   → mos.eliminar_gasto(p jsonb)   (router gas/Code.gs case 'eliminarGasto')
--
-- ⚠️ NACE INERTE (triple, IDÉNTICO al patrón de 81/82): (1) kill-switch server-side por flag mos.config —
--    UNO PARA EL MÓDULO (MOS_GASTOS_DIRECTO), default '0'; (2) nadie cablea js/api.js todavía → ninguna PWA
--    llama estas RPCs; (3) MOS sigue 100% por GAS. Las RPCs existen y tienen grant, pero el flag OFF las hace
--    devolver MOS_GASTOS_DIRECTO_OFF (el front cae a GAS).
--
-- ── PARIDAD HONESTA CON GAS (verificada contra los handlers reales en gas/Finanzas.gs) ───────────────────────
--   GAS expone SOLO crear + eliminar (NO hay editarGasto/actualizarGasto NI anularGasto soft en el router;
--   case 'getGastos'/'registrarGasto'/'eliminarGasto' y nada más). Por eso este archivo crea EXACTAMENTE 2 RPCs.
--   NO se inventa una RPC de actualización ni de anulación: sería un contrato que GAS no tiene.
--
--   · registrarGasto: appendRow CRUDO (sin lock ni dedup) → doble-tap / reintento de cola offline = gasto
--       DUPLICADO. En DINERO eso es inaceptable. Acá la idempotencia por `local_id` (índice único parcial +
--       SELECT-previo + on conflict + red unique_violation) hace que el MISMO gesto NO inserte un 2do gasto.
--       Campos por NOMBRE (paridad appendRow): fecha / categoria / tipo / descripcion / monto / comprobante /
--       registrado_por.  Validación paridad GAS: requiere descripcion, monto y categoria.
--       Defaults paridad GAS:  tipo → 'VARIABLE' si ausente;  fecha → now() si ausente (GAS usa _hoy()).
--       ⚠️ DINERO — monto EXACTO en centavos: se parsea con mos._numn (→ numeric, NO float binario). Además se
--          exige monto > 0 (GAS rechazaba !params.monto, lo que también descarta 0 y vacío).
--
--   · eliminarGasto: en GAS es un BORRADO DURO (deleteRow en la hoja + _sbDelete('mos.gastos', id_gasto=eq.X)
--       en la sombra). NO es soft-anular (no hay columna de estado en mos.gastos: id/fecha/categoria/tipo/
--       descripcion/monto/comprobante/registrado_por). Por fidelidad, mos.eliminar_gasto hace un DELETE
--       atómico por PK. Idempotente por naturaleza: borrar 2 veces el mismo id → 1ra borra, 2da informa
--       'ya eliminado' sin reventar (no duplica efecto).
--
-- ── IDS ──────────────────────────────────────────────────────────────────────────────────────────────────
--   _generateId('GAS') de GAS = 'GAS' + Date.getTime() (epoch ms). Acá: 'GAS'+(epoch*1000 de clock_timestamp())
--   ::bigint. La idempotencia REAL es por local_id (no por el id de negocio); el id de negocio se puede mandar
--   desde el front (lo obtiene de la 1ra respuesta) y se respeta on conflict (PK id_gasto).
--
-- ⚠️ COLISIÓN DE PREFIJO 'GAS' OBSERVADA Y ACEPTADA: id_gasto e id_pago(81) ambos derivan de epoch; viven en
--    tablas DISTINTAS (mos.gastos vs mos.pagos_proveedor) con PK propia → no hay choque real de PK. La
--    idempotencia de negocio es por local_id de cada tabla.

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 0) CIMIENTO (idempotente): columna local_id + índice único PARCIAL en mos.gastos.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
alter table mos.gastos add column if not exists local_id text;

create unique index if not exists ux_mos_gastos_localid on mos.gastos (local_id) where local_id is not null;

-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
-- 1) KILL-SWITCH (default '0' → INERTE). Sembrado idempotente.
-- ───────────────────────────────────────────────────────────────────────────────────────────────────────
insert into mos.config (clave, valor, descripcion) values
  ('MOS_GASTOS_DIRECTO','0','MOS Fase 2: escritura directa de GASTOS (DINERO) a Supabase. OFF → front cae a GAS.')
on conflict (clave) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.crear_gasto(p jsonb) — espeja registrarGasto.  ⚠️ DINERO ⚠️
--   Idempotencia por local_id (gesto de cliente) y por PK id_gasto (si el front reenvía el id).
--   monto EXACTO (numeric vía _numn) y > 0. Validación paridad GAS: descripcion + monto + categoria.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.crear_gasto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_local text := nullif(btrim(coalesce(p->>'localId','')), '');
  v_id    text := nullif(btrim(coalesce(p->>'idGasto','')), '');
  v_cat   text := nullif(btrim(coalesce(p->>'categoria','')), '');
  v_desc  text := nullif(btrim(coalesce(p->>'descripcion','')), '');
  v_monto numeric := mos._numn(p->>'monto');
  v_fecha timestamptz;
  v_inserted int;
  v_existe text;
begin
  if coalesce((select valor from mos.config where clave='MOS_GASTOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_GASTOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  -- Validaciones (paridad GAS: requiere descripcion, monto y categoria) + DINERO: monto > 0.
  if v_desc is null then return jsonb_build_object('ok',false,'error','Requiere descripcion, monto y categoria'); end if;
  if v_cat  is null then return jsonb_build_object('ok',false,'error','Requiere descripcion, monto y categoria'); end if;
  if v_monto is null or v_monto <= 0 then return jsonb_build_object('ok',false,'error','Requiere descripcion, monto y categoria'); end if;

  -- IDEMPOTENCIA por local_id (gesto): si ya se registró este gasto → dedup, devolver el id persistido.
  if v_local is not null then
    select id_gasto into v_existe from mos.gastos where local_id = v_local limit 1;
    if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idGasto', v_existe)); end if;
  end if;

  -- IDEMPOTENCIA por PK (reintento que reenvía idGasto)
  if v_id is not null and exists (select 1 from mos.gastos where id_gasto = v_id) then
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idGasto', v_id));
  end if;

  -- fecha: texto (yyyy-MM-dd o ISO) → timestamptz; ausente/basura → now() (paridad GAS _hoy()).
  begin
    v_fecha := nullif(btrim(coalesce(p->>'fecha','')),'')::timestamptz;
  exception when others then v_fecha := null;
  end;
  v_fecha := coalesce(v_fecha, now());

  v_id := coalesce(v_id, 'GAS'||(extract(epoch from clock_timestamp())*1000)::bigint::text);

  insert into mos.gastos (
    id_gasto, fecha, categoria, tipo, descripcion, monto, comprobante, registrado_por, local_id
  ) values (
    v_id, v_fecha, v_cat,
    coalesce(nullif(btrim(coalesce(p->>'tipo','')),''),'VARIABLE'),   -- default 'VARIABLE' (paridad GAS)
    v_desc,
    v_monto,                                                          -- numeric exacto (centavos), NO float
    coalesce(nullif(btrim(coalesce(p->>'comprobante','')),''),''),    -- GAS escribe '' si ausente
    coalesce(nullif(btrim(coalesce(p->>'registradoPor','')),''),''),  -- GAS escribe '' si ausente
    v_local
  )
  on conflict (id_gasto) do nothing;
  get diagnostics v_inserted = row_count;

  -- carrera: el conflicto pudo ser por id_gasto (PK). El local_id chocaría como unique_violation (abajo).
  if v_inserted = 0 then
    if v_local is not null then
      select id_gasto into v_existe from mos.gastos where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idGasto', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idGasto', v_id));
  end if;

  return jsonb_build_object('ok',true,'dedup',false,'data', jsonb_build_object('idGasto', v_id));
exception
  -- red de seguridad ANTI-DOBLE-GASTO: dos tx con el MISMO local_id en paralelo → la perdedora choca el
  -- índice único parcial; en vez de propagar el error (que abortaría su tx), devolvemos el gasto persistido.
  when unique_violation then
    if v_local is not null then
      select id_gasto into v_existe from mos.gastos where local_id = v_local limit 1;
      if found then return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idGasto', v_existe)); end if;
    end if;
    return jsonb_build_object('ok',true,'dedup',true,'data', jsonb_build_object('idGasto', v_id));
end;
$fn$;
revoke all on function mos.crear_gasto(jsonb) from public;
grant execute on function mos.crear_gasto(jsonb) to service_role, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- mos.eliminar_gasto(p jsonb) — espeja eliminarGasto (BORRADO DURO).
--   GAS: deleteRow en la hoja + _sbDelete a la sombra. Acá: DELETE atómico por PK (lock de fila implícito).
--   Idempotente: borrar 2 veces → 1ra elimina (ok:true,eliminado:true), 2da informa (ok:true,eliminado:false).
--   ⚠️ NO es soft-anular: mos.gastos no tiene columna de estado (paridad exacta con GAS = borrado físico).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.eliminar_gasto(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id text := nullif(btrim(coalesce(p->>'idGasto','')), '');
  v_n  int;
begin
  if coalesce((select valor from mos.config where clave='MOS_GASTOS_DIRECTO' limit 1),'0') <> '1' then
    return jsonb_build_object('ok',false,'error','MOS_GASTOS_DIRECTO_OFF');
  end if;
  if not mos._claim_ok() then return jsonb_build_object('ok',false,'error','APP_NO_AUTORIZADA'); end if;

  if v_id is null then return jsonb_build_object('ok',false,'error','Requiere idGasto'); end if;

  delete from mos.gastos where id_gasto = v_id;
  get diagnostics v_n = row_count;

  -- Paridad GAS: si no existía, GAS devolvía {ok:false,'Gasto no encontrado'}. Acá lo hacemos IDEMPOTENTE
  -- (ok:true, eliminado:false) para que un reintento del MISMO borrado no falle ni alarme la cola offline;
  -- el efecto neto (el gasto ya no está) es idéntico. Si se prefiere paridad literal, cambiar a ok:false.
  if v_n = 0 then return jsonb_build_object('ok',true,'eliminado',false); end if;
  return jsonb_build_object('ok',true,'eliminado',true);
end;
$fn$;
revoke all on function mos.eliminar_gasto(jsonb) from public;
grant execute on function mos.eliminar_gasto(jsonb) to service_role, authenticated;
