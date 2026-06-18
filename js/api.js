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

  // ── [INTERRUPTOR CENTRAL] Flags de toda la flota MOS, leídos de mos.config vía la RPC mos.get_flags()
  //    (anon, SIN token: se llama al arrancar antes del mint). Réplica fiel de me.get_flags() (MosExpress).
  //    El frontend los refresca al arrancar y cada ~2min. Cada helper hace `serverFlag || localStorage ||
  //    MOS_CONFIG`: el server prende/apaga a TODOS desde pg (flip/kill-switch instantáneo, sin depender del
  //    rollout del SW), y localStorage/MOS_CONFIG siguen como override por-dispositivo (piloto).
  //    Fail-safe: si get_flags falla (500/red caída), conservamos los últimos flags buenos (o {} en el
  //    arranque) → manda localStorage/MOS_CONFIG → default OFF = seguro (cae a GAS). NUNCA rompe.
  //    Esto es PREREQUISITO del cutover de escritura: permite flipear escritura-directa + sync-off (atómico,
  //    server-side) sin la ventana de incoherencia en la que un dispositivo con SW viejo seguía escribiendo
  //    por GAS→hoja mientras el sync ya estaba apagado (dato perdido de la sombra). INERTE: con todos los
  //    flags server en '0' (estado actual), _serverFlags trae todo '0' → _mosFlag decide igual que hoy.
  let _serverFlags = {};
  async function _cargarFlagsMOS() {
    try {
      const res = await _sbFetchTimeout(`${_SB_URL}/rest/v1/rpc/get_flags`, {
        method: 'POST',
        headers: {
          'apikey': _SB_ANON, 'Authorization': 'Bearer ' + _SB_ANON,
          'Accept-Profile': 'mos', 'Content-Profile': 'mos', 'Content-Type': 'application/json'
        },
        body: '{}'
      }, 8000);
      if (res.ok) { const d = await res.json(); if (d && typeof d === 'object') _serverFlags = d; }
    } catch (_) { /* fail-safe: conservar los últimos flags buenos (o {} = manda localStorage/MOS_CONFIG/OFF) */ }
  }

  // Flags de activación. Orden de evaluación: server (mos.get_flags, flota) || localStorage (por-dispositivo) ||
  // window.MOS_CONFIG[cfgKey] (server-wide en index.html, hoy {catalogoDirecto:true}). Default OFF → INERTE.
  // El término server es `_serverFlags[cfgKey] === '1'` (valor crudo de mos.config, igual que ME).
  function _mosFlag(lsKey, cfgKey) {
    try {
      if (_serverFlags && _serverFlags[cfgKey] === '1') return true;
      if (localStorage.getItem(lsKey) === '1') return true;
      return (typeof window !== 'undefined' && window.MOS_CONFIG && window.MOS_CONFIG[cfgKey] === true);
    } catch (_) {
      if (_serverFlags && _serverFlags[cfgKey] === '1') return true;
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

  // [FASE 2 · LOTE PROVEEDORES/PEDIDOS/PAGOS] gates *_DIRECTO por-operación (espejo de los kill-switches server-side
  // MOS_PROVEEDORES_DIRECTO / MOS_PEDIDOS_DIRECTO / MOS_PAGOS_DIRECTO / MOS_PROVPROD_DIRECTO, todos default '0').
  // ⚠️ MODELO DUAL-WRITE: estos gates *_DIRECTO ya NO gobiernan NINGÚN read-path ni write-path cableado. Se
  //    conservan SOLO por compatibilidad/diagnóstico (espejan el kill-switch server que ahora gobernaría una
  //    escritura-directa-pura que el dual-write NO usa). La LECTURA usa los nuevos gates *_LECTURA (abajo); la
  //    ESCRITURA va SIEMPRE por GAS (que hace _dualWriteMOS → espeja a la sombra). Default OFF → INERTE.
  // [PILOTO ESCRITURA DIRECTA · PROVEEDORES] Gate por-módulo de ESCRITURA directa de proveedores.
  // ⚠️ A DIFERENCIA del catálogo, NO incluye el maestro de LECTURAS (_mosLecturaDirecta): ese flag está ON en prod
  //    (gobierna las 56 lecturas directas) y atarlo aquí ACTIVARÍA la escritura directa al instante con el sync aún
  //    encendido → pisado/duplicación (el incidente del 2026-06-15). La ESCRITURA es un cutover aparte que exige su
  //    propio flag + apagar el sync (MOS_SYNC_OFF_TABLAS) JUNTOS. Por eso depende SOLO de su flag dedicado.
  // Default OFF (mos_proveedores_directo / proveedoresDirecto ausente) → INERTE: crearProveedor/actualizarProveedor
  // van por GAS, bit-idéntico a hoy. Activación = ver RUNBOOK_cutover_escritura_proveedores.md (flag + sync-off).
  function _mosProveedoresDirecto() { return !!_mosFlag('mos_proveedores_directo', 'proveedoresDirecto'); }
  // ════════════════════════════════════════════════════════════════════
  // [DUAL-WRITE · PROVEEDORES] Gate SEPARADO y PREFERIDO sobre el directo-puro de arriba. Default OFF → INERTE.
  // DIFERENCIA CRÍTICA entre los dos modos de escritura de proveedores:
  //   · _mosProveedoresDirecto (DIRECTO-PURO): escribe SOLO Supabase (NO GAS). Exige apagar el sync de
  //     proveedores (MOS_SYNC_OFF_TABLAS) o el sync Hoja→sombra pisa lo escrito directo. Un device viejo que
  //     escriba por GAS→Hoja con el sync apagado PIERDE el dato (incidente del 2026-06-15). PELIGROSO.
  //   · _mosProveedoresDualWrite (DUAL-WRITE, ESTE): escribe PRIMERO por GAS (Hoja = verdad + _dualWriteMOS de
  //     GAS espeja la sombra), y SOLO si GAS devolvió ok hace ADEMÁS un upsert best-effort directo a la misma
  //     RPC para asegurar que la sombra quede fresca aunque el urlfetch de GAS haya fallado por cuota. El sync
  //     NO se apaga; un device viejo NO rompe nada (la Hoja sigue siendo verdad). SEGURO.
  // Orden CRÍTICO: GAS primero, Supabase después → la sombra NUNCA queda ADELANTE de la Hoja. Si GAS falla, NO
  // se hace el write directo (comportamiento = hoy). El upsert directo es fire-and-forget: su fallo NO afecta
  // el retorno ni lanza (el sync/GAS reconcilia). Activación = solo prender este flag (ver RUNBOOK §DUAL-WRITE).
  function _mosProveedoresDualWrite() { return !!_mosFlag('mos_proveedores_dualwrite', 'proveedoresDualWrite'); }
  // [DUAL-WRITE · LOTE EXTENDIDO] Gates dedicados por-módulo, MISMO patrón y semántica que _mosProveedoresDualWrite:
  // GAS escribe PRIMERO (Hoja = verdad + sus hooks: recompute liquidación/push/enforcement horario) y SOLO si GAS
  // devolvió ok se hace un upsert best-effort a la MISMA RPC (sombra fresca, aditivo). El sync NO se apaga; un device
  // viejo no rompe nada. Orden CRÍTICO: GAS primero, Supabase después → la sombra NUNCA queda ADELANTE de la Hoja.
  // Default OFF (flag ausente) → INERTE: _postMOS ni evalúa esta rama → la acción va recto a GAS, bit-idéntico a hoy.
  function _mosPedidosDualWrite()  { return !!_mosFlag('mos_pedidos_dualwrite',  'pedidosDualWrite'); }
  function _mosProvProdDualWrite() { return !!_mosFlag('mos_provprod_dualwrite', 'provprodDualWrite'); }
  function _mosGastosDualWrite()   { return !!_mosFlag('mos_gastos_dualwrite',   'gastosDualWrite'); }
  function _mosJornadasDualWrite() { return !!_mosFlag('mos_jornadas_dualwrite', 'jornadasDualWrite'); }
  function _mosEvalDualWrite()     { return !!_mosFlag('mos_eval_dualwrite',     'evalDualWrite'); }
  function _mosPedidosDirecto()     { return !!_mosFlag('mos_pedidos_directo',     'pedidosDirecto'); }
  function _mosPagosDirecto()       { return !!_mosFlag('mos_pagos_directo',       'pagosDirecto'); }
  function _mosProvProdDirecto()    { return !!_mosFlag('mos_provprod_directo',    'provprodDirecto'); }

  // ════════════════════════════════════════════════════════════════════
  // [DUAL-WRITE · GATES DE LECTURA POR MÓDULO] Separan la LECTURA directa de la ESCRITURA. En el modelo
  // dual-write, la escritura va SIEMPRE por GAS (espeja la sombra); SOLO la lectura se activa por flag. Cada
  // gate de lectura = MAESTRO (_mosLecturaDirecta, prende TODAS de golpe) OR su flag específico de módulo
  // `mos_<modulo>_lectura` (cfgKey `<modulo>Lectura`). Patrón IDÉNTICO a catálogo/finanzas/historial.
  // Default OFF (maestro OFF + específico OFF) → INERTE: el read-path va recto a GAS, bit-idéntico a hoy.
  // server clave en mos.config: MOS_<MODULO>_LECTURA (ver SQL get_flags). NO confundir con MOS_*_DIRECTO.
  // ════════════════════════════════════════════════════════════════════
  function _mosProveedoresLectura() { return !!(_mosLecturaDirecta() || _mosFlag('mos_proveedores_lectura', 'proveedoresLectura')); }
  function _mosPedidosLectura()     { return !!(_mosLecturaDirecta() || _mosFlag('mos_pedidos_lectura',     'pedidosLectura')); }
  function _mosPagosLectura()       { return !!(_mosLecturaDirecta() || _mosFlag('mos_pagos_lectura',       'pagosLectura')); }
  function _mosProvProdLectura()    { return !!(_mosLecturaDirecta() || _mosFlag('mos_provprod_lectura',    'provprodLectura')); }
  function _mosJornadasLectura()    { return !!(_mosLecturaDirecta() || _mosFlag('mos_jornadas_lectura',    'jornadasLectura')); }
  function _mosEvalLectura()        { return !!(_mosLecturaDirecta() || _mosFlag('mos_eval_lectura',        'evalLectura')); }
  function _mosHorarioLectura()     { return !!(_mosLecturaDirecta() || _mosFlag('mos_horario_lectura',     'horarioLectura')); }

  // [FASE 2 · LOTE BAJO-RIESGO + GASTOS] gates *_DIRECTO por-operación (espejo de los kill-switches server-side
  // MOS_GASTOS_DIRECTO (83) / MOS_EVAL_DIRECTO / MOS_HORARIO_DIRECTO (82), todos default '0').
  // ⚠️ MODELO DUAL-WRITE: estos *_DIRECTO ya NO gobiernan ningún write-path cableado (la escritura va SIEMPRE
  //    por GAS). gastos NO tiene read-path directo cableado (sin RPC de lista cableada) → su gate queda solo
  //    diagnóstico. eval/horario usan ahora los gates *_LECTURA (arriba) en sus read-paths. Default OFF → INERTE.
  function _mosGastosDirecto()  { return !!_mosFlag('mos_gastos_directo',  'gastosDirecto'); }
  function _mosEvalDirecto()    { return !!_mosFlag('mos_eval_directo',    'evalDirecto'); }
  function _mosHorarioDirecto() { return !!_mosFlag('mos_horario_directo', 'horarioDirecto'); }
  // [FASE 2 · ETIQUETAS] gate por-módulo (espejo del kill-switch server MOS_ETIQ_DIRECTO, default '0'). El
  // frontend MOS NO consume getEtiquetasPendientes (las etiquetas las leen WH/ME, no el panel admin MOS) → este
  // gate existe por uniformidad/diagnóstico pero NO gobierna ningún read-path cableado. Ver REPORTE.
  function _mosEtiqDirecto()    { return !!_mosFlag('mos_etiq_directo',    'etiqDirecto'); }

  // [FASE 2 · LOTE JORNALES/LIQUIDACIONES] gates *_DIRECTO por-operación (espejo de los kill-switches server-side
  // MOS_JORNADAS_DIRECTO (84) / MOS_LIQDIA_DIRECTO (85), ambos default '0'). DINERO (jornal/liquidación).
  // ⚠️ MODELO DUAL-WRITE: ya NO gobiernan write-path (la escritura de jornadas/liquidaciones va SIEMPRE por GAS).
  //    La LECTURA de jornadas usa el gate _mosJornadasLectura (arriba). liqdia no tiene read-path directo cableado
  //    → su gate queda solo diagnóstico. Default OFF → INERTE.
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
  // [Optimización] getPersonalDiaFast → mos.personal_dia_lista (105): lee la sombra liquidaciones_dia
  // (materializada por Fase D + cron), shape camelCase PARITARIO con getPersonalDiaFast (Liquidaciones.gs:1204).
  async function _getPersonalDiaFastDirecto(params)    { return _getListaDirectaMOS('personal_dia_lista',       params, 'personalDia'); }
  // [Optimización] catálogos base → RPCs 106 (bools '1'/'0' paritarios con getEquivalencias/getCategorias).
  async function _getEquivalenciasDirecto(params)      { return _getListaDirectaMOS('equivalencias_lista',      params, 'equivalencias'); }
  async function _getCategoriasDirecto(params)         { return _getListaDirectaMOS('categorias_lista',         params, 'categorias'); }
  // [Optimización] catálogos/config → RPCs 107 (personal sin pin_hash; bools '1'/'0'; pin/adminPin via RLS).
  async function _getPersonalMasterDirecto(params)     { return _getListaDirectaMOS('personal_master_lista',    params, 'personalMaster'); }
  async function _getZonasDirecto(params)              { return _getListaDirectaMOS('zonas_lista',              params, 'zonas'); }
  async function _getEstacionesDirecto(params)         { return _getListaDirectaMOS('estaciones_lista',         params, 'estaciones'); }
  async function _getImpresorasDirecto(params)         { return _getListaDirectaMOS('impresoras_lista',         params, 'impresoras'); }
  async function _getSeriesDirecto(params)             { return _getListaDirectaMOS('series_lista',             params, 'series'); }
  // [Optimización] complejos (108/109/110). finanzas_dia/historico devuelven OBJETO (no array) → helper propio
  // con gate _fresh (igual que _getFinanzasRangoDirecto). provprod_stock devuelve array → _getListaDirectaMOS.
  async function _getFinanzasDiaDirecto(params) {
    const r = await _sbRpcMOS('finanzas_dia', { p_fecha: (params && params.fecha) || null });
    if (r == null) return null;
    if (!r.ok || !r.data) return null;
    if (r._fresh !== true) { try { console.warn('[MOS finanzas_dia] sombra STALE → GAS'); } catch(_){} return null; }
    return r.data;
  }
  async function _getProductosProveedorStockDirecto(params) { return _getListaDirectaMOS('productos_proveedor_stock', params, 'provprodStock'); }
  async function _getHistoricoProveedorDirecto(params) {
    const r = await _sbRpcMOS('historico_proveedor', { p: params || {} });
    if (r == null) return null;
    if (!r.ok || !r.data) return null;
    if (r._fresh !== true) { try { console.warn('[MOS historico_proveedor] sombra STALE → GAS'); } catch(_){} return null; }
    return r.data;
  }
  // Helper para RPCs cuyo data es OBJETO (no array) — devuelve r.data o null→GAS, con gate _fresh.
  async function _getObjDirectoMOS(fn, params, etq) {
    const r = await _sbRpcMOS(fn, { p: params || {} });
    if (r == null) return null;
    if (!r.ok || r.data == null) return null;
    if (r._fresh !== true) { try { console.warn('[MOS ' + etq + '] sombra STALE → GAS'); } catch(_){} return null; }
    return r.data;
  }
  // [Optimización · vistas cross-app] cajas (ME) + warehouse (WH) leídas desde MOS (RPCs 111/112/113).
  async function _getCierresCajaDirecto(params)         { return _getObjDirectoMOS('cierres_caja',           params, 'cierresCaja'); }
  async function _getMermasWarehouseDirecto(params)     { return _getListaDirectaMOS('mermas_warehouse',     params, 'mermasWH'); }
  async function _getEnvasadosWarehouseDirecto(params)  { return _getListaDirectaMOS('envasados_warehouse',  params, 'envasadosWH'); }
  async function _getAlertasWarehouseDirecto(params)    { return _getObjDirectoMOS('alertas_warehouse',      params, 'alertasWH'); }
  async function _getRotacionProductosDirecto(params)   { return _getListaDirectaMOS('rotacion_productos',   params, 'rotacion'); }
  async function _getCatalogoStockResumenDirecto(params){ return _getObjDirectoMOS('catalogo_stock_resumen', params, 'catStockResumen'); }
  async function _getDashboardAlmacenDirecto(params)    { return _getObjDirectoMOS('dashboard_almacen',      params, 'dashAlmacen'); }
  // [Optimización · portables 114/115/116] config + dispositivos + liquidaciones + bloqueos + auditoría + proveedores.
  async function _getConfigDirecto(params)              { return _getObjDirectoMOS('config_publico',          params, 'config'); }
  async function _getDispositivosDirecto(params)        { return _getListaDirectaMOS('listar_dispositivos',   params, 'dispositivos'); }
  async function _getLiqPendientesDirecto(params)       { return _getListaDirectaMOS('liquidaciones_pendientes', params, 'liqPend'); }
  async function _getLiqPagadasDirecto(params)          { return _getListaDirectaMOS('liquidaciones_pagadas', params, 'liqPag'); }
  async function _getLiqVetadasDirecto(params)          { return _getListaDirectaMOS('liquidaciones_vetadas', params, 'liqVet'); }
  async function _getPagoDetalleDirecto(params)         { return _getObjDirectoMOS('pago_detalle',            params, 'pagoDet'); }
  async function _getLiqDiaBonSanDirecto(params)        { return _getObjDirectoMOS('liq_dia_bon_san',         params, 'liqBonSan'); }
  async function _getProveedoresQueVendenDirecto(params){ return _getListaDirectaMOS('proveedores_que_venden', params, 'provVenden'); }
  async function _getVendedoresMEBloqueadosDirecto(params){ return _getListaDirectaMOS('vendedores_me_bloqueados', params, 'vendBloq'); }
  async function _getDispositivosBloqueadosDirecto(params){ return _getObjDirectoMOS('dispositivos_bloqueados', params, 'dispBloq'); }
  async function _getNotificacionesConfigDirecto(params){ return _getListaDirectaMOS('notificaciones_config', params, 'notifCfg'); }
  async function _getAuditoriaAdminDirecto(params)      { return _getListaDirectaMOS('auditoria_admin_lista',  params, 'audAdmin'); }
  async function _getAuditoriaIntegridadDirecto(params) { return _getObjDirectoMOS('auditoria_integridad_lista', params, 'audInteg'); }
  async function _getProductosEditadosRecientesDirecto(params){ return _getListaDirectaMOS('productos_editados_recientes', params, 'prodEdit'); }
  // [Optimización · cross-app vistas 117/118/119] solo las verificadas con paridad (las con bugs/gaps siguen GAS).
  async function _getRankingZonasDirecto(params)        { return _getObjDirectoMOS('ranking_zonas',           params, 'rankZonas'); }
  async function _getProductosSinVentaDirecto(params)   { return _getObjDirectoMOS('productos_sin_venta',     params, 'prodSinVenta'); }
  async function _getAlertasOperativasDirecto(params)   { return _getObjDirectoMOS('alertas_operativas',      params, 'alertasOp'); }
  async function _getGuiasYPreingresosDirecto(params)   { return _getObjDirectoMOS('guias_y_preingresos',     params, 'guiasPre'); }
  async function _getOperacionesUnificadasDirecto(params){ return _getObjDirectoMOS('operaciones_unificadas', params, 'opsUnif'); }
  async function _getStockUnificadoDirecto(params)      { return _getObjDirectoMOS('stock_unificado',         params, 'stockUnif'); }
  async function _getInsightsStockDirecto(params)       { return _getObjDirectoMOS('insights_stock',          params, 'insStock'); }
  async function _getAnaliticaProductoDirecto(params)   { return _getObjDirectoMOS('analitica_producto',      params, 'analProd'); }
  async function _getMeCajasAbiertasDirecto(params)     { return _getListaDirectaMOS('me_cajas_abiertas',     params, 'meCajas'); }
  // [FIX bug SQL alias x.ord→ord] me_cobros_en_vuelo devuelve OBJETO {enVuelo,recientes} → _getObjDirectoMOS.
  async function _getMeCobrosEnVueloDirecto(params)     { return _getObjDirectoMOS('me_cobros_en_vuelo',     params, 'meCobrosVuelo'); }
  // [Optimización · portables 124] tarjeta WA + créditos pendientes ME + consultar cliente ME (RPC en 118).
  // getTarjetaWA → mos.tarjeta_wa_obj: OBJETO {TARJETA_WA_COMERCIAL,TARJETA_WA_COMPRAS,TARJETA_MARCA} (app.js:18231 lee r.data plano).
  async function _getTarjetaWADirecto(params)           { return _getObjDirectoMOS('tarjeta_wa_obj',         params, 'tarjetaWA'); }
  // meGetCreditosPendientes → mos.me_creditos_pendientes: OBJETO {grupos,totalAcumulado,totalTickets} (app.js:24917 lee d.grupos).
  async function _getMeCreditosPendientesDirecto(params){ return _getObjDirectoMOS('me_creditos_pendientes', params, 'meCreditos'); }
  // meConsultarCliente → mos.me_consultar_cliente (118): OBJETO PLANO {nombre,razonSocial,direccion,...} bajo data
  // (app.js:26156 lee r.nombre/r.razon_social/r.direccion del RAÍZ; MOS API.get desempaqueta d.data → llega plano).
  // ⚠ CAVEAT: no resuelve SUNAT/RENIEC en vivo; si encontrado:false el front debe seguir su lookup manual/GAS.
  async function _getMeConsultarClienteDirecto(params)  { return _getObjDirectoMOS('me_consultar_cliente',   params, 'meCliente'); }
  // [resumen_todos_dia FULL] getResumenTodosDia → array de resumen_dia paritario (real via resumen_dia + virtuales
  // MEX inline paritarios). El consumidor (app.js:32513) hace Array.isArray(res) → devolvemos r.data (array).
  async function _getResumenTodosDiaDirecto(params)     { return _getListaDirectaMOS('resumen_todos_dia',    params, 'resumenTodos'); }
  // [eco_status] getEcoStatus → objeto {ok,me,wh} (ZONAS_CONFIG derivada de series/estaciones). El consumidor lee
  // eco.me/eco.wh (dots + modal detalle); el `ok` interno se ignora. Gate _fresh → GAS si sombra stale.
  async function _getEcoStatusDirecto(params)           { return _getObjDirectoMOS('eco_status',             params, 'ecoStatus'); }

  // ════════════════════════════════════════════════════════════════════
  // [RIZ · CAPA 4] Módulo de Reposición Inteligente por Zona (RIZ). Frontend 100% Supabase:
  // las RPCs viven en el esquema `me` (me.zona_panel / me.tendencia_zona / me.zona_ticket_dia /
  // me.zona_lotes_historial — LECTURAS; me.zona_ajustar_stock / me.zona_pedir_almacen — ACCIONES).
  //
  // ⚠️ INERTE POR DEFECTO: gate por-módulo `mos_zona_modulo` (cfgKey `zonaModulo`), default OFF.
  // El frontend (app.js loadZona) SOLO entra a la vista si el flag está ON; con el flag OFF la app
  // es idéntica a hoy (el item de nav está oculto y loadZona nunca se invoca). Estos helpers existen
  // pero no se llaman hasta que la vista se abra.
  //
  // PERFIL: las RPCs se DEFINEN en el esquema `me`, pero el frontend MOS solo tiene expuesto el perfil
  // PostgREST 'mos'. Por eso se invocan los WRAPPERS `mos.zona_*` (supabase/132) — homónimos que hacen
  // pass-through a `me.zona_*` (mismo patrón que mos.me_creditos_pendientes). Se pasa profile='mos'.
  // PARÁMETRO: el backend lee `{zona:'ZONA-XX'}` (NO `zonaId`). _zonaParams() normaliza zonaId→zona.
  //
  // ESCRITURA (ajuste de stock + pedir a almacén): por dual-write-frontend el diseño pide GAS-primero
  // si existe el endpoint GAS. A la fecha NO existe un endpoint GAS equivalente para RIZ (es un módulo
  // nuevo 100% Supabase: pg_cron + RPCs me.zona_*). Por eso estas DOS acciones van **SOLO a Supabase**
  // (RPC directa) + console.log de auditoría. Si en el futuro WH/ME exponen un endpoint GAS espejo
  // (p.ej. wh.pickups vía forwardWHPickup para "pedir"), reintroducir el GAS-primero acá. Mientras el
  // flag del módulo esté OFF (default) estas acciones NUNCA se disparan. — Ver REPORTE Capa 4.
  // ════════════════════════════════════════════════════════════════════
  function _mosZonaModulo() { return !!_mosFlag('mos_zona_modulo', 'zonaModulo'); }

  // RPC de ESCRITURA RIZ directa a PostgREST vía los WRAPPERS `mos.zona_*` (supabase/132). Espejo de
  // _sbRpcMOSWrite con profile 'mos'. Sin token → null ("no commiteó"); 4xx definitivo → permanente; 5xx/timeout → transitorio.
  async function _sbRpcZonaWrite(fn, args) {
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
      const e = new Error('rpc zona HTTP ' + res.status);
      e.status = res.status;
      e.permanente = (res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429);
      throw e;
    }
    return res.json();
  }

  // Normaliza los params RIZ al contrato del backend: zonaId → zona (el resto pasa tal cual).
  // El backend SIEMPRE lee `zona`; el frontend histórico mandaba `zonaId`. Aceptamos ambos.
  function _zonaParams(params) {
    const p = Object.assign({}, params || {});
    if (p.zona == null && p.zonaId != null) p.zona = p.zonaId;
    delete p.zonaId;
    return p;
  }

  // ── LECTURAS RIZ (wrappers profile 'mos'). Devuelven r.data (o el objeto/array crudo) o null si no hay token.
  //    NO aplican gate _fresh estricto: el panel muestra el chip de frescura usando r._fresh que viene
  //    en la respuesta (la decisión de "datos con retraso" es del UI, no se cae a GAS — RIZ no tiene GAS).
  async function _zonaPanelDirecto(params)        { const r = await _sbRpcMOS('zona_panel',           { p: _zonaParams(params) }, 'mos'); return r; }
  async function _zonaTendenciaDirecto(params)    { const r = await _sbRpcMOS('tendencia_zona',       { p: _zonaParams(params) }, 'mos'); return r; }
  async function _zonaTicketDiaDirecto(params)    { const r = await _sbRpcMOS('zona_ticket_dia',      { p: _zonaParams(params) }, 'mos'); return r; }
  async function _zonaLotesHistorialDirecto(params){ const r = await _sbRpcMOS('zona_lotes_historial',{ p: _zonaParams(params) }, 'mos'); return r; }

  // ── ACCIONES RIZ (Supabase-only + log, ver cabecera). Lanzan ante error de negocio/HTTP; el caller
  //    (app.js) hace optimista + revierte. Devuelven la respuesta cruda {ok,data,...} de la RPC, o null
  //    si no hay token (el caller trata null como fallo → revierte).
  async function _zonaAjustarStock(params) {
    const zona = params && (params.zona != null ? params.zona : params.zonaId);
    // [RIZ MEJORA 5] ajuste POR CÓDIGO: el backend ahora lee `codBarra` (singular). Aceptamos
    // codBarra | codBarras | codigoBarra del caller y lo normalizamos al contrato del backend.
    const codBarra = params && (params.codBarra != null ? params.codBarra
                               : (params.codBarras != null ? params.codBarras
                               : (params.codigoBarra != null ? params.codigoBarra : null)));
    try { console.log('[RIZ] zona_ajustar_stock', { zona, sku: params && params.skuBase, codBarra, nuevo: params && params.nuevo }); } catch (_) {}
    // Backend me.zona_ajustar_stock lee: zona, codBarra (o skuBase), nuevo, usuario, localId? (NO stockAntes).
    return _sbRpcZonaWrite('zona_ajustar_stock', { p: {
      zona:    zona != null ? String(zona) : undefined,
      skuBase: params && params.skuBase != null ? String(params.skuBase) : undefined,
      nuevo:   params && params.nuevo,
      localId: params && params.localId != null ? String(params.localId) : undefined,
      codBarra: codBarra != null ? String(codBarra) : undefined,
      usuario: _mosUsuario(params)
    } });
  }
  async function _zonaPedirAlmacen(params) {
    const zona = params && (params.zona != null ? params.zona : params.zonaId);
    try { console.log('[RIZ] zona_pedir_almacen', { zona, sku: params && params.skuBase, cant: params && params.cantidad }); } catch (_) {}
    // Backend me.zona_pedir_almacen lee: zona, items:[{skuBase,cantidad}], usuario, localId?.
    // Si el caller manda skuBase+cantidad planos (1 producto), los empaquetamos en items[]; si manda items[], se respetan.
    const items = Array.isArray(params && params.items) ? params.items
      : (params && params.skuBase != null ? [{ skuBase: String(params.skuBase), cantidad: params.cantidad }] : []);
    return _sbRpcZonaWrite('zona_pedir_almacen', { p: {
      zona:    zona != null ? String(zona) : undefined,
      items,
      localId: params && params.localId != null ? String(params.localId) : undefined,
      usuario: _mosUsuario(params)
    } });
  }
  // [RIZ · CAPA 5] Acción BCG-perro (Promocionar/Góndola/Rematar). NO muta stock/dinero: registra la decisión
  // del admin (mos.zona_marcar_accion → me.zona_accion_perro, SQL 157). Idempotente por localId. Supabase-only.
  async function _zonaMarcarAccion(params) {
    const zona = params && (params.zona != null ? params.zona : params.zonaId);
    const accion = String((params && params.accion) || '').toUpperCase();
    try { console.log('[RIZ] zona_marcar_accion', { zona, sku: params && params.skuBase, accion }); } catch (_) {}
    return _sbRpcZonaWrite('zona_marcar_accion', { p: {
      zona:    zona != null ? String(zona) : undefined,
      skuBase: params && params.skuBase != null ? String(params.skuBase) : undefined,
      accion:  accion || undefined,
      localId: params && params.localId != null ? String(params.localId) : undefined,
      usuario: _mosUsuario(params)
    } });
  }

  // ── [RIZ · TRASLADO VERIFICADO] Ingreso por almacén con ESCANEO (supabase/141). ──────────────────────────
  // El almacén emite una guía de ENTRADA hacia la zona (en me.guias_cabecera, tipo ENTRADA_*). El operador
  // escanea el QR de la guía (=idGuia), luego escanea producto por producto lo que llegó, y al "Cerrar ingreso"
  // la PC compara enviado (guía) vs escaneado (real) → completo/incompleto. Lo escaneado se registra en el
  // KARDEX (TRASLADO_IN); la aplicación al SALDO real (me.stock_zonas) está GATED/INERTE en el backend (141).
  // LECTURAS → _sbRpcMOS (devuelve r o null si no hay token). CIERRE → _sbRpcZonaWrite (lanza ante HTTP, el
  // caller hace optimista + revierte). Todos aceptan {zona}/{zonaId}; _zonaParams normaliza.
  async function _zonaTrasladosPendientes(params) { const r = await _sbRpcMOS('zona_traslados_pendientes', { p: _zonaParams(params) }, 'mos'); return r; }
  async function _zonaTrasladosResumen(params)    { const r = await _sbRpcMOS('zona_traslados_resumen',    { p: _zonaParams(params) }, 'mos'); return r; }
  async function _zonaTrasladoGuia(params) {
    const idGuia = params && (params.idGuia != null ? params.idGuia : params.id);
    const r = await _sbRpcMOS('zona_traslado_guia', { p: { idGuia: idGuia != null ? String(idGuia) : undefined } }, 'mos');
    return r;
  }
  // Cierre del ingreso: registra escaneados en kardex + persiste verificación. Idempotente por idGuia.
  // escaneados: [{codBarra, cantidad}]. Devuelve {ok,[dedup],stockAplicado,data:{estado,total_*,detalle,...}} o null.
  async function _zonaTrasladoCerrar(params) {
    const p = params || {};
    const idGuia = p.idGuia != null ? p.idGuia : p.id;
    const escaneados = Array.isArray(p.escaneados) ? p.escaneados.map(e => ({
      codBarra: String(e.codBarra != null ? e.codBarra : (e.cod_barra != null ? e.cod_barra : '')),
      cantidad: Number(e.cantidad != null ? e.cantidad : 0)
    })) : [];
    try { console.log('[RIZ] zona_traslado_cerrar', { idGuia, items: escaneados.length }); } catch (_) {}
    return _sbRpcZonaWrite('zona_traslado_cerrar', { p: {
      idGuia: idGuia != null ? String(idGuia) : undefined,
      escaneados,
      usuario: _mosUsuario(params),
      origen: 'MOS-PWA'
    } });
  }
  // Baseline: marca las guías ENTRADA_* existentes SIN verificación como BASELINE (verificadas de arranque), para
  // empezar con la lista de pendientes vacía. Idempotente (ON CONFLICT DO NOTHING). {zona} opcional acota a una zona.
  async function _zonaBaselineTraslados(params) {
    const p = params || {};
    const zona = p.zona != null ? p.zona : p.zonaId;
    return _sbRpcZonaWrite('zona_baseline_traslados', { p: {
      ...(zona != null ? { zona: String(zona) } : {}),
      usuario: _mosUsuario(params) || 'BASELINE'
    } });
  }

  // ── [RIZ · CAPA 5] IMPRESIÓN 80mm vía Edge `riz-print` ─────────────────
  // La Edge construye el ESC/POS server-side (lee mos.zona_ticket_dia / mos.zona_lista_compras con
  // service_role) y lo manda a PrintNode. Acá solo armamos el body + token (igual que cualquier Edge).
  // Devuelve {ok,printJobId} | {ok:false,error}. Lanza solo ante red/HTTP; nunca duplica (es 1 print job).
  // tipo: 'ticket_diario' | 'lista_compras'. printerId obligatorio (lo elige el usuario en el front).
  async function _zonaImprimir(params) {
    const token = await _mintTokenMOS();
    if (!token) return { ok: false, error: 'sin token (Edge mint-mos caída)' };
    const p = params || {};
    const zona = p.zona != null ? p.zona : p.zonaId;
    const body = {
      tipo: String(p.tipo || ''),
      zona: zona != null ? String(zona) : undefined,
      printerId: p.printerId,
      ...(p.fecha != null ? { fecha: String(p.fecha) } : {}),
      ...(p.semana != null ? { semana: p.semana } : {})
    };
    try { console.log('[RIZ] riz-print', { tipo: body.tipo, zona: body.zona, printerId: body.printerId }); } catch (_) {}
    const res = await _sbFetchTimeout(`${_SB_URL}/functions/v1/riz-print`, {
      method: 'POST',
      headers: { 'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }, 20000);
    const d = await res.json().catch(() => null);
    if (!res.ok || !d || d.ok === false) {
      const e = new Error((d && d.error) || ('riz-print HTTP ' + res.status));
      e.status = res.status;
      throw e;
    }
    return d;
  }

  // ── [RIZ · CAPA 5] IA real vía Edge `/functions/ia` (Claude, JWT-gated) ─
  // El frontend arma los `messages` (con los NÚMEROS determinísticos de las RPCs) y la Edge reenvía a
  // Claude con la API key del secret. La IA SOLO redacta texto natural; los números NO los inventa.
  // Devuelve el JSON crudo de Claude (el caller lee .content[0].text, igual que WH/ME). Lanza si falla
  // → el caller usa el texto local determinista de fallback.
  async function _zonaIA(payload) {
    const token = await _mintTokenMOS();
    if (!token) throw new Error('sin token (Edge mint-mos caída)');
    const p = payload || {};
    const body = {
      messages: p.messages,
      ...(p.system ? { system: String(p.system) } : {}),
      ...(p.model ? { model: String(p.model) } : {}),
      ...(p.max_tokens ? { max_tokens: p.max_tokens } : {})
    };
    const res = await _sbFetchTimeout(`${_SB_URL}/functions/v1/ia`, {
      method: 'POST',
      headers: { 'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }, 30000);
    const d = await res.json().catch(() => null);
    if (!res.ok || !d || d.ok === false) throw new Error((d && d.error) || ('ia HTTP ' + res.status));
    return d;   // {content:[{text}], ...} crudo de Claude
  }

  // ════════════════════════════════════════════════════════════════════
  // [IMPRESORAS · LISTAR/VERIFICAR vía Edge `printers`] Reemplaza el salto a GAS de
  // listarImpresorasPN / verificarImpresoraAhora (que tardaban ~9s por la latencia de UrlFetchApp).
  // La Edge MERGEA el catálogo MOS (mos.impresoras_lista/zonas_lista/estaciones_lista, service_role) con el
  // estado EN VIVO de PrintNode (/printers + /computers) → devuelve el MISMO shape que el GAS, campo por campo.
  // CAMINO COMPARTIDO (liquidaciones / costos guía / picker universal) → el shape DEBE ser BYTE-equivalente.
  //
  // Gate dedicado `_mosImpresorasPNEdge` (maestro OR mos_impresoras_pn_edge). Default OFF → INERTE: con el
  // flag OFF jamás se entra a la Edge y va recto a GAS = IDÉNTICO a hoy. Con el flag ON: intenta la Edge y,
  // ante CUALQUIER fallo (sin token / HTTP / {ok:false} / shape inesperado), devuelve null → _conFallbackMOS
  // cae a GAS (red de seguridad). NUNCA rompe la impresión.
  //
  // ⚠️ El consumidor (app.js) hace `API.get(...)` que DESEMPAQUETA d.data (devuelve la respuesta cruda de la
  //    Edge sin envoltura {ok,data}). Por eso estos helpers devuelven el ARRAY (list) / OBJETO (verify) PELADO
  //    —tal como GAS, donde _fetch('GET') ya devuelve d.data—, NO el wrapper {ok,data}.
  function _mosImpresorasPNEdge() { return !!_mosFlag('mos_impresoras_pn_edge', 'impresorasPNEdge'); }

  // op:'list' → array de impresoras (shape de listarImpresorasPN) o null (→ GAS).
  async function _listarImpresorasEdge() {
    const token = await _mintTokenMOS();
    if (!token) return null;                       // Edge mint-mos caída → GAS
    try {
      const res = await _sbFetchTimeout(`${_SB_URL}/functions/v1/printers`, {
        method: 'POST',
        headers: { 'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ op: 'list' })
      }, 20000);
      const d = await res.json().catch(() => null);
      if (!res.ok || !d || d.ok !== true || !Array.isArray(d.data)) return null;  // cualquier anomalía → GAS
      return d.data;   // ARRAY pelado == d.data de GAS (API.get no re-desempaqueta esto)
    } catch (_) { return null; }                   // red/HTTP → GAS
  }

  // op:'verify' → objeto estado de UNA impresora (shape de verificarImpresoraAhora) o null (→ GAS).
  async function _verificarImpresoraEdge(params) {
    const pid = params && (params.printerId != null ? params.printerId : params.id);
    if (pid == null || String(pid).trim() === '') return null;   // sin id → GAS (idéntico a GAS: error → fallback)
    const token = await _mintTokenMOS();
    if (!token) return null;
    try {
      const res = await _sbFetchTimeout(`${_SB_URL}/functions/v1/printers`, {
        method: 'POST',
        headers: { 'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ op: 'verify', printerId: String(pid) })
      }, 15000);
      const d = await res.json().catch(() => null);
      if (!res.ok || !d || d.ok !== true || !d.data || typeof d.data !== 'object') return null;
      return d.data;   // OBJETO pelado {state,reason,icon,color,online,...} == d.data de GAS
    } catch (_) { return null; }
  }

  // ── [RIZ · CAPA 5] Lista de compras como LECTURA (cablear botón "+Lista compras") ──
  // mos.zona_lista_compras(p) vía el wrapper profile 'mos' (igual que zona_panel). Devuelve r.data | null.
  async function _zonaListaComprasDirecto(params) { const r = await _sbRpcMOS('zona_lista_compras', { p: _zonaParams(params) }, 'mos'); return r; }

  // ── [ASEGURAR DATA] LECTURAS de diagnóstico de stock (SOLO LECTURA, no muta nada). Wrappers profile 'mos'.
  //    · diferencias()       → mos.stock_diferencias_listar(p) → {ok,data:{total,items:[...]},_fresh} (botón master).
  //    · kardexHistorial()   → mos.zona_kardex_historial(p {zona, codBarra|skuBase}) → historial reconstruido de ZONA.
  //    · almacenKardex()     → mos.almacen_kardex_historial(p {codBarra|skuBase}) → historial del kardex de ALMACÉN.
  //   Devuelven la respuesta cruda {ok,data,...} (o null si no hay token). El caller (app.js) lee r.data.
  async function _zonaDiferencias(params)       { const r = await _sbRpcMOS('stock_diferencias_listar', { p: _zonaParams(params || {}) }, 'mos'); return r; }
  async function _zonaKardexHistorial(params)   { const r = await _sbRpcMOS('zona_kardex_historial',     { p: _zonaParams(params || {}) }, 'mos'); return r; }
  async function _almacenKardexHistorial(params){ const r = await _sbRpcMOS('almacen_kardex_historial',  { p: params || {} }, 'mos'); return r; }

  // ════════════════════════════════════════════════════════════════════
  // [FASE 2 · LOTE EVAL/HORARIO/ETIQ] read-paths directos (RPCs 98). Mismo patrón que 94 pero con dos shapes:
  //   · evaluaciones_dia / etiquetas_pendientes → data ARRAY camelCase (== d.data de GAS) → usan el helper común.
  //   · horarios_apps → data OBJETO keyed por app (== d.data de getHorariosApps) → helper dedicado (NO es array).
  // Cada uno gated por SU flag de módulo (el mismo que ya gobierna la escritura directa) → cutover coherente.
  // Flag OFF (default, estado real) ⇒ no se entra al directo y va recto a GAS = IDÉNTICO a hoy.
  // ════════════════════════════════════════════════════════════════════
  // getEvaluacionesDia → mos.evaluaciones_dia (filtro fecha-día TZ Lima + activo + idPersonal, paridad GAS).
  async function _getEvaluacionesDiaDirecto(params)    { return _getListaDirectaMOS('evaluaciones_dia',         params, 'evaluaciones'); }
  // getEtiquetasPendientes → mos.etiquetas_pendientes (ventana 3d + estado + enriquecimientos). ⚠️ Sin consumidor
  // frontend en MOS (no se cabla en el dispatcher); se expone solo para diagnóstico/paridad. Ver REPORTE.
  async function _getEtiquetasPendientesDirecto(params){ return _getListaDirectaMOS('etiquetas_pendientes',     params, 'etiquetas'); }
  // getHorariosApps → mos.horarios_apps. Devuelve el OBJETO {<app>:{...}} (= d.data de GAS) o null (→ GAS).
  // null si: sin token, !ok, shape inesperado (no-objeto / array), o _fresh!==true (sombra stale).
  async function _getHorariosAppsDirecto(params) {
    const r = await _sbRpcMOS('horarios_apps', { p: params || {} });
    if (r == null) return null;                                            // sin token → GAS
    if (!r.ok || !r.data || typeof r.data !== 'object' || Array.isArray(r.data)) return null;  // shape inesperado → GAS
    if (r._fresh !== true) {                                               // sombra horarios stale → GAS
      try { console.warn('[MOS horarios directo] sombra STALE (_fresh=false, heartbeat=' + r._heartbeat + ') → fallback a GAS'); } catch (_) {}
      return null;
    }
    return r.data;   // {<app>:{app,horario,dias,admins_libres,actualizadoPor,fechaActualizacion}} == d.data de GAS
  }

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

  // [CATÁLOGO DELETE-SAFE] Sube la foto de un producto a Supabase Storage (bucket 'producto-fotos', máxima
  // calidad). Réplica EXACTA del patrón probado de WH (_subirFotoStorage). path: productos/<skuBase>/<archivo>.
  // Nombre DETERMINÍSTICO por skuBase → un reintento sobreescribe el MISMO path (no acumula basura) y reusa la
  // misma URL pública. Devuelve {ok, path, url, preview} o LANZA (red/RLS). Sin token (Edge caída) → lanza
  // (el caller cae a GAS). El binario va con el JWT MOS (claim app='MOS' → policy producto_fotos_insert).
  async function _subirFotoStorageMOS(skuBase, base64, mime, nombreSeed) {
    const token = await _mintTokenMOS();
    if (!token) { const e = new Error('sin token storage'); e.sinToken = true; throw e; }
    const ext = (mime || '').includes('png') ? 'png' : (mime || '').includes('webp') ? 'webp' : 'jpg';
    // limpiar prefijo data-URI (FileReader.readAsDataURL lo agrega) — sin esto atob() lanza.
    const b64 = String(base64 || '').replace(/^data:[^;]+;base64,/, '');
    // nombre estable: el skuBase comparte foto entre canónico/presentaciones → un mismo skuBase sobreescribe.
    const seed = (nombreSeed != null && String(nombreSeed) !== '') ? String(nombreSeed) : String(skuBase || 'foto');
    const nombre = seed.replace(/[^a-zA-Z0-9_\-\.]/g, '_') + '.' + ext;
    const path = `productos/${encodeURIComponent(String(skuBase || 'sin-sku'))}/${nombre}`;
    const bin = Uint8Array.from(atob(b64), ch => ch.charCodeAt(0));
    // upsert vía x-upsert (la foto del skuBase se REEMPLAZA al cambiarla). El bucket tiene policy UPDATE para
    // app='MOS', así que el ON CONFLICT DO UPDATE de Storage pasa la RLS (a diferencia de wh-fotos, que no tiene).
    const res = await _sbFetchTimeout(`${_SB_URL}/storage/v1/object/producto-fotos/${path}`, {
      method: 'POST',
      headers: { 'apikey': _SB_ANON, 'Authorization': 'Bearer ' + token, 'Content-Type': mime || 'image/jpeg', 'x-upsert': 'true' },
      body: bin
    }, 30000);
    if (!res.ok) {
      const body = await res.json().catch(() => null);
      const bodyCode = parseInt((body && body.statusCode), 10) || res.status;
      if (bodyCode === 409 || (body && /duplicate/i.test(String(body.error || '')))) {
        return { ok: true, path, url: `${_SB_URL}/storage/v1/object/public/producto-fotos/${path}`, preview: `${_SB_URL}/storage/v1/render/image/public/producto-fotos/${path}?width=800&quality=80` };
      }
      const err = new Error('storage upload ' + bodyCode + (body && body.message ? ': ' + body.message : ''));
      if (bodyCode >= 400 && bodyCode < 500 && bodyCode !== 429) err.permanente = true;
      throw err;
    }
    return {
      ok: true, path,
      url:     `${_SB_URL}/storage/v1/object/public/producto-fotos/${path}`,
      preview: `${_SB_URL}/storage/v1/render/image/public/producto-fotos/${path}?width=800&quality=80`
    };
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

    if (action === 'actualizarSegmentosPrecio') {
      // [CATÁLOGO DELETE-SAFE] mos.actualizar_segmentos_precio(p): valida (KGM + canónico + sin solapamientos,
      // réplica _validarSegmentosPrecio) y persiste mos.productos.segmentos_precio (jsonb). Idempotente (UPDATE
      // atómico al mismo valor = no-op). El front (app.js:16384 segPersistirSiCambio) lee res.ok y res.error;
      // GAS devuelve {ok,segmentos,total} en el NIVEL RAÍZ (no en data) → para que res.ok/res.error existan tras
      // el desempaque de _fetch, NO podemos usar _desempacarCatalogo (devuelve solo data). Resolvemos a mano:
      //   ok:false con *_OFF/APP_NO_AUTORIZADA → null (caé a GAS); otro error → lanza (rechazo de negocio = mismo
      //   error que GAS); ok:true → devolvemos el objeto RAÍZ {ok,segmentos,total} (paridad con la respuesta GAS).
      const out = await _sbRpcMOSWrite('actualizar_segmentos_precio', { p: {
        idProducto: p.idProducto != null ? String(p.idProducto) : undefined,
        segmentos: Array.isArray(p.segmentos) ? p.segmentos : [],
        usuario: _mosUsuario(p)
      } });
      if (out == null) return null;                 // sin token → GAS
      if (out.ok === false) {
        const err = out.error || 'rpc directo sin respuesta';
        if (/_OFF$/.test(err) || err === 'APP_NO_AUTORIZADA') return null;   // kill-switch/sin claim → GAS
        throw new Error(err);                                                // rechazo de negocio (paridad GAS)
      }
      // ok:true → {ok:true, segmentos:[...], total:N} (mismo shape RAÍZ que GAS actualizarSegmentosPrecio).
      return { ok: true, segmentos: out.segmentos || [], total: out.total || 0 };
    }

    if (action === 'subirFotoProducto') {
      // [CATÁLOGO DELETE-SAFE] Sube la foto a Supabase Storage (browser→bucket producto-fotos, máxima calidad) y
      // persiste foto_url en TODAS las filas del skuBase vía mos.set_foto_producto (paridad subirFotoProducto GAS).
      // El front (app.js:4843) lee r.ok!==false y r.fotoUrl → devolvemos {ok:true, skuBase, fotoUrl, fileId, actualizados}.
      const sku = p.skuBase != null ? String(p.skuBase) : '';
      const b64 = String(p.fotoBase64 || '').trim();
      const mime = String(p.mimeType || 'image/jpeg');
      if (!sku || !b64) return null;                // sin datos → que GAS valide (skuBase/fotoBase64 requeridos)
      let up;
      try { up = await _subirFotoStorageMOS(sku, b64, mime); }
      catch (e) {
        // sin token (Edge caída) → caé a GAS (sube a Drive, como hoy). Cualquier otro error de Storage (RLS/red)
        // tras flag ON: el front MOS no tiene cola de writes → caer a GAS subiría a Drive y duplicaría la foto en
        // dos backends. Pero como la persistencia (set_foto_producto) aún no ocurrió, NO hay doble-escritura de
        // foto_url. Para no romper el UX optimista, propagamos null SOLO sin token; el resto se propaga al UI.
        if (e && e.sinToken) return null;
        throw (e instanceof Error ? e : new Error('storage upload falló'));
      }
      // persistir la URL pública en mos.productos (todas las filas del skuBase)
      const out = await _sbRpcMOSWrite('set_foto_producto', { p: { skuBase: sku, fotoUrl: up.url } });
      if (out == null) return null;                 // sin token en la 2da llamada → GAS (raro; el upload ya pasó)
      if (out.ok === false) {
        const err = out.error || 'rpc directo sin respuesta';
        if (/_OFF$/.test(err) || err === 'APP_NO_AUTORIZADA') return null;   // flag server OFF → GAS
        throw new Error(err);
      }
      const d = (out.data && typeof out.data === 'object') ? out.data : {};
      // shape paritario con GAS: {skuBase, fotoUrl, fileId, actualizados}. fileId = path en Storage (para borrar).
      return { ok: true, skuBase: sku, fotoUrl: up.url, fileId: up.path, actualizados: d.actualizados || 0 };
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
      // ✅ [CUTOVER DELETE-SAFE · 167] RESUELTO: mos.crear_evaluacion AHORA corre los hooks DINERO server-side
      //    (materializar_liquidacion_dia AUTO + set_bonificacion_sancion con soloTipo + fusión de motivos),
      //    réplica EXACTA de _liqDiaRecomputar/_liqDiaSetBonSan (validado al centavo en validate_167). Por eso YA
      //    es seguro activar mos_eval_directo aun con bonificación/sanción/ajuste (sin Sheet, GAS no podría correr
      //    esos hooks → el server los asume). Con el flag OFF (default) sigue siendo 100% GAS, idéntico a hoy.
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
        bonificacion: p.bonificacion, bonificacionMotivo: p.bonificacionMotivo,
        // [CUTOVER DELETE-SAFE] _ajusteTocado/ajusteTipo: la RPC mos.crear_evaluacion (167) los usa para
        // materializar bon/san en LIQUIDACIONES_DIA con soloTipo + fusión de motivos (réplica _liqDiaSetBonSan).
        _ajusteTocado: p._ajusteTocado, ajusteTipo: p.ajusteTipo
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
  //
  // ⚠️ MODELO DUAL-WRITE: SOLO el catálogo (pilot) conserva escritura directa (su gate _mosCatalogoDirecto =
  //    maestro OR mos_catalogo_directo). El RESTO de módulos (proveedores/pedidos/pagos/provprod/gastos/eval/
  //    horario/jornadas/liquidaciones) NO va por escritura directa: su escritura va SIEMPRE por GAS, que hace
  //    _dualWriteMOS → espeja la sombra Supabase. Por eso esas acciones se RETIRARON de este mapa: al prender
  //    su flag de LECTURA (mos_<modulo>_lectura) la LECTURA va directa pero la ESCRITURA sigue por GAS.
  //    El despachador _postDirectoMOS conserva los `if(action===...)` de esas acciones (código muerto inocuo,
  //    nunca alcanzado porque no están en este mapa) → reactivar escritura-directa-pura sería re-agregarlas acá.
  const _MOS_POST_DIRECTO = {
    crearProducto:              _mosCatalogoDirecto,
    actualizarProducto:         _mosCatalogoDirecto,
    publicarPrecio:             _mosCatalogoDirecto,
    crearEquivalencia:          _mosCatalogoDirecto,
    actualizarEquivalencia:     _mosCatalogoDirecto,
    // [CATÁLOGO DELETE-SAFE] segmentos de precio (graneles) + foto a Storage — las 2 piezas que faltaban para
    // que el catálogo NO dependa de la Hoja en NINGUNA escritura. Gate _mosCatalogoDirecto (igual que el resto
    // del catálogo). OFF (default) ⇒ recto a GAS (segmentos a la Hoja; foto a Drive) = IDÉNTICO a hoy.
    actualizarSegmentosPrecio:  _mosCatalogoDirecto,
    subirFotoProducto:          _mosCatalogoDirecto,
    // [PILOTO ESCRITURA DIRECTA · PROVEEDORES] Re-cableado de la escritura directa de proveedores como PILOTO
    // (no es dinero → menor riesgo). Gated por _mosProveedoresDirecto (maestro OR mos_proveedores_directo, default
    // OFF). El despachador _postDirectoMOS YA tiene los `if(action==='crearProveedor'/'actualizarProveedor')`
    // (mapean payload→RPC mos.crear_proveedor / mos.actualizar_proveedor, idempotencia por local_id, paridad de
    // retorno verificada con rollback). Con el gate OFF (default) NUNCA se evalúa el directo → va recto a GAS,
    // IDÉNTICO a hoy. ⚠️ El cutover de ESCRITURA exige además apagar el sync de proveedores (MOS_SYNC_OFF_TABLAS):
    // ver RUNBOOK. Prenderlo SIN apagar el sync → el sync Hoja→sombra pisa lo escrito directo (incoherencia).
    crearProveedor:             _mosProveedoresDirecto,
    actualizarProveedor:        _mosProveedoresDirecto,
    // [CUTOVER DELETE-SAFE · DINERO] eval + jornadas en DIRECTO-PURO. Habilitado SOLO si el gate DIRECTO está ON
    // (default OFF) Y el dual-write de ese módulo está OFF (el dual-write se evalúa antes y, si está ON, gana).
    // Estado de cutover esperado: mos_*_dualwrite=0 + mos_*_directo=1. Ahora es SEGURO porque la RPC server-side
    // corre los hooks DINERO:
    //   · crearEvaluacion → mos.crear_evaluacion (167) materializa LIQUIDACIONES_DIA (AUTO + bon/san + fusión de
    //     motivos + soloTipo), réplica EXACTA de _liqDiaRecomputar/_liqDiaSetBonSan (validado al centavo).
    //   · registrarJornada → mos.registrar_jornada (84) idempotente por localId+PK (DINERO jornal).
    // Sin Sheet, GAS no podría correr los hooks → por eso el cutover MUEVE la escritura al server (delete-safe).
    crearEvaluacion:            _mosEvalDirecto,
    registrarJornada:           _mosJornadasDirecto,
    eliminarJornada:            _mosJornadasDirecto,
    rehabilitarJornada:         _mosJornadasDirecto
    // [DUAL-WRITE] pedidos/pagos/provprod/gastos/horario/liqdia: SIN entrada acá → su escritura va SIEMPRE por
    // GAS (dual-write espeja la sombra). marcarPagos/anularPago/recomputarLiquidacionDia tampoco (incompatibles).
  };

  // Acciones que soportan DUAL-WRITE (GAS primero = verdad, luego espejo best-effort a Supabase), CADA UNA con
  // su gate dedicado (default OFF). DISTINTO del directo-puro de _MOS_POST_DIRECTO: aquí GAS SIEMPRE escribe.
  // Con el gate OFF (default) _postMOS ni siquiera evalúa esta rama → va por el camino de hoy (solo GAS).
  // PRECEDENCIA: el dual-write se evalúa ANTES que el directo-puro y, si está ON, NO se entra al directo-puro
  // (son modos mutuamente excluyentes para la misma acción). Reactivar más módulos = agregar entradas acá.
  const _MOS_POST_DUALWRITE = {
    crearProveedor:      _mosProveedoresDualWrite,
    actualizarProveedor: _mosProveedoresDualWrite,
    // [DUAL-WRITE · LOTE EXTENDIDO] Mismas reglas: GAS primero (verdad + hooks), espejo best-effort después.
    // Cada action tiene case en el router GAS (Code.gs) Y branch cableado en _postDirectoMOS. Gate dedicado, OFF.
    // pedidos (81): SOLO crearPedido. actualizarPedido NO va: no existe case en el router GAS (Code.gs) →
    //   con el gate ON GAS respondería "acción no reconocida" → _fetch lanzaría → CAMBIARÍA el comportamiento.
    crearPedido:                 _mosPedidosDualWrite,
    // proveedor-producto (81): agregar/actualizar comparten la RPC mos.upsert_proveedor_producto en el dispatcher.
    //   eliminarProductoProveedor NO va: no existe RPC mos.eliminar_proveedor_producto ni branch en _postDirectoMOS.
    agregarProductoProveedor:    _mosProvProdDualWrite,
    actualizarProductoProveedor: _mosProvProdDualWrite,
    // gastos (83) ⚠️DINERO: GAS escribe igual que hoy; el espejo es aditivo a la sombra (idempotente por local_id+PK).
    registrarGasto:              _mosGastosDualWrite,
    eliminarGasto:               _mosGastosDualWrite,
    // jornadas (84) ⚠️DINERO jornal: registrarJornada la llama el front hoy; eliminar/rehabilitar son FORWARD-LOOKING
    //   (el front no las llama hoy, pero el case GAS y el branch dispatcher existen → inertes hasta que se usen).
    //   importarJornadasDesdeCajas NO va: no existe RPC mos.importar_jornadas ni branch en _postDirectoMOS.
    registrarJornada:            _mosJornadasDualWrite,
    eliminarJornada:             _mosJornadasDualWrite,
    rehabilitarJornada:          _mosJornadasDualWrite,
    // evaluaciones (82): GAS sigue corriendo _liqDiaRecomputar/_liqDiaSetBonSan (hooks DINERO); el espejo es aditivo.
    //   SEGURO en dual-write (a diferencia del directo-puro, que se los saltaría).
    crearEvaluacion:             _mosEvalDualWrite
  };

  // POST con escritura directa opcional. Con el gate de la acción OFF (default) es IDÉNTICO a hoy: ni
  // siquiera evalúa el directo → va recto a _fetch('POST') → GAS. Con el gate ON + token + RPC viva, escribe
  // directo; si el directo dice "no commiteó" (null) → GAS; si lanza (negocio/timeout) → PROPAGA (no GAS).
  async function _postMOS(action, p) {
    // ── [DUAL-WRITE] Modo PREFERIDO y SEGURO (gate dedicado, default OFF). Se evalúa ANTES que el directo-puro.
    //   1) GAS primero (AWAIT): escribe la Hoja = VERDAD y devuelve su shape (idéntico a hoy) + corre su propio
    //      _dualWriteMOS → espeja la sombra. Ese resultado es el que se DEVUELVE al front.
    //   2) SOLO si GAS resolvió ok: best-effort fire-and-forget _postDirectoMOS → upsert directo a la MISMA RPC
    //      mos.crear_proveedor/actualizar_proveedor, para asegurar la sombra fresca aunque el urlfetch de GAS
    //      haya fallado por cuota. Su fallo (.catch) NO propaga, NO afecta el retorno (el sync/GAS reconcilia).
    //   3) Si GAS LANZA (red/negocio/timeout): se PROPAGA tal cual (comportamiento de hoy) y NO se escribe
    //      directo → la sombra NUNCA queda ADELANTE de la Hoja. _postDirectoMOS reusa p.localId (estampado por
    //      GAS o estable) → si llega a commitear, dedupea contra lo que el _dualWriteMOS de GAS ya espejó.
    const dwGate = _MOS_POST_DUALWRITE[action];
    if (dwGate && dwGate()) {
      const res = await _fetch('POST', { action, ...p });   // GAS = verdad; lanza ⇒ propaga (no se escribe directo)
      try {
        const pr = _postDirectoMOS(action, p);              // best-effort: upsert a la sombra (puede ser null→no-op)
        if (pr && typeof pr.then === 'function') pr.then(function(){}, function(){});  // swallow async (null/throw)
      } catch (_) { /* swallow sync throw: el espejo a la sombra es best-effort, jamás afecta el retorno */ }
      return res;                                            // shape GAS, bit-idéntico a la rama de hoy
    }

    const gate = _MOS_POST_DIRECTO[action];
    if (gate && gate()) {
      // throws de _postDirectoMOS se PROPAGAN (negocio = mismo error que GAS; timeout = anti-duplicado).
      const d = await _postDirectoMOS(action, p);
      if (d != null) {
        // [CAVEAT-CLOSE HORARIOS] ⚠️ INALCANZABLE en el modelo dual-write: setHorarioApp ya NO está en
        // _MOS_POST_DIRECTO (su escritura va SIEMPRE por GAS), así que `gate` es undefined y nunca se entra
        // acá. Se conserva por si se re-introdujera escritura-directa-pura de horario. Detalle histórico:
        // El directo escribe SOLO la sombra Supabase (mos.config_horarios_apps),
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

  // ── [INTERRUPTOR CENTRAL] Arranque: leer los flags de la flota una vez al cargar el módulo y refrescar cada
  //    ~2min (propagación del flip/kill server-side, sin recargar la PWA). Fire-and-forget: si falla, _mosFlag
  //    cae a localStorage/MOS_CONFIG (INERTE/seguro). El primer fetch corre en background; las lecturas/escrituras
  //    directas de FASE 1/2 ya consultan _serverFlags vía _mosFlag → en cuanto resuelve, la flota está al día.
  try {
    _cargarFlagsMOS();
    const _flagsTid = setInterval(_cargarFlagsMOS, 120000);
    try { if (_flagsTid && _flagsTid.unref) _flagsTid.unref(); } catch (_) {}
  } catch (_) { /* nunca romper el arranque del módulo por los flags */ }

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
      // [DUAL-WRITE · LOTE PROVEEDORES/PEDIDOS/PAGOS/PROVPROD/JORNADAS] read-paths directos (RPCs 94). Cada uno
      // gated por SU gate de LECTURA _mos<Modulo>Lectura (maestro OR mos_<modulo>_lectura). La ESCRITURA de estos
      // módulos ya NO va directa: va SIEMPRE por GAS (dual-write → GAS espeja la sombra). Así, prender la lectura
      // de un módulo NO toca su escritura. Gate de lectura OFF (default) ⇒ recto a GAS = IDÉNTICO a hoy.
      if (action === 'getProveedores') {
        return _conFallbackMOS(
          () => _getProveedoresDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosProveedoresLectura
        );
      }
      if (action === 'getPedidos') {
        return _conFallbackMOS(
          () => _getPedidosDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosPedidosLectura
        );
      }
      if (action === 'getPagos') {
        return _conFallbackMOS(
          () => _getPagosDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosPagosLectura
        );
      }
      if (action === 'getProveedorProductos') {
        return _conFallbackMOS(
          () => _getProveedorProductosDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosProvProdLectura
        );
      }
      if (action === 'getJornadas') {
        return _conFallbackMOS(
          () => _getJornadasDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosJornadasLectura
        );
      }
      // [DUAL-WRITE · EVAL] getEvaluacionesDia → lectura directa (RPC evaluaciones_dia, 98). Gated por el gate de
      // LECTURA _mosEvalLectura (maestro OR mos_eval_lectura) → la escritura crearEvaluacion ya NO va directa (GAS
      // siempre, dual-write). Flag de lectura OFF (default) ⇒ recto a GAS = IDÉNTICO a hoy. Array camelCase paritario.
      if (action === 'getEvaluacionesDia') {
        return _conFallbackMOS(
          () => _getEvaluacionesDiaDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosEvalLectura
        );
      }
      // [Optimización] getPersonalDiaFast → lectura directa (RPC personal_dia_lista, 105). Lee la sombra
      // liquidaciones_dia (materializada), shape paritario con getPersonalDiaFast. Gated por el MAESTRO
      // _mosLecturaDirecta (mismo que las demás). Gate OFF ⇒ recto a GAS = IDÉNTICO a hoy. Fallback total a GAS.
      if (action === 'getPersonalDiaFast') {
        return _conFallbackMOS(
          () => _getPersonalDiaFastDirecto(p),
          () => _fetch('GET', { action, ...p }),
          _mosLecturaDirecta
        );
      }
      // [Optimización] catálogos base → lectura directa (RPCs 106). Maestro _mosLecturaDirecta + fallback GAS.
      if (action === 'getEquivalencias') {
        return _conFallbackMOS(() => _getEquivalenciasDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta);
      }
      if (action === 'getCategorias') {
        return _conFallbackMOS(() => _getCategoriasDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta);
      }
      // [Optimización] catálogos/config (107) → lectura directa. Maestro + fallback GAS. Nombre de acción no
      // matcheado ⇒ recto a GAS (no rompe; solo no acelera ese caso).
      if (action === 'getPersonalMaster') { return _conFallbackMOS(() => _getPersonalMasterDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getZonas')          { return _conFallbackMOS(() => _getZonasDirecto(p),          () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getEstaciones')     { return _conFallbackMOS(() => _getEstacionesDirecto(p),     () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getImpresoras')     { return _conFallbackMOS(() => _getImpresorasDirecto(p),     () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getSeries')         { return _conFallbackMOS(() => _getSeriesDirecto(p),         () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // [Optimización] read-paths COMPLEJOS (108/109/110): finanzas del día (P&L), productos-proveedor-con-stock,
      // histórico proveedor. Maestro _mosLecturaDirecta + fallback total a GAS + gate _fresh interno.
      if (action === 'getFinanzasDia') {
        return _conFallbackMOS(() => _getFinanzasDiaDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta);
      }
      if (action === 'getProductosProveedorConStock') {
        return _conFallbackMOS(() => _getProductosProveedorStockDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta);
      }
      if (action === 'getHistoricoProveedor') {
        return _conFallbackMOS(() => _getHistoricoProveedorDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta);
      }
      // [Optimización · vistas cross-app cajas/warehouse] — maestro + fallback GAS + gate _fresh.
      if (action === 'getCierresCaja')         { return _conFallbackMOS(() => _getCierresCajaDirecto(p),         () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getMermasWarehouse')     { return _conFallbackMOS(() => _getMermasWarehouseDirecto(p),     () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getEnvasadosWarehouse')  { return _conFallbackMOS(() => _getEnvasadosWarehouseDirecto(p),  () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getAlertasWarehouse')    { return _conFallbackMOS(() => _getAlertasWarehouseDirecto(p),    () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getRotacionProductos')   { return _conFallbackMOS(() => _getRotacionProductosDirecto(p),   () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getCatalogoStockResumen'){ return _conFallbackMOS(() => _getCatalogoStockResumenDirecto(p),() => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getDashboardAlmacen')    { return _conFallbackMOS(() => _getDashboardAlmacenDirecto(p),    () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // [Optimización · portables 114/115/116]
      if (action === 'getConfig')              { return _conFallbackMOS(() => _getConfigDirecto(p),             () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getDispositivos')        { return _conFallbackMOS(() => _getDispositivosDirecto(p),       () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getLiquidacionesPendientes') { return _conFallbackMOS(() => _getLiqPendientesDirecto(p),  () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getLiquidacionesPagadas' || action === 'getLiquidacionesEmitidas') { return _conFallbackMOS(() => _getLiqPagadasDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getLiquidacionesVetadas') { return _conFallbackMOS(() => _getLiqVetadasDirecto(p),        () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getPagoDetalle')         { return _conFallbackMOS(() => _getPagoDetalleDirecto(p),        () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getLiqDiaBonSan')        { return _conFallbackMOS(() => _getLiqDiaBonSanDirecto(p),       () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getProveedoresQueVenden'){ return _conFallbackMOS(() => _getProveedoresQueVendenDirecto(p),() => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getVendedoresMEBloqueados'){ return _conFallbackMOS(() => _getVendedoresMEBloqueadosDirecto(p),() => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getDispositivosBloqueados'){ return _conFallbackMOS(() => _getDispositivosBloqueadosDirecto(p),() => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getNotificacionesConfig'){ return _conFallbackMOS(() => _getNotificacionesConfigDirecto(p),() => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getAuditoriaAdmin')      { return _conFallbackMOS(() => _getAuditoriaAdminDirecto(p),     () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getAuditoriaIntegridad' && !p.run) { return _conFallbackMOS(() => _getAuditoriaIntegridadDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getProductosEditadosRecientes') { return _conFallbackMOS(() => _getProductosEditadosRecientesDirecto(p), () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // [Optimización · cross-app 117/118/119]
      if (action === 'getRankingZonas')        { return _conFallbackMOS(() => _getRankingZonasDirecto(p),       () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // [RECABLEADO 2026-06-16 · optimizado SQL 123] productos_sin_venta: 13.8s→0.6s (subqueries correlacionadas
      // sobre CTE → LEFT JOIN). Bajo statement_timeout 8s, paridad de datos verificada (mismo set de 208).
      if (action === 'getProductosSinVenta')   { return _conFallbackMOS(() => _getProductosSinVentaDirecto(p),  () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getAlertasOperativas')   { return _conFallbackMOS(() => _getAlertasOperativasDirecto(p),  () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getGuiasYPreingresos')   { return _conFallbackMOS(() => _getGuiasYPreingresosDirecto(p),  () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getOperacionesUnificadas'){ return _conFallbackMOS(() => _getOperacionesUnificadasDirecto(p),() => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getStockUnificado')      { return _conFallbackMOS(() => _getStockUnificadoDirecto(p),     () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // [RECABLEADO 2026-06-16 · optimizado SQL 123] insights_stock: 9.8s→0.4s. Bajo timeout, paridad byte-idéntica.
      if (action === 'getInsightsStock')       { return _conFallbackMOS(() => _getInsightsStockDirecto(p),      () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getAnaliticaProducto')   { return _conFallbackMOS(() => _getAnaliticaProductoDirecto(p),  () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'meCajasAbiertas')        { return _conFallbackMOS(() => _getMeCajasAbiertasDirecto(p),    () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'meCobrosEnVuelo')        { return _conFallbackMOS(() => _getMeCobrosEnVueloDirecto(p),    () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // [Optimización · portables 124]
      if (action === 'getTarjetaWA')           { return _conFallbackMOS(() => _getTarjetaWADirecto(p),          () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // meConsultarCliente: si la sombra NO tiene el doc (encontrado:false), NO servir directo → caer a GAS
      // (preserva el lookup SUNAT/RENIEC en vivo que solo GAS hace). El helper igual devuelve el objeto; el guard
      // de "encontrado" lo aplica aquí envolviendo el directo para que el null caiga al fallback.
      if (action === 'meConsultarCliente')     { return _conFallbackMOS(async () => { const r = await _getMeConsultarClienteDirecto(p); return (r && r.encontrado) ? r : null; }, () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getResumenTodosDia')     { return _conFallbackMOS(() => _getResumenTodosDiaDirecto(p),    () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      if (action === 'getEcoStatus')           { return _conFallbackMOS(() => _getEcoStatusDirecto(p),         () => _fetch('GET', { action, ...p }), _mosLecturaDirecta); }
      // [IMPRESORAS Edge] listar/verificar impresoras 100% Supabase (Edge `printers`, shape paritario con GAS) +
      // fallback total a GAS. Gate dedicado _mosImpresorasPNEdge (maestro OR mos_impresoras_pn_edge), default OFF
      // ⇒ recto a GAS = IDÉNTICO a hoy. CAMINO COMPARTIDO (liq/costos/picker) → shape BYTE-equivalente.
      if (action === 'listarImpresorasPN' || action === 'getPrintNodePrinters') {
        return _conFallbackMOS(() => _listarImpresorasEdge(),       () => _fetch('GET', { action, ...p }), _mosImpresorasPNEdge);
      }
      if (action === 'verificarImpresoraAhora') {
        return _conFallbackMOS(() => _verificarImpresoraEdge(p),    () => _fetch('GET', { action, ...p }), _mosImpresorasPNEdge);
      }
      return _fetch('GET',  { action, ...p });
    },
    // [DUAL-WRITE] post → escritura directa Supabase SOLO para el catálogo (pilot, gate mos_catalogo_directo /
    // maestro). TODO el resto de escrituras (proveedores/pedidos/pago/provprod/gastos/eval/horario/jornadas/
    // liquidaciones) va SIEMPRE por GAS (dual-write → GAS espeja la sombra), aunque su flag de LECTURA esté ON.
    // Con el gate de catálogo OFF (default) ⇒ IDÉNTICO a hoy (va recto a GAS).
    post: (action, p = {}) => {
      // [DUAL-WRITE · HORARIO] getHorariosApps es una LECTURA enviada por POST (el front la llama con API.post).
      // Read-path directo (RPC horarios_apps, 98) gated por el gate de LECTURA _mosHorarioLectura (maestro OR
      // mos_horario_lectura). La escritura setHorarioApp ya NO va directa (GAS siempre, dual-write). Gate de
      // lectura OFF (default) ⇒ recto a GAS = IDÉNTICO a hoy. Devuelve el OBJETO {<app>:{...}} igual que GAS;
      // el consumidor lee `(r && r.data) || r` → ambos sirven.
      if (action === 'getHorariosApps') {
        return _conFallbackMOS(
          () => _getHorariosAppsDirecto(p),
          () => _fetch('POST', { action, ...p }),
          _mosHorarioLectura
        );
      }
      // [Optimización · portables 124] meGetCreditosPendientes es una LECTURA enviada por POST (API.post,
      // app.js:24917). Read-path directo (RPC me_creditos_pendientes, 124) gated por _mosLecturaDirecta.
      // Devuelve el OBJETO {grupos,totalAcumulado,totalTickets} (r.data); el consumidor lee d.grupos.
      // Gate OFF (default) ⇒ recto a GAS = idéntico a hoy.
      if (action === 'meGetCreditosPendientes') {
        return _conFallbackMOS(
          () => _getMeCreditosPendientesDirecto(p),
          () => _postMOS(action, p),
          _mosLecturaDirecta
        );
      }
      return _postMOS(action, p);
    },
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
      flag:           _mosFlag,             // gate genérico (FASE 1: flags por-acción) — server||local||MOS_CONFIG
      // [INTERRUPTOR CENTRAL] flags de la flota leídos de mos.get_flags(). Para diagnóstico/forzar refresco.
      recargarFlags:  _cargarFlagsMOS,      // re-lee mos.get_flags() ahora (devuelve promesa) — diagnóstico/test
      serverFlags:    () => Object.assign({}, _serverFlags),  // snapshot de los flags server vigentes — diagnóstico
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
      // [DUAL-WRITE] gates *_DIRECTO por-operación (default OFF). ⚠️ Ya NO gobiernan read ni write cableado
      // (la escritura va por GAS; la lectura usa los gates *Lectura de abajo). Se exponen solo para diagnóstico.
      // EXCEPCIÓN: proveedoresDirecto SÍ gobierna la escritura directa (piloto re-cableado en _MOS_POST_DIRECTO).
      proveedoresDirecto: _mosProveedoresDirecto,  // ¿escritura DIRECTO-PURO de proveedores ON? (gate de crear/actualizarProveedor; exige sync-off)
      proveedoresDualWrite: _mosProveedoresDualWrite, // ¿escritura DUAL-WRITE de proveedores ON? (GAS verdad + espejo best-effort; NO apaga sync) — diagnóstico/test
      // [DUAL-WRITE · LOTE EXTENDIDO] gates dedicados (default OFF). GAS verdad + espejo best-effort, NO apaga sync.
      pedidosDualWrite:   _mosPedidosDualWrite,    // ¿escritura DUAL-WRITE de pedidos ON? (crearPedido) — diagnóstico/test
      provprodDualWrite:  _mosProvProdDualWrite,   // ¿escritura DUAL-WRITE de proveedor-producto ON? (agregar/actualizar) — diagnóstico/test
      gastosDualWrite:    _mosGastosDualWrite,     // ¿escritura DUAL-WRITE de gastos ON? (registrar/eliminar; DINERO) — diagnóstico/test
      jornadasDualWrite:  _mosJornadasDualWrite,   // ¿escritura DUAL-WRITE de jornadas ON? (registrar/eliminar/rehabilitar; DINERO) — diagnóstico/test
      evalDualWrite:      _mosEvalDualWrite,       // ¿escritura DUAL-WRITE de evaluaciones ON? (crearEvaluacion) — diagnóstico/test
      pedidosDirecto:     _mosPedidosDirecto,      // (diagnóstico) ¿flag mos_pedidos_directo ON?
      pagosDirecto:       _mosPagosDirecto,        // (diagnóstico) ¿flag mos_pagos_directo ON?
      provprodDirecto:    _mosProvProdDirecto,     // (diagnóstico) ¿flag mos_provprod_directo ON?
      // [DUAL-WRITE] gates de LECTURA por módulo (maestro OR mos_<modulo>_lectura). Estos SÍ gobiernan los
      // read-paths directos. Default OFF → INERTE. (gastos/liqdia/etiq no tienen read-path directo cableado.)
      proveedoresLectura: _mosProveedoresLectura,  // ¿lectura directa de proveedores ON?
      pedidosLectura:     _mosPedidosLectura,      // ¿lectura directa de pedidos ON?
      pagosLectura:       _mosPagosLectura,        // ¿lectura directa de pagos ON?
      provprodLectura:    _mosProvProdLectura,     // ¿lectura directa de proveedor-producto ON?
      jornadasLectura:    _mosJornadasLectura,     // ¿lectura directa de jornadas ON?
      evalLectura:        _mosEvalLectura,         // ¿lectura directa de evaluaciones ON?
      horarioLectura:     _mosHorarioLectura,      // ¿lectura directa de horarios ON?
      // [FASE 2] read-paths directos de estos módulos (RPCs 94, array o null→GAS) — diagnóstico/test de paridad.
      getProveedoresDirecto:        _getProveedoresDirecto,
      getPedidosDirecto:            _getPedidosDirecto,
      getPagosDirecto:              _getPagosDirecto,
      getProveedorProductosDirecto: _getProveedorProductosDirecto,
      // [FASE 2 · LOTE GASTOS/EVAL/HORARIO] gates por-módulo (default OFF). Etiquetas NO se cablea (el front
      // MOS no llama marcarVisto/marcarPegada ni crear-etiqueta). Ver REPORTE.
      gastosDirecto:      _mosGastosDirecto,       // (diagnóstico) ¿flag mos_gastos_directo ON?
      evalDirecto:        _mosEvalDirecto,         // (diagnóstico) ¿flag mos_eval_directo ON?
      horarioDirecto:     _mosHorarioDirecto,      // (diagnóstico) ¿flag mos_horario_directo ON?
      etiqDirecto:        _mosEtiqDirecto,         // (diagnóstico) ¿flag mos_etiq_directo ON? (sin consumidor front MOS)
      // [FASE 2 · 98] read-paths directos eval/horario/etiq (array u objeto o null→GAS) — diagnóstico/paridad.
      getEvaluacionesDiaDirecto:    _getEvaluacionesDiaDirecto,    // RPC evaluaciones_dia (array o null→GAS)
      getHorariosAppsDirecto:       _getHorariosAppsDirecto,       // RPC horarios_apps (objeto keyed por app o null→GAS)
      getEtiquetasPendientesDirecto:_getEtiquetasPendientesDirecto, // RPC etiquetas_pendientes (array o null→GAS) — sin consumidor
      // [FASE 2 · LOTE JORNALES/LIQUIDACIONES] gates por-grupo (default OFF, DINERO). marcarPagos/anularPago/
      // recomputarLiquidacionDia NO cableados (shape/seguridad incompatibles con la RPC) — ver REPORTE.
      jornadasDirecto:    _mosJornadasDirecto,     // (diagnóstico) ¿flag mos_jornadas_directo ON?
      getJornadasDirecto: _getJornadasDirecto,     // read-path directo jornadas (array o null→GAS) — diagnóstico
      liqdiaDirecto:      _mosLiqdiaDirecto,       // (diagnóstico) ¿flag mos_liqdia_directo ON?
      localId:            _mosLocalId,             // genera/estampa local_id estable por gesto — test de idempotencia
      // [RIZ · CAPA 4] gate del módulo Zona + helpers directos (wrappers mos.zona_* → me.zona_*). Default OFF → INERTE.
      zonaModulo:         _mosZonaModulo,          // ¿flag mos_zona_modulo ON? (gobierna la visibilidad del nav + loadZona)
      zonaPanelDirecto:        _zonaPanelDirecto,
      zonaTendenciaDirecto:    _zonaTendenciaDirecto,
      zonaTicketDiaDirecto:    _zonaTicketDiaDirecto,
      zonaLotesHistorialDirecto: _zonaLotesHistorialDirecto,
      zonaAjustarStock:        _zonaAjustarStock,
      zonaPedirAlmacen:        _zonaPedirAlmacen,
      // [IMPRESORAS Edge] gate + helpers de listar/verificar vía Edge `printers` (default OFF → GAS). Diagnóstico/test.
      impresorasPNEdge:        _mosImpresorasPNEdge,    // ¿flag mos_impresoras_pn_edge (o maestro) ON?
      listarImpresorasEdge:    _listarImpresorasEdge,   // op:'list' (array shape-GAS o null→GAS)
      verificarImpresoraEdge:  _verificarImpresoraEdge  // op:'verify' (objeto shape-GAS o null→GAS)
    },
    // [RIZ · CAPA 4] API pública del módulo Zona. 100% Supabase (wrappers mos.zona_* → me.zona_*), sin GAS.
    // SOLO se invocan desde la vista 'zona' de app.js, que a su vez solo se abre con el flag mos_zona_modulo
    // ON. Con el flag OFF nada de esto se ejecuta → la app es idéntica a hoy. Todos aceptan {zona} (o {zonaId}).
    zona: {
      moduloOn:        _mosZonaModulo,          // bool: ¿el módulo está habilitado?
      panel:           _zonaPanelDirecto,       // mos.zona_panel(p)            → {ok,data:{zona,filtro,items:[...]},_fresh}
      tendencia:       _zonaTendenciaDirecto,   // mos.tendencia_zona(p)        → {ok,data:{zona,semanas,umbral,items:[...]},_fresh}
      ticketDia:       _zonaTicketDiaDirecto,   // mos.zona_ticket_dia(p)       → {ok,data:{zona,fecha,origen,lotes:[...]},_fresh}
      lotesHistorial:  _zonaLotesHistorialDirecto, // mos.zona_lotes_historial(p) → {ok,data:{...,items:[lotes FIFO]},_fresh}
      ajustarStock:    _zonaAjustarStock,       // mos.zona_ajustar_stock(p)    → {ok,data} (Supabase-only + log)
      pedirAlmacen:    _zonaPedirAlmacen,       // mos.zona_pedir_almacen(p)    → {ok,data} (Supabase-only + log)
      marcarAccion:    _zonaMarcarAccion,       // mos.zona_marcar_accion(p {skuBase,accion}) → {ok,[dedup],data} (perro: NO muta stock)
      // [RIZ · CAPA 5] nuevos: lista de compras (lectura), impresión 80mm (Edge riz-print), IA real (Edge /functions/ia)
      listaCompras:    _zonaListaComprasDirecto,// mos.zona_lista_compras(p)    → {ok,data:{zona,semana,items:[...]},_fresh}
      imprimir:        _zonaImprimir,           // Edge riz-print {tipo,zona,fecha|semana,printerId} → {ok,printJobId}
      ia:              _zonaIA,                 // Edge /functions/ia {messages,system?,model?} → JSON Claude (.content[0].text)
      // [ASEGURAR DATA] diagnóstico de stock — SOLO LECTURA (no muta stock). Botón master + historial en el card.
      diferencias:     _zonaDiferencias,        // mos.stock_diferencias_listar(p {ambito?,zona?}) → {ok,data:{total,items:[...]},_fresh}
      kardexHistorial: _zonaKardexHistorial,    // mos.zona_kardex_historial(p {zona,codBarra|skuBase}) → {ok,data:{movimientos:[...]},_fresh}
      almacenKardex:   _almacenKardexHistorial, // mos.almacen_kardex_historial(p {codBarra|skuBase}) → {ok,data:{movimientos:[...]},_fresh}
      // [RIZ · TRASLADO VERIFICADO] ingreso por almacén con ESCANEO (supabase/141). El stock real (me.stock_zonas)
      // queda GATED/INERTE en el backend (zona_traslado_cerrar.v_aplicar_stock=false); sólo registra kardex + verificación.
      trasladosPendientes: _zonaTrasladosPendientes, // mos.zona_traslados_pendientes(p {zona}) → {ok,data:{total,items:[{idGuia,fecha,lineas,totalEnviado,edadSeg,edadLbl,...}]},_fresh}
      trasladosResumen:    _zonaTrasladosResumen,    // mos.zona_traslados_resumen(p {zona})    → {ok,data:{completo,incompleto,pendiente,verificaciones:[...]},_fresh}
      trasladoGuia:        _zonaTrasladoGuia,        // mos.zona_traslado_guia(p {idGuia})      → {ok,data:{idGuia,zona,verificada,lineas:[{codBarra,descripcion,enviado}]},_fresh}
      trasladoCerrar:      _zonaTrasladoCerrar,      // mos.zona_traslado_cerrar(p {idGuia,escaneados:[{codBarra,cantidad}]}) → {ok,[dedup],stockAplicado,data:{estado,total_*,detalle}}
      baselineTraslados:   _zonaBaselineTraslados    // mos.zona_baseline_traslados(p {zona?}) → {ok,marcadas,total_pendientes_antes} — marca guías existentes como BASELINE (1 sola vez)
    },
  };
})();
