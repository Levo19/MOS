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
      return _fetch('GET',  { action, ...p });
    },
    post: (action, p = {}) => _fetch('POST', { action, ...p }),
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
      getHistorialPreciosDirecto:_getHistorialPreciosDirecto // RPC+frescura (array o null→GAS) — diagnóstico
    },
  };
})();
