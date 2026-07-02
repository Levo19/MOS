-- 118_mos_vistas_me.sql — [MIGRACIÓN MOS · FASE 2 · LECTURA CROSS-APP de MosExpress (esquema me)]
-- Porta a RPCs Supabase las 6 vistas/bridges de ME que MOS consume hoy vía GAS (proxy _meBridgeGet /
-- lectura directa de la hoja). Espeja gas/Cajas.gs:
--   · meCajasAbiertas      (Cajas.gs:1337) → me.cajas estado='ABIERTA'                       [PORTABLE]
--   · meConsultarCliente   (Cajas.gs:1357) → me.clientes_frecuentes por documento            [PORTABLE c/caveat]
--   · meHistorialVenta     (Cajas.gs:1306) → me.ventas.historial_cambios (jsonb)             [PORTABLE]
--   · meHistorialExtra     (Cajas.gs:1318) → me.movimientos_extra.historial_cambios (jsonb)  [PORTABLE]
--   · meHistorialCliente   (Cajas.gs:1312) → ⚠ GAP (timeline derivado ME-side, no en sombra) [GAP]
--   · meCobrosEnVuelo      (Cajas.gs:1396) → me.creditos_cobro_asignado (computado)          [PORTABLE]
--
-- ⚠️ INERTE / NO-APLICAR-AUN: este archivo SOLO define RPCs + grant. NADIE las llama todavía. El wiring de
--    js/api.js (read-paths) y el flip de flags es tanda posterior. MOS sigue 100% por GAS. Mismo patrón inerte
--    que 94/98/106/107/109/113/116. NO toca flags, NO toca sync, NO cablea frontend.
--
-- ⚠️ ESTAS RPCs LEEN me.* CROSS-SCHEMA (idéntico a 93_mos_resumen_dia y 113_mos_vistas_wh_agregados, que ya
--    leen me.ventas/me.cajas/me.stock_zonas desde el esquema mos). Las tablas me.cajas / me.clientes_frecuentes /
--    me.ventas / me.movimientos_extra / me.creditos_cobro_asignado existen (02_schema_me.sql:16/70/91/109/165).
--    Las RPCs son SECURITY DEFINER y el owner (postgres/service_role) tiene grant ALL sobre el esquema me
--    (02_schema_me.sql:290), así que el cross-schema funciona aunque authenticated NO tenga grant a las tablas.
--
-- ⚠️ NOTA DE NOMBRE — "me.clientes" NO existe; la tabla real es me.clientes_frecuentes (← CLIENTES_FRECUENTES,
--    02_schema_me.sql:109). PK = documento. El bridge ME consultar_cliente puede además consultar RUC en SUNAT
--    en vivo cuando el doc no está en la hoja; ESO no es portable (servicio externo). Ver caveat en la función.
--
-- ── GATE + ENVOLTORIO (idéntico al resto de la Fase 2) ────────────────────────────────────────────────────
--   mos._claim_ok()        (74_mos_claim_ok_f0a.sql)  — service_role/GAS o claim app='MOS'; otro → APP_NO_AUTORIZADA.
--   mos._frescura_sombra() (94_mos_lecturas_proveedores_jornadas.sql) — agrega _heartbeat/_now/_ttl_min/_fresh.
--   Las 4 tablas me.* son SOMBRAS del sync GAS→Supabase de ME → el latido MOS_SYNC_HEARTBEAT NO las cubre
--   directamente (es el sync de MOS). _fresh aquí es la señal del sync MOS; para datos ME el front debe tratar
--   _fresh como "heurística conservadora": si la sombra MOS está congelada, probablemente las de ME también.
--   (No hay un latido ME separado en mos.config hoy; documentado como riesgo abajo.)
--   TZ: America/Lima en cualquier corte de fecha. revoke public + grant service_role + authenticated.
--
-- ── PARIDAD DE SHAPE (leída en js/app.js, consumidores reales) ────────────────────────────────────────────
--   · meCajasAbiertas: el front lee `r.data` = [{idCaja,vendedor,estacion,zona}] (app.js:24370/25933). EXACTO
--     como Cajas.gs:1346. zona ← me.cajas.zona_id.
--   · meConsultarCliente: el front lee r.nombre / r.razon_social / r.direccion (app.js:26157/26270). Devolvemos
--     ambos `nombre` y `razonSocial` (alias) + `direccion` + `documento` + `tipoDoc`. La respuesta NO va envuelta
--     en {data:...} para nombre/direccion porque el front los lee del raíz (r?.nombre). Devolvemos plano + ok.
--   · meHistorial*: el front (_abrirHistorialGenerico app.js:26327) acepta `Array | {historial:[...]}`. _tkHistRender
--     (app.js:26370) consume cada evento como {accion, timestamp|fecha, cambios:[{campo,antes,despues}], motivo,
--     autorizadoPor:{nombre}, usuario, rol}. Devolvemos {ok,historial:[...]} con el jsonb crudo de historial_cambios
--     (ya tiene ESE shape porque lo escribió ME con esas claves). NO re-mapeamos claves del evento (pasamos el
--     array jsonb tal cual) → paridad 1:1 con lo que ME serializaba.
--   · meCobrosEnVuelo: el front lee d.enVuelo / d.recientes (app.js:24348). Cada ítem usa
--     {idCobro,idVenta,cliente,vendedorDest,cajaDestino,monto,metodoSug,correlativo,fechaVencimiento,
--      mensajeAdmin,reasignaciones,estado,fechaRes} (cardVuelo/cardReciente app.js:24693-24760). Mapeo abajo.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════

create schema if not exists mos;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) mos.me_cajas_abiertas(p jsonb) — cajas ME estado ABIERTA (selector receptora).
--    Espeja meCajasAbiertas (Cajas.gs:1337). Shape por fila: {idCaja,vendedor,estacion,zona}. Orden por idCaja.
--    Envoltorio: {ok:true, data:[...]} || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_cajas_abiertas(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_data jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'idCaja',   coalesce(c.id_caja,''),
           'vendedor', coalesce(c.vendedor,''),
           'estacion', coalesce(c.estacion,''),
           'zona',     coalesce(c.zona_id,'')
         ) order by c.id_caja), '[]'::jsonb)
    into v_data
    from me.cajas c
   where upper(coalesce(c.estado,'')) = 'ABIERTA';

  -- [fix] me.cajas es TABLA VIVA (apertura ME_APERTURA_DIRECTO=1 + cierre ME_CIERRE_DIRECTO/FORZADO
  -- directos), NO una sombra del sync GAS. Aplicar _frescura_sombra() aquí medía un heartbeat muerto y
  -- reportaba _fresh:false intermitentemente → el front caía a GAS STALE y mostraba cajas ya CERRADAS como
  -- asignables (bug: cobro enviado a caja cerrada → rechazado + rollback). Al leer la tabla autoritativa,
  -- _fresh:true SIEMPRE: la lista directa (solo ABIERTA) manda, sin fallback a GAS obsoleto.
  return jsonb_build_object('ok', true, 'data', v_data, '_fresh', true);
end;
$fn$;
revoke all on function mos.me_cajas_abiertas(jsonb) from public;
grant execute on function mos.me_cajas_abiertas(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) mos.me_consultar_cliente(p jsonb {documento}) — cliente ME por documento.
--    Espeja meConsultarCliente (Cajas.gs:1357) → bridge ME consultar_cliente.
--    El front (app.js:26157/26270) lee r.nombre / r.razon_social / r.direccion del RAÍZ → devolvemos PLANO
--    (no anidado en data) + ok. Alias razonSocial y razon_social ambos por robustez del consumidor.
--
--    ⚠️ CAVEAT (GAP PARCIAL): el bridge ME, cuando el doc NO está en CLIENTES_FRECUENTES, puede consultar SUNAT/
--       RENIEC en vivo (servicio externo) y devolver nombre/razón social. ESO no es portable a una RPC SQL
--       (no hay acceso a APIs externas desde Postgres). Esta RPC SOLO resuelve contra la sombra
--       me.clientes_frecuentes. Si el doc no está en la sombra → ok:true, encontrado:false, nombre:'' → el front
--       hace fallback (deja escribir el nombre a mano). Para el lookup SUNAT en vivo, el front debe seguir
--       cayendo a GAS (o el wiring debe llamar al bridge SUNAT por separado). Documentado como riesgo abajo.
--
--    Acepta el param tanto como {documento} (nombre canónico pedido) como {doc} (lo que el front pasa hoy,
--    app.js:26156 → API.get('meConsultarCliente',{doc})). Tolerante a ambos.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_consultar_cliente(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_doc    text := nullif(btrim(coalesce(p->>'documento', p->>'doc', '')), '');
  v_nombre text;
  v_dir    text;
  v_tipo   text;
  v_fr     jsonb := mos._frescura_sombra();
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_doc is null then
    return jsonb_build_object('ok', false, 'error', 'documento requerido') || v_fr;
  end if;

  select cf.nombre, cf.direccion, cf.tipo_doc
    into v_nombre, v_dir, v_tipo
    from me.clientes_frecuentes cf
   where cf.documento = v_doc
   limit 1;

  if v_nombre is null and v_dir is null and v_tipo is null then
    -- No está en la sombra. El front cae a su flujo manual / lookup SUNAT por GAS (ver caveat).
    return jsonb_build_object(
      'ok', true, 'encontrado', false, 'documento', v_doc,
      'nombre', '', 'razonSocial', '', 'razon_social', '', 'direccion', ''
    ) || v_fr;
  end if;

  return jsonb_build_object(
    'ok', true, 'encontrado', true, 'documento', v_doc,
    'nombre', coalesce(v_nombre,''),
    'razonSocial', coalesce(v_nombre,''),   -- alias: el front lee r.razon_social como fallback
    'razon_social', coalesce(v_nombre,''),
    'direccion', coalesce(v_dir,''),
    'tipoDoc', coalesce(v_tipo,'')
  ) || v_fr;
end;
$fn$;
revoke all on function mos.me_consultar_cliente(jsonb) from public;
grant execute on function mos.me_consultar_cliente(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) mos.me_historial_venta(p jsonb {idVenta}) — timeline JSON de un ticket.
--    Espeja meHistorialVenta (Cajas.gs:1306) → bridge ME historial_venta.
--    FUENTE: me.ventas.historial_cambios (jsonb, 02_schema_me.sql:36). El bridge ME devolvía ESE array (lo
--    escribe ME con claves {accion,timestamp|fecha,cambios:[{campo,antes,despues}],motivo,autorizadoPor,usuario,rol}).
--    Devolvemos el array CRUDO (sin re-mapear claves) → paridad 1:1 con _tkHistRender (app.js:26370).
--    Si historial_cambios es null → historial:[] (el front muestra "Sin eventos registrados").
--    Envoltorio: {ok:true, historial:[...]} || _frescura_sombra().  (_abrirHistorialGenerico acepta {historial:[]}.)
--
--    ⚠️ Si la venta no existe en la sombra → ok:true, encontrado:false, historial:[]. (No es error duro: la
--       venta podría ser muy reciente y aún no sincronizada → _fresh lo señala.)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_historial_venta(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idVenta','')), '');
  v_hist jsonb;
  v_found boolean := false;
  v_fr   jsonb := mos._frescura_sombra();
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'idVenta requerido') || v_fr;
  end if;

  select true, coalesce(v.historial_cambios, '[]'::jsonb)
    into v_found, v_hist
    from me.ventas v
   where v.id_venta = v_id
   limit 1;

  -- normalizar: si historial_cambios fuese un objeto {historial:[...]} en vez de array, desenvolver.
  if v_hist is not null and jsonb_typeof(v_hist) = 'object' and v_hist ? 'historial' then
    v_hist := v_hist->'historial';
  end if;
  if v_hist is null or jsonb_typeof(v_hist) <> 'array' then
    v_hist := '[]'::jsonb;
  end if;

  return jsonb_build_object('ok', true, 'encontrado', coalesce(v_found,false), 'historial', v_hist) || v_fr;
end;
$fn$;
revoke all on function mos.me_historial_venta(jsonb) from public;
grant execute on function mos.me_historial_venta(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) mos.me_historial_cliente(p jsonb {documento}) — ⚠ GAP (no plenamente portable).
--    Espeja meHistorialCliente (Cajas.gs:1312) → bridge ME historial_cliente.
--
--    ⚠️ POR QUÉ ES GAP: NO sabemos (no está en este repo) qué arma el bridge ME 'historial_cliente'. Dos lecturas:
--       (a) timeline de CAMBIOS del registro de cliente → fuente sería me.clientes_frecuentes.historial_cambios
--           (jsonb, 02_schema_me.sql:115). ESO sí es portable.
--       (b) historial de COMPRAS/ventas del cliente (lista de tickets) → sería un agregado derivado ME-side
--           con un shape distinto (no el del timeline _tkHistRender). NO verificable sin el ME backend.
--    Dado que el front lo abre con _abrirHistorialGenerico (mismo render de timeline que venta/extra), la
--    lectura (a) es la coherente con el consumidor. La servimos desde clientes_frecuentes.historial_cambios,
--    pero la MARCAMOS como GAP/no-confirmada: el shape exacto ME no está verificado → en el cutover NO activar
--    el read-path de historial_cliente por directo sin antes confrontar contra una respuesta real del bridge ME.
--    Mientras tanto la RPC existe (inerte) y devuelve la mejor aproximación + bandera `_gap:true`.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_historial_cliente(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_doc  text := nullif(btrim(coalesce(p->>'documento', p->>'doc', '')), '');
  v_hist jsonb;
  v_found boolean := false;
  v_fr   jsonb := mos._frescura_sombra();
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_doc is null then
    return jsonb_build_object('ok', false, 'error', 'documento requerido') || v_fr;
  end if;

  select true, coalesce(cf.historial_cambios, '[]'::jsonb)
    into v_found, v_hist
    from me.clientes_frecuentes cf
   where cf.documento = v_doc
   limit 1;

  if v_hist is not null and jsonb_typeof(v_hist) = 'object' and v_hist ? 'historial' then
    v_hist := v_hist->'historial';
  end if;
  if v_hist is null or jsonb_typeof(v_hist) <> 'array' then
    v_hist := '[]'::jsonb;
  end if;

  -- _gap:true → señal honesta de que el shape ME-side no está confirmado contra el backend de ME.
  return jsonb_build_object('ok', true, 'encontrado', coalesce(v_found,false), 'historial', v_hist, '_gap', true) || v_fr;
end;
$fn$;
revoke all on function mos.me_historial_cliente(jsonb) from public;
grant execute on function mos.me_historial_cliente(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) mos.me_historial_extra(p jsonb {idExtra}) — timeline JSON de un movimiento extra.
--    Espeja meHistorialExtra (Cajas.gs:1318) → bridge ME historial_extra.
--    FUENTE: me.movimientos_extra.historial_cambios (jsonb, 02_schema_me.sql:100). Mismo tratamiento que venta.
--    Devolvemos array crudo. {ok,encontrado,historial:[]} || _frescura_sombra().
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_historial_extra(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_id   text := nullif(btrim(coalesce(p->>'idExtra','')), '');
  v_hist jsonb;
  v_found boolean := false;
  v_fr   jsonb := mos._frescura_sombra();
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'idExtra requerido') || v_fr;
  end if;

  select true, coalesce(mx.historial_cambios, '[]'::jsonb)
    into v_found, v_hist
    from me.movimientos_extra mx
   where mx.id_extra = v_id
   limit 1;

  if v_hist is not null and jsonb_typeof(v_hist) = 'object' and v_hist ? 'historial' then
    v_hist := v_hist->'historial';
  end if;
  if v_hist is null or jsonb_typeof(v_hist) <> 'array' then
    v_hist := '[]'::jsonb;
  end if;

  return jsonb_build_object('ok', true, 'encontrado', coalesce(v_found,false), 'historial', v_hist) || v_fr;
end;
$fn$;
revoke all on function mos.me_historial_extra(jsonb) from public;
grant execute on function mos.me_historial_extra(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) mos.me_cobros_en_vuelo(p jsonb) — créditos asignados a cajas (en vuelo) + recientes resueltos.
--    Espeja meCobrosEnVuelo (Cajas.gs:1396) → bridge ME cobros_en_vuelo_admin.
--    FUENTE: me.creditos_cobro_asignado (02_schema_me.sql:165). 18 cols. estado: ASIGNADO·COBRADO·RECHAZADO·
--      CANCELADO·EXPIRADO (+ legacy CANCELADO_ADMIN/REASIGNADO que el front reconoce, app.js:24745-24748).
--
--    PARTICIÓN (computado, espejando lo que el panel admin muestra):
--      · enVuelo   = estado = 'ASIGNADO' (activos, con countdown por fecha_vencimiento). Orden: vence antes primero.
--      · recientes = estado en (COBRADO,EXPIRADO,CANCELADO,CANCELADO_ADMIN,RECHAZADO,REASIGNADO) resueltos en las
--                    últimas 24h (por fecha_res). Orden: más reciente primero. Cap 50 (defensivo, el panel solo
--                    muestra "cobrados hoy <4h" + "otros recientes"; 24h/50 es cota generosa y barata).
--
--    Shape por ítem (camelCase, EXACTO a cardVuelo/cardReciente en app.js:24693-24760):
--      idCobro, idVenta, cliente, vendedorDest, cajaDestino, monto, metodoSug, correlativo,
--      fechaVencimiento (ISO), mensajeAdmin, reasignaciones, estado, fechaRes (ISO, solo recientes).
--      `cliente` ← cliente_nombre (el front hace coalesce a 'VARIOS' si vacío).
--    Envoltorio: {ok:true, data:{enVuelo:[...], recientes:[...]}} || _frescura_sombra().
--      (El front, app.js:24347, hace `const d = r.data ? r.data : r; d.enVuelo / d.recientes`.)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function mos.me_cobros_en_vuelo(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_envuelo   jsonb;
  v_recientes jsonb;
begin
  if not mos._claim_ok() then
    return jsonb_build_object('ok', false, 'error', 'APP_NO_AUTORIZADA');
  end if;

  -- EN VUELO: ASIGNADO (activos). Orden por vencimiento ascendente (el más urgente primero).
  select coalesce(jsonb_agg(jsonb_build_object(
           'idCobro',          coalesce(cc.id_cobro,''),
           'idVenta',          coalesce(cc.id_venta,''),
           'cliente',          coalesce(cc.cliente_nombre,''),
           'vendedorDest',     coalesce(cc.vendedor_dest,''),
           'cajaDestino',      coalesce(cc.caja_destino,''),
           'monto',            coalesce(cc.monto,0),
           'metodoSug',        coalesce(cc.metodo_sug,''),
           'correlativo',      coalesce(cc.correlativo,''),
           'fechaVencimiento', cc.fecha_vencimiento,
           'mensajeAdmin',     coalesce(cc.mensaje_admin,''),
           'reasignaciones',   coalesce(cc.reasignaciones,0),
           'estado',           coalesce(cc.estado,'')
         ) order by cc.fecha_vencimiento asc nulls last, cc.fecha_asig asc), '[]'::jsonb)
    into v_envuelo
    from me.creditos_cobro_asignado cc
   where upper(coalesce(cc.estado,'')) = 'ASIGNADO';

  -- RECIENTES: resueltos en últimas 24h. Orden por fecha_res descendente. Cap 50.
  select coalesce(jsonb_agg(x order by ord desc), '[]'::jsonb)
    into v_recientes
    from (
      select jsonb_build_object(
               'idCobro',          coalesce(cc.id_cobro,''),
               'idVenta',          coalesce(cc.id_venta,''),
               'cliente',          coalesce(cc.cliente_nombre,''),
               'vendedorDest',     coalesce(cc.vendedor_dest,''),
               'cajaDestino',      coalesce(cc.caja_destino,''),
               'monto',            coalesce(cc.monto,0),
               'metodoSug',        coalesce(cc.metodo_sug,''),
               'correlativo',      coalesce(cc.correlativo,''),
               'fechaVencimiento', cc.fecha_vencimiento,
               'mensajeAdmin',     coalesce(cc.mensaje_admin,''),
               'reasignaciones',   coalesce(cc.reasignaciones,0),
               'estado',           coalesce(cc.estado,''),
               'fechaRes',         cc.fecha_res
             ) as x,
             cc.fecha_res as ord
        from me.creditos_cobro_asignado cc
       where upper(coalesce(cc.estado,'')) <> 'ASIGNADO'
         and cc.fecha_res is not null
         and cc.fecha_res >= now() - interval '24 hours'
       order by cc.fecha_res desc
       limit 50
    ) sub;

  -- [fix] me.creditos_cobro_asignado es tabla VIVA (asignar/confirmar/cancelar/reasignar/cierre escriben
  -- DIRECTO, RPCs 308/313/314/315). NO es sombra GAS → _frescura_sombra() medía un heartbeat muerto y
  -- reportaba _fresh:false intermitente → el front caía a GAS STALE (que ni tiene los cobros directos)
  -- mostrando cobros en-vuelo desactualizados. _fresh:true SIEMPRE: la lectura directa manda.
  return jsonb_build_object('ok', true, 'data',
           jsonb_build_object('enVuelo', v_envuelo, 'recientes', v_recientes)
         ) || jsonb_build_object('_fresh', true);
end;
$fn$;
revoke all on function mos.me_cobros_en_vuelo(jsonb) from public;
grant execute on function mos.me_cobros_en_vuelo(jsonb) to service_role, authenticated;


-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
-- NOTAS / GAPS / RIESGOS (honestidad 40x)
-- ─────────────────────────────────────────────────────────────────────────────────────────────────────────
-- GAPS (fuentes no migradas o no verificables sin el backend de ME):
--   1) me_consultar_cliente: el lookup SUNAT/RENIEC EN VIVO del bridge ME (cuando el doc no está en la hoja)
--      NO es portable (servicio externo). Esta RPC solo resuelve contra la sombra me.clientes_frecuentes →
--      devuelve encontrado:false si no está. El read-path por directo NO reemplaza el lookup SUNAT; el front
--      debe mantener ese camino por GAS (o invocar el endpoint SUNAT por separado).
--   2) me_historial_cliente: GAP marcado con _gap:true. El shape exacto del bridge ME 'historial_cliente' NO
--      está en este repo (no se sabe si es timeline de cambios del cliente o lista de compras). Servida como
--      aproximación desde clientes_frecuentes.historial_cambios. NO activar su read-path por directo en el
--      cutover sin confrontar primero contra una respuesta real del bridge ME.
--
-- RIESGOS:
--   A) FRESCURA: _frescura_sombra() refleja el latido del sync de MOS (MOS_SYNC_HEARTBEAT), NO un latido propio
--      del sync de ME. Las 4 tablas me.* son sombras del sync GAS→Supabase de ME; si ESE sync se atrasa, _fresh
--      puede reportar fresco (porque el de MOS lo está) mientras los datos ME están viejos. Mitigación pendiente
--      en el cutover: agregar un ME_SYNC_HEARTBEAT y un _frescura_sombra_me() análogo, o que el front considere
--      ambos latidos. HOY es inerte → sin impacto, pero es prerequisito antes de activar cualquier read-path.
--   B) historial_cambios SHAPE: asumimos que ME serializó cada evento con las claves que _tkHistRender espera
--      ({accion,timestamp|fecha,cambios,motivo,autorizadoPor,usuario,rol}). Pasamos el array CRUDO sin re-mapear
--      → si ME usó otras claves, el render mostraría campos vacíos (no rompe, degrada). Verificar con un ticket
--      real con historial antes del cutover.
--   C) me.clientes_frecuentes vs "me.clientes": el prompt menciona "me.clientes" (consultar_cliente) — esa tabla
--      NO existe. La real es me.clientes_frecuentes (PK documento). Usada aquí.
--   D) cobros_en_vuelo "recientes": el corte 24h/cap-50 es una DECISIÓN de esta RPC (el bridge ME podría usar otro
--      criterio, p.ej. "hoy" o cap distinto). El front filtra de nuevo client-side (cobrados <4h vs otros), así que
--      un superconjunto razonable es seguro. Si el panel ME mostrara MÁS de 24h de recientes, ampliar el intervalo.
--   E) CROSS-SCHEMA + grants: SECURITY DEFINER ejecuta como owner (service_role/postgres) que tiene grant ALL en
--      esquema me → lee me.* aunque authenticated no tenga grant a esas tablas. Igual que 93/113 ya en prod inerte.
--      RLS en me.* (02:320+) NO bloquea al owner DEFINER (service_role bypassa RLS).
--
-- PORTABLES SIN CAVEAT: me_cajas_abiertas, me_historial_venta, me_historial_extra, me_cobros_en_vuelo.
-- PORTABLE CON CAVEAT:  me_consultar_cliente (sin SUNAT live).
-- GAP MARCADO:          me_historial_cliente (_gap:true).
-- ═════════════════════════════════════════════════════════════════════════════════════════════════════════
