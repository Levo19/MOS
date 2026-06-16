// ════════════════════════════════════════════════════════════════════
// DeviceAuth — módulo compartido de verificación de dispositivos
// v1.0.16 — 2026-06-16 — FASE 3b: UX MODERNO/OPTIMISTA/FLUIDO + 2 bugs reales.
//   ┌─ BUG 1 "(sin id)" (reportado en WH al "activar in-situ") ────────────────
//   │ El overlay/modal renderizaban `_state.deviceId || '(sin id)'` de forma
//   │ SÍNCRONA. Pero el deviceId se resuelve ASYNC en init() vía _resolverDeviceId
//   │ (race de 3 stores hasta 3s). El overlay "Verificando" se pinta ANTES de que
//   │ resuelva → _state.deviceId === null → "(sin id)". FIX: el nodo del UUID se
//   │ registra en _state.devIdNodes y _setDeviceId() lo actualiza EN VIVO cuando
//   │ resuelve. Mientras tanto muestra "generando ID…" (no "(sin id)"). Copiable
//   │ siempre que ya haya id.
//   ├─ BUG 2 flujo NO optimista / parpadeo "sin autorización" ─────────────────
//   │ Tras aprobar in-situ, el módulo recargaba y RE-VERIFICABA contra el backend;
//   │ si la sombra/hoja todavía no propagó, el re-verify devolvía NO_REGISTRADO/
//   │ PENDIENTE → la app PARPADEABA "equipo sin autorización" antes de entrar.
//   │ FIX OPTIMISTA: (a) al aprobar OK → check SVG trazado + transición DIRECTA a
//   │ la app por evento `deviceauth:authorized` + onAuth(), SIN reload duro si la
//   │ app ya está montada (fade-out overlay / fade-in app). (b) RED ANTI-RETROCESO:
//   │ tras una aprobación exitosa marcamos _state.recienAprobado=true (+ marca de
//   │ tiempo en localStorage 'da_optimista_ts'); mientras esté vigente (ventana
//   │ 90s), un re-verify SILENCIOSO que devuelva NO_REGISTRADO/PENDIENTE NO baja la
//   │ app a estado de bloqueo (fail-soft) — sólo INACTIVO/SUSPENDIDO/forzar_reverify
//   │ (revocación REAL) puede cerrar. Así nunca se retrocede a "sin autorización"
//   │ inmediatamente después de aprobar. El reload (cuando ocurre) hereda la marca.
//   └──────────────────────────────────────────────────────────────────────────
//   UX MODERNO (mockups DISENO §3): spinner suave sin parpadeo · UUID visible/
//   copiable con ✓+vibrate · clave 8 casillas OTP (auto-avanza, auto-submit al 8º,
//   inputmode numeric) · submit optimista ("Activando…") · clave mala → shake rojo
//   + buzz + vibrate, limpia sin perder contexto · ÉXITO = check SVG que se traza +
//   vibrate(40) + acorde corto · transición suave a la app · revocado = shake +
//   tono grave. Triple feedback (sonoro+visual+háptico). prefers-reduced-motion →
//   estados sin animación. iOS-safe (webkitAudioContext en gesto, no dvh). NO toca
//   la lógica Fase 3a (RPCs/fallback/flag) — sólo el UX y la SECUENCIA de estados.
// v1.0.15 — 2026-06-16 — FASE 3a: REGISTRO/VERIFICACIÓN/APROBACIÓN cableados
//   a las RPCs Supabase de Fase 1 (SQL 100), CON FALLBACK a GAS, detrás del
//   flag DEVICE_AUTH_DIRECTO. ⚠️ 100% INERTE: con el flag en OFF (default y
//   estado actual) el comportamiento es BIT-IDÉNTICO a v1.0.14 — todo va por
//   GAS, ninguna RPC nueva se llama. Esto es la garantía de seguridad.
//   · Flag: _devAuthDirecto() → localStorage 'mos_device_auth_directo'==='1'
//     || window.MOS_CONFIG.deviceAuthDirecto===true. Default OFF.
//     (get_flags() AÚN no expone 'deviceAuthDirecto'; cuando lo haga se
//      añadirá aquí sin tocar más nada — ver _devAuthDirecto.)
//   · ON → verificación: mos.verificar_dispositivo (REST anon, id_dispositivo
//     snake). ON → registro: mos.registrar_dispositivo. ON → aprobación in-situ:
//     mos.aprobar_dispositivo (con clave admin + es_reactivar). En CUALQUIER
//     fallo de RPC (red/{ok:false}/excepción) → FALLBACK transparente a GAS
//     (mismo path que hoy). FAIL-CLOSED en auth: un error nunca abre la app.
//   · DUAL-WRITE A LA HOJA: cuando se APRUEBA in-situ DIRECTO a Supabase, se
//     dispara TAMBIÉN el endpoint GAS actual (best-effort, fire-and-forget)
//     para que la HOJA DISPOSITIVOS siga fresca para los ~40 lectores GAS no
//     migrados. Así no hace falta el sync inverso (Fase 2) todavía. NO bloquea
//     ni revierte el resultado directo si el GAS falla.
//   · DENYLIST: el heartbeat consulta get_flags().dispositivos_revocados; si
//     el id_dispositivo propio aparece → bloquea (revocación ≤2min, sin esperar
//     el día). Solo activo con flag ON.
//   · Mapeo snake→camel: la RPC devuelve estado/autorizado/verify_version/
//     fecha_hoy_lima/forzar_*/desbloqueo_temporal_hasta; se adapta al shape
//     camelCase que el resto del módulo ya consume (d.verifyVersion, etc.).
// v1.0.14 — 2026-06-16 — FASE 0 higiene: DeviceAuth.VERSION expuesto + log
//   "[DeviceAuth] vX en <app>" al boot (init) para cazar desyncs de ?v= entre
//   las 3 apps en consola. Sin cambio de comportamiento (solo versionado honesto).
// v1.0.13 — 2026-06-16 — FIX RAÍZ del 401-post-aprobación (caso real MOS):
//   1) deviceId RESILIENTE: persiste en localStorage + IndexedDB + Cache
//      Storage. Lee de cualquiera y re-siembra los que falten. Sobrevive
//      limpiezas PARCIALES (que borran un store y no otro) → el id NO cambia.
//      LIMITACIÓN HONESTA: un "Clear site data" TOTAL borra los 3 stores; ahí
//      el id se pierde inevitablemente y el navegador genera uno nuevo — para
//      ESE caso el remedio es la aprobación in-situ robusta (punto 2).
//   2) Aprobación in-situ ROBUSTA: aprueba el deviceId que el navegador usa
//      AHORA (leído en vivo), MUESTRA el UUID completo que va a activar, y tras
//      aprobar CONFIRMA que mint-mos ya emite token para ESE id (read-back real)
//      antes de recargar. El backend propaga al instante a la sombra
//      mos.dispositivos + ecoa el deviceId activado (imposible desfase).
//   3) Overlay con UUID completo + copiar, para que el master vea/comparta el
//      id exacto y no quede el caso "entrando por GAS mientras mint-mos 401a".
// v1.0.12 — 2026-06-05 — Sync de extensión de horario AGREGADO al heartbeat
//           también (antes solo en _consultarBackend del boot/polling).
//           Sin esto la revocación de extensión desde panel no llegaba al
//           cliente hasta el siguiente boot.
// v1.0.11 — 2026-06-05 — Sync inicial con ExtensorHorario (solo en boot/polling).
// v1.0.10 — 2026-06-05 — Bug E (in-situ ahora lee verifyVersion del backend
//           response, eliminando el fetch extra en el próximo boot).
// v1.0.9 — 2026-06-04 — Bug T (seguridad: PENDIENTE no invalidaba cache),
//          Bug N (heartbeat sin PENDIENTE_APROBACION), Bug H (polling en
//          background tab), Bug Q (deadcode cleanup), Bug JJ (polling sin
//          stop en terminales), Bug LL (verifyPromise zombi).
//
// Lo cargan las 3 apps del ecosistema (MOS, MosExpress, warehouseMos)
// vía CDN MOS pages. Centraliza el flow de verificación:
//   - Capa 1: dispositivo nuevo → modal "esperando aprobación" o in-situ
//   - Capa 2: dispositivo aprobado → cache por día calendario Lima
//   - Heartbeat 1h consulta Forzar_ReVerify y verifyVersion
//   - Polling 15s mientras PENDIENTE (con sonido + vibración al aprobar)
//   - Fail-CLOSED en todos los errores (R2 del usuario)
//
// Uso: DeviceAuth.init({
//   mosGasUrl:    'https://script.google.com/.../exec',
//   app:          'MOS' | 'mosExpress' | 'warehouseMos',
//   isMaster:     true (MOS) | false (WH/ME)  ← UI-side hint, backend re-valida
//   storageKeys:  { deviceId, lastVerifyDate, verifyVersion, lastVerifyDeviceId },
//   onAuth:       () => void,
//   onPending:    () => void,
//   onInactive:   () => void,
//   onSuspended:  () => void,
//   onNoRegistered: () => void,
//   onError:      (err) => void,
//   onAprobado:   () => void  ← se dispara cuando POLLING detecta aprobación
//                                (después de PENDIENTE). Aquí va el wizard.
//   uiContainer:  HTMLElement opcional para inyectar la UI (default body)
// });
// ════════════════════════════════════════════════════════════════════
(function() {
  'use strict';
  if (window.DeviceAuth) return;  // dedupe carga doble

  // [v1.0.14] Versión honesta del módulo. Las 3 apps lo cargan vía CDN con un
  // pin ?v= en su <script>; si ese pin miente, ESTA constante revela la versión
  // REAL servida. Se loguea al boot (init) como "[DeviceAuth] vX en <app>".
  var _VERSION = '1.0.18';

  var _config = null;
  var _state = {
    deviceId: null,
    estado: 'INIT',        // INIT | VERIFICANDO | ACTIVO | PENDIENTE_APROBACION | INACTIVO | SUSPENDIDO | NO_REGISTRADO | SIN_VERIFICAR
    // [v1.0.9 BUG Q cleanup] Removido fechaUltimaVerifLima — nunca se asignaba.
    verifyVersion: 0,
    pollingTimer: null,
    heartbeatTimer: null,
    visibilityHandler: null,
    // [v1.0.16 BUG 1] Nodos del DOM que muestran el UUID (overlay + modal). Se
    // actualizan EN VIVO cuando _resolverDeviceId resuelve, para que el UUID
    // nunca quede en "(sin id)". WeakRef no — array simple, los limpiamos al re-render.
    devIdNodes: [],
    // [v1.0.16 BUG 2] Marca optimista: tras aprobar in-situ, true durante la
    // ventana anti-retroceso. Evita que un re-verify silencioso lagueado baje la
    // app a "sin autorización" justo después de aprobar.
    recienAprobado: false
  };
  // [v1.0.16 BUG 2] Clave + ventana (ms) de la marca optimista anti-retroceso.
  // Persistida para que SOBREVIVA al reload (cuando la app sí recarga). Sólo
  // protege contra estados NO-revocación (NO_REGISTRADO/PENDIENTE); INACTIVO/
  // SUSPENDIDO/forzar_reverify siempre pueden cerrar (revocación real fail-closed).
  var _OPTIMISTA_KEY = 'da_optimista_ts';
  var _OPTIMISTA_VENTANA_MS = 90 * 1000;  // 90s: holgura para propagación de sombra/hoja
  // Singleton de promise para dedupe de verificaciones concurrentes (multi-tab)
  var _verifyPromise = null;

  // ── Helpers ──────────────────────────────────────────────────
  function _fechaHoyLima() {
    return new Date().toLocaleString('en-CA', {
      timeZone: 'America/Lima',
      year: 'numeric', month: '2-digit', day: '2-digit'
    }).substring(0, 10);  // "2026-06-04"
  }
  function _lsGet(key) { try { return localStorage.getItem(key); } catch(_) { return null; } }
  function _lsSet(key, val) { try { localStorage.setItem(key, val); } catch(_) {} }
  function _lsRm(key)  { try { localStorage.removeItem(key); } catch(_) {} }
  // [v1.0.6] Escape HTML — usado en mensajes con nombre del aprobador
  function _escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
    });
  }
  // [v1.0.16] prefers-reduced-motion → desactivar animaciones (mockups §3).
  function _reducedMotion() {
    try { return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches; }
    catch(_) { return false; }
  }

  // [v1.0.16 BUG 2] Marca optimista anti-retroceso (sobrevive reload).
  function _marcarRecienAprobado() {
    _state.recienAprobado = true;
    _lsSet(_OPTIMISTA_KEY, String(Date.now()));
  }
  function _limpiarRecienAprobado() {
    _state.recienAprobado = false;
    _lsRm(_OPTIMISTA_KEY);
  }
  // Vigente si la marca (memoria o localStorage tras reload) está dentro de la ventana.
  function _optimistaVigente() {
    if (_state.recienAprobado) return true;
    var ts = parseInt(_lsGet(_OPTIMISTA_KEY) || '0', 10);
    if (!ts) return false;
    if (Date.now() - ts <= _OPTIMISTA_VENTANA_MS) return true;
    _lsRm(_OPTIMISTA_KEY);  // venció → limpiar
    return false;
  }

  // [v1.0.16 BUG 1] Registrar un nodo del DOM (overlay/modal) que muestra el
  // UUID, y actualizar EN VIVO cuando el id resuelva. Texto provisional sin id.
  function _registrarDevIdNode(el) {
    if (!el) return;
    _state.devIdNodes.push(el);
    _pintarDevIdNode(el);
  }
  function _pintarDevIdNode(el) {
    if (!el) return;
    if (_state.deviceId) {
      el.textContent = _state.deviceId;
      el.classList.remove('da-dev-pend');
      el.setAttribute('title', 'Toca para copiar el ID del dispositivo');
    } else {
      el.textContent = 'generando ID…';   // BUG 1: nunca "(sin id)"
      el.classList.add('da-dev-pend');
      el.setAttribute('title', 'Resolviendo el ID del dispositivo…');
    }
  }
  // Llamado por init() cuando _resolverDeviceId resuelve: refresca todos los nodos.
  function _setDeviceId(id) {
    _state.deviceId = id;
    _state.devIdNodes.forEach(_pintarDevIdNode);
  }
  // Handler de copia compartido (overlay + modal). No copia si aún no hay id.
  function _engancharCopiaDevId(el) {
    if (!el) return;
    el.addEventListener('click', function() {
      if (!_state.deviceId) { _vibrar(15); return; }  // aún generando → buzz corto
      try {
        if (navigator.clipboard) navigator.clipboard.writeText(_state.deviceId);
        var prev = el.textContent;
        el.textContent = '✓ ID copiado';
        el.classList.add('da-dev-copied');
        setTimeout(function(){ el.textContent = prev; el.classList.remove('da-dev-copied'); }, 1200);
        _vibrar(20);
      } catch(_) {}
    });
  }

  // ── [v1.0.15 FASE 3a] Auth DIRECTO a Supabase — flag + REST anon + mapeo ──
  // TODO ESTE BLOQUE ES INERTE con el flag OFF (default): ningún caller lo
  // ejecuta salvo que _devAuthDirecto() devuelva true.
  //
  // Flag DEVICE_AUTH_DIRECTO. Default OFF → comportamiento GAS bit-idéntico.
  // Fuentes (cualquiera en true → ON): localStorage 'mos_device_auth_directo'
  // === '1' (override por-dispositivo, piloto) || window.MOS_CONFIG
  // .deviceAuthDirecto === true (server-wide vía index.html). Cuando get_flags()
  // exponga 'deviceAuthDirecto', añadir aquí la rama _flagsAnon.deviceAuthDirecto
  // === '1' (mismo patrón que api.js _mosFlag) sin tocar nada más.
  function _devAuthDirecto() {
    try {
      // [FIX robustez 40x] Sin config Supabase (base + anon) NO intentar el directo: evita el rebote
      // colgado a GAS que vivió WH (que no pasa sbUrl/sbAnon en su init). Sin config => directo a GAS,
      // sin intentar el path Supabase ni el fallback ruidoso. Solo MOS (con mintUrl+sbAnon) puede ir directo.
      if (!_sbBase() || !(_config && _config.sbAnon)) return false;
      if (typeof window !== 'undefined' && window.MOS_CONFIG && window.MOS_CONFIG.deviceAuthDirecto === true) return true;
      if (_lsGet('mos_device_auth_directo') === '1') return true;
    } catch (_) {}
    return false;
  }

  // Base REST de Supabase. Preferimos un config.sbUrl explícito; si no, lo
  // derivamos de mintUrl (".../functions/v1/mint-mos" → "https://<ref>.supabase.co").
  // Sin base utilizable → null (el caller cae a GAS).
  function _sbBase() {
    try {
      if (_config && _config.sbUrl) return String(_config.sbUrl).replace(/\/+$/, '');
      if (_config && _config.mintUrl) {
        var m = String(_config.mintUrl).match(/^(https?:\/\/[^/]+)/);
        if (m) return m[1];
      }
    } catch (_) {}
    return null;
  }

  // Llama una RPC mos.<fn> por REST anon (mismo mecanismo que api.js _sb y
  // get_flags: POST a /rest/v1/rpc/<fn> con apikey/Authorization=anon +
  // Accept-Profile/Content-Profile: mos). Las RPCs de auth esperan los args
  // bajo la clave `p`. Devuelve Promise<objeto JSON> o RECHAZA (timeout/red/
  // status no-2xx/JSON inválido) — el caller decide el fallback a GAS.
  function _rpcAnon(fn, args) {
    var base = _sbBase();
    if (!base || !_config.sbAnon) return Promise.reject(new Error('SB no configurado'));
    var ctrl = new AbortController();
    var to = setTimeout(function () { ctrl.abort(); }, 8000);
    return fetch(base + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: {
        'apikey': _config.sbAnon,
        'Authorization': 'Bearer ' + _config.sbAnon,
        'Accept-Profile': 'mos', 'Content-Profile': 'mos',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ p: args }),
      signal: ctrl.signal
    }).then(function (r) {
      clearTimeout(to);
      if (!r.ok) throw new Error('RPC ' + fn + ' HTTP ' + r.status);
      return r.json();
    }).then(function (j) {
      if (!j || typeof j !== 'object') throw new Error('RPC ' + fn + ' respuesta inválida');
      return j;
    }).catch(function (e) { clearTimeout(to); throw e; });
  }

  // get_flags() por REST anon (sin args bajo `p`: get_flags() no toma jsonb).
  // Usado SOLO por la denylist del heartbeat (flag ON). Cache corto en memoria
  // para no martillar el endpoint. RECHAZA en error (la denylist se salta, no rompe).
  function _getFlagsAnon() {
    var base = _sbBase();
    if (!base || !_config.sbAnon) return Promise.reject(new Error('SB no configurado'));
    var ctrl = new AbortController();
    var to = setTimeout(function () { ctrl.abort(); }, 8000);
    return fetch(base + '/rest/v1/rpc/get_flags', {
      method: 'POST',
      headers: {
        'apikey': _config.sbAnon,
        'Authorization': 'Bearer ' + _config.sbAnon,
        'Accept-Profile': 'mos', 'Content-Profile': 'mos',
        'Content-Type': 'application/json'
      },
      body: '{}',
      signal: ctrl.signal
    }).then(function (r) {
      clearTimeout(to);
      if (!r.ok) throw new Error('get_flags HTTP ' + r.status);
      return r.json();
    }).catch(function (e) { clearTimeout(to); throw e; });
  }

  // Adapta la respuesta snake_case de verificar_dispositivo/registrar_dispositivo
  // al shape camelCase `d` que _consultarBackend ya consume (mismas claves que el
  // GAS devolvía: estado, autorizado, verifyVersion, fechaHoyLima, nombre,
  // forzar_reverify, desbloqueo_temporal_hasta, error). Defensivo ante claves
  // ausentes. NO inventa estado: si la RPC no trae 'estado', devuelve null para
  // que el caller trate como fallo y caiga a GAS (fail-closed).
  function _mapVerifyResp(j) {
    if (!j || j.ok === false || !j.estado) return null;
    return {
      estado:        j.estado,
      autorizado:    j.autorizado === true || j.estado === 'ACTIVO',
      verifyVersion: j.verify_version || j.device_verify_version || 0,
      fechaHoyLima:  j.fecha_hoy_lima || '',
      nombre:        j.nombre_equipo || j.aprobado_por || 'admin',
      error:         j.error || '',
      // Campos de control que el heartbeat/extensión ya leen tal cual (snake):
      forzar_reverify:           j.forzar_reverify === true,
      desbloqueo_temporal_hasta: j.desbloqueo_temporal_hasta
    };
  }

  // ── deviceId RESILIENTE (multi-store) ────────────────────────
  // El deviceId vivía SOLO en localStorage. Un "Clear site data" (o un borrado
  // parcial de un solo store) lo perdía → el navegador generaba un UUID NUEVO →
  // el master aprobaba un id que ya no era el que el device usaba para mint-mos
  // → 401 persistente. Ahora lo persistimos en 3 stores INDEPENDIENTES:
  //   · localStorage  (rápido, síncrono)
  //   · IndexedDB     (sobrevive a algunos "clear" que solo tocan localStorage)
  //   · Cache Storage (otra superficie de almacenamiento, distinta política)
  // Leemos de CUALQUIERA (precedencia LS→IDB→Cache) y re-sembramos los faltantes.
  // Así una limpieza PARCIAL (que vacía 1 store) NO cambia el id: se recupera de
  // otro y se re-siembra el borrado. Solo un Clear TOTAL (los 3 a la vez) lo pierde.
  var _IDB_DB = 'da_device';        // nombre BD IndexedDB
  var _IDB_STORE = 'kv';
  var _CACHE_NAME = 'da-device-cache';

  function _idbGet(key) {
    return new Promise(function(resolve) {
      try {
        if (!window.indexedDB) return resolve(null);
        var req = indexedDB.open(_IDB_DB, 1);
        req.onupgradeneeded = function() {
          try { req.result.createObjectStore(_IDB_STORE); } catch(_) {}
        };
        req.onerror = function() { resolve(null); };
        req.onsuccess = function() {
          try {
            var db = req.result;
            if (!db.objectStoreNames.contains(_IDB_STORE)) { db.close(); return resolve(null); }
            var tx = db.transaction(_IDB_STORE, 'readonly');
            var g = tx.objectStore(_IDB_STORE).get(key);
            g.onsuccess = function() { resolve(g.result || null); db.close(); };
            g.onerror = function() { resolve(null); db.close(); };
          } catch(_) { resolve(null); }
        };
      } catch(_) { resolve(null); }
    });
  }
  function _idbSet(key, val) {
    return new Promise(function(resolve) {
      try {
        if (!window.indexedDB) return resolve(false);
        var req = indexedDB.open(_IDB_DB, 1);
        req.onupgradeneeded = function() {
          try { req.result.createObjectStore(_IDB_STORE); } catch(_) {}
        };
        req.onerror = function() { resolve(false); };
        req.onsuccess = function() {
          try {
            var db = req.result;
            if (!db.objectStoreNames.contains(_IDB_STORE)) { db.close(); return resolve(false); }
            var tx = db.transaction(_IDB_STORE, 'readwrite');
            tx.objectStore(_IDB_STORE).put(val, key);
            tx.oncomplete = function() { resolve(true); db.close(); };
            tx.onerror = function() { resolve(false); db.close(); };
          } catch(_) { resolve(false); }
        };
      } catch(_) { resolve(false); }
    });
  }
  // Cache Storage: guardamos el id como cuerpo de una "respuesta" en una URL sintética.
  function _cacheGet(key) {
    try {
      if (!window.caches) return Promise.resolve(null);
      return caches.open(_CACHE_NAME).then(function(c) {
        return c.match('/__da__/' + encodeURIComponent(key)).then(function(resp) {
          if (!resp) return null;
          return resp.text().then(function(t) { return t || null; });
        });
      }).catch(function(){ return null; });
    } catch(_) { return Promise.resolve(null); }
  }
  function _cacheSet(key, val) {
    try {
      if (!window.caches) return Promise.resolve(false);
      return caches.open(_CACHE_NAME).then(function(c) {
        return c.put('/__da__/' + encodeURIComponent(key), new Response(String(val))).then(function(){ return true; });
      }).catch(function(){ return false; });
    } catch(_) { return Promise.resolve(false); }
  }

  function _idValido(v) {
    return typeof v === 'string' && v.length >= 8 && v.length <= 80;
  }

  // Resuelve el deviceId leyendo los 3 stores, eligiendo el primero válido y
  // re-sembrando los que falten. Devuelve Promise<string>.
  function _resolverDeviceId() {
    var key = _config.storageKeys.deviceId;
    var lsVal = _lsGet(key);
    // [v2.43.224 FIX] Race contra timeout 3s: si IndexedDB/Cache cuelgan (UA raro,
    // modo privado, open() sin success/error), NO bloquear el arranque — caer a
    // [null,null] => se usa lsVal o se genera. El gate de boot (da-pre-block) sigue
    // protegiendo (fail-closed): peor caso = 3s de overlay VERIFICANDO, nunca colgado.
    var _stores = Promise.race([
      Promise.all([_idbGet(key), _cacheGet(key)]),
      new Promise(function(resolve){ setTimeout(function(){ resolve([null, null]); }, 3000); })
    ]);
    return _stores.then(function(res) {
      var idbVal = res[0], cacheVal = res[1];
      // Precedencia: el primero VÁLIDO (LS→IDB→Cache). Si LS ya tiene uno válido,
      // ese gana (es el que el navegador venía usando) — máxima estabilidad.
      var id = null;
      if (_idValido(lsVal)) id = lsVal;
      else if (_idValido(idbVal)) id = idbVal;
      else if (_idValido(cacheVal)) id = cacheVal;
      if (!id) {
        // Ningún store tenía un id válido → generar uno nuevo (caso primer arranque
        // o Clear TOTAL). Honesto: aquí el id ANTERIOR se perdió irrecuperablemente.
        id = (window.crypto && crypto.randomUUID)
          ? crypto.randomUUID()
          : ('D-' + Date.now() + '-' + Math.random().toString(36).substring(2, 10));
      }
      // Re-sembrar TODOS los stores que no coincidan (fire-and-forget; LS síncrono).
      try { if (lsVal !== id) _lsSet(key, id); } catch(_) {}
      if (idbVal !== id) _idbSet(key, id);
      if (cacheVal !== id) _cacheSet(key, id);
      return id;
    }).catch(function() {
      // Falla total de IDB/Cache → caer a LS o generar. Nunca bloquear el arranque.
      if (_idValido(lsVal)) return lsVal;
      var nuevo = (window.crypto && crypto.randomUUID)
        ? crypto.randomUUID()
        : ('D-' + Date.now() + '-' + Math.random().toString(36).substring(2, 10));
      _lsSet(key, nuevo);
      return nuevo;
    });
  }

  // R4: cache válido si fechaUltimaVerifLima === hoy Lima
  // Defensa: la fechaHoyLima viene del servidor. Si no la tenemos, NO confiar
  // en el reloj local — devolver false y forzar verificación.
  function _cacheValidoHoy(fechaServerLima) {
    var lastDate = _lsGet(_config.storageKeys.lastVerifyDate);
    var lastDevId = _lsGet(_config.storageKeys.lastVerifyDeviceId);
    if (!lastDate || !lastDevId) return false;
    if (lastDevId !== _state.deviceId) return false;  // device cambió
    // Comparar contra fecha server si la tenemos, sino contra local (fallback)
    var hoyLima = fechaServerLima || _fechaHoyLima();
    return lastDate === hoyLima;
  }

  function _guardarCacheExitoso(fechaLima, verifyVersion) {
    _lsSet(_config.storageKeys.lastVerifyDate, fechaLima || _fechaHoyLima());
    _lsSet(_config.storageKeys.lastVerifyDeviceId, _state.deviceId);
    if (verifyVersion) _lsSet(_config.storageKeys.verifyVersion, String(verifyVersion));
  }
  function _invalidarCache() {
    _lsRm(_config.storageKeys.lastVerifyDate);
    _lsRm(_config.storageKeys.verifyVersion);
  }

  // ── Sonidos + vibración ──────────────────────────────────────
  function _sonidoAprobado() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      var ctx = new Ctx();
      [523, 659, 784].forEach(function(freq, i) {
        var osc = ctx.createOscillator();
        var gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.value = freq;
        osc.connect(gain);
        gain.connect(ctx.destination);
        var t = ctx.currentTime + i * 0.15;
        gain.gain.setValueAtTime(0.0001, t);
        gain.gain.exponentialRampToValueAtTime(0.35, t + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.32);
        osc.start(t);
        osc.stop(t + 0.35);
      });
    } catch(_){}
  }
  function _sonidoError() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      var ctx = new Ctx();
      [392, 311].forEach(function(freq, i) {
        var osc = ctx.createOscillator();
        var gain = ctx.createGain();
        osc.type = 'square';
        osc.frequency.value = freq;
        osc.connect(gain);
        gain.connect(ctx.destination);
        var t = ctx.currentTime + i * 0.18;
        gain.gain.setValueAtTime(0.0001, t);
        gain.gain.exponentialRampToValueAtTime(0.25, t + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.18);
        osc.start(t);
        osc.stop(t + 0.2);
      });
    } catch(_){}
  }
  // [v1.0.16] Tono GRAVE para revocado/bloqueo (mockups §3 Estado 4).
  function _sonidoGrave() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      var ctx = new Ctx();
      [196, 147].forEach(function(freq, i) {
        var osc = ctx.createOscillator();
        var gain = ctx.createGain();
        osc.type = 'sawtooth';
        osc.frequency.value = freq;
        osc.connect(gain);
        gain.connect(ctx.destination);
        var t = ctx.currentTime + i * 0.22;
        gain.gain.setValueAtTime(0.0001, t);
        gain.gain.exponentialRampToValueAtTime(0.3, t + 0.03);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.4);
        osc.start(t);
        osc.stop(t + 0.42);
      });
    } catch(_){}
  }
  function _vibrar(pattern) {
    try { if (navigator.vibrate) navigator.vibrate(pattern); } catch(_) {}
  }

  // ── UI ───────────────────────────────────────────────────────
  var OVERLAY_ID = 'deviceAuthOverlay';
  function _injectCss() {
    if (document.getElementById('device-auth-css')) return;
    var s = document.createElement('style');
    s.id = 'device-auth-css';
    s.textContent = [
      '#' + OVERLAY_ID + '{position:fixed;inset:0;z-index:99997;background:linear-gradient(135deg,#0c1426 0%,#1e293b 50%,#0c1426 100%);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;color:#e2e8f0;font-family:system-ui,-apple-system,sans-serif;text-align:center;transition:opacity .45s ease}',
      '#' + OVERLAY_ID + '.da-fade-out{opacity:0;pointer-events:none}',
      '#' + OVERLAY_ID + ' .da-emoji{font-size:64px;margin-bottom:18px;animation:da-pulse 1.6s ease-in-out infinite;line-height:1}',
      // [v1.0.16] Spinner suave (anillo) — reemplaza el emoji giratorio en VERIFICANDO.
      '#' + OVERLAY_ID + ' .da-spinner{width:58px;height:58px;margin:0 auto 20px;border-radius:50%;border:4px solid rgba(16,185,129,.18);border-top-color:#10b981;animation:da-spin .9s linear infinite}',
      '#' + OVERLAY_ID + ' .da-dots{display:inline-flex;gap:5px;margin-top:4px}',
      '#' + OVERLAY_ID + ' .da-dots i{width:7px;height:7px;border-radius:50%;background:#10b981;opacity:.4;animation:da-dot 1.2s ease-in-out infinite}',
      '#' + OVERLAY_ID + ' .da-dots i:nth-child(2){animation-delay:.2s}',
      '#' + OVERLAY_ID + ' .da-dots i:nth-child(3){animation-delay:.4s}',
      '#' + OVERLAY_ID + ' .da-h1{font-size:22px;font-weight:800;margin:0 0 8px;color:#f1f5f9}',
      '#' + OVERLAY_ID + ' .da-p{font-size:14px;color:#94a3b8;max-width:440px;line-height:1.5;margin:0 0 6px}',
      '#' + OVERLAY_ID + ' .da-dev{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;color:#fbbf24;background:rgba(251,191,36,.1);padding:8px 14px;border-radius:8px;margin-top:14px;letter-spacing:.5px;word-break:break-all;max-width:90%;cursor:pointer;transition:background .15s,transform .1s;border:1px solid rgba(251,191,36,.18)}',
      '#' + OVERLAY_ID + ' .da-dev:active{transform:scale(.97)}',
      '#' + OVERLAY_ID + ' .da-dev:hover{background:rgba(251,191,36,.18)}',
      '#' + OVERLAY_ID + ' .da-dev.da-dev-pend{color:#94a3b8;background:rgba(148,163,184,.1);border-color:rgba(148,163,184,.18);cursor:default;font-style:italic}',
      '#' + OVERLAY_ID + ' .da-dev.da-dev-copied{color:#34d399;background:rgba(16,185,129,.18);border-color:rgba(16,185,129,.4)}',
      '#' + OVERLAY_ID + ' .da-dev-cap{font-size:10px;color:#64748b;margin-top:6px;text-transform:uppercase;letter-spacing:.6px}',
      '#' + OVERLAY_ID + ' .da-actions{display:flex;gap:10px;margin-top:24px;flex-wrap:wrap;justify-content:center}',
      // .da-emoji.da-shake → ícono que tiembla (revocado/bloqueo)
      '.da-shake{animation:da-shake .5s ease-in-out!important}',
      // [v1.0.3 FIX] Estilos .da-btn GLOBALES — antes scopados a #deviceAuthOverlay,
      // por eso los botones del modal in-situ aparecían SIN colores (solo el
      // padding genérico de .da-insitu-actions button). Ahora aplican en ambos.
      '.da-btn{padding:12px 22px;border-radius:10px;font-weight:800;font-size:14px;border:1px solid transparent;cursor:pointer;transition:transform .15s,background .15s,box-shadow .15s;display:inline-flex;align-items:center;justify-content:center;gap:6px}',
      '.da-btn:active{transform:scale(.96)}',
      '.da-btn:disabled{opacity:.7;cursor:default}',
      '.da-btn-primary{background:linear-gradient(135deg,#10b981,#059669);color:#fff;box-shadow:0 4px 14px -2px rgba(16,185,129,.45)}',
      '.da-btn-primary:hover{box-shadow:0 6px 20px -2px rgba(16,185,129,.6)}',
      '.da-btn-secondary{background:#1e293b;color:#e2e8f0;border-color:#334155}',
      '.da-btn-secondary:hover{background:#334155}',
      '.da-btn-warn{background:rgba(239,68,68,.15);color:#fca5a5;border-color:rgba(239,68,68,.4)}',
      '.da-btn-warn:hover{background:rgba(239,68,68,.25)}',
      '@keyframes da-pulse{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(.94);opacity:.85}}',
      '@keyframes da-pop{from{opacity:0;transform:scale(.85)}to{opacity:1;transform:scale(1)}}',
      '@keyframes da-spin{to{transform:rotate(360deg)}}',
      '@keyframes da-dot{0%,100%{opacity:.35;transform:translateY(0)}50%{opacity:1;transform:translateY(-3px)}}',
      '@keyframes da-shake{0%,100%{transform:translateX(0)}15%,55%{transform:translateX(-9px)}35%,75%{transform:translateX(9px)}}',
      // Check SVG trazado (éxito)
      '@keyframes da-draw{to{stroke-dashoffset:0}}',
      '@keyframes da-ring{from{transform:scale(.4);opacity:0}to{transform:scale(1);opacity:1}}',
      '.da-check-wrap{display:flex;align-items:center;justify-content:center;margin-bottom:14px}',
      '.da-check-svg{width:84px;height:84px}',
      '.da-check-svg .da-ck-ring{stroke:#10b981;stroke-width:5;fill:none;stroke-dasharray:289;stroke-dashoffset:289;animation:da-draw .55s ease-out forwards;transform-origin:center}',
      '.da-check-svg .da-ck-tick{stroke:#10b981;stroke-width:6;fill:none;stroke-linecap:round;stroke-linejoin:round;stroke-dasharray:60;stroke-dashoffset:60;animation:da-draw .4s .45s ease-out forwards}',
      // Modal in-situ
      '.da-insitu-overlay{position:fixed;inset:0;background:rgba(2,6,23,.85);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);z-index:99999;display:flex;align-items:center;justify-content:center;padding:16px}',
      '.da-insitu-modal{width:100%;max-width:420px;max-height:92vh;overflow:auto;background:#0a1424;border:1px solid rgba(16,185,129,.4);border-radius:18px;padding:24px;animation:da-pop .3s ease-out;box-sizing:border-box}',
      '.da-insitu-modal.da-modal-shake{animation:da-shake .5s ease-in-out}',
      '.da-insitu-modal h3{margin:0 0 16px;color:#10b981;font-size:18px;font-weight:800}',
      '.da-insitu-modal label{display:block;margin:12px 0 6px;color:#cbd5e1;font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.5px}',
      '.da-insitu-modal input[type=text]{width:100%;padding:10px 12px;border-radius:8px;background:#070d18;border:1px solid #334155;color:#f1f5f9;font-size:14px;box-sizing:border-box;transition:border-color .15s}',
      '.da-insitu-modal input[type=text]:focus{outline:none;border-color:#10b981}',
      // OTP de 8 casillas
      '.da-otp{display:flex;gap:7px;justify-content:center;margin:4px 0 2px;direction:ltr}',
      '.da-otp input{width:34px;height:46px;text-align:center;font-size:22px;font-weight:800;border-radius:9px;background:#070d18;border:1.5px solid #334155;color:#f1f5f9;box-sizing:border-box;transition:border-color .15s,box-shadow .15s,background .15s;-moz-appearance:textfield;padding:0}',
      '.da-otp input::-webkit-outer-spin-button,.da-otp input::-webkit-inner-spin-button{-webkit-appearance:none;margin:0}',
      '.da-otp input:focus{outline:none;border-color:#10b981;box-shadow:0 0 0 3px rgba(16,185,129,.18);background:#0a1626}',
      '.da-otp input.da-otp-filled{border-color:#10b981}',
      '.da-otp.da-otp-bad input{border-color:#ef4444;color:#fca5a5}',
      '.da-otp.da-otp-bad{animation:da-shake .45s ease-in-out}',
      '.da-insitu-err{color:#fca5a5;font-size:12px;margin-top:8px;min-height:18px;font-weight:600}',
      '.da-insitu-actions{display:flex;gap:8px;margin-top:18px}',
      '.da-insitu-actions button{flex:1;padding:11px;border-radius:8px;font-weight:800;font-size:14px;border:0;cursor:pointer}',
      '.da-insitu-hint{font-size:11px;color:#64748b;margin-top:8px;line-height:1.4}',
      // Toast aprobado
      '#daApproveToast{position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);background:linear-gradient(135deg,#10b981,#059669);color:#fff;padding:24px 36px;border-radius:16px;font-size:18px;font-weight:800;z-index:99998;box-shadow:0 20px 60px rgba(16,185,129,.4);animation:da-pop .4s ease-out;text-align:center}',
      // prefers-reduced-motion → sin animaciones (mockups §3): estados estáticos.
      '@media (prefers-reduced-motion: reduce){',
      '  #' + OVERLAY_ID + '{transition:none}',
      '  #' + OVERLAY_ID + ' .da-emoji,#' + OVERLAY_ID + ' .da-spinner,#' + OVERLAY_ID + ' .da-dots i,.da-shake,.da-insitu-modal,.da-insitu-modal.da-modal-shake,#daApproveToast,.da-otp.da-otp-bad,.da-check-svg .da-ck-ring,.da-check-svg .da-ck-tick{animation:none!important}',
      '  .da-check-svg .da-ck-ring,.da-check-svg .da-ck-tick{stroke-dashoffset:0!important}',
      '  #' + OVERLAY_ID + ' .da-spinner{border-top-color:#10b981;border-color:rgba(16,185,129,.35);border-top-color:#10b981}',
      '}',
      // [v1.0.2 BUG SEC] Bloqueo total de la app cuando overlay está activo.
      // Sin esto la app sigue cargando UI Vue+badges flotantes que el operador
      // puede clickear → bypass de autorización. Critico para MOS porque permite
      // aprobar otros dispositivos sin haber sido autorizado primero.
      // pointer-events:none bloquea clicks; filter difumina visualmente; overflow
      // hidden previene scroll/inputs. Solo el overlay y modales DA siguen activos.
      'body.da-blocked{overflow:hidden!important}',
      'body.da-blocked > *:not(#' + OVERLAY_ID + '):not(.da-insitu-overlay):not(#daApproveToast):not(#device-auth-css){pointer-events:none!important;filter:blur(4px) brightness(.4) saturate(.5)!important;user-select:none!important}'
    ].join('\n');
    document.head.appendChild(s);
  }

  // [v1.0.1 BUG FIX] El script se carga en <head> → document.body puede no
  // existir cuando _renderOverlay corre. Helper que espera a que body esté
  // listo antes de hacer appendChild. Si ya existe, append inmediato.
  function _appendCuandoListo(node, contenedor) {
    var target = contenedor || _config.uiContainer || document.body;
    if (target) {
      target.appendChild(node);
      return;
    }
    // Body aún no existe — esperar DOMContentLoaded
    var attach = function() {
      var t2 = _config.uiContainer || document.body;
      if (t2) t2.appendChild(node);
      else setTimeout(attach, 50);  // último recurso
    };
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', attach, { once: true });
    } else {
      setTimeout(attach, 0);
    }
  }

  function _renderOverlay(opts) {
    _injectCss();
    // [v1.0.2] Bloquear app cuando mostramos overlay
    _bloquearApp();
    // [v1.0.6 BUG R1 FIX] DEFENSA: si el estado NO es ACTIVO, restaurar
    // html.da-pre-block. Esto cubre el caso en que el cache optimista
    // quitó el pre-block y luego el background refresh detectó PENDIENTE/
    // INACTIVO/SUSPENDIDO. Sin esta defensa, body quedaba visible y el
    // operador podía interactuar con la app de fondo.
    if (_state.estado !== 'ACTIVO' && document.documentElement) {
      document.documentElement.classList.add('da-pre-block');
    }
    var existing = document.getElementById(OVERLAY_ID);
    if (existing) existing.remove();
    // [v1.0.16 BUG 1] Re-render limpia los nodos viejos del UUID (el DOM anterior
    // se descarta); registramos los nuevos para que _setDeviceId los refresque.
    _state.devIdNodes = [];
    var ov = document.createElement('div');
    ov.id = OVERLAY_ID;
    var actions = '';
    if (opts.actions) {
      opts.actions.forEach(function(a) {
        actions += '<button class="da-btn da-btn-' + (a.style || 'secondary') + '" data-act="' + a.id + '">' + a.label + '</button>';
      });
    }
    // [v1.0.16] Cabecera: spinner suave (VERIFICANDO) o emoji (con shake opcional
    // para revocado/bloqueo). El UUID se pinta vacío y _registrarDevIdNode lo
    // rellena en vivo cuando _resolverDeviceId resuelve (BUG 1: nunca "(sin id)").
    var head = opts.spinner
      ? '<div class="da-spinner" aria-hidden="true"></div>'
      : '<div class="da-emoji' + (opts.shake && !_reducedMotion() ? ' da-shake' : '') + '">' + (opts.emoji || '🔄') + '</div>';
    ov.innerHTML = ''
      + head
      + '<h1 class="da-h1">' + opts.title + '</h1>'
      + '<p class="da-p">' + opts.detail + (opts.spinner ? ' <span class="da-dots"><i></i><i></i><i></i></span>' : '') + '</p>'
      + (opts.subDetail ? '<p class="da-p" style="font-size:12px;color:#64748b">' + opts.subDetail + '</p>' : '')
      + (opts.showDevId === false ? '' :
            '<div class="da-dev" id="daDevId"></div>'
          + (opts.devIdCaption ? '<div class="da-dev-cap">' + _escapeHtml(opts.devIdCaption) + '</div>' : ''))
      + (actions ? '<div class="da-actions">' + actions + '</div>' : '');
    _appendCuandoListo(ov);
    // [v1.0.16 BUG 1] Registrar + enganchar copia del nodo del UUID (live-bound).
    if (opts.showDevId !== false) {
      var devEl = ov.querySelector('#daDevId');
      _registrarDevIdNode(devEl);    // pinta el id actual o "generando ID…"
      _engancharCopiaDevId(devEl);
    }
    // Handlers (se enganchan al nodo, no requieren que esté en DOM aún)
    if (opts.actions) {
      opts.actions.forEach(function(a) {
        var btn = ov.querySelector('[data-act="' + a.id + '"]');
        if (btn) btn.addEventListener('click', a.onClick);
      });
    }
  }
  function _ocultarOverlay() {
    var ov = document.getElementById(OVERLAY_ID);
    if (ov) ov.remove();
    // [v1.0.2] Quitar bloqueo de la app — pointer-events y blur vuelven al estado normal
    _desbloquearApp();
    // [v1.0.6 BUG R1 FIX] Quitar pre-block del <html> SOLO si estado es ACTIVO.
    // Antes lo quitaba siempre, lo que generaba bypass cuando se llamaba
    // desde el cache optimista pero el server después devolvía PENDIENTE.
    if (_state.estado === 'ACTIVO' && document.documentElement) {
      document.documentElement.classList.remove('da-pre-block');
    }
  }

  // [v1.0.2 BUG SEC FIX] Bloqueo de toda la UI mientras overlay está activo.
  // Aplica clase al body que CSS usa para deshabilitar TODO excepto los nodos
  // del módulo. Previene que el operador interactúe con la app antes de estar
  // autorizado (caso reportado: badge flotante de alertas accesible sin auth).
  function _bloquearApp() {
    var apply = function() {
      if (document.body) document.body.classList.add('da-blocked');
    };
    if (document.body) apply();
    else if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', apply, { once: true });
    } else {
      setTimeout(apply, 0);
    }
  }
  function _desbloquearApp() {
    if (document.body) document.body.classList.remove('da-blocked');
  }

  function _toastAprobado(mensaje) {
    var existing = document.getElementById('daApproveToast');
    if (existing) existing.remove();
    var t = document.createElement('div');
    t.id = 'daApproveToast';
    t.textContent = mensaje || '✅ Dispositivo aprobado · iniciando...';
    _appendCuandoListo(t);  // [v1.0.1] body puede no existir aún
    setTimeout(function() { if (t.parentNode) t.parentNode.removeChild(t); }, 3000);
  }

  // ── UI por estado ────────────────────────────────────────────
  function _mostrarUI(estado, extra) {
    if (estado === 'VERIFICANDO') {
      // [v1.0.16] Spinner suave (anillo) + dots — sin emoji giratorio, sin parpadeo.
      // El UUID no aporta aquí y aún puede estar resolviéndose → showDevId:false.
      _renderOverlay({
        spinner: true, title: 'Verificando dispositivo',
        detail: 'Conectando con MOS',
        showDevId: false,
        actions: []
      });
    } else if (estado === 'PENDIENTE_APROBACION') {
      // [v1.0.2] Labels según rol (MOS=master only, WH/ME=admin/master)
      var labelInSituP = _config.isMaster
        ? '🔑 Activar in-situ (master presente)'
        : '🔑 Activar in-situ (admin o master)';
      var detailP = _config.isMaster
        ? 'Tu dispositivo está pendiente de aprobación del master.'
        : 'Tu dispositivo está pendiente de aprobación del admin/master.';
      _renderOverlay({
        emoji: '⌛', title: 'Esperando aprobación',
        detail: detailP,
        subDetail: 'Re-verificación automática cada 15 segundos.',
        devIdCaption: 'ID de este dispositivo · toca para copiar',
        actions: [
          // [v1.0.2] Botón re-solicitar siempre presente — operador puede re-empujar
          // la notificación si el admin no la vio o si ya pasó mucho tiempo.
          { id: 'reenviar', label: '🔔 Re-enviar solicitud', style: 'secondary',
            onClick: function() { _solicitarAcceso(); } },
          { id: 'insitu', label: labelInSituP, style: 'primary',
            onClick: function() { _abrirModalInSitu(); } }
        ]
      });
    } else if (estado === 'INACTIVO') {
      // [v1.0.16] Estado revocado/bloqueo (mockups §3 Estado 4): ícono shake +
      // vibrate + tono grave. Triple feedback. Reduced-motion → sin shake (CSS).
      _renderOverlay({
        emoji: '🚫', shake: true, title: 'Dispositivo desactivado',
        detail: extra || 'Este dispositivo fue desactivado por el administrador.',
        subDetail: 'Contacta al admin si necesitas reactivarlo.',
        devIdCaption: 'ID de este dispositivo · toca para copiar',
        actions: []
      });
      _sonidoGrave();
      _vibrar([50, 30, 50]);
    } else if (estado === 'SUSPENDIDO') {
      _renderOverlay({
        emoji: '⏸', shake: true, title: 'Dispositivo suspendido',
        detail: extra || 'Tu dispositivo fue suspendido por inactividad (>7 días sin uso).',
        subDetail: 'Pide reactivación al admin (panel) o usa "Reactivar in-situ" con clave.',
        devIdCaption: 'ID de este dispositivo · toca para copiar',
        actions: [
          { id: 'reactivar', label: '🔑 Reactivar in-situ (admin presente)', style: 'primary',
            onClick: function() { _abrirModalInSitu(true); } }
        ]
      });
      _sonidoGrave();
      _vibrar([50, 30, 50]);
    } else if (estado === 'NO_REGISTRADO') {
      // [v1.0.2] Labels distinguidos por rol esperado
      var labelSolicitarN = _config.isMaster
        ? '📨 Solicitar acceso al master (remoto)'
        : '📨 Solicitar acceso al admin/master (remoto)';
      var labelInSituN = _config.isMaster
        ? '🔑 Activar in-situ (master presente)'
        : '🔑 Activar in-situ (admin o master)';
      var subDetailN = _config.isMaster
        ? 'Solo el master puede activar MOS en un dispositivo nuevo.'
        : 'Admin o master pueden aprobar este dispositivo.';
      _renderOverlay({
        emoji: '🔒', title: 'Dispositivo no autorizado',
        detail: 'Este dispositivo aún no fue aprobado para esta app.',
        subDetail: subDetailN,
        devIdCaption: 'ID de este dispositivo · toca para copiar',
        actions: [
          { id: 'solicitar', label: labelSolicitarN, style: 'primary',
            onClick: function() { _solicitarAcceso(); } },
          { id: 'insitu', label: labelInSituN, style: 'secondary',
            onClick: function() { _abrirModalInSitu(); } }
        ]
      });
    } else if (estado === 'SIN_VERIFICAR') {
      _renderOverlay({
        emoji: '📡', title: 'Sin conexión con MOS',
        detail: extra || 'No se pudo verificar el dispositivo. Revisa tu red e intenta de nuevo.',
        subDetail: 'Esta app NO permite operar sin verificación previa.',
        actions: [
          { id: 'reintentar', label: '🔄 Reintentar', style: 'primary',
            onClick: function() { _verificar(); } }
        ]
      });
    }
  }

  // ── Modal in-situ (admin presente con clave 8 dígitos) ────────
  function _abrirModalInSitu(esReactivar) {
    if (document.getElementById('daInsituModal')) return;
    _injectCss();
    var ov = document.createElement('div');
    ov.id = 'daInsituModal';
    ov.className = 'da-insitu-overlay';
    var titulo = esReactivar ? '🔑 Reactivar dispositivo suspendido' : '🔑 Activar dispositivo in-situ';
    var hint = _config.isMaster
      ? 'Solo MASTER puede activar MOS · clave 8 dígitos (4 globales + 4 PIN master)'
      : 'Admin o master presente · clave 8 dígitos (4 globales + 4 PIN personal)';
    // [v1.0.16 BUG 1] El UUID se inyecta en VIVO (_registrarDevIdNode); arranca en
    // "generando ID…" si _resolverDeviceId aún no resolvió y se actualiza solo.
    // [v1.0.16] Clave = 8 casillas tipo OTP (auto-avanza, inputmode numeric,
    // auto-submit al 8º). Un input HIDDEN #daIsClave concentra el valor para que
    // _confirmarInSitu (y el ENTER) lo lean igual que antes (compat).
    var otpBoxes = '';
    for (var i = 0; i < 8; i++) {
      otpBoxes += '<input type="tel" inputmode="numeric" autocomplete="off" '
        + 'maxlength="1" data-otp="' + i + '" aria-label="Dígito ' + (i + 1) + '">';
    }
    ov.innerHTML = ''
      + '<div class="da-insitu-modal">'
      +   '<h3>' + titulo + '</h3>'
      +   '<div style="font-size:11px;color:#94a3b8;margin-bottom:6px">Se activará este dispositivo:</div>'
      +   '<div class="da-dev" id="daIsDevId" style="margin:0 0 4px;display:block"></div>'
      +   (esReactivar ? '' : '<label>Nombre del equipo</label><input id="daIsNombre" type="text" placeholder="ej. Caja Principal · Almacén · Tablet 2" maxlength="60">')
      +   '<label>Clave admin (8 dígitos)</label>'
      +   '<div class="da-otp" id="daIsOtp">' + otpBoxes + '</div>'
      +   '<input id="daIsClave" type="hidden">'
      +   '<div class="da-insitu-hint">' + hint + '</div>'
      +   '<div class="da-insitu-err" id="daIsErr"></div>'
      +   '<div class="da-insitu-actions">'
      +     '<button class="da-btn da-btn-secondary" id="daIsCancel">Cancelar</button>'
      +     '<button class="da-btn da-btn-primary" id="daIsOk">' + (esReactivar ? 'Reactivar' : 'Activar') + '</button>'
      +   '</div>'
      + '</div>';
    _appendCuandoListo(ov);  // [v1.0.1] body puede no existir aún
    // [v1.0.16 BUG 1] UUID live-bound dentro del modal (copiable).
    var devEl = ov.querySelector('#daIsDevId');
    _registrarDevIdNode(devEl);
    _engancharCopiaDevId(devEl);

    var hidden = ov.querySelector('#daIsClave');
    var boxes = [].slice.call(ov.querySelectorAll('.da-otp input'));
    var otpWrap = ov.querySelector('#daIsOtp');
    var btnOk = ov.querySelector('#daIsOk');

    function _syncHidden() {
      var v = boxes.map(function(b){ return b.value; }).join('');
      hidden.value = v;
      boxes.forEach(function(b){ b.classList.toggle('da-otp-filled', !!b.value); });
      return v;
    }
    function _intentarSubmit() {
      if (btnOk && btnOk.disabled) return;          // ya procesando
      if (_syncHidden().length === 8) _confirmarInSitu(esReactivar, ov);
    }
    boxes.forEach(function(box, idx) {
      box.addEventListener('input', function() {
        // Solo dígitos. Si pegan varios (paste), distribuir.
        var raw = (box.value || '').replace(/\D/g, '');
        if (raw.length > 1) {
          for (var k = 0; k < raw.length && (idx + k) < boxes.length; k++) {
            boxes[idx + k].value = raw[k];
          }
          var next = Math.min(idx + raw.length, boxes.length - 1);
          boxes[next].focus();
        } else {
          box.value = raw;
          if (raw && idx < boxes.length - 1) boxes[idx + 1].focus();
        }
        _intentarSubmit();   // auto-submit al completar el 8º
      });
      box.addEventListener('keydown', function(e) {
        if (e.key === 'Backspace' && !box.value && idx > 0) {
          boxes[idx - 1].focus();
          boxes[idx - 1].value = '';
          _syncHidden();
          e.preventDefault();
        } else if (e.key === 'ArrowLeft' && idx > 0) {
          boxes[idx - 1].focus(); e.preventDefault();
        } else if (e.key === 'ArrowRight' && idx < boxes.length - 1) {
          boxes[idx + 1].focus(); e.preventDefault();
        } else if (e.key === 'Enter') {
          // [v1.0.7 BUG A] Respetar disabled (no doble-fire).
          if (btnOk && btnOk.disabled) return;
          _intentarSubmit();
        }
      });
      box.addEventListener('focus', function(){ box.select(); });
    });
    // Exponer helpers de OTP en el nodo para que _confirmarInSitu pueda limpiar
    // tras clave mala (shake + reset + refoco), sin perder el contexto del modal.
    ov._daOtp = { boxes: boxes, wrap: otpWrap, sync: _syncHidden };

    setTimeout(function() { if (boxes[0]) boxes[0].focus(); }, 80);
    ov.querySelector('#daIsCancel').onclick = function() { ov.remove(); };
    btnOk.onclick = function() { _intentarSubmit(); };
  }

  // [v1.0.13] Verifica en VIVO que la Edge mint-mos YA emite token para este
  // deviceId (= la sombra mos.dispositivos quedó ACTIVA y es legible). Reintenta
  // brevemente porque, aunque el backend hizo upsert+read-back síncrono, puede
  // haber un instante de propagación. Devuelve Promise<boolean>. Best-effort:
  // NUNCA lanza ni bloquea indefinidamente (máx ~4 intentos / ~6s).
  function _confirmarMintListo(deviceId, shadowOkBackend) {
    if (!_config.mintUrl || !_config.sbAnon) return Promise.resolve(true);
    var intentos = 0;
    var MAX = 4;
    function _unIntento() {
      intentos++;
      var ctrl = new AbortController();
      var to = setTimeout(function(){ ctrl.abort(); }, 5000);
      return fetch(_config.mintUrl, {
        method: 'POST',
        headers: { 'apikey': _config.sbAnon, 'Content-Type': 'application/json' },
        body: JSON.stringify({ deviceId: deviceId }),
        signal: ctrl.signal
      }).then(function(r) {
        clearTimeout(to);
        return r.json().catch(function(){ return null; });
      }).then(function(j) {
        if (j && j.ok && j.token) return true;
        // 401/ok:false → sombra todavía no lista. Reintentar con backoff corto.
        if (intentos >= MAX) return false;
        return new Promise(function(res){ setTimeout(res, 700 * intentos); }).then(_unIntento);
      }).catch(function() {
        clearTimeout(to);
        if (intentos >= MAX) return false;
        return new Promise(function(res){ setTimeout(res, 700 * intentos); }).then(_unIntento);
      });
    }
    return _unIntento();
  }

  function _confirmarInSitu(esReactivar, modal) {
    var errEl = document.getElementById('daIsErr');
    var btnOk = document.getElementById('daIsOk');
    var nombre = !esReactivar
      ? (document.getElementById('daIsNombre')?.value || '').trim()
      : '';
    var clave = (document.getElementById('daIsClave')?.value || '').trim();
    var labelDefault = esReactivar ? 'Reactivar' : 'Activar';
    if (errEl) errEl.textContent = '';
    // [v1.0.16] Clave mala → shake rojo del OTP + buzz + vibrate + limpiar + refoco,
    // SIN perder el contexto del modal (mockups §3 Estado 3).
    function _claveMala(msg) {
      if (errEl) errEl.textContent = msg;
      _vibrar([30, 40, 30]);
      _sonidoError();
      var otp = modal._daOtp;
      if (otp && otp.wrap && !_reducedMotion()) {
        otp.wrap.classList.remove('da-otp-bad');
        void otp.wrap.offsetWidth;       // reflow → re-disparar animación
        otp.wrap.classList.add('da-otp-bad');
        setTimeout(function(){ if (otp.wrap) otp.wrap.classList.remove('da-otp-bad'); }, 500);
      }
      if (otp && otp.boxes) {
        otp.boxes.forEach(function(b){ b.value = ''; b.classList.remove('da-otp-filled'); });
        otp.sync();
        if (otp.boxes[0]) otp.boxes[0].focus();
      }
      if (btnOk) { btnOk.disabled = false; btnOk.textContent = labelDefault; }
    }
    if (!/^\d{8}$/.test(clave)) {
      _claveMala('La clave debe ser de 8 dígitos numéricos');
      return;
    }
    // [v1.0.16 BUG 1] Defensa: el id aún no resolvió (clic muy rápido). NO crashear
    // (idActivar.substring) — avisar y dejar reintentar; el UUID se pinta solo.
    if (!_state.deviceId) {
      if (errEl) errEl.textContent = 'Generando ID del dispositivo… reintenta en un segundo';
      _vibrar(15);
      return;
    }
    // [v1.0.16] Submit OPTIMISTA: "Activando…" de inmediato (mockups §3).
    btnOk.disabled = true;
    btnOk.textContent = esReactivar ? 'Reactivando…' : 'Activando…';

    var ua = (navigator.userAgent || '').substring(0, 200);
    var endpoint = esReactivar ? 'reactivarDispositivoSuspendido' : 'aprobarDispositivoEnSitu';
    // [v1.0.13] Aprobar el deviceId que el navegador usa AHORA. _state.deviceId
    // ya fue resuelto (multi-store) en init() y es exactamente el que api.js usa
    // para mint-mos (misma fuente: DeviceAuth.deviceId() / localStorage). No hay
    // un id "cacheado viejo" distinto: el modal in-situ solo se abre tras init().
    var idActivar = _state.deviceId;
    var nombreEquipoFinal = !esReactivar ? (nombre || ('Mobile ' + idActivar.substring(0, 6))) : '';
    var payload = {
      action:       endpoint,
      deviceId:     idActivar,
      claveAdmin:   clave,
      app:          _config.app,
      userAgent:    ua
    };
    if (!esReactivar) payload.nombreEquipo = nombreEquipoFinal;

    // [v1.0.15 FASE 3a] El POST a GAS (camino histórico) → Promise<d camelCase>.
    function _aprobarViaGAS() {
      return fetch(_config.mosGasUrl, { method: 'POST', body: JSON.stringify(payload) })
        .then(function(r) { return r.json(); })
        .then(function(j) { return (j && j.data) || null; });
    }

    // [v1.0.15 FASE 3a] Aprobación DIRECTA a Supabase (flag ON) → mapea la
    // respuesta snake de aprobar_dispositivo al `d` camelCase que el consumidor
    // ya espera (autorizado, deviceId-eco, aprobadoPor, error, verifyVersion).
    // DUAL-WRITE: si la aprobación directa AUTORIZA, dispara TAMBIÉN el POST GAS
    // (best-effort, fire-and-forget) para refrescar la HOJA DISPOSITIVOS y que
    // los ~40 lectores GAS no-migrados sigan viendo el device ACTIVO sin esperar
    // un sync inverso (Fase 2). El fallo del GAS NO revierte ni bloquea el directo.
    function _aprobarViaDirecto() {
      return _rpcAnon('aprobar_dispositivo', {
        id_dispositivo: idActivar,
        app:            _config.app,
        clave_admin:    clave,
        nombre_equipo:  nombreEquipoFinal || null,
        es_reactivar:   !!esReactivar
      }).then(function(j) {
        var autorizado = !!(j && j.autorizado === true);
        if (autorizado) {
          // DUAL-WRITE a la hoja (fire-and-forget). No await, no .catch ruidoso.
          try { _aprobarViaGAS().catch(function(){}); } catch(_) {}
        }
        return {
          autorizado:    autorizado,
          deviceId:      (j && j.device_id) || idActivar,   // eco anti-desfase
          aprobadoPor:   (j && j.aprobado_por) || 'admin',
          verifyVersion: (j && j.verify_version) || 0,
          fechaHoyLima:  '',
          error:         (j && j.error) || '',
          shadowOk:      autorizado   // el directo ESCRIBIÓ la sombra → lista
        };
      });
    }

    // Dispatcher: flag ON → directo (con fallback a GAS si la RPC FALLA por red/
    // excepción — un "Clave incorrecta" NO es fallo de RPC, es veredicto válido y
    // NO debe reintentar por GAS). Flag OFF → GAS directo (bit-idéntico v1.0.14).
    var _dispatch = !_devAuthDirecto()
      ? _aprobarViaGAS()
      : _aprobarViaDirecto().catch(function(e) {
          console.warn('[DeviceAuth] aprobación directa falló → fallback GAS:', e && e.message);
          return _aprobarViaGAS();
        });

    _dispatch
      .then(function(d) {
        if (!d || !d.autorizado) {
          _claveMala((d && d.error) || 'Clave incorrecta');
          return;
        }
        // [v1.0.13] DEFENSA imposible-desfase: el backend ECOA el deviceId que
        // dejó ACTIVO. Debe coincidir EXACTO con el que estamos usando. Si por
        // cualquier razón difiere, NO seguimos: avisamos para evitar el caso
        // "aprobé un id distinto al que el device usa" → 401 fantasma.
        var idEco = String(d.deviceId || idActivar);
        if (d.deviceId && idEco !== String(idActivar)) {
          if (errEl) errEl.textContent = 'Desfase de ID detectado. Recarga e intenta de nuevo.';
          _sonidoError(); _vibrar([40, 30, 40]);
          btnOk.disabled = false;
          btnOk.textContent = labelDefault;
          return;
        }
        // ── ÉXITO ──────────────────────────────────────────────────────────
        // [v1.0.16 BUG 2] OPTIMISTA + ANTI-RETROCESO: marcamos ACTIVO + cache +
        // marca recienAprobado (sobrevive reload). A partir de aquí NUNCA volvemos
        // a un estado de bloqueo por un re-verify lagueado (la marca lo protege en
        // _procesarRespuestaVerify). Nunca re-mostramos "verificando"/"sin auth".
        _state.estado = 'ACTIVO';
        _detenerPolling();
        _marcarRecienAprobado();
        // [v1.0.10 BUG E FIX] verifyVersion del backend para cachear sin re-fetch.
        var verBackend = parseInt(d.verifyVersion || 0, 10);
        if (verBackend > 0) _state.verifyVersion = verBackend;
        var fechaBackend = d.fechaHoyLima || _fechaHoyLima();
        _guardarCacheExitoso(fechaBackend, _state.verifyVersion);
        _sonidoAprobado();
        _vibrar(40);   // mockups §3 Estado 5

        // [v1.0.16] ÉXITO visual: check SVG que se traza (reduced-motion → estático).
        var modalContent = modal.querySelector('.da-insitu-modal');
        function _pintarSuccess(msg, sub) {
          if (!modalContent) return;
          modalContent.classList.remove('da-modal-shake');
          modalContent.innerHTML = ''
            + '<div style="text-align:center;padding:18px 0">'
            +   '<div class="da-check-wrap"><svg class="da-check-svg" viewBox="0 0 100 100" aria-hidden="true">'
            +     '<circle class="da-ck-ring" cx="50" cy="50" r="46"/>'
            +     '<path class="da-ck-tick" d="M28 52 L44 68 L74 34"/>'
            +   '</svg></div>'
            +   '<h3 style="margin:0 0 8px;color:#10b981;font-size:20px">' + _escapeHtml(msg) + '</h3>'
            +   '<p style="margin:0 0 6px;color:#cbd5e1;font-size:14px">Aprobado por <strong>' + _escapeHtml(d.aprobadoPor || 'admin') + '</strong></p>'
            +   '<p style="margin:0;color:#94a3b8;font-size:12px">' + _escapeHtml(sub || 'Entrando…') + '</p>'
            + '</div>';
        }
        // [v1.0.16 BUG 2] Transición DIRECTA a la app. Si la app ya está montada
        // (onAuth cableado) → fade-out overlay + onAuth() + evento authorized, SIN
        // reload duro (mockups §3 Estado 5: "sin reload duro si fue in-situ"). El
        // reload queda como respaldo (onAprobado de cada app puede recargar). Esto
        // ELIMINA el ciclo reload→re-verify→parpadeo "sin autorización".
        function _entrar(sub) {
          _pintarSuccess('¡Dispositivo activado!', sub || 'Entrando…');
          setTimeout(function() {
            try { if (modal && modal.parentNode) modal.parentNode.removeChild(modal); } catch(_) {}
            _transicionarAApp('insitu', d.aprobadoPor || 'admin');
          }, 900);
        }
        _pintarSuccess('¡Clave correcta!', 'Confirmando activación…');
        // Verificación de extremo a extremo contra mint-mos (solo si está cableado).
        if (_config.mintUrl && _config.sbAnon) {
          _confirmarMintListo(idActivar, !!d.shadowOk).then(function(ok) {
            if (!ok) {
              // No pudimos confirmar mint-mos. NO bloqueamos: el sync horario es la
              // red de respaldo y la lectura directa cae a GAS sin romper. Entramos
              // igual (optimista) avisando honestamente.
              _entrar('Sincronizando acceso directo (puede tardar unos minutos)…');
              return;
            }
            _entrar('Entrando…');
          });
        } else {
          // WH/ME u otra app sin mint-mos cableado → entrar directo.
          _entrar('Entrando…');
        }
      })
      .catch(function(e) {
        // Fallo de RED (no veredicto de clave) → mantener contexto, permitir reintento.
        if (errEl) errEl.textContent = 'Sin conexión: ' + (e && e.message || 'reintenta');
        _vibrar([40, 30, 40]);
        _sonidoError();
        btnOk.disabled = false;
        btnOk.textContent = labelDefault;
      });
  }

  // [v1.0.16 BUG 2] Transición OPTIMISTA a la app tras aprobación in-situ.
  // Evita el parpadeo "sin autorización": NO re-verifica antes de entrar. Si la
  // app está montada (onAuth cableado) hace fade-out del overlay + onAuth() +
  // evento authorized + onAprobado (wizard) en caliente. El reload se evita por
  // defecto; las apps cuyo onAprobado recarga heredarán la marca recienAprobado
  // (persistida) para que el boot post-reload NO parpadee tampoco.
  function _transicionarAApp(origen, porQuien) {
    _state.estado = 'ACTIVO';
    _arrancarHeartbeat();
    // Disparar el evento que Vue de la app escucha para flip de su ref inmediato.
    try {
      window.dispatchEvent(new CustomEvent('deviceauth:authorized', {
        detail: { porQuien: porQuien, origen: origen || 'insitu' }
      }));
    } catch(_) {}
    if (_config.onAuth) try { _config.onAuth(); } catch(_) {}
    // Fade-out del overlay (si estaba visible) + quitar pre-block + desbloquear.
    var ov = document.getElementById(OVERLAY_ID);
    function _quitarBloqueo() {
      if (document.documentElement) document.documentElement.classList.remove('da-pre-block');
      _desbloquearApp();
    }
    if (ov && !_reducedMotion()) {
      ov.classList.add('da-fade-out');
      setTimeout(function() { if (ov.parentNode) ov.parentNode.removeChild(ov); _quitarBloqueo(); }, 460);
    } else {
      if (ov && ov.parentNode) ov.parentNode.removeChild(ov);
      _quitarBloqueo();
    }
    // Wizard / setup post-aprobación (cada app decide; algunas recargan aquí).
    // La marca recienAprobado ya persiste → si la app recarga, el boot no parpadea.
    if (_config.onAprobado) setTimeout(function() {
      try { _config.onAprobado(); } catch(_) {}
    }, 700);
  }

  function _solicitarAcceso() {
    // Re-trigger verificación: registrarSesionDispositivo creará el row PENDIENTE
    _verificar().then(function(estado) {
      if (estado === 'PENDIENTE_APROBACION') {
        _toastAprobado('📤 Solicitud enviada al admin');
        _sonidoAprobado();
        _vibrar([30, 20, 30]);
      }
    }).catch(function(){});
  }

  // ── Verificación con singleton dedupe ────────────────────────
  function _verificar() {
    if (_verifyPromise) return _verifyPromise;
    _state.estado = 'VERIFICANDO';
    _mostrarUI('VERIFICANDO');
    _verifyPromise = _verificarReal().finally(function() { _verifyPromise = null; });
    return _verifyPromise;
  }

  function _verificarReal() {
    if (!_config.mosGasUrl) {
      // R2: sin URL configurada → fail-CLOSED
      _state.estado = 'SIN_VERIFICAR';
      _mostrarUI('SIN_VERIFICAR', 'MOS no configurado');
      return Promise.reject(new Error('MOS_GAS_URL no configurado'));
    }

    // [v1.0.7 BUG B FIX + v1.0.8 BUG D FIX] R4 + R1 coexisten:
    // - Cache local existe pero NO autoriza optimistamente
    // - Siempre verificamos server PRIMERO antes de quitar pre-block
    // - Si server confirma rápido (200-500ms), operador no nota latencia
    // - Si server falla (sin red), CAEMOS al cache para honrar R4 (fail-soft)
    //
    // v1.0.8: usamos silencioso=true para que un fetch fallido NO muestre
    // overlay SIN_VERIFICAR rojo momentáneo antes del fail-soft. Antes (v1.0.7)
    // el operador veía un flash "📡 Sin conexión" que después desaparecía,
    // confundiendo la UX.
    if (_cacheValidoHoy()) {
      return _consultarBackend(true).catch(function(e) {
        // Server falla con cache válido → R4 fail-soft silencioso: aceptar cache.
        // El overlay verde "Verificando dispositivo" se mantuvo todo el tiempo,
        // ahora pasamos a body visible sin flash de error intermedio.
        console.warn('[DeviceAuth] server falló con cache válido → fail-soft offline:', e.message);
        _state.estado = 'ACTIVO';
        _ocultarOverlay();
        if (_config.onAuth) try { _config.onAuth(); } catch(_){}
        _arrancarHeartbeat();
        return 'ACTIVO';
      });
    }

    // Sin cache → consulta backend BLOQUEANTE
    return _consultarBackend(false);
  }

  // [v1.0.15 FASE 3a] Dispatcher: flag ON → Supabase (registrar+verificar) con
  // FALLBACK a GAS en cualquier fallo de RPC; flag OFF → GAS directo (bit-idéntico
  // a v1.0.14). El procesamiento del estado (state-machine UI/cache/polling) es
  // COMÚN a ambos caminos vía _procesarRespuestaVerify → cero divergencia de auth.
  function _consultarBackend(silencioso) {
    if (!_devAuthDirecto()) {
      // ── Flag OFF: camino histórico INTACTO ──
      return _consultarBackendGAS(silencioso);
    }
    // ── Flag ON: Supabase directo. registrar_dispositivo refresca el heartbeat
    //    y (para WH/ME nuevos) crea PENDIENTE idempotente; verificar_dispositivo
    //    da el estado canónico. Para MOS, registrar devuelve NO_REGISTRADO sin
    //    insertar (master se aprueba in-situ) — coherente con GAS. Si CUALQUIER
    //    RPC falla → fallback transparente a GAS (auth nunca se queda sin red). ──
    var ua = (navigator.userAgent || '').substring(0, 200);
    return _rpcAnon('registrar_dispositivo', {
      id_dispositivo: _state.deviceId, app: _config.app,
      user_agent: ua, nombre_equipo: null
    }).then(function () {
      // El veredicto de estado lo da verificar_dispositivo (registrar solo
      // siembra/heartbea). Si registrar falla NO bloqueamos: igual verificamos.
      return _rpcAnon('verificar_dispositivo', {
        id_dispositivo: _state.deviceId, app: _config.app
      });
    }, function () {
      // registrar falló → intentar verificar igual (puede existir ya).
      return _rpcAnon('verificar_dispositivo', {
        id_dispositivo: _state.deviceId, app: _config.app
      });
    }).then(function (j) {
      var d = _mapVerifyResp(j);
      if (!d) throw new Error('verificar_dispositivo: respuesta sin estado');
      return _procesarRespuestaVerify(d, silencioso);
    }).catch(function (e) {
      console.warn('[DeviceAuth] auth directo falló → fallback GAS:', e && e.message);
      return _consultarBackendGAS(silencioso);
    });
  }

  function _consultarBackendGAS(silencioso) {
    var ua = (navigator.userAgent || '').substring(0, 200);
    var url = _config.mosGasUrl
      + '?action=registrarSesionDispositivo'
      + '&ID_Dispositivo=' + encodeURIComponent(_state.deviceId)
      + '&app=' + encodeURIComponent(_config.app)
      + '&userAgent=' + encodeURIComponent(ua);

    var ctrl = new AbortController();
    var timeout = setTimeout(function() { ctrl.abort(); }, 10000);

    return fetch(url, { signal: ctrl.signal })
      .then(function(r) { clearTimeout(timeout); return r.json(); })
      .then(function(j) {
        if (!j || j.ok === false) {
          throw new Error(j && j.error || 'Respuesta inválida del backend');
        }
        return _procesarRespuestaVerify(j.data || {}, silencioso);
      })
      .catch(function(e) {
        clearTimeout(timeout);
        if (silencioso) {
          console.warn('[DeviceAuth] refresh silencioso falló:', e.message);
          throw e;
        }
        _state.estado = 'SIN_VERIFICAR';
        _mostrarUI('SIN_VERIFICAR', e.message || 'Error de red');
        if (_config.onError) try { _config.onError(e); } catch(_){}
        throw e;
      });
  }

  // [v1.0.15] State-machine COMÚN (extraída de _consultarBackend v1.0.14, sin
  // cambios de lógica). Recibe el `d` ya desempaquetado (GAS: j.data; directo:
  // _mapVerifyResp(rpc)). Decide estado, cache, polling/heartbeat y UI.
  function _procesarRespuestaVerify(d, silencioso) {
    return Promise.resolve().then(function() {
        d = d || {};
        // R5: validar verifyVersion — si el server bumpó, invalidar cache local
        var storedVer = parseInt(_lsGet(_config.storageKeys.verifyVersion) || '0', 10);
        var serverVer = parseInt(d.verifyVersion || 0, 10);
        // [v1.0.9 BUG E FIX] Solo invalidar cache si el cliente TENÍA una versión
        // válida vieja. Si storedVer=0 (cliente nuevo o in-situ recién hecho),
        // no había nada que invalidar — solo registramos la versión actual.
        // Antes: cliente in-situ → cache con verifyVersion=0 → next boot detecta
        // serverVer=1 > 0 → invalida cache → re-fetch → re-guarda. Bucle ineficiente.
        if (serverVer > storedVer && serverVer > 0 && storedVer > 0) {
          _invalidarCache();
          // Si era refresh background, no re-disparar (evitar loop). Frontend
          // tomará efecto en el siguiente boot natural.
        }

        _state.verifyVersion = serverVer;

        // [v1.0.10] Sincronizar extensión de horario in-situ con el módulo
        // ExtensorHorario (si está cargado en esta app). El backend manda
        // 'desbloqueo_temporal_hasta' = ISO string en _payloadDeviceAuthExtras.
        // - Si viene un TS futuro → guardarlo localmente para que el flow
        //   fuera-de-horario lo respete sin volver a consultar backend.
        // - Si viene vacío o pasado → limpiar localmente (extensión vencida o
        //   revocada por admin desde panel).
        try {
          if (window.ExtensorHorario && typeof d.desbloqueo_temporal_hasta !== 'undefined') {
            var dthIso = String(d.desbloqueo_temporal_hasta || '').trim();
            if (dthIso) {
              var dthMs = Date.parse(dthIso);
              if (!isNaN(dthMs) && dthMs > Date.now()) {
                ExtensorHorario.guardarLocal(dthIso);
              } else {
                ExtensorHorario.limpiar();
              }
            } else {
              ExtensorHorario.limpiar();
            }
          }
        } catch(_) {}

        // [v1.0.16 BUG 2] RED ANTI-RETROCESO post-aprobación. Si acabamos de
        // aprobar in-situ (marca recienAprobado vigente, ≤90s, sobrevive reload) y
        // el server devuelve un estado de NO-revocación lagueado (NO_REGISTRADO o
        // PENDIENTE: la sombra/hoja aún no propagó la aprobación), NO retrocedemos a
        // un estado de bloqueo — eso causaba el parpadeo "equipo sin autorización"
        // tras aprobar. Lo tratamos como ACTIVO (fail-soft optimista). Sólo aplica a
        // estos dos estados NO-críticos. La REVOCACIÓN REAL (INACTIVO/SUSPENDIDO/
        // forzar_reverify/verBump) NUNCA es bloqueada por esta marca → fail-closed
        // se mantiene: un device revocado a los segundos de aprobado igual se cierra.
        var verBumpReal = serverVer > storedVer && serverVer > 0 && storedVer > 0;
        var esRevocacionReal = d.estado === 'INACTIVO' || d.estado === 'SUSPENDIDO'
                            || d.forzar_reverify === true || verBumpReal;
        // [FIX SEGURIDAD 40x] La marca SUPRIME el retroceso de un estado YA autorizado en ESTA sesión
        // (_state.estado==='ACTIVO'), NO autoriza la entrada en un boot fresco. Sin esta guarda, setear
        // localStorage['da_optimista_ts'] a mano hacía entrar a un device NO aprobado 90s (bypass del gate
        // frontend). En boot fresco _state.estado arranca INIT/VERIFICANDO → no aplica → cierra el bypass.
        // El caso legítimo (aprobar in-situ sin reload → _state.estado='ACTIVO' → re-verify lagueado) se preserva.
        if (_state.estado === 'ACTIVO' && _optimistaVigente() && !esRevocacionReal
            && (d.estado === 'NO_REGISTRADO' || d.estado === 'PENDIENTE_APROBACION')) {
          // Propagación pendiente tras aprobar → mantener ACTIVO, sin parpadeo.
          if (!silencioso) console.warn('[DeviceAuth] re-verify lagueado (' + d.estado + ') ignorado: aprobación reciente vigente (anti-retroceso).');
          _state.estado = 'ACTIVO';
          _guardarCacheExitoso(d.fechaHoyLima, _state.verifyVersion);
          _ocultarOverlay();
          if (_config.onAuth) try { _config.onAuth(); } catch(_) {}
          _arrancarHeartbeat();
          _detenerPolling();
          return 'ACTIVO';
        }
        // Si el server YA confirma ACTIVO, la propagación terminó → limpiar marca.
        if ((d.estado === 'ACTIVO' || d.autorizado === true)) _limpiarRecienAprobado();
        // Revocación real tras aprobar → la marca no debe sobrevivir al bloqueo.
        if (esRevocacionReal) _limpiarRecienAprobado();

        if (d.estado === 'ACTIVO' || d.autorizado === true) {
          // [BUG A FIX] Si pasamos de PENDIENTE a ACTIVO → SIEMPRE celebrar,
          // sin importar quién originó el fetch (polling silencioso o boot).
          // El polling siempre pasa silencioso=true, por eso antes nunca se
          // disparaba el sonido al ser aprobado vía panel remoto.
          var fueAprobacion = (_state.estado === 'PENDIENTE_APROBACION');
          _state.estado = 'ACTIVO';
          _guardarCacheExitoso(d.fechaHoyLima, serverVer);
          if (fueAprobacion) {
            _onAprobacionDetectada(d.nombre || 'admin');
          } else {
            _ocultarOverlay();
            if (_config.onAuth) try { _config.onAuth(); } catch(_){}
          }
          _arrancarHeartbeat();
          _detenerPolling();
          return 'ACTIVO';
        }
        if (d.estado === 'PENDIENTE_APROBACION') {
          _state.estado = 'PENDIENTE_APROBACION';
          // [v1.0.9 BUG T FIX] CRÍTICO SEGURIDAD: invalidar cache si server retorna
          // PENDIENTE — antes el path solo mostraba UI pero no invalidaba cache.
          // Escenario explotable: admin marca PENDIENTE en sheet SIN bumpar
          // verifyVersion (edit manual). Próximo boot offline → cache válido →
          // fail-soft → autoriza con cache obsoleto = bypass. Ahora invalidamos
          // siempre que el server emita PENDIENTE, igual que en INACTIVO/SUSPENDIDO.
          _invalidarCache();
          _mostrarUI('PENDIENTE_APROBACION');
          if (_config.onPending) try { _config.onPending(); } catch(_){}
          _arrancarPolling();
          return 'PENDIENTE_APROBACION';
        }
        if (d.estado === 'INACTIVO') {
          _state.estado = 'INACTIVO';
          _invalidarCache();
          _mostrarUI('INACTIVO', d.error);
          if (_config.onInactive) try { _config.onInactive(); } catch(_){}
          _detenerPolling();
          _detenerHeartbeat();
          return 'INACTIVO';
        }
        if (d.estado === 'SUSPENDIDO') {
          _state.estado = 'SUSPENDIDO';
          _invalidarCache();
          _mostrarUI('SUSPENDIDO', d.error);
          if (_config.onSuspended) try { _config.onSuspended(); } catch(_){}
          // [v1.0.9 BUG JJ FIX] Estado terminal — detener polling y heartbeat.
          // Antes el polling seguía cada 15s para siempre si SUSPENDIDO fue detectado
          // desde un PENDIENTE previo (polling ya estaba corriendo).
          _detenerPolling();
          _detenerHeartbeat();
          return 'SUSPENDIDO';
        }
        if (d.estado === 'NO_REGISTRADO') {
          _state.estado = 'NO_REGISTRADO';
          _mostrarUI('NO_REGISTRADO');
          if (_config.onNoRegistered) try { _config.onNoRegistered(); } catch(_){}
          // [v1.0.9 BUG JJ FIX] Caso típico: cron cancelarPendientesAntiguos20h
          // mata un PENDIENTE → frontend recibe NO_REGISTRADO en el próximo poll.
          // Sin estos detener, el polling seguía indefinidamente.
          _detenerPolling();
          _detenerHeartbeat();
          return 'NO_REGISTRADO';
        }
        // Estado desconocido → fail-CLOSED
        _state.estado = 'SIN_VERIFICAR';
        _mostrarUI('SIN_VERIFICAR', 'Estado desconocido: ' + d.estado);
        _detenerPolling();
        _detenerHeartbeat();
        return 'SIN_VERIFICAR';
    }).catch(function(e) {
        // [v1.0.15] Fail-CLOSED si el procesamiento mismo lanza. (Los fallos de
        // RED del GAS se manejan en _consultarBackendGAS; los del directo en el
        // dispatcher con fallback a GAS — aquí solo cae un throw de la máquina.)
        if (silencioso) {
          console.warn('[DeviceAuth] procesar verify falló (silencioso):', e.message);
          throw e;
        }
        _state.estado = 'SIN_VERIFICAR';
        _mostrarUI('SIN_VERIFICAR', e.message || 'Error de verificación');
        if (_config.onError) try { _config.onError(e); } catch(_){}
        throw e;
      });
  }

  // ── Polling 15s mientras PENDIENTE_APROBACION ────────────────
  function _arrancarPolling() {
    if (_state.pollingTimer) return;
    _state.pollingTimer = setInterval(function() {
      // [v1.0.9 BUG H FIX] No quemar fetches mientras la pestaña está oculta.
      // setInterval en background tab Chrome se ralentiza pero sigue corriendo;
      // si el operador deja la app en background varias horas en PENDIENTE,
      // hacíamos cientos de requests innecesarios. visibilitychange handler
      // ya re-verifica al volver a foreground si cambió el día Lima.
      if (document.visibilityState === 'hidden') return;
      _consultarBackend(true).catch(function(){});  // _consultarBackend ya cambia el estado y dispara onAprobacionDetectada si pasa a ACTIVO
    }, 15000);
  }
  function _detenerPolling() {
    if (_state.pollingTimer) {
      clearInterval(_state.pollingTimer);
      _state.pollingTimer = null;
    }
  }

  // ── Heartbeat 10min: consulta Forzar_ReVerify + bump verifyVersion ──
  // [v1.0.10] Bajado de 1h a 10min para reducir ventana de detección de
  // revocación. Antes una revocación tardaba hasta 1h en propagarse al
  // cliente; ahora <10min. Trade-off: 6 fetches/h por cliente vs 1.
  // Acceptable: el endpoint es liviano y respeta visibilityState.
  function _arrancarHeartbeat() {
    if (_state.heartbeatTimer) return;
    _state.heartbeatTimer = setInterval(function() {
      // [v1.0.10 BUG H consistent] Saltar heartbeat si pestaña oculta
      if (document.visibilityState === 'hidden') return;
      // [v1.0.15 FASE 3a] Flag ON → heartbeat directo (verificar + denylist);
      // flag OFF → GAS (bit-idéntico v1.0.14).
      if (_devAuthDirecto()) { _heartbeatDirecto(); }
      else { _heartbeatGAS(); }
    }, 10 * 60 * 1000);  // 10 min (antes 1h)
  }

  // [v1.0.15] Aplica la decisión de bloqueo COMÚN a ambos caminos (GAS/directo).
  // `d` es el shape camelCase del estado. Cualquier estado/flag de revocación →
  // invalida cache, detiene heartbeat y re-verifica (que mostrará el overlay).
  function _aplicarDecisionHeartbeat(d) {
    if (!d) return;
    // [BUG B FIX + v1.0.9 BUG N FIX] Detectar TODOS los casos que requieren bloquear:
    //   - forzar_reverify · INACTIVO/SUSPENDIDO · NO_REGISTRADO · PENDIENTE · verBump
    var serverVer = parseInt(d.verifyVersion || 0, 10);
    var storedVer = parseInt(_lsGet(_config.storageKeys.verifyVersion) || '0', 10);
    var verBump = serverVer > 0 && serverVer > storedVer;
    var debeBloquear = d.forzar_reverify === true
                    || d.estado === 'INACTIVO'
                    || d.estado === 'SUSPENDIDO'
                    || d.estado === 'NO_REGISTRADO'
                    || d.estado === 'PENDIENTE_APROBACION'
                    || verBump;
    if (debeBloquear) {
      _invalidarCache();
      _detenerHeartbeat();
      _verificar();
    }
    // [v1.0.11] Sincronizar extensión de horario in-situ (revocación de extensión
    // desde panel admin se propaga sin esperar reload / cambio de día Lima).
    try {
      if (window.ExtensorHorario && typeof d.desbloqueo_temporal_hasta !== 'undefined') {
        var dthIso = String(d.desbloqueo_temporal_hasta || '').trim();
        if (dthIso) {
          var dthMs = Date.parse(dthIso);
          if (!isNaN(dthMs) && dthMs > Date.now()) { ExtensorHorario.guardarLocal(dthIso); }
          else { ExtensorHorario.limpiar(); }
        } else { ExtensorHorario.limpiar(); }
      }
    } catch(_) {}
  }

  function _heartbeatGAS() {
    var url = _config.mosGasUrl
      + '?action=consultarEstadoDispositivo'
      + '&deviceId=' + encodeURIComponent(_state.deviceId);
    fetch(url).then(function(r){ return r.json(); }).then(function(j) {
      _aplicarDecisionHeartbeat(j && j.data);
    }).catch(function(){});
  }

  // [v1.0.15 FASE 3a] Heartbeat DIRECTO: (1) verificar_dispositivo da estado +
  // verify_version + extensión; (2) DENYLIST — get_flags().dispositivos_revocados:
  // si el id propio aparece, bloquear de inmediato (revocación ≤2min, sin esperar
  // que el estado per-device propague). Ambas fuentes son best-effort: un fallo de
  // red NO desbloquea (fail-closed mantiene el estado ACTIVO actual del cache del
  // día; el próximo tick reintenta). NO cae a GAS aquí: con flag ON la sombra es
  // el maestro; el bloqueo solo se ENDURECE, nunca se relaja por error de red.
  function _heartbeatDirecto() {
    // (2) Denylist primero (corta más rápido y es barata).
    _getFlagsAnon().then(function(flags) {
      var rev = flags && flags.dispositivos_revocados;
      if (Array.isArray(rev) && _state.deviceId && rev.indexOf(_state.deviceId) !== -1) {
        // Revocado en la flota → bloquear ya (equivale a INACTIVO/SUSPENDIDO).
        _aplicarDecisionHeartbeat({ estado: 'INACTIVO' });
        return null;  // no hace falta verificar estado puntual; ya bloqueamos
      }
      // No revocado → consultar estado puntual + extensión.
      return _rpcAnon('verificar_dispositivo', {
        id_dispositivo: _state.deviceId, app: _config.app
      }).then(function(j) {
        _aplicarDecisionHeartbeat(_mapVerifyResp(j));
      });
    }).catch(function(e) {
      // get_flags falló → intentar al menos el estado puntual (no relaja nada).
      _rpcAnon('verificar_dispositivo', {
        id_dispositivo: _state.deviceId, app: _config.app
      }).then(function(j) {
        _aplicarDecisionHeartbeat(_mapVerifyResp(j));
      }).catch(function(){});
    });
  }
  function _detenerHeartbeat() {
    if (_state.heartbeatTimer) {
      clearInterval(_state.heartbeatTimer);
      _state.heartbeatTimer = null;
    }
  }

  // ── Trigger de aprobación detectada (polling REMOTO) ──────────
  // [v1.0.16] El operador esperaba en PENDIENTE y el admin aprobó desde el panel.
  // Celebramos (check + acorde + vibrate) y transicionamos OPTIMISTA a la app.
  // Marcamos recienAprobado para que el boot post-reload (apps que recargan en
  // onAprobado) NO parpadee "sin autorización" mientras la sombra/hoja propaga.
  function _onAprobacionDetectada(porQuien) {
    _state.estado = 'ACTIVO';
    _detenerPolling();
    _marcarRecienAprobado();
    _guardarCacheExitoso(_fechaHoyLima(), _state.verifyVersion);
    _sonidoAprobado();
    _vibrar(40);
    // Pintar un check de éxito sobre el overlay actual (si sigue visible), luego
    // transición suave. Si el overlay ya no está, el toast cubre el feedback.
    var ov = document.getElementById(OVERLAY_ID);
    if (ov) {
      ov.innerHTML = ''
        + '<div class="da-check-wrap"><svg class="da-check-svg" viewBox="0 0 100 100" aria-hidden="true">'
        +   '<circle class="da-ck-ring" cx="50" cy="50" r="46"/>'
        +   '<path class="da-ck-tick" d="M28 52 L44 68 L74 34"/>'
        + '</svg></div>'
        + '<h1 class="da-h1">¡Dispositivo aprobado!</h1>'
        + '<p class="da-p">Aprobado por <strong>' + _escapeHtml(porQuien) + '</strong> · entrando…</p>';
    } else {
      _toastAprobado('✅ Aprobado por ' + porQuien + ' · iniciando…');
    }
    setTimeout(function() { _transicionarAApp('remoto', porQuien); }, 900);
  }

  // ── visibilitychange: si vuelve de background y cambió el día Lima, re-verificar ──
  function _onVisibilityChange() {
    if (document.visibilityState !== 'visible') return;
    // [v1.0.9 BUG H FIX] Si estamos en PENDIENTE_APROBACION y la pestaña vuelve
    // a foreground, hacer un fetch inmediato sin esperar 15s al próximo tick
    // del polling (que pudo haberse saltado mientras estaba en background).
    if (_state.estado === 'PENDIENTE_APROBACION') {
      _consultarBackend(true).catch(function(){});
      return;
    }
    if (_state.estado !== 'ACTIVO') return;
    // Si el día cambió, invalidar cache + re-verificar
    if (!_cacheValidoHoy()) {
      _invalidarCache();
      _verificar();
    }
  }

  // ── API pública ──────────────────────────────────────────────
  function init(config) {
    if (!config || !config.mosGasUrl || !config.app || !config.storageKeys) {
      console.error('[DeviceAuth] init requiere { mosGasUrl, app, storageKeys }');
      return Promise.reject(new Error('init config inválido'));
    }
    _config = config;
    // [v1.0.14] Log de versión honesta al boot. Un desync de ?v= entre apps se
    // ve acá (la versión REAL del módulo servido, no el pin del <script>).
    try { console.log('[DeviceAuth] v' + _VERSION + ' en ' + config.app); } catch(_) {}
    // Suscribirse a visibilitychange
    if (!_state.visibilityHandler) {
      _state.visibilityHandler = _onVisibilityChange;
      document.addEventListener('visibilitychange', _state.visibilityHandler);
    }
    // [v1.0.13] Resolver el deviceId RESILIENTE (multi-store) ANTES de verificar.
    // Es async (IndexedDB/Cache), por eso init ahora encadena la verificación.
    // Mientras resuelve, mostramos el overlay "verificando" (fail-closed visual).
    // [v1.0.16 BUG 2] Heredar la marca optimista si venimos de un reload post-
    // aprobación (persistida en localStorage). Así el primer re-verify no parpadea.
    _state.recienAprobado = _optimistaVigente();
    _state.estado = 'VERIFICANDO';
    _mostrarUI('VERIFICANDO');
    return _resolverDeviceId().then(function(id) {
      // [v1.0.16 BUG 1] _setDeviceId actualiza EN VIVO los nodos del UUID ya
      // pintados (overlay/modal) → "(sin id)"/"generando ID…" se reemplaza por el
      // id real apenas resuelve. Nunca queda vacío.
      _setDeviceId(id);
      return _verificar().then(function(estado) {
        // [v1.0.13] Red de seguridad PASIVA contra el "401-silencioso": si el
        // device quedó ACTIVO (por GAS) pero mint-mos NO emite token (sombra
        // mos.dispositivos desincronizada — p.ej. aprobado por panel-remoto pero
        // el sync horario murió), lo detectamos y AVISAMOS. NO bloqueamos (la
        // lectura directa cae a GAS sin romper), pero el master ve que el acceso
        // directo no está listo en vez de un fallo mudo. Solo aplica a MOS
        // (mintUrl cableada). Fire-and-forget, fuera del camino crítico.
        if (estado === 'ACTIVO' && _config.mintUrl && _config.sbAnon) {
          _confirmarMintListo(_state.deviceId, false).then(function(ok) {
            if (!ok) {
              console.warn('[DeviceAuth] ACTIVO pero mint-mos no emite token: sombra mos.dispositivos desincronizada. Acceso directo caerá a GAS hasta el próximo sync. Reaprueba in-situ si el problema persiste.');
              try {
                window.dispatchEvent(new CustomEvent('deviceauth:mint-degradado', {
                  detail: { deviceId: _state.deviceId }
                }));
              } catch(_) {}
            }
          });
        }
        return estado;
      });
    });
  }

  window.DeviceAuth = {
    VERSION: _VERSION,
    init: init,
    estado: function() { return JSON.parse(JSON.stringify(_state)); },
    deviceId: function() { return _state.deviceId; },
    forzarReVerify: function() {
      _invalidarCache();
      _detenerPolling();
      _detenerHeartbeat();
      return _verificar();
    },
    isAuthorized: function() { return _state.estado === 'ACTIVO'; },
    cerrarSesion: function() {
      _invalidarCache();
      _detenerPolling();
      _detenerHeartbeat();
      // [v1.0.9 BUG LL FIX] Limpiar promise zombi — antes próxima init() reusaba
      // la promesa pendiente (que nunca resolvía si cerrarSesion la abortó).
      _verifyPromise = null;
      if (_state.visibilityHandler) {
        document.removeEventListener('visibilitychange', _state.visibilityHandler);
        _state.visibilityHandler = null;
      }
      _ocultarOverlay();
    }
  };
})();
