// MOS Admin — api.js
// Thin wrapper around the MOS GAS Web App URL

const API = (() => {
  const GAS_URL = 'https://script.google.com/macros/s/AKfycbxalFhPdiVi_e4tq1f4ce6MHoLJb2_hwPts9bCttotlArIepooUwFpMl4nsX-3x4HfM/exec';

  function getUrl()      { return GAS_URL; }
  function setUrl()      { /* URL fija en código */ }
  function isConfigured(){ return true; }

  // [v2.43.63] Timeout 45s vía AbortController. Antes el fetch quedaba colgado
  // PARA SIEMPRE cuando Chrome reportaba ERR_NETWORK_IO_SUSPENDED (red suspendida
  // por ahorro de energía, pestaña inactiva, VPN intermitente, cable flojo).
  // Spinner eterno + sin toast porque el await nunca resolvía ni rechazaba.
  // Ahora abortamos a los 45s y throweamos error claro distinguible por el caller.
  const DEFAULT_TIMEOUT_MS = 45000;

  function _fetchConTimeout(url, opts, timeoutMs) {
    return new Promise((resolve, reject) => {
      const ctrl = new AbortController();
      const tid = setTimeout(() => {
        ctrl.abort();
        const err = new Error('Timeout: la conexión tardó más de ' + (timeoutMs/1000) + 's. Revisa tu red y vuelve a intentar.');
        err.code = 'TIMEOUT';
        reject(err);
      }, timeoutMs);
      fetch(url, Object.assign({}, opts, { signal: ctrl.signal }))
        .then(res => { clearTimeout(tid); resolve(res); })
        .catch(e => {
          clearTimeout(tid);
          // Distinguir abort por timeout (ya rechazado arriba) de errores de red
          if (e.name === 'AbortError') return; // ya manejado
          if (/NetworkError|Failed to fetch|ERR_NETWORK/i.test(e.message)) {
            const ne = new Error('Sin red: el navegador no pudo enviar la petición (' + e.message + ')');
            ne.code = 'NETWORK';
            reject(ne);
          } else {
            reject(e);
          }
        });
    });
  }

  async function _fetch(method, params) {
    const url = getUrl();
    if (!url) throw new Error('GAS URL no configurada. Abre ⚙️ Configuración.');
    // Check rápido de offline ANTES de gastar el timeout
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
      const oe = new Error('Sin conexión a internet. Espera a recuperar señal y reintenta.');
      oe.code = 'OFFLINE';
      throw oe;
    }

    if (method === 'GET') {
      const qs = new URLSearchParams(params).toString();
      const res = await _fetchConTimeout(`${url}?${qs}`, {}, DEFAULT_TIMEOUT_MS);
      const d   = await res.json();
      if (!d.ok) throw new Error(d.error || 'Error del servidor');
      return d.data;
    } else {
      // Inyectar contexto de auditoría (quién/cuándo/dónde) en cada POST
      const audit = window.__MOS_AUDIT ? Object.assign({}, window.__MOS_AUDIT, { timestamp: new Date().toISOString() }) : null;
      const body = audit && !params._audit ? Object.assign({ _audit: audit }, params) : params;
      const res = await _fetchConTimeout(url, {
        method:  'POST',
        body:    JSON.stringify(body),
        headers: { 'Content-Type': 'text/plain' }
      }, DEFAULT_TIMEOUT_MS);
      const d = await res.json();
      if (!d.ok) throw new Error(d.error || 'Error del servidor');
      return d.data;
    }
  }

  // ════════════════════════════════════════════════════════════════════
  // [FASE 0B · migración MOS→Supabase] Infraestructura de LECTURA DIRECTA
  // (navegador→PostgREST). Réplica del patrón de warehouseMos (js/api.js).
  //
  // ⚠️ INERTE POR DEFECTO: con los flags OFF (default) NADA de esto se invoca
  // todavía. MOS sigue 100% por GAS. El cableado de lecturas concretas es FASE 1.
  //
  // url + anon key son PÚBLICOS (van en el cliente; la RLS los protege en el
  // server vía el claim app='MOS' del JWT que mintea la Edge `mint-mos` — FASE 0A).
  // Mismo proyecto Supabase que WH (rzbzdeipbtqkzjqdchqk) → constantes idénticas.
  // ════════════════════════════════════════════════════════════════════
  const _SB_URL  = 'https://rzbzdeipbtqkzjqdchqk.supabase.co';
  const _SB_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
  const _sbTok = { token: null, exp: 0 };

  // ── Flags de activación (default OFF → INERTE) ──
  // MOS no tiene un objeto de config server-wide tipo WH_CONFIG en index.html.
  // Replicamos el MECANISMO dual de WH (localStorage + objeto global opcional):
  //   1) localStorage 'mos_lectura_navegador' === '1'   (palanca por dispositivo)
  //   2) window.MOS_CONFIG?.lecturaNavegador === true     (palanca server-wide futura)
  // Preparado para flags por-acción 'mos_<x>_directo' en FASE 1 (helper _mosFlag).
  function _mosFlag(lsKey, cfgKey) {
    try {
      if (localStorage.getItem(lsKey) === '1') return true;
      return (typeof window !== 'undefined' && window.MOS_CONFIG && window.MOS_CONFIG[cfgKey] === true);
    } catch (_) {
      return (typeof window !== 'undefined' && window.MOS_CONFIG && window.MOS_CONFIG[cfgKey] === true);
    }
  }
  // Flag MAESTRO de lectura directa. Default OFF. FASE 1 lo consultará por-acción.
  function _mosLecturaDirecta() { return _mosFlag('mos_lectura_navegador', 'lecturaNavegador'); }

  function _sbFetchTimeout(url, opts, ms) {
    const ctrl = new AbortController();
    const tid  = setTimeout(() => ctrl.abort(), ms || 12000);
    return fetch(url, { ...opts, signal: ctrl.signal }).finally(() => clearTimeout(tid));
  }

  // deviceId de MOS: fuente canónica = DeviceAuth.deviceId() (módulo compartido,
  // assets/auth/device-auth.js). Fallback directo a localStorage 'mos_device_id'
  // (la misma clave que DeviceAuth usa como storageKeys.deviceId) por si DeviceAuth
  // aún no inicializó. (window._getDeviceIdMos vive en un bloque `if(false)`
  // deprecado → NO confiable, no se usa.)
  function _mosDeviceId() {
    try {
      if (typeof window !== 'undefined' && window.DeviceAuth && window.DeviceAuth.deviceId) {
        const id = window.DeviceAuth.deviceId();
        if (id) return id;
      }
    } catch (_) {}
    try { return localStorage.getItem('mos_device_id') || ''; } catch (_) { return ''; }
  }

  // Mintea el JWT (app='MOS') y lo cachea. PRIMARIO y ÚNICO: Edge Function `mint-mos`
  // (HS256, exp ~30min). A DIFERENCIA de WH, MOS NO tiene endpoint GAS `mintTokenMOS`
  // de fallback → si la Edge falla/timeout/{ok:false}, retorna null y NO hay token.
  // La operación que lo use (FASE 1) caerá a GAS por su propio fallback (_sbRpcMOS/
  // _sbLeerTablaMOS devuelven null → señal de "caé a GAS"). Refresh proactivo ~120s
  // antes de exp; _mintInFlight dedup para no disparar ráfaga de POSTs en el arranque.
  let _mintInFlight = null;

  // Edge `mint-mos`: verify_jwt=false → va con `apikey` (anon, público), SIN Authorization
  // (es quien EMITE el token). Devuelve {ok,token,exp}. Lanza si no hay token válido.
  async function _mintViaEdgeMOS(deviceId) {
    const res = await _sbFetchTimeout(`${_SB_URL}/functions/v1/mint-mos`, {
      method: 'POST',
      headers: { 'apikey': _SB_ANON, 'Content-Type': 'application/json' },
      body: JSON.stringify({ deviceId })
    }, 6000);
    const d = await res.json().catch(() => null);
    if (!d || !d.ok || !d.token) throw new Error('mint-mos edge: ' + ((d && d.error) || res.status));
    return d;
  }

  // Devuelve el token cacheado (válido), o lo mintea via Edge. Si la Edge falla →
  // retorna null (NO hay fallback GAS en MOS). NUNCA lanza: el caller trata null
  // como "no hay token → caé a GAS".
  async function _mintTokenMOS() {
    const now = Math.floor(Date.now() / 1000);
    if (_sbTok.token && (_sbTok.exp - now) > 30) { _agendarRefreshMOS(); return _sbTok.token; }
    if (_mintInFlight) return _mintInFlight;
    _mintInFlight = (async () => {
      try {
        const d = await _mintViaEdgeMOS(_mosDeviceId());
        const n = Math.floor(Date.now() / 1000);
        _sbTok.token = d.token; _sbTok.exp = d.exp || (n + 1800);
        _agendarRefreshMOS();
        return d.token;
      } catch (_) {
        return null;   // Edge caída → sin token → el caller cae a GAS
      }
    })();
    try { return await _mintInFlight; }
    finally { _mintInFlight = null; }
  }

  // Refresh PROACTIVO en background: re-mintea ~120s ANTES de expirar, fuera del
  // camino crítico, para que una navegación NUNCA dispare el mint sincrónico.
  // Fire-and-forget: si falla, el camino sincrónico bajo demanda es la red de seguridad.
  let _refreshTid = null;
  function _agendarRefreshMOS() {
    if (_refreshTid) return;
    const now = Math.floor(Date.now() / 1000);
    const margen = 120;
    let enMs = (_sbTok.exp - now - margen) * 1000;
    if (!isFinite(enMs) || enMs < 1000) enMs = 1000;
    if (enMs > 1800000) enMs = 1800000;
    _refreshTid = setTimeout(async () => {
      _refreshTid = null;
      try {
        const d = await _mintViaEdgeMOS(_mosDeviceId());
        const n = Math.floor(Date.now() / 1000);
        _sbTok.token = d.token; _sbTok.exp = d.exp || (n + 1800);
        _agendarRefreshMOS();
      } catch (_) { /* el camino sincrónico re-minteará bajo demanda */ }
    }, enMs);
    try { if (_refreshTid && _refreshTid.unref) _refreshTid.unref(); } catch (_) {}
  }

  // Llama una RPC de LECTURA directo a PostgREST (apikey + Bearer + Profile 'mos').
  // Si no hay token (Edge caída) → retorna null (señal de "caé a GAS"). Lanza solo
  // ante HTTP de error (el caller decide: la mayoría de lecturas FASE 1 caerán a GAS
  // ante throw vía su propio try/catch). profile default 'mos' (esquema de MOS).
  async function _sbRpcMOS(fn, args, profile) {
    const token = await _mintTokenMOS();
    if (!token) return null;
    const prof = profile || 'mos';
    const res = await _sbFetchTimeout(`${_SB_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token,
        'Accept-Profile': prof, 'Content-Profile': prof, 'Content-Type': 'application/json'
      },
      body: JSON.stringify(args || {})
    }, 12000);
    if (!res.ok) throw new Error('rpc directo HTTP ' + res.status);
    return res.json();
  }

  // Lee una tabla del esquema mos.* directo (GET /rest/v1/{tabla}, Accept-Profile 'mos').
  // `query` = querystring PostgREST opcional (ej. 'select=*&estado=eq.1'). Si no hay token
  // → null ("caé a GAS"). Lanza ante HTTP de error. (FASE 1 elegirá RPC vs tabla por caso.)
  async function _sbLeerTablaMOS(tabla, query, profile) {
    const token = await _mintTokenMOS();
    if (!token) return null;
    const prof = profile || 'mos';
    const qs = query ? ('?' + String(query).replace(/^\?/, '')) : '';
    const res = await _sbFetchTimeout(`${_SB_URL}/rest/v1/${tabla}${qs}`, {
      method: 'GET',
      headers: { 'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token, 'Accept-Profile': prof }
    }, 12000);
    if (!res.ok) throw new Error('leer tabla HTTP ' + res.status);
    return res.json();
  }

  // Helper de FALLBACK (lo usará FASE 1 para no duplicar el patrón en cada lectura):
  //   directo = async () => respuesta-Supabase  (usa _sbRpcMOS/_sbLeerTablaMOS)
  //   gas     = async () => respuesta-GAS         (la llamada GAS de hoy)
  // Regla: si flag MAESTRO ON → intenta `directo`; si devuelve null (sin token o
  // acción sin backend RLS) o LANZA → cae a `gas`. Con flag OFF → siempre `gas`
  // (INERTE). `flagFn` opcional permite gate por-acción (default = _mosLecturaDirecta).
  async function _conFallbackMOS(directo, gas, flagFn) {
    const on = (typeof flagFn === 'function') ? flagFn() : _mosLecturaDirecta();
    if (on) {
      try {
        const r = await directo();
        if (r != null) return r;   // null = "sin backend directo / sin token" → GAS
      } catch (_) { /* error directo → GAS (red de seguridad) */ }
    }
    return await gas();
  }

  // ════════════════════════════════════════════════════════════════════
  // [FASE 1 · PILOTO] Lectura directa del CATÁLOGO MAESTRO (getProductos).
  // Gate por-acción `mos_catalogo_directo` (ADEMÁS del maestro). Default OFF → INERTE.
  // RPC: mos.productos_master_rls() (75_…) → { ok, productos:[crudo snake], _fresh, _count, ... }.
  // El FRONT mapea snake→shape-hoja camelCase (inverso de _CAT_SPECS.productos) para que el shape sea
  // BYTE-equivalente a getProductosMaster de GAS (un mismatch dejaría el catálogo vacío/roto al activar).
  // ════════════════════════════════════════════════════════════════════

  // Flag por-acción del catálogo: ON solo si (maestro OR por-acción). Permite activar SOLO el catálogo
  // sin prender toda la lectura directa de MOS. Default OFF (ambos flags OFF → INERTE).
  function _mosCatalogoDirecto() {
    return !!(_mosLecturaDirecta() || _mosFlag('mos_catalogo_directo', 'catalogoDirecto'));
  }

  // Mapa snake(pg) → camelCase(shape-hoja) + tipo, INVERSO EXACTO de _CAT_SPECS.productos (gas/MigracionCatalogo.gs).
  // [pgCol, headerHoja, tipo]. Mantener sincronizado con el backfill: la fuente de verdad del shape es ese spec.
  const _MOS_PROD_SPEC = [
    ['id_producto','idProducto','text'], ['sku_base','skuBase','text'],
    ['codigo_barra','codigoBarra','text'], ['descripcion','descripcion','text'],
    ['marca','marca','text'], ['id_categoria','idCategoria','text'], ['unidad','unidad','text'],
    ['precio_venta','precioVenta','num'], ['precio_costo','precioCosto','num'],
    ['cod_tributo','Cod_Tributo','text'], ['igv_porcentaje','IGV_Porcentaje','num'],
    ['cod_sunat','Cod_SUNAT','text'], ['tipo_igv','Tipo_IGV','int'],
    ['unidad_medida','Unidad_Medida','text'], ['estado','estado','bool10'],
    ['es_envasable','esEnvasable','bool10'], ['codigo_producto_base','codigoProductoBase','text'],
    ['factor_conversion','factorConversion','num'], ['factor_conversion_base','factorConversionBase','num'],
    ['merma_esperada_pct','mermaEsperadaPct','num'], ['stock_minimo','stockMinimo','num'],
    ['stock_maximo','stockMaximo','num'], ['zona','zona','text'],
    ['fecha_creacion','fechaCreacion','date'], ['creado_por','creadoPor','text'],
    ['modo_venta','modoVenta','text'], ['margen_pct','margenPct','num'],
    ['precio_tope','precioTope','num'], ['foto_url','fotoUrl','text'],
    ['historial_cambios','historialCambios','json'], ['segmentos_precio','segmentos_precio','json'],
    // tipo_producto es derivado en el backfill (post()) pero existe como columna en la sombra → exponerlo igual.
    ['tipo_producto','tipoProducto','text']
  ];

  // Convierte un valor crudo de PostgREST al tipo del shape-hoja.
  //  - bool10: el front compara String(estado)!=='0' / String(esEnvasable)==='1' → entregar '1'/'0' (NUNCA true/false).
  //  - num/int: Number (la sombra ya viene numérica; defensivo). null se preserva.
  //  - text: String() defensivo (ids/codigoBarra SIEMPRE texto). null se preserva (≡ celda vacía de la hoja).
  //  - date: ya viene ISO/text desde pg (timestamptz). El front lo usa como string igual que _sheetToObjects.
  //  - json: ya viene parseado (jsonb) → se deja tal cual (el front usa historialCambios como array).
  function _sbValProd(raw, tipo) {
    if (raw === undefined) raw = null;
    switch (tipo) {
      case 'bool10': return (raw === true || raw === 1 || raw === '1' || raw === 'true') ? '1' : '0';
      case 'num':    return raw == null ? null : Number(raw);
      case 'int':    return raw == null ? null : Math.round(Number(raw));
      case 'text':   return raw == null ? null : String(raw);
      default:       return raw; // date(json) tal cual
    }
  }

  // Mapea una fila cruda snake → objeto shape-hoja camelCase.
  function _mapProdSnakeToHoja(row) {
    const o = {};
    for (let i = 0; i < _MOS_PROD_SPEC.length; i++) {
      const pg = _MOS_PROD_SPEC[i][0], hdr = _MOS_PROD_SPEC[i][1], t = _MOS_PROD_SPEC[i][2];
      o[hdr] = _sbValProd(row[pg], t);
    }
    return o;
  }

  // Replica EXACTA de los filtros server-side de getProductosMaster (gas/Productos.gs) sobre el shape-hoja,
  // para que el resultado directo sea idéntico al de GAS ante los mismos params (estado/skuBase/categoria/q).
  function _filtrarProdComoGAS(rows, params) {
    let out = rows;
    if (params && params.estado)    out = out.filter(r => String(r.estado) === String(params.estado));
    if (params && params.skuBase)   out = out.filter(r => r.skuBase === params.skuBase);
    if (params && params.categoria) out = out.filter(r => r.idCategoria === params.categoria);
    if (params && params.q) {
      const q = String(params.q).toLowerCase();
      out = out.filter(r =>
        (r.descripcion || '').toLowerCase().indexOf(q) >= 0 ||
        (r.codigoBarra || '').indexOf(q) >= 0 ||
        (r.skuBase     || '').toLowerCase().indexOf(q) >= 0);
    }
    return out;
  }

  // Lectura directa de productos. Devuelve el ARRAY (mismo shape que d.data de GAS) o null (→ caé a GAS).
  // null si: sin token (Edge caída), respuesta no-ok, o GATE DE FRESCURA en false (sombra stale/vacía).
  async function _getProductosDirecto(params) {
    const r = await _sbRpcMOS('productos_master_rls', {});   // null si no hay token → caé a GAS
    if (r == null) return null;
    if (!r.ok || !Array.isArray(r.productos)) return null;   // backend dijo no → GAS
    // GATE DE FRESCURA: si la sombra no está fresca (sync muerto / vacía) NO servimos datos viejos → GAS.
    if (r._fresh !== true) {
      try { console.warn('[MOS catálogo directo] sombra STALE (_fresh=false, _count=' + r._count + ', heartbeat=' + r._heartbeat + ') → fallback a GAS'); } catch (_) {}
      return null;
    }
    const mapped = r.productos.map(_mapProdSnakeToHoja);
    return _filtrarProdComoGAS(mapped, params);
  }

  // ════════════════════════════════════════════════════════════════════
  // [FASE 1] Lectura directa de FINANZAS por rango (getFinanzasRango) e HISTORIAL de precios
  // (getHistorialPrecios). Gates por-acción `mos_finanzas_directo` / `mos_historial_directo`
  // (ADEMÁS del maestro). Default OFF → INERTE (con flag OFF jamás entran al directo).
  //   · finanzas:  RPC mos.finanzas_rango(p_desde,p_hasta)        (76_) → {ok, data:{serie,totales,desde,hasta}, _fresh}
  //   · historial: RPC mos.historial_precios_lista(p_sku,p_codigo,p_limit) (77_) → {ok, data:[...], _fresh}
  // Ambas RPCs devuelven números financieros YA redondeados a 2 dec en pg (mismo _r2 que GAS); el front NO
  // re-castea importes (los pasa tal cual = paridad exacta de centavos). El shape de `data` es BYTE-equivalente
  // al `d.data` que hoy entrega GAS (getFinanzasRango/getHistorialPrecios) → el resto de la app no cambia.
  // ════════════════════════════════════════════════════════════════════
  function _mosFinanzasDirecto()  { return !!(_mosLecturaDirecta() || _mosFlag('mos_finanzas_directo',  'finanzasDirecto')); }
  function _mosHistorialDirecto() { return !!(_mosLecturaDirecta() || _mosFlag('mos_historial_directo', 'historialDirecto')); }

  // [FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS] gates por-operación (espejo de los kill-switches server-side
  // MOS_PROVEEDORES_DIRECTO / MOS_PEDIDOS_DIRECTO / MOS_PAGOS_DIRECTO / MOS_PROVPROD_DIRECTO, todos default '0').
  // CADA grupo tiene su flag de cliente independiente → se puede activar proveedores sin activar pagos, etc.
  // Default OFF (cliente) + OFF (server) → INERTE doble. (El flag maestro mos_lectura_navegador NO los
  // habilita: estas son ESCRITURAS de dinero/negocio, las queremos detrás de un flag explícito por grupo.)
  function _mosProveedoresDirecto() { return !!_mosFlag('mos_proveedores_directo', 'proveedoresDirecto'); }
  function _mosPedidosDirecto()     { return !!_mosFlag('mos_pedidos_directo',     'pedidosDirecto'); }
  function _mosPagosDirecto()       { return !!_mosFlag('mos_pagos_directo',       'pagosDirecto'); }
  function _mosProvProdDirecto()    { return !!_mosFlag('mos_provprod_directo',    'provprodDirecto'); }

  // [FASE 2 · LOTE BAJO-RIESGO + GASTOS] gates por-operación (espejo de los kill-switches server-side
  // MOS_GASTOS_DIRECTO (83) / MOS_EVAL_DIRECTO / MOS_HORARIO_DIRECTO (82), todos default '0').
  // CADA módulo tiene su flag de cliente independiente → se activa uno sin tocar los otros. Default OFF
  // (cliente) + OFF (server) → INERTE doble. El flag maestro mos_lectura_navegador NO los habilita
  // (gastos = DINERO; eval/horario = escrituras de negocio → flag explícito por módulo, igual que prov/pago).
  // ⚠️ ETIQUETAS (MOS_ETIQ_DIRECTO) NO se cablea acá: el frontend MOS no llama marcarVisto/marcarPegada ni
  //    ningún "crear etiqueta" (las filas nacen del hook de precio en GAS). Cablearlo sería inventar un
  //    consumidor que no existe. Ver REPORTE.
  function _mosGastosDirecto()  { return !!_mosFlag('mos_gastos_directo',  'gastosDirecto'); }
  function _mosEvalDirecto()    { return !!_mosFlag('mos_eval_directo',    'evalDirecto'); }
  function _mosHorarioDirecto() { return !!_mosFlag('mos_horario_directo', 'horarioDirecto'); }

  // [FASE 2 · LOTE JORNALES/LIQUIDACIONES] gates por-operación (espejo de los kill-switches server-side
  // MOS_JORNADAS_DIRECTO (84) / MOS_LIQDIA_DIRECTO (85), ambos default '0'). DINERO (jornal/liquidación).
  // CADA grupo tiene su flag de cliente independiente → se activa jornadas sin tocar liquidaciones, etc.
  // Default OFF (cliente) + OFF (server) → INERTE doble. El flag maestro mos_lectura_navegador NO los
  // habilita (son ESCRITURAS de dinero → flag explícito por grupo, igual que prov/pago/gasto).
  // ⚠️ PAGOS DE JORNALES (MOS_PAGOS_JORNAL_DIRECTO, 86: marcarPagos/anularPago) NO se cabla acá. El
  //    frontend MOS llama esas acciones con un SHAPE incompatible con la RPC y/o saltaría una validación:
  //      · marcarPagos: el front manda `fechas[]` (strings), NO `dias[]` con snapshot por día. La RPC
  //        mos.marcar_pagos EXIGE `dias:[{fecha,montoBase,pagoEnvasado,bonoMeta,sancion,totalDia}]` y NO
  //        recalcula cross-app (envasados/ventas) → con el payload actual el total quedaría en 0 (pago vacío).
  //        El snapshot lo arma GAS vía getResumenDia (cross-app) → el cómputo se queda en GAS por diseño.
  //      · anularPago: el front manda `claveAdmin` y depende de que el BACKEND valide la clave admin
  //        (verificarClaveAdmin → {autorizado:false}). La RPC mos.anular_pago NO verifica la clave (su nota:
  //        "queda en el cliente/GAS") → cablearla saltaría el gate de clave admin. La verificación vive en GAS.
  //    Ver REPORTE. Con todo OFF (default) marcarPagos/anularPago van 100% por GAS, idéntico a hoy.
  function _mosJornadasDirecto() { return !!_mosFlag('mos_jornadas_directo', 'jornadasDirecto'); }
  function _mosLiqdiaDirecto()   { return !!_mosFlag('mos_liqdia_directo',   'liqdiaDirecto'); }

  // Lectura directa de finanzas por rango. Devuelve {serie,totales,desde,hasta} (= d.data de GAS) o null (→ GAS).
  // null si: sin token, respuesta no-ok, o GATE DE FRESCURA en false (sombra mos.* stale → no servir P&L viejo).
  async function _getFinanzasRangoDirecto(params) {
    const r = await _sbRpcMOS('finanzas_rango', {
      p_desde: (params && params.desde) || null,
      p_hasta: (params && params.hasta) || null
    });
    if (r == null) return null;                                   // sin token → GAS
    if (!r.ok || !r.data || !Array.isArray(r.data.serie)) return null;  // backend dijo no / shape inesperado → GAS
    if (r._fresh !== true) {                                      // sombra costos/personal/gastos stale → GAS (P&L mezclado)
      try { console.warn('[MOS finanzas directo] sombra STALE (_fresh=false, heartbeat=' + r._heartbeat + ') → fallback a GAS'); } catch (_) {}
      return null;
    }
    return r.data;   // {serie,totales,desde,hasta} — números ya redondeados en pg, sin re-castear (centavos exactos)
  }

  // Lectura directa del historial de precios. Devuelve el ARRAY de filas (= d.data de GAS) o null (→ GAS).
  async function _getHistorialPreciosDirecto(params) {
    const r = await _sbRpcMOS('historial_precios_lista', {
      p_sku:    (params && params.skuBase)     || null,
      p_codigo: (params && params.codigoBarra) || null,
      p_limit:  (params && params.limit != null && params.limit !== '') ? parseInt(params.limit, 10) : null
    });
    if (r == null) return null;
    if (!r.ok || !Array.isArray(r.data)) return null;
    if (r._fresh !== true) {
      try { console.warn('[MOS historial directo] sombra STALE (_fresh=false, heartbeat=' + r._heartbeat + ') → fallback a GAS'); } catch (_) {}
      return null;
    }
    return r.data;   // filas camelCase {id,skuBase,codigoBarra,...} — espejo del header de la hoja
  }

  // ════════════════════════════════════════════════════════════════════
  // [FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS/PROVPROD/JORNADAS] LECTURA-LISTA directa (read-paths).
  // RPCs SQL 94 (mos.*_lista, p jsonb). Cada una devuelve { ok, data:[camelCase], _count, _fresh, ... }
  // donde `data` es BYTE-equivalente al `d.data` que hoy entrega GAS (espejo de _MOS_SPECS, ver cabecera 94).
  // PATRÓN IDÉNTICO a finanzas/historial: directo→{array} o null (sin token / !ok / shape inesperado /
  // _fresh!==true). null ⇒ caé a GAS. El gate por-módulo (default OFF) decide si se entra siquiera al directo.
  // ⚠️ getProductosProveedorConStock NO se cabla acá: es OTRA acción (stock-enriquecida cross-app), no la lista
  //    plana de proveedor_producto_lista → seguiría 100% por GAS aunque se prenda mos_provprod_directo.
  // Helper común: ejecuta la RPC `fn` con {p:params}, valida ok+array+frescura, devuelve r.data o null→GAS.
  async function _getListaDirectaMOS(fn, params, etiqueta) {
    const r = await _sbRpcMOS(fn, { p: params || {} });   // RPCs 94 reciben un único `p jsonb`
    if (r == null) return null;                            // sin token → GAS
    if (!r.ok || !Array.isArray(r.data)) return null;      // backend dijo no / shape inesperado → GAS
    if (r._fresh !== true) {                               // sombra stale → no servir datos viejos → GAS
      try { console.warn('[MOS ' + etiqueta + ' directo] sombra STALE (_fresh=false, heartbeat=' + r._heartbeat + ') → fallback a GAS'); } catch (_) {}
      return null;
    }
    return r.data;   // array camelCase == d.data de GAS
  }
  // getProveedores → mos.proveedores_lista (filtros estado/q, paridad getProveedoresMaster).
  async function _getProveedoresDirecto(params)        { return _getListaDirectaMOS('proveedores_lista',        params, 'proveedores'); }
  // getPedidos → mos.pedidos_proveedor_lista (filtros idProveedor/estado, paridad getPedidosProveedor).
  async function _getPedidosDirecto(params)            { return _getListaDirectaMOS('pedidos_proveedor_lista',  params, 'pedidos'); }
  // getPagos → mos.pagos_proveedor_lista (filtros idProveedor/estado, paridad getPagosProveedor).
  async function _getPagosDirecto(params)              { return _getListaDirectaMOS('pagos_proveedor_lista',    params, 'pagos'); }
  // getProveedorProductos → mos.proveedor_producto_lista (EXIGE idProveedor + solo activas, paridad GAS).
  async function _getProveedorProductosDirecto(params) { return _getListaDirectaMOS('proveedor_producto_lista', params, 'provprod'); }
  // getJornadas → mos.jornadas_lista (filtro fecha YYYY-MM-DD, paridad getJornadas).
  async function _getJornadasDirecto(params)           { return _getListaDirectaMOS('jornadas_lista',           params, 'jornadas'); }

  // ════════════════════════════════════════════════════════════════════
  // [FASE 2 · LOTE CATÁLOGO] ESCRITURA DIRECTA del catálogo maestro (navegador→PostgREST).
  // Réplica del dispatcher de WH (warehouseMos/js/api.js `_postDirecto`) adaptada a MOS.
  //
  // ⚠️ INERTE POR DEFECTO (triple candado, igual que el SQL 78/79):
  //   1) flag de cliente `mos_catalogo_directo` OFF (gate _mosCatalogoDirecto, ya existe);
  //   2) sin token (Edge `mint-mos` caída) → _sbRpcMOSWrite devuelve null → fallback GAS;
  //   3) kill-switch server-side mos.config.MOS_CATALOGO_DIRECTO='0' → la RPC responde
  //      {ok:false,error:'MOS_CATALOGO_DIRECTO_OFF'} → tratamos como *_OFF → fallback GAS.
  //   Con CUALQUIERA de los tres en OFF, MOS escribe EXACTAMENTE como hoy (100% por GAS).
  //
  // CONTRATO de _postDirectoMOS(action, params):
  //   · devuelve OBJETO (la `data` YA DESEMPAQUETADA) → ÉXITO directo. El caller lo
  //     retorna tal cual, idéntico a lo que devuelve `_fetch('POST')` (que también
  //     desempaqueta d.data; ver memoria architecture_mos_api_shape).
  //   · devuelve null → "caé a GAS" (flag OFF / sin token / acción no cableada /
  //     RPC respondió *_OFF o APP_NO_AUTORIZADA → NO commiteó → GAS es SEGURO).
  //   · LANZA Error → o bien un RECHAZO de negocio (la RPC validó y NO commiteó: misma
  //     validación que haría GAS → propagamos el error al UI, igual que _fetch lanza
  //     d.error) o bien un TIMEOUT/red tras posible commit. En AMBOS casos el caller
  //     PROPAGA el error y NUNCA reintenta en GAS (MOS no tiene cola de writes) → así un
  //     timeout-tras-commit JAMÁS duplica (la RPC pudo escribir; reintentar en GAS, que
  //     no comparte el estado de Supabase, crearía un 2do producto/precio). Anti-duplicado
  //     cross-backend cubierto: solo el camino "no commiteó" (null) cae a GAS.
  // ════════════════════════════════════════════════════════════════════

  // RPC de ESCRITURA directa a PostgREST (esquema mos). A diferencia de _sbRpcMOS (lectura),
  // ETIQUETA el error HTTP: un 4xx definitivo (≠408/429) es PERMANENTE (la función PL/pgSQL
  // corre en 1 tx que hace ROLLBACK ante error → NO commiteó → seguro descartar/caer a GAS);
  // un 5xx/408/429/timeout es TRANSITORIO y PUDO commitear → no se marca permanente.
  // Sin token (Edge caída) → null ("caé a GAS"), nunca lanza por falta de token.
  async function _sbRpcMOSWrite(fn, args) {
    const token = await _mintTokenMOS();
    if (!token) return null;
    const res = await _sbFetchTimeout(`${_SB_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token,
        'Accept-Profile': 'mos', 'Content-Profile': 'mos', 'Content-Type': 'application/json'
      },
      body: JSON.stringify(args || {})
    }, 15000);
    if (!res.ok) {
      const e = new Error('rpc directo HTTP ' + res.status);
      e.status = res.status;
      e.permanente = (res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429);
      throw e;
    }
    return res.json();
  }

  // Normaliza la respuesta de una RPC de escritura {ok, data, error, dedup?} al CONTRATO de _postDirectoMOS:
  //   ok:false con error *_OFF / APP_NO_AUTORIZADA      → null (kill-switch/sin claim ⇒ caé a GAS, no commiteó)
  //   ok:false con cualquier otro error (negocio/valid) → LANZA Error(error) (= _fetch lanza d.error; no commiteó)
  //   ok:true                                            → devuelve out.data (desempaquetado, shape == GAS) o {} si falta
  // `out == null` (sin token) ya lo maneja el caller ANTES de llamar acá.
  // ⚠️ El *_OFF se matchea por SUFIJO (cualquier MOS_<X>_DIRECTO_OFF), no por la clave literal del catálogo:
  //   cada lote tiene su propio kill-switch server-side (MOS_CATALOGO_DIRECTO_OFF, MOS_PROVEEDORES_DIRECTO_OFF,
  //   MOS_GASTOS_DIRECTO_OFF, MOS_JORNADAS_DIRECTO_OFF, MOS_LIQDIA_DIRECTO_OFF, MOS_PAGOS_JORNAL_DIRECTO_OFF, …).
  //   Con el flag de CLIENTE ON pero el server-side en '0', la RPC responde su *_OFF → debe caer a GAS (no lanzar),
  //   honrando el contrato "kill-switch server OFF → front cae a GAS" para TODOS los lotes por igual.
  function _desempacarCatalogo(out) {
    if (!out || out.ok === false) {
      const err = (out && out.error) || 'rpc directo sin respuesta';
      // *_OFF (kill-switch server-side, cualquier lote) o claim no autorizado → la RPC NO escribió → caé a GAS.
      if (/_OFF$/.test(err) || err === 'APP_NO_AUTORIZADA') return null;
      throw new Error(err);   // rechazo de negocio (misma validación que GAS) → propagar al UI
    }
    return (out.data != null && typeof out.data === 'object') ? out.data : {};
  }

  // Dispatcher de ESCRITURA: mapea una acción de catálogo → su RPC mos.*; envuelve la respuesta
  // al SHAPE (data desempaquetada) que devuelve la acción GAS correspondiente. Devuelve la data
  // (éxito), null (caé a GAS), o lanza (rechazo de negocio / timeout — el caller NO va a GAS).
  // Cada `p:{...}` mapea payload-frontend (camelCase) → args jsonb de la RPC (la RPC ya re-mapea
  // a snake_case internamente). ids/codigoBarra van como String() (regla: nunca número en el cruce).
  // Resuelve el usuario igual que GAS: explícito > window.__MOS_AUDIT.usuario (auto-inyectado por _fetch) > ''.
  // El directo NO pasa por _fetch (que inyecta _audit), así que resolvemos el usuario acá para que historial_precios
  // quede con el MISMO autor que por GAS (paridad de auditoría). Nunca undefined (la RPC lo trata con coalesce '').
  function _mosUsuario(p) {
    if (p && p.usuario != null && String(p.usuario) !== '') return String(p.usuario);
    try { return (window.__MOS_AUDIT && window.__MOS_AUDIT.usuario) ? String(window.__MOS_AUDIT.usuario) : ''; }
    catch (_) { return ''; }
  }

  // Resuelve un local_id ESTABLE por GESTO para las RPCs idempotentes (proveedor/pedido/pago/prov-prod).
  // CRÍTICO en PAGO (dinero): la RPC lo EXIGE y dedupea por él; un reintento del mismo gesto NO debe duplicar.
  //   1) si el front ya mandó localId → se respeta tal cual (gesto identificado por la PWA);
  //   2) si no, se GENERA uno y se ESTAMPA de vuelta sobre el MISMO objeto params (p.localId). Así, si el caller
  //      reintenta con el MISMO objeto (p.ej. un await que reentra), reusa el id → idempotente. Como `post()`
  //      recibe el objeto por referencia desde app.js, el id sobrevive a un reintento del mismo gesto.
  // Un doble-tap genera DOS objetos params distintos → dos local_id → la dedup dura recae en la RPC (que para
  // pago dedupea por monto+gesto vía índice único de local_id); aquí garantizamos al menos el caso reintento.
  // Formato: prefijo + uuid (o fallback time+random iOS-safe si crypto.randomUUID no existe en Safari viejo).
  function _mosLocalId(p, prefijo) {
    if (p && p.localId != null && String(p.localId) !== '') return String(p.localId);
    var uuid;
    try {
      uuid = (typeof crypto !== 'undefined' && crypto.randomUUID) ? crypto.randomUUID() : null;
    } catch (_) { uuid = null; }
    if (!uuid) uuid = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
    var lid = (prefijo || 'MOS') + '_' + uuid;
    try { if (p && typeof p === 'object') p.localId = lid; } catch (_) {}
    return lid;
  }

  async function _postDirectoMOS(action, params) {
    const p = params || {};

    if (action === 'crearProducto') {
      // mos.crear_producto(p): valida desc/precio, ids atómicos (secuencia), dedup por PK/codigoBarra.
      // Idempotencia: si el front manda idProducto/skuBase (de una 1ra respuesta) un reintento dedupea por PK.
      // Si NO los manda (alta nueva normal), la RPC los genera; el modal cierra optimista ANTES del await →
      // no hay re-submit por UI. (La cola offline-directo de writes queda para una tanda futura.)
      const out = await _sbRpcMOSWrite('crear_producto', { p: {
        descripcion: p.descripcion, precioVenta: p.precioVenta, precioCosto: p.precioCosto,
        idProducto: p.idProducto != null ? String(p.idProducto) : undefined,
        skuBase: p.skuBase != null ? String(p.skuBase) : undefined,
        codigoBarra: p.codigoBarra != null ? String(p.codigoBarra) : undefined,
        marca: p.marca, idCategoria: p.idCategoria, unidad: p.unidad, Unidad_Medida: p.Unidad_Medida,
        Cod_Tributo: p.Cod_Tributo, IGV_Porcentaje: p.IGV_Porcentaje, Cod_SUNAT: p.Cod_SUNAT, Tipo_IGV: p.Tipo_IGV,
        esEnvasable: p.esEnvasable,
        codigoProductoBase: p.codigoProductoBase != null ? String(p.codigoProductoBase) : undefined,
        factorConversion: p.factorConversion, factorConversionBase: p.factorConversionBase,
        mermaEsperadaPct: p.mermaEsperadaPct, stockMinimo: p.stockMinimo, stockMaximo: p.stockMaximo,
        zona: p.zona, modoVenta: p.modoVenta, margenPct: p.margenPct, precioTope: p.precioTope,
        usuario: _mosUsuario(p)
      } });
      if (out == null) return null;                 // sin token → GAS
      // GAS devuelve data:{idProducto, skuBase, secuencia}. La RPC devuelve {idProducto, skuBase, tipo?}.
      // El front solo lee r.idProducto (app.js:17625) → con idProducto/skuBase basta. `secuencia` no se consume.
      return _desempacarCatalogo(out);
    }

    if (action === 'actualizarProducto') {
      // mos.actualizar_producto(p): patch parcial, guard de no-vaciables, UPDATE atómico + propagación de precio.
      // Idempotente natural (UPDATE al mismo valor = no-op). El front manda solo los campos a tocar → reenviamos
      // SOLO las claves presentes (mandar undefined NO crea la clave; la RPC usa `p ? 'campo'` para distinguir
      // "presente" de "ausente", igual que GAS distingue params[campo]!==undefined). _noPropagar/_permitirVaciar
      // se reenvían si el front los manda. ids/codigoBarra a String.
      // Solo se reenvían las claves PRESENTES Y no-undefined (paridad EXACTA con GAS, que filtra
      // por params[campo]!==undefined). Así un `idProducto: undefined` (que el modal NO manda en edición,
      // pero el create sí) jamás se inyecta como clave en el patch. ids/codigoBarra como String.
      const a = {};
      ['idProducto','codigoBarra','skuBase','codigoProductoBase'].forEach(k => {
        if (k in p && p[k] !== undefined) a[k] = (p[k] != null ? String(p[k]) : '');
      });
      ['descripcion','marca','idCategoria','unidad','Unidad_Medida','precioVenta','precioCosto',
       'Cod_Tributo','IGV_Porcentaje','Cod_SUNAT','Tipo_IGV','estado','esEnvasable',
       'factorConversion','factorConversionBase','mermaEsperadaPct','stockMinimo','stockMaximo',
       'zona','modoVenta','margenPct','precioTope','motivoPrecio'].forEach(k => {
        if (k in p && p[k] !== undefined) a[k] = p[k];
      });
      if ('_noPropagar' in p && p._noPropagar !== undefined) a._noPropagar = p._noPropagar;
      // usuario: explícito o desde __MOS_AUDIT (paridad de autor en historial_precios cuando cambia el precio).
      a.usuario = _mosUsuario(p);
      const out = await _sbRpcMOSWrite('actualizar_producto', { p: a });
      if (out == null) return null;
      // GAS y RPC devuelven IDÉNTICO: data:{presentacionesActualizadas}.
      return _desempacarCatalogo(out);
    }

    if (action === 'publicarPrecio') {
      // mos.publicar_precio(p): persiste precio (delega en actualizar_producto → propaga + historial).
      // Idempotente natural (mismo precio = no-op). SHAPE: GAS devuelve data:{precioNuevo, alertaGenerada,
      // etiquetas}; la RPC devuelve data:{precioNuevo, presentacionesActualizadas} (la impresión de
      // etiquetas/membretes es side-effect de GAS/Edge, no de la RPC). El front (app.js:17678) NO lee la
      // respuesta de publicarPrecio (solo await + toast) → el mismatch alertaGenerada/etiquetas es INOCUO.
      // Igual normalizamos alertaGenerada (paridad defensiva) por si un consumidor futuro lo lee.
      const out = await _sbRpcMOSWrite('publicar_precio', { p: {
        precioNuevo: p.precioNuevo,
        idProducto: p.idProducto != null ? String(p.idProducto) : undefined,
        codigoBarra: p.codigoBarra != null ? String(p.codigoBarra) : undefined,
        skuBase: p.skuBase != null ? String(p.skuBase) : undefined,
        motivo: p.motivo, usuario: _mosUsuario(p)
      } });
      if (out == null) return null;
      const data = _desempacarCatalogo(out);
      if (data && data.alertaGenerada === undefined) {
        data.alertaGenerada = (p.imprimirMembretes === 'true' || p.imprimirMembretes === true);
      }
      return data;   // {precioNuevo, presentacionesActualizadas, alertaGenerada} — el front no lo consume
    }

    if (action === 'crearEquivalencia') {
      // mos.crear_equivalencia(p): requiere skuBase+codigoBarra; nace activa; dedup por id_equiv y por (sku,cod) activa.
      const out = await _sbRpcMOSWrite('crear_equivalencia', { p: {
        idEquiv: p.idEquiv != null ? String(p.idEquiv) : undefined,
        skuBase: p.skuBase != null ? String(p.skuBase) : undefined,
        codigoBarra: p.codigoBarra != null ? String(p.codigoBarra) : undefined,
        descripcion: p.descripcion
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);   // data:{idEquiv} — idéntico a GAS
    }

    if (action === 'actualizarEquivalencia') {
      // mos.actualizar_equivalencia(p): patch codigoBarra/descripcion/activo por PK idEquiv. UPDATE atómico idempotente.
      const a = { idEquiv: p.idEquiv != null ? String(p.idEquiv) : undefined };
      if ('codigoBarra' in p && p.codigoBarra !== undefined) a.codigoBarra = (p.codigoBarra != null ? String(p.codigoBarra) : '');
      if ('descripcion' in p && p.descripcion !== undefined) a.descripcion = p.descripcion;
      if ('activo' in p && p.activo !== undefined)           a.activo = p.activo;
      const out = await _sbRpcMOSWrite('actualizar_equivalencia', { p: a });
      if (out == null) return null;
      // GAS devuelve {ok:true} (sin data). _fetch('POST') desempaqueta a d.data = undefined → el front no lee nada.
      // _desempacarCatalogo devuelve {} (data ausente) → equivalente inocuo (el front solo await; app.js:17514).
      return _desempacarCatalogo(out);
    }

    // ════════════════════════════════════════════════════════════════════
    // [FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS] — 6 acciones de negocio.
    // Cada una mapea payload-frontend (camelCase) → args jsonb de la RPC mos.* (la RPC re-mapea a snake_case),
    // y normaliza la respuesta {ok,data,error,dedup?} con _desempacarCatalogo (que ya trata *_OFF/APP_NO_AUTORIZADA
    // como null→GAS y el resto como rechazo de negocio→throw). ids como String (regla: nunca número en el cruce).
    // ════════════════════════════════════════════════════════════════════

    if (action === 'crearProveedor') {
      // GAS crearProveedorMaster → data:{idProveedor}. RPC mos.crear_proveedor → data:{idProveedor} (+dedup, no leído).
      // localId estable (idempotencia de gesto; aquí no es dinero, pero evita doble alta en reintento).
      const out = await _sbRpcMOSWrite('crear_proveedor', { p: {
        localId: _mosLocalId(p, 'PROV'),
        idProveedor: p.idProveedor != null ? String(p.idProveedor) : undefined,
        nombre: p.nombre, ruc: p.ruc, imagen: p.imagen, telefono: p.telefono,
        banco: p.banco, numeroCuenta: p.numeroCuenta, cci: p.cci, email: p.email,
        diaPedido: p.diaPedido, diaPago: p.diaPago, diaEntrega: p.diaEntrega,
        formaPago: p.formaPago, plazoCredito: p.plazoCredito,
        responsable: p.responsable, categoriaProducto: p.categoriaProducto
      } });
      if (out == null) return null;            // sin token → GAS
      return _desempacarCatalogo(out);         // {idProveedor} — el front lee r.data.idProveedor del refresh, no de esto
    }

    if (action === 'actualizarProveedor') {
      // GAS actualizarProveedorMaster → {ok:true} (sin data); _fetch desempaqueta a undefined; el front no lee nada.
      // RPC mos.actualizar_proveedor → {ok:true}. Patch PARCIAL: reenviar SOLO las claves presentes (paridad GAS,
      // que filtra por params[c]!==undefined; la RPC distingue presente/ausente con `p ? 'clave'`).
      const a = { idProveedor: p.idProveedor != null ? String(p.idProveedor) : undefined };
      ['nombre','ruc','telefono','banco','numeroCuenta','cci','email',
       'diaPedido','diaPago','diaEntrega','formaPago','plazoCredito',
       'responsable','categoriaProducto','estado'].forEach(k => {
        if (k in p && p[k] !== undefined) a[k] = p[k];
      });
      const out = await _sbRpcMOSWrite('actualizar_proveedor', { p: a });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {} (sin data) — inocuo, el front solo await
    }

    if (action === 'crearPedido') {
      // GAS crearPedidoProveedor → data:{idPedido}. RPC mos.crear_pedido_proveedor → data:{idPedido}. items=array jsonb.
      // localId estable (idempotencia de gesto: el modal cierra optimista; un reintento no crea 2 pedidos BORRADOR).
      const out = await _sbRpcMOSWrite('crear_pedido_proveedor', { p: {
        localId: _mosLocalId(p, 'PED'),
        idPedido: p.idPedido != null ? String(p.idPedido) : undefined,
        idProveedor: p.idProveedor != null ? String(p.idProveedor) : undefined,
        items: Array.isArray(p.items) ? p.items : [],
        montoEstimado: p.montoEstimado,
        fechaEstimada: p.fechaEstimada, usuario: p.usuario, notas: p.notas
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {idPedido} — el front no lee la respuesta (solo toast), pero queda paritario
    }

    if (action === 'actualizarPedido') {
      // ⚠️ Sin equivalente en GAS hoy (no hay case 'actualizarPedido' en el router) → con el flag OFF esta acción
      // SIEMPRE cae a GAS y el router responde "acción no reconocida" (= comportamiento de hoy, no la usa nadie).
      // Cableada acá FORWARD-LOOKING para cuando la PWA mueva estado/items (la RPC ya existe). RPC → {ok:true}.
      const a = { idPedido: p.idPedido != null ? String(p.idPedido) : undefined };
      if ('estado' in p && p.estado !== undefined)               a.estado = p.estado;
      if ('items' in p && Array.isArray(p.items))                a.items = p.items;
      if ('montoEstimado' in p && p.montoEstimado !== undefined) a.montoEstimado = p.montoEstimado;
      if ('notas' in p && p.notas !== undefined)                 a.notas = p.notas;
      if ('fechaEstimada' in p && p.fechaEstimada !== undefined) a.fechaEstimada = p.fechaEstimada;
      const out = await _sbRpcMOSWrite('actualizar_pedido_proveedor', { p: a });
      if (out == null) return null;
      return _desempacarCatalogo(out);
    }

    if (action === 'registrarPago') {
      // ⚠️ DINERO ⚠️ GAS registrarPago → data:{idPago}. RPC mos.registrar_pago_proveedor → data:{idPago}.
      // localId OBLIGATORIO (la RPC RECHAZA sin él) y ESTABLE: si el caller reintenta el MISMO objeto params,
      // _mosLocalId reusa p.localId → la RPC dedupea por local_id → NUNCA un 2do pago. Anti-duplicado: un timeout
      // tras posible commit se PROPAGA (el caller NO reintenta en GAS), así no se crea un pago en el otro backend.
      const out = await _sbRpcMOSWrite('registrar_pago_proveedor', { p: {
        localId: _mosLocalId(p, 'PAG'),
        idPago: p.idPago != null ? String(p.idPago) : undefined,
        idProveedor: p.idProveedor != null ? String(p.idProveedor) : undefined,
        monto: p.monto, fecha: p.fecha, numeroFactura: p.numeroFactura,
        estado: p.estado, observacion: p.observacion,
        registradoPor: p.registradoPor != null ? p.registradoPor : _mosUsuario(p)
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {idPago} — el front no lee la respuesta (toast optimista + refresh getPagos)
    }

    if (action === 'agregarProductoProveedor' || action === 'actualizarProductoProveedor') {
      // Ambas GAS (agregarProductoProveedor → data:{idPP}; actualizarProductoProveedor → {ok:true}) → UNA sola RPC
      // mos.upsert_proveedor_producto (insert si no hay idPP/sku existente; update si sí). RPC → data:{idPP,accion}.
      // El front lee idPP en el alta (app.js refresca por getProveedorProductos igual) y NO lee nada en la edición →
      // los campos extra (accion) son inocuos. Patch parcial: reenviar SOLO claves presentes (paridad GAS).
      // localId estable solo aporta en el alta (la RPC lo usa para dedup de inserción; en update con idPP es no-op).
      const a = {
        localId: _mosLocalId(p, 'PP'),
        idPP: p.idPP != null ? String(p.idPP) : undefined,
        idProveedor: p.idProveedor != null ? String(p.idProveedor) : undefined
      };
      if ('skuBase' in p && p.skuBase !== undefined)                 a.skuBase = String(p.skuBase);
      if ('codigoBarra' in p && p.codigoBarra !== undefined)         a.codigoBarra = (p.codigoBarra != null ? String(p.codigoBarra) : '');
      if ('descripcion' in p && p.descripcion !== undefined)         a.descripcion = p.descripcion;
      if ('precioReferencia' in p && p.precioReferencia !== undefined) a.precioReferencia = p.precioReferencia;
      if ('minimoCompra' in p && p.minimoCompra !== undefined)       a.minimoCompra = p.minimoCompra;
      if ('diasEntrega' in p && p.diasEntrega !== undefined)         a.diasEntrega = p.diasEntrega;
      if ('activa' in p && p.activa !== undefined)                   a.activa = p.activa;
      if ('notas' in p && p.notas !== undefined)                     a.notas = p.notas;
      if ('unidadesPorBulto' in p && p.unidadesPorBulto !== undefined) a.unidadesPorBulto = p.unidadesPorBulto;
      const out = await _sbRpcMOSWrite('upsert_proveedor_producto', { p: a });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {idPP, accion} — el front lee idPP (alta) o nada (edición)
    }

    // ════════════════════════════════════════════════════════════════════
    // [FASE 2 · LOTE GASTOS (DINERO) + BAJO-RIESGO] — 4 acciones que el frontend MOS llama hoy.
    //   · registrarGasto / eliminarGasto → mos.crear_gasto / mos.eliminar_gasto   (flag mos_gastos_directo, DINERO)
    //   · crearEvaluacion                → mos.crear_evaluacion                    (flag mos_eval_directo)
    //   · setHorarioApp                  → mos.actualizar_horario_app              (flag mos_horario_directo)
    // Respuesta {ok,data,error,dedup?} → _desempacarCatalogo (trata *_OFF/APP_NO_AUTORIZADA como null→GAS,
    // y cualquier otro error como rechazo de negocio→throw). ids como String (regla: nunca número en el cruce).
    // local_id ESTABLE en los CREAR (gasto/evaluación) → la RPC dedupea por él (anti-doble-registro en reintento).
    // ════════════════════════════════════════════════════════════════════

    if (action === 'registrarGasto') {
      // ⚠️ DINERO ⚠️ GAS registrarGasto → data:{idGasto} (appendRow CRUDO, SIN dedup → doble-tap duplica gasto).
      // RPC mos.crear_gasto → data:{idGasto} con idempotencia por local_id (gesto) + PK. localId ESTABLE: si el
      // caller reintenta el MISMO objeto params, _mosLocalId reusa p.localId → NUNCA un 2do gasto. Un timeout
      // tras posible commit se PROPAGA (el caller NO va a GAS) → no se crea un gasto en el otro backend.
      // monto va como viene (la RPC lo parsea con _numn → numeric EXACTO en centavos, no float). El front no lee
      // la respuesta (solo await + toast + finCargar) → {idGasto} es paritario y suficiente.
      const out = await _sbRpcMOSWrite('crear_gasto', { p: {
        localId: _mosLocalId(p, 'GAS'),
        idGasto: p.idGasto != null ? String(p.idGasto) : undefined,
        fecha: p.fecha, categoria: p.categoria, tipo: p.tipo,
        descripcion: p.descripcion, monto: p.monto,
        comprobante: p.comprobante,
        registradoPor: p.registradoPor != null ? p.registradoPor : _mosUsuario(p)
      } });
      if (out == null) return null;            // sin token → GAS
      return _desempacarCatalogo(out);         // {idGasto} — el front no lee la respuesta (toast + refresh)
    }

    if (action === 'eliminarGasto') {
      // ⚠️ DINERO ⚠️ GAS eliminarGasto → {ok:true} (sin data); _fetch desempaqueta a undefined; el front no lee nada.
      // RPC mos.eliminar_gasto → {ok:true,eliminado} (DELETE atómico por PK, idempotente: borrar 2 veces no falla).
      // _desempacarCatalogo devuelve {} (data ausente) → equivalente inocuo a undefined (el front solo await + refresh).
      const out = await _sbRpcMOSWrite('eliminar_gasto', { p: {
        idGasto: p.idGasto != null ? String(p.idGasto) : undefined
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {} — el front no lee la respuesta
    }

    if (action === 'crearEvaluacion') {
      // GAS crearEvaluacion → data:{idEval, bonificacion, sancion, ajusteTocado}. RPC mos.crear_evaluacion →
      // data:{idEval} (SOLO el appendRow crudo; idempotente por local_id + PK). El front (app.js) llama esto
      // FIRE-AND-FORGET y NO lee la respuesta (.then ignora el payload, refresca por getPersonalDiaFast) → el
      // mismatch de campos extra (bonificacion/sancion/ajusteTocado) es INOCUO para el consumidor actual.
      // ⚠️ DIVERGENCIA CONOCIDA Y ACEPTADA (documentada en el SQL 82): GAS además corre los hooks de
      //    materialización _liqDiaRecomputar/_liqDiaSetBonSan que tocan LIQUIDACIONES_DIA (DINERO). La RPC NO
      //    los corre (los orquestadores quedan en GAS por diseño). ⇒ NO activar mos_eval_directo cuando la
      //    evaluación lleva bonificación/sanción/ajuste hasta migrar también esos hooks. Con el flag OFF
      //    (default) esto es 100% GAS (hooks incluidos), idéntico a hoy.
      // localId ESTABLE → anti-doble-fila en reintento del mismo gesto (GAS no dedupea: doble-tap = 2 filas).
      const out = await _sbRpcMOSWrite('crear_evaluacion', { p: {
        localId: _mosLocalId(p, 'EV'),
        idEval: p.idEval != null ? String(p.idEval) : undefined,
        idPersonal: p.idPersonal != null ? String(p.idPersonal) : undefined,
        rol: p.rol, fecha: p.fecha, hora: p.hora,
        limpiezaPct: p.limpiezaPct, limpiezaProfPct: p.limpiezaProfPct,
        controlChecks: p.controlChecks, comentario: p.comentario,
        evaluadoPor: p.evaluadoPor != null ? p.evaluadoPor : _mosUsuario(p),
        aplicaComision: p.aplicaComision, aplicaBonoMeta: p.aplicaBonoMeta,
        sancion: p.sancion, sancionMotivo: p.sancionMotivo,
        bonificacion: p.bonificacion, bonificacionMotivo: p.bonificacionMotivo
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {idEval} — el front no lee la respuesta (fire-and-forget)
    }

    if (action === 'setHorarioApp') {
      // GAS setHorarioApp → data:{app, horario, admins_libres}. RPC mos.actualizar_horario_app →
      // data:{app, horario, admins_libres} (UPSERT por PK natural `app`; sin local_id — la clave de negocio
      // ES la app). El front manda `horario` (shape legacy {lun..dom}) + `admins_libres` (snake) + actualizadoPor;
      // la RPC acepta ese shape (cae a `horario` si no hay `dias`). El front NO lee la respuesta (then→beep ok,
      // refresca por cache local optimista) → shape paritario.
      // ⚠️ SIDE-EFFECTS GAS-ONLY (documentado en SQL 82): GAS (a) reescribe la HOJA que WH/ME usan para la
      //    ENFORCEMENT de horario (resolverHorarioPersonal lee la hoja, NO Supabase), (b) dispara push a admins,
      //    (c) invalida la cache de horario de WH. La RPC NO los hace (orquestación queda en GAS). ⇒ CAVEAT
      //    CERRADO en _postMOS: tras el directo OK se dispara GAS setHorarioApp fire-and-forget → hoja+push+cache
      //    quedan al día (sync hoja→Supabase reconcilia, upsert onConflict=app, sin duplicar). Con el flag OFF
      //    (default) es 100% GAS, idéntico.
      // NOTA: el front no manda claveAdmin → la rama de auth remoto de GAS no aplica a esta llamada (paridad).
      const a = { app: p.app != null ? String(p.app) : undefined };
      if ('dias' in p && p.dias !== undefined)             a.dias = p.dias;
      if ('horario' in p && p.horario !== undefined)       a.horario = p.horario;
      if ('admins_libres' in p && p.admins_libres !== undefined) a.admins_libres = p.admins_libres;
      a.actualizadoPor = (p.actualizadoPor != null && String(p.actualizadoPor) !== '') ? p.actualizadoPor : _mosUsuario(p);
      const out = await _sbRpcMOSWrite('actualizar_horario_app', { p: a });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {app, horario, admins_libres} — el front no lee la respuesta
    }

    // ════════════════════════════════════════════════════════════════════
    // [FASE 2 · LOTE JORNALES/LIQUIDACIONES] — acciones que el frontend MOS llama hoy:
    //   · registrarJornada            → mos.registrar_jornada        (flag mos_jornadas_directo, DINERO jornal)
    //   · vetarLiquidacionDia         → mos.vetar_liquidacion_dia    (flag mos_liqdia_directo, DINERO)
    //   · desvetarLiquidacionDia      → mos.desvetar_liquidacion_dia (flag mos_liqdia_directo, DINERO)
    // + 2 FORWARD-LOOKING (el front NO las llama hoy — finVetarPago/finRehabilitarPago usan vetar/desvetar —
    //   pero la RPC y el case del router GAS existen; cableadas inertes por completitud, gate mos_jornadas_directo):
    //   · eliminarJornada             → mos.eliminar_jornada         (VETO tombstone)
    //   · rehabilitarJornada          → mos.rehabilitar_jornada
    // ⚠️ recomputarLiquidacionDia / marcarPagos / anularPago NO se cablean (shape/seguridad incompatibles) — ver
    //    el bloque de gates arriba y el REPORTE. Con su gate ausente del mapa van 100% por GAS, idéntico a hoy.
    // Respuesta {ok,data,error,dedup?} → _desempacarCatalogo (trata *_OFF/APP_NO_AUTORIZADA como null→GAS, y
    // cualquier otro error como rechazo de negocio→throw, igual que _fetch lanza d.error). ids como String.
    // ════════════════════════════════════════════════════════════════════

    if (action === 'registrarJornada') {
      // ⚠️ DINERO (jornal) ⚠️ GAS registrarJornada → data:{idJornada} (appendRow CRUDO, SIN dedup → doble-tap
      // duplica jornada). RPC mos.registrar_jornada → data:{idJornada} con idempotencia por local_id (gesto) + PK.
      // localId ESTABLE: si el caller reintenta el MISMO objeto params, _mosLocalId reusa p.localId → la RPC
      // dedupea por local_id → NUNCA una 2da jornada. Un timeout tras posible commit se PROPAGA (el caller NO va
      // a GAS) → no se crea una jornada en el otro backend. montoJornal va como viene (la RPC lo parsea con _numn
      // → numeric EXACTO, no float). El front NO lee la respuesta (await + toast + finCargar) → {idJornada} basta.
      // Validación paridad GAS: la RPC exige nombre + montoJornal>0 (mismo rechazo que GAS) → throw → UI, no GAS.
      const out = await _sbRpcMOSWrite('registrar_jornada', { p: {
        localId: _mosLocalId(p, 'JOR'),
        idJornada: p.idJornada != null ? String(p.idJornada) : undefined,
        nombre: p.nombre, montoJornal: p.montoJornal, fecha: p.fecha,
        idPersonal: p.idPersonal != null ? String(p.idPersonal) : undefined,
        rol: p.rol, zona: p.zona, observacion: p.observacion,
        appOrigen: p.appOrigen,
        registradoPor: p.registradoPor != null ? p.registradoPor : _mosUsuario(p)
      } });
      if (out == null) return null;            // sin token → GAS
      return _desempacarCatalogo(out);         // {idJornada} — el front no lee la respuesta
    }

    if (action === 'eliminarJornada') {
      // ⚠️ FORWARD-LOOKING (el front NO llama esta acción hoy; finVetarPago usa vetarLiquidacionDia). Con el gate
      // OFF (default) va a GAS igual. GAS eliminarJornada → data:{vetoTs, idJornada} (VETO tombstone, NO borra).
      // RPC mos.eliminar_jornada → data:{vetoTs, idJornada}. UPDATE atómico idempotente (re-vetar re-sella ts).
      const out = await _sbRpcMOSWrite('eliminar_jornada', { p: {
        idJornada: p.idJornada != null ? String(p.idJornada) : undefined,
        actor: p.actor,
        registradoPor: p.registradoPor != null ? p.registradoPor : _mosUsuario(p)
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {vetoTs, idJornada}
    }

    if (action === 'rehabilitarJornada') {
      // ⚠️ FORWARD-LOOKING (el front NO llama esta acción hoy; finRehabilitarPago usa desvetarLiquidacionDia).
      // GAS rehabilitarJornada → data:{rehabTs, idJornada, monto}. RPC mos.rehabilitar_jornada → data:{rehabTs,
      // idJornada, monto}. Solo si fuente='ELIMINADA' (mismo rechazo 'La jornada no está vetada' → throw → UI).
      const out = await _sbRpcMOSWrite('rehabilitar_jornada', { p: {
        idJornada: p.idJornada != null ? String(p.idJornada) : undefined,
        actor: p.actor,
        registradoPor: p.registradoPor != null ? p.registradoPor : _mosUsuario(p),
        monto: p.monto, montoDefault: p.montoDefault
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {rehabTs, idJornada, monto}
    }

    if (action === 'vetarLiquidacionDia') {
      // ⚠️ DINERO ⚠️ GAS vetarLiquidacionDia → {ok:true} (sin data); _fetch desempaqueta a undefined; el front
      // NO lee la respuesta (await resuelve = éxito; .catch lee e.message = YA_PAGADA/NO_ENCONTRADA). RPC
      // mos.vetar_liquidacion_dia → {ok:true,data:{idDia,estado}} en éxito; en rechazo de negocio devuelve
      // {ok:false,error:'YA_PAGADA'|'NO_ENCONTRADA'|'idPersonal y fecha requeridos'} → _desempacarCatalogo
      // LANZA Error(error) → e.message == el MISMO key que GAS → el front muestra el toast correcto. UPDATE
      // atómico condicional (no toca PAGADA) → idempotente, sin lost-update. El front manda `localId` (la RPC
      // lo IGNORA: el veto es idempotente por estado, no por gesto) → inocuo. No es alta → no _mosLocalId.
      const out = await _sbRpcMOSWrite('vetar_liquidacion_dia', { p: {
        idPersonal: p.idPersonal != null ? String(p.idPersonal) : undefined,
        fecha: p.fecha
      } });
      if (out == null) return null;            // sin token → GAS
      return _desempacarCatalogo(out);         // {idDia,estado} — el front no lee la data (solo éxito/throw)
    }

    if (action === 'desvetarLiquidacionDia') {
      // ⚠️ DINERO ⚠️ GAS desvetarLiquidacionDia → {ok:true} (sin data); el front NO lee la respuesta (await=éxito;
      // .catch lee e.message). RPC mos.desvetar_liquidacion_dia → {ok:true,data:{idDia,estado}} o rechazo
      // {ok:false,error:'NO_VETADA'|'NO_ENCONTRADA'|...} → _desempacarCatalogo LANZA con el MISMO error key.
      // VETADA→PENDIENTE atómico condicional (solo si VETADA) → idempotente. `localId` del front es inocuo.
      const out = await _sbRpcMOSWrite('desvetar_liquidacion_dia', { p: {
        idPersonal: p.idPersonal != null ? String(p.idPersonal) : undefined,
        fecha: p.fecha
      } });
      if (out == null) return null;
      return _desempacarCatalogo(out);         // {idDia,estado} — el front no lee la data
    }

    return null;   // acción no cableada → GAS
  }

  // Acciones enrutables por escritura directa, CADA UNA con su gate por-acción (default OFF).
  // El valor es la función-gate que decide si esa acción intenta el directo. Con el gate OFF (default)
  // _postMOS ni siquiera evalúa el directo para esa acción → va recto a GAS, idéntico a hoy.
  //   · catálogo (5)           → _mosCatalogoDirecto   (flag mos_catalogo_directo / maestro)
  //   · proveedores (crear/edit)→ _mosProveedoresDirecto (flag mos_proveedores_directo)
  //   · pedidos (crear/edit)    → _mosPedidosDirecto      (flag mos_pedidos_directo)
  //   · pagos (DINERO)          → _mosPagosDirecto        (flag mos_pagos_directo)
  //   · proveedor-producto      → _mosProvProdDirecto     (flag mos_provprod_directo)
  //   · gastos (crear/eliminar) → _mosGastosDirecto       (flag mos_gastos_directo, DINERO)
  //   · evaluaciones (crear)    → _mosEvalDirecto         (flag mos_eval_directo)
  //   · horarios (setHorarioApp)→ _mosHorarioDirecto      (flag mos_horario_directo)
  const _MOS_POST_DIRECTO = {
    crearProducto:              _mosCatalogoDirecto,
    actualizarProducto:         _mosCatalogoDirecto,
    publicarPrecio:             _mosCatalogoDirecto,
    crearEquivalencia:          _mosCatalogoDirecto,
    actualizarEquivalencia:     _mosCatalogoDirecto,
    crearProveedor:             _mosProveedoresDirecto,
    actualizarProveedor:        _mosProveedoresDirecto,
    crearPedido:                _mosPedidosDirecto,
    actualizarPedido:           _mosPedidosDirecto,
    registrarPago:              _mosPagosDirecto,
    agregarProductoProveedor:   _mosProvProdDirecto,
    actualizarProductoProveedor:_mosProvProdDirecto,
    registrarGasto:             _mosGastosDirecto,
    eliminarGasto:              _mosGastosDirecto,
    crearEvaluacion:            _mosEvalDirecto,
    setHorarioApp:              _mosHorarioDirecto,
    // [FASE 2 · LOTE JORNALES/LIQUIDACIONES] DINERO. Gates por-grupo (default OFF). marcarPagos/anularPago/
    // recomputarLiquidacionDia NO van en este mapa a propósito (shape/seguridad incompatibles) → siempre GAS.
    registrarJornada:           _mosJornadasDirecto,
    eliminarJornada:            _mosJornadasDirecto,   // forward-looking (el front no la llama hoy)
    rehabilitarJornada:         _mosJornadasDirecto,   // forward-looking (el front no la llama hoy)
    vetarLiquidacionDia:        _mosLiqdiaDirecto,
    desvetarLiquidacionDia:     _mosLiqdiaDirecto
  };

  // POST con escritura directa opcional. Con el gate de la acción OFF (default) es IDÉNTICO a hoy: ni
  // siquiera evalúa el directo → va recto a _fetch('POST') → GAS. Con el gate ON + token + RPC viva, escribe
  // directo; si el directo dice "no commiteó" (null) → GAS; si lanza (negocio/timeout) → PROPAGA (no GAS).
  async function _postMOS(action, p) {
    const gate = _MOS_POST_DIRECTO[action];
    if (gate && gate()) {
      // throws de _postDirectoMOS se PROPAGAN (negocio = mismo error que GAS; timeout = anti-duplicado).
      const d = await _postDirectoMOS(action, p);
      if (d != null) {
        // [CAVEAT-CLOSE HORARIOS] El directo escribe SOLO la sombra Supabase (mos.config_horarios_apps),
        // pero la ENFORCEMENT de horario en WH/ME (resolverHorarioPersonal/verificarHorario) lee la HOJA
        // GAS, NO Supabase. Además GAS dispara push a admins + invalida la cache de horario de WH. Para no
        // dejar la hoja desfasada (WH/ME aplicarían el horario VIEJO) ni perder el push/invalidación,
        // disparamos GAS setHorarioApp FIRE-AND-FORGET tras el directo OK. GAS reescribe la hoja (idempotente)
        // + push + invalida cache; el sync hoja→Supabase reconcilia (upsert onConflict=app, sin duplicar).
        // El UI ya resolvió con el directo (optimista); este ping es best-effort y NO bloquea ni revierte.
        if (action === 'setHorarioApp') {
          try { _fetch('POST', { action, ...p }).catch(function(){}); } catch (_) {}
        }
        return d;   // éxito directo (data desempaquetada == shape GAS)
      }
      // null → no commiteó (flag server OFF / sin token / no cableada) → GAS, seguro.
    }
    return _fetch('POST', { action, ...p });
  }

  return {
    getUrl,
    setUrl,
    isConfigured,
    get:  (action, p = {}) => {
      // [FASE 1 · PILOTO] getProductos → lectura directa Supabase con gate por-acción + frescura + fallback GAS.
      // Con el flag OFF (default) esto es IDÉNTICO a hoy: _conFallbackMOS NO entra al directo y va directo a GAS.
      if (action === 'getProductos') {
        return _conFallbackMOS(
          () => _getProductosDirecto(p),                 // directo: RPC + map a shape-hoja + filtros (null→GAS)
          () => _fetch('GET', { action, ...p }),         // gas: la llamada de SIEMPRE (devuelve d.data = array)
          _mosCatalogoDirecto                            // gate por-acción (default OFF)
        );
      }
      // [FASE 1] getFinanzasRango → lectura directa (RPC finanzas_rango) con gate por-acción + frescura + fallback GAS.
      // Flag OFF (default) ⇒ IDÉNTICO a hoy (va directo a GAS). Devuelve {serie,totales,desde,hasta} igual que GAS.
      if (action === 'getFinanzasRango') {
        return _conFallbackMOS(
          () => _getFinanzasRangoDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosFinanzasDirecto
        );
      }
      // [FASE 1] getHistorialPrecios → lectura directa (RPC historial_precios_lista). Flag OFF (default) ⇒ GAS.
      if (action === 'getHistorialPrecios') {
        return _conFallbackMOS(
          () => _getHistorialPreciosDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosHistorialDirecto
        );
      }
      // [FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS/PROVPROD/JORNADAS] read-paths directos (RPCs 94). Cada uno
      // gated por SU flag de módulo (mismo flag que ya gobierna la escritura directa del módulo) → al prender
      // el flip, lectura + escritura del módulo van directas A LA VEZ (cutover coherente, ver cabecera SQL 94).
      // Flag OFF (default, estado real) ⇒ _conFallbackMOS NO entra al directo y va recto a GAS = IDÉNTICO a hoy.
      if (action === 'getProveedores') {
        return _conFallbackMOS(
          () => _getProveedoresDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosProveedoresDirecto
        );
      }
      if (action === 'getPedidos') {
        return _conFallbackMOS(
          () => _getPedidosDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosPedidosDirecto
        );
      }
      if (action === 'getPagos') {
        return _conFallbackMOS(
          () => _getPagosDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosPagosDirecto
        );
      }
      if (action === 'getProveedorProductos') {
        return _conFallbackMOS(
          () => _getProveedorProductosDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosProvProdDirecto
        );
      }
      if (action === 'getJornadas') {
        return _conFallbackMOS(
          () => _getJornadasDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosJornadasDirecto
        );
      }
      return _fetch('GET',  { action, ...p });
    },
    // [FASE 2] post → escritura directa Supabase, gate POR-ACCIÓN (todos default OFF): 5 de catálogo
    // (mos_catalogo_directo) + proveedores/pedidos/pago/proveedor-producto (mos_*_directo). Con el gate de la
    // acción OFF ⇒ IDÉNTICO a hoy (va recto a GAS). El resto de acciones SIEMPRE por GAS.
    post: (action, p = {}) => _postMOS(action, p),
    getProductosNuevosWH: (p = {}) => _fetch('GET',  { action: 'getProductosNuevosWH', ...p }),
    lanzarProductoNuevo:  (p = {}) => _fetch('POST', { action: 'lanzarProductoNuevo',  ...p }),
    // Crea un PN manualmente desde MOS (admin/master). idGuia vacío → WH no
    // escribe en GUIA_DETALLE (no afecta stock ni guías). Solo encola en
    // PRODUCTO_NUEVO con estado PENDIENTE para revisión normal.
    crearPNManual:        (p = {}) => _fetch('POST', { action: 'forwardWHAction', whAction: 'registrarProductoNuevo', idGuia: '', ...p }),

    // ── [FASE 0B] Infraestructura de lectura directa Supabase — INERTE (flags OFF por
    //    defecto). Expuesta para que FASE 1 cablee lecturas concretas sin tocar el wrapper.
    //    Mientras los flags estén OFF, NINGUNA de estas se invoca en el flujo normal. ──
    _sb: {
      lecturaDirecta: _mosLecturaDirecta,   // ¿flag maestro ON?
      flag:           _mosFlag,             // gate genérico (FASE 1: flags por-acción)
      mintToken:      _mintTokenMOS,        // JWT app='MOS' (null si Edge caída → GAS)
      deviceId:       _mosDeviceId,
      rpc:            _sbRpcMOS,            // RPC PostgREST esquema mos (null = caé a GAS)
      leerTabla:      _sbLeerTablaMOS,      // SELECT tabla mos.* (null = caé a GAS)
      conFallback:    _conFallbackMOS,      // patrón "directo si flag+token, si no GAS"
      // [FASE 1 · PILOTO] catálogo directo (getProductos):
      catalogoDirecto:    _mosCatalogoDirecto,   // ¿flag por-acción del catálogo ON?
      getProductosDirecto:_getProductosDirecto,  // RPC+map+frescura (array o null→GAS) — para diagnóstico
      mapProd:            _mapProdSnakeToHoja,    // map snake→shape-hoja (test de paridad)
      // [FASE 1] finanzas + historial directos (getFinanzasRango / getHistorialPrecios):
      finanzasDirecto:        _mosFinanzasDirecto,        // ¿flag por-acción de finanzas ON?
      historialDirecto:       _mosHistorialDirecto,       // ¿flag por-acción de historial ON?
      getFinanzasRangoDirecto:   _getFinanzasRangoDirecto,   // RPC+frescura ({serie,totales,...} o null→GAS) — diagnóstico
      getHistorialPreciosDirecto:_getHistorialPreciosDirecto, // RPC+frescura (array o null→GAS) — diagnóstico
      // [FASE 2 · LOTE CATÁLOGO] escritura directa del catálogo (crear/actualizar producto, publicar precio,
      // crear/actualizar equivalencia). INERTE: solo entra con flag mos_catalogo_directo ON + token + RPC viva.
      rpcWrite:        _sbRpcMOSWrite,    // RPC mos.* de escritura con etiqueta .permanente (null = caé a GAS)
      postDirecto:     _postDirectoMOS,   // dispatcher write→RPC (data o null→GAS, lanza en negocio/timeout) — diagnóstico/test
      // [FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS] gates por-operación (default OFF) + helper de local_id.
      proveedoresDirecto: _mosProveedoresDirecto,  // ¿flag mos_proveedores_directo ON?
      pedidosDirecto:     _mosPedidosDirecto,      // ¿flag mos_pedidos_directo ON?
      pagosDirecto:       _mosPagosDirecto,        // ¿flag mos_pagos_directo ON? (DINERO)
      provprodDirecto:    _mosProvProdDirecto,     // ¿flag mos_provprod_directo ON?
      // [FASE 2] read-paths directos de estos módulos (RPCs 94, array o null→GAS) — diagnóstico/test de paridad.
      getProveedoresDirecto:        _getProveedoresDirecto,
      getPedidosDirecto:            _getPedidosDirecto,
      getPagosDirecto:              _getPagosDirecto,
      getProveedorProductosDirecto: _getProveedorProductosDirecto,
      // [FASE 2 · LOTE GASTOS/EVAL/HORARIO] gates por-módulo (default OFF). Etiquetas NO se cablea (el front
      // MOS no llama marcarVisto/marcarPegada ni crear-etiqueta). Ver REPORTE.
      gastosDirecto:      _mosGastosDirecto,       // ¿flag mos_gastos_directo ON? (DINERO)
      evalDirecto:        _mosEvalDirecto,         // ¿flag mos_eval_directo ON?
      horarioDirecto:     _mosHorarioDirecto,      // ¿flag mos_horario_directo ON?
      // [FASE 2 · LOTE JORNALES/LIQUIDACIONES] gates por-grupo (default OFF, DINERO). marcarPagos/anularPago/
      // recomputarLiquidacionDia NO cableados (shape/seguridad incompatibles con la RPC) — ver REPORTE.
      jornadasDirecto:    _mosJornadasDirecto,     // ¿flag mos_jornadas_directo ON? (DINERO jornal)
      getJornadasDirecto: _getJornadasDirecto,     // read-path directo jornadas (array o null→GAS) — diagnóstico
      liqdiaDirecto:      _mosLiqdiaDirecto,       // ¿flag mos_liqdia_directo ON? (DINERO liquidación)
      localId:            _mosLocalId              // genera/estampa local_id estable por gesto — test de idempotencia
    },
  };
})();
