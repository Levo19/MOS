// ════════════════════════════════════════════════════════════════════
// DeviceAuth — módulo compartido de verificación de dispositivos
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

  var _config = null;
  var _state = {
    deviceId: null,
    estado: 'INIT',        // INIT | VERIFICANDO | ACTIVO | PENDIENTE_APROBACION | INACTIVO | SUSPENDIDO | NO_REGISTRADO | SIN_VERIFICAR
    // [v1.0.9 BUG Q cleanup] Removido fechaUltimaVerifLima — nunca se asignaba.
    verifyVersion: 0,
    pollingTimer: null,
    heartbeatTimer: null,
    visibilityHandler: null
  };
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
      '#' + OVERLAY_ID + '{position:fixed;inset:0;z-index:99997;background:linear-gradient(135deg,#0c1426 0%,#1e293b 50%,#0c1426 100%);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;color:#e2e8f0;font-family:system-ui,-apple-system,sans-serif;text-align:center}',
      '#' + OVERLAY_ID + ' .da-emoji{font-size:64px;margin-bottom:18px;animation:da-pulse 1.6s ease-in-out infinite}',
      '#' + OVERLAY_ID + ' .da-h1{font-size:22px;font-weight:800;margin:0 0 8px;color:#f1f5f9}',
      '#' + OVERLAY_ID + ' .da-p{font-size:14px;color:#94a3b8;max-width:440px;line-height:1.5;margin:0 0 6px}',
      '#' + OVERLAY_ID + ' .da-dev{font-family:monospace;font-size:11px;color:#fbbf24;background:rgba(251,191,36,.1);padding:6px 12px;border-radius:6px;margin-top:12px;letter-spacing:.5px;word-break:break-all;max-width:90%}',
      '#' + OVERLAY_ID + ' .da-actions{display:flex;gap:10px;margin-top:24px;flex-wrap:wrap;justify-content:center}',
      // [v1.0.3 FIX] Estilos .da-btn GLOBALES — antes scopados a #deviceAuthOverlay,
      // por eso los botones del modal in-situ aparecían SIN colores (solo el
      // padding genérico de .da-insitu-actions button). Ahora aplican en ambos.
      '.da-btn{padding:12px 22px;border-radius:10px;font-weight:800;font-size:14px;border:1px solid transparent;cursor:pointer;transition:transform .15s,background .15s,box-shadow .15s;display:inline-flex;align-items:center;justify-content:center;gap:6px}',
      '.da-btn:active{transform:scale(.96)}',
      '.da-btn-primary{background:linear-gradient(135deg,#10b981,#059669);color:#fff;box-shadow:0 4px 14px -2px rgba(16,185,129,.45)}',
      '.da-btn-primary:hover{box-shadow:0 6px 20px -2px rgba(16,185,129,.6)}',
      '.da-btn-secondary{background:#1e293b;color:#e2e8f0;border-color:#334155}',
      '.da-btn-secondary:hover{background:#334155}',
      '.da-btn-warn{background:rgba(239,68,68,.15);color:#fca5a5;border-color:rgba(239,68,68,.4)}',
      '.da-btn-warn:hover{background:rgba(239,68,68,.25)}',
      '@keyframes da-pulse{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(.94);opacity:.85}}',
      '@keyframes da-pop{from{opacity:0;transform:scale(.85)}to{opacity:1;transform:scale(1)}}',
      // Modal in-situ
      '.da-insitu-overlay{position:fixed;inset:0;background:rgba(2,6,23,.85);backdrop-filter:blur(8px);z-index:99999;display:flex;align-items:center;justify-content:center;padding:16px}',
      '.da-insitu-modal{width:100%;max-width:420px;background:#0a1424;border:1px solid rgba(16,185,129,.4);border-radius:18px;padding:24px;animation:da-pop .3s ease-out}',
      '.da-insitu-modal h3{margin:0 0 16px;color:#10b981;font-size:18px;font-weight:800}',
      '.da-insitu-modal label{display:block;margin:12px 0 6px;color:#cbd5e1;font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.5px}',
      '.da-insitu-modal input{width:100%;padding:10px 12px;border-radius:8px;background:#070d18;border:1px solid #334155;color:#f1f5f9;font-size:14px;box-sizing:border-box}',
      '.da-insitu-modal input:focus{outline:none;border-color:#10b981}',
      '.da-insitu-err{color:#fca5a5;font-size:12px;margin-top:8px;min-height:18px}',
      '.da-insitu-actions{display:flex;gap:8px;margin-top:18px}',
      '.da-insitu-actions button{flex:1;padding:11px;border-radius:8px;font-weight:800;font-size:14px;border:0;cursor:pointer}',
      '.da-insitu-hint{font-size:11px;color:#64748b;margin-top:8px;line-height:1.4}',
      // Toast aprobado
      '#daApproveToast{position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);background:linear-gradient(135deg,#10b981,#059669);color:#fff;padding:24px 36px;border-radius:16px;font-size:18px;font-weight:800;z-index:99998;box-shadow:0 20px 60px rgba(16,185,129,.4);animation:da-pop .4s ease-out}',
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
    var ov = document.createElement('div');
    ov.id = OVERLAY_ID;
    // [v1.0.13] Mostrar el deviceId COMPLETO (antes solo 12 chars + "...").
    // El master necesita ver/compartir el id EXACTO que va a aprobar, y así
    // confirmar que coincide con el que el device usa para mint-mos. Escapado.
    var devFull = _escapeHtml(_state.deviceId || '(sin id)');
    var actions = '';
    if (opts.actions) {
      opts.actions.forEach(function(a) {
        actions += '<button class="da-btn da-btn-' + (a.style || 'secondary') + '" data-act="' + a.id + '">' + a.label + '</button>';
      });
    }
    ov.innerHTML = ''
      + '<div class="da-emoji">' + (opts.emoji || '🔄') + '</div>'
      + '<h1 class="da-h1">' + opts.title + '</h1>'
      + '<p class="da-p">' + opts.detail + '</p>'
      + (opts.subDetail ? '<p class="da-p" style="font-size:12px;color:#64748b">' + opts.subDetail + '</p>' : '')
      + '<div class="da-dev" id="daDevId" title="Toca para copiar el ID del dispositivo">' + devFull + '</div>'
      + (actions ? '<div class="da-actions">' + actions + '</div>' : '');
    _appendCuandoListo(ov);
    // Copiar el deviceId al tocarlo (útil para soporte / aprobación remota).
    var devEl = ov.querySelector('#daDevId');
    if (devEl) devEl.addEventListener('click', function() {
      try {
        if (navigator.clipboard) navigator.clipboard.writeText(_state.deviceId || '');
        var prev = devEl.textContent;
        devEl.textContent = '✓ ID copiado';
        setTimeout(function(){ devEl.textContent = prev; }, 1200);
        _vibrar(20);
      } catch(_) {}
    });
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
      _renderOverlay({
        emoji: '🔄', title: 'Verificando dispositivo',
        detail: 'Conectando con MOS...',
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
      _renderOverlay({
        emoji: '🚫', title: 'Dispositivo desactivado',
        detail: extra || 'Este dispositivo fue desactivado por el administrador.',
        subDetail: 'Contacta al admin si necesitas reactivarlo.',
        actions: []
      });
    } else if (estado === 'SUSPENDIDO') {
      _renderOverlay({
        emoji: '⏸', title: 'Dispositivo suspendido',
        detail: extra || 'Tu dispositivo fue suspendido por inactividad (>7 días sin uso).',
        subDetail: 'Pide reactivación al admin (panel) o usa "Reactivar in-situ" con clave.',
        actions: [
          { id: 'reactivar', label: '🔑 Reactivar in-situ (admin presente)', style: 'primary',
            onClick: function() { _abrirModalInSitu(true); } }
        ]
      });
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
    // [v1.0.13] Mostrar el UUID EXACTO que se va a activar — el master ve qué
    // aprueba (es el mismo id que el device usa para mint-mos: imposible desfase).
    var devFullModal = _escapeHtml(_state.deviceId || '(sin id)');
    ov.innerHTML = ''
      + '<div class="da-insitu-modal">'
      +   '<h3>' + titulo + '</h3>'
      +   '<div style="font-size:11px;color:#94a3b8;margin-bottom:6px">Se activará este dispositivo:</div>'
      +   '<div class="da-dev" style="margin:0 0 8px;display:block" title="ID que quedará ACTIVO">' + devFullModal + '</div>'
      +   (esReactivar ? '' : '<label>Nombre del equipo</label><input id="daIsNombre" type="text" placeholder="ej. Caja Principal · Almacén · Tablet 2" maxlength="60">')
      +   '<label>Clave admin (8 dígitos)</label>'
      +   '<input id="daIsClave" type="password" inputmode="numeric" pattern="[0-9]*" maxlength="8" autocomplete="off" placeholder="••••••••">'
      +   '<div class="da-insitu-hint">' + hint + '</div>'
      +   '<div class="da-insitu-err" id="daIsErr"></div>'
      +   '<div class="da-insitu-actions">'
      +     '<button class="da-btn da-btn-secondary" id="daIsCancel">Cancelar</button>'
      +     '<button class="da-btn da-btn-primary" id="daIsOk">' + (esReactivar ? 'Reactivar' : 'Activar') + '</button>'
      +   '</div>'
      + '</div>';
    _appendCuandoListo(ov);  // [v1.0.1] body puede no existir aún
    setTimeout(function() {
      var clave = document.getElementById('daIsClave');
      if (clave) clave.focus();
    }, 80);
    document.getElementById('daIsCancel').onclick = function() { ov.remove(); };
    document.getElementById('daIsOk').onclick = function() {
      _confirmarInSitu(esReactivar, ov);
    };
    // [v1.0.7 BUG A FIX] ENTER en clave → confirmar PERO respetar btnOk.disabled.
    // Antes ENTER ignoraba el disabled, lo que permitía doble-fire del fetch.
    document.getElementById('daIsClave').addEventListener('keydown', function(e) {
      if (e.key !== 'Enter') return;
      var btn = document.getElementById('daIsOk');
      if (btn && btn.disabled) return;  // ← bloquear si ya está procesando
      _confirmarInSitu(esReactivar, ov);
    });
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
    if (errEl) errEl.textContent = '';
    if (!/^\d{8}$/.test(clave)) {
      if (errEl) errEl.textContent = 'La clave debe ser de 8 dígitos numéricos';
      _vibrar([40, 30, 40]);
      _sonidoError();
      return;
    }
    btnOk.disabled = true;
    btnOk.textContent = 'Validando...';

    var ua = (navigator.userAgent || '').substring(0, 200);
    var endpoint = esReactivar ? 'reactivarDispositivoSuspendido' : 'aprobarDispositivoEnSitu';
    // [v1.0.13] Aprobar el deviceId que el navegador usa AHORA. _state.deviceId
    // ya fue resuelto (multi-store) en init() y es exactamente el que api.js usa
    // para mint-mos (misma fuente: DeviceAuth.deviceId() / localStorage). No hay
    // un id "cacheado viejo" distinto: el modal in-situ solo se abre tras init().
    var idActivar = _state.deviceId;
    var payload = {
      action:       endpoint,
      deviceId:     idActivar,
      claveAdmin:   clave,
      app:          _config.app,
      userAgent:    ua
    };
    if (!esReactivar) payload.nombreEquipo = nombre || ('Mobile ' + idActivar.substring(0, 6));

    fetch(_config.mosGasUrl, {
      method: 'POST', body: JSON.stringify(payload)
    })
      .then(function(r) { return r.json(); })
      .then(function(j) {
        var d = j && j.data;
        if (!d || !d.autorizado) {
          if (errEl) errEl.textContent = (d && d.error) || 'Clave incorrecta';
          _vibrar([40, 30, 40]);
          _sonidoError();
          btnOk.disabled = false;
          btnOk.textContent = esReactivar ? 'Reactivar' : 'Activar';
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
          btnOk.textContent = esReactivar ? 'Reactivar' : 'Activar';
          return;
        }
        // [v1.0.6 UX FIX] Feedback claro dentro del modal antes de cerrarlo.
        _state.estado = 'ACTIVO';
        _detenerPolling();
        // [v1.0.10 BUG E FIX] verifyVersion del backend para cachear sin re-fetch.
        var verBackend = parseInt(d.verifyVersion || 0, 10);
        if (verBackend > 0) _state.verifyVersion = verBackend;
        var fechaBackend = d.fechaHoyLima || _fechaHoyLima();
        _guardarCacheExitoso(fechaBackend, _state.verifyVersion);
        _sonidoAprobado();
        _vibrar([100, 50, 100, 50, 100]);

        // [v1.0.13 FIX RAÍZ] CONFIRMAR que la sombra mos.dispositivos quedó lista
        // ANTES de recargar. Sin esto, el device recargaba, intentaba mint-mos,
        // 401aba (sombra aún no propagada) y caía a GAS en silencio = el bug.
        //   · d.shadowOk === true  → el backend ya confirmó el upsert+read-back.
        //   · si además hay mintUrl configurada (MOS), verificamos en VIVO que
        //     mint-mos YA emite token para este id (verdad de extremo a extremo).
        var modalContent = modal.querySelector('.da-insitu-modal');
        function _pintarSuccess(msg, sub) {
          if (!modalContent) return;
          modalContent.innerHTML = ''
            + '<div style="text-align:center;padding:20px 0">'
            +   '<div style="font-size:64px;margin-bottom:14px;animation:da-pop .5s ease-out">✅</div>'
            +   '<h3 style="margin:0 0 8px;color:#10b981;font-size:20px">' + _escapeHtml(msg) + '</h3>'
            +   '<p style="margin:0 0 6px;color:#cbd5e1;font-size:14px">Aprobado por <strong>' + _escapeHtml(d.aprobadoPor || 'admin') + '</strong></p>'
            +   '<p style="margin:0;color:#94a3b8;font-size:12px">' + _escapeHtml(sub || 'Recargando aplicación...') + '</p>'
            + '</div>';
        }
        function _finalizarYRecargar() {
          _pintarSuccess('¡Dispositivo activado!', 'Recargando aplicación...');
          setTimeout(function() { location.reload(); }, 1200);
        }
        _pintarSuccess('¡Clave correcta!', 'Confirmando activación...');
        // Verificación de extremo a extremo contra mint-mos (solo si está cableado).
        if (_config.mintUrl && _config.sbAnon) {
          _confirmarMintListo(idActivar, !!d.shadowOk).then(function(ok) {
            if (!ok) {
              // No pudimos confirmar mint-mos. NO bloqueamos para siempre: el sync
              // horario es la red de respaldo y la lectura directa cae a GAS sin
              // romper. Avisamos honestamente y recargamos igual.
              _pintarSuccess('¡Activado!', 'Sincronizando acceso directo (puede tardar unos minutos)...');
              setTimeout(function() { location.reload(); }, 1800);
              return;
            }
            _finalizarYRecargar();
          });
        } else {
          // WH/ME u otra app sin mint-mos cableado → comportamiento previo.
          _finalizarYRecargar();
        }
      })
      .catch(function(e) {
        if (errEl) errEl.textContent = 'Sin conexión: ' + (e && e.message || 'reintenta');
        _vibrar([40, 30, 40]);
        _sonidoError();
        btnOk.disabled = false;
        btnOk.textContent = esReactivar ? 'Reactivar' : 'Activar';
      });
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

  function _consultarBackend(silencioso) {
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
        var d = j.data || {};

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
      var url = _config.mosGasUrl
        + '?action=consultarEstadoDispositivo'
        + '&deviceId=' + encodeURIComponent(_state.deviceId);
      fetch(url).then(function(r){ return r.json(); }).then(function(j) {
        var d = j && j.data;
        if (!d) return;
        // [BUG B FIX + v1.0.9 BUG N FIX] Detectar TODOS los casos que requieren bloquear:
        //   - forzar_reverify: master forzó manualmente
        //   - INACTIVO/SUSPENDIDO: revocación
        //   - NO_REGISTRADO: master eliminó el row de la sheet
        //   - PENDIENTE_APROBACION: admin re-puso el dispositivo en pendiente (raro
        //     pero posible si master quiere re-verificar in-vivo) — antes el
        //     heartbeat ignoraba este estado y dejaba la app abierta hasta el día sig.
        //   - verifyVersion mayor: bump global
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
        // [v1.0.11] Sincronizar extensión de horario in-situ (mismo flow que
        // _consultarBackend pero aplicado al heartbeat). Sin esto, una revocación
        // de extensión desde el panel admin no se propagaría al cliente hasta
        // que el operador reload o cambie día Lima.
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
      }).catch(function(){});
    }, 10 * 60 * 1000);  // 10 min (antes 1h)
  }
  function _detenerHeartbeat() {
    if (_state.heartbeatTimer) {
      clearInterval(_state.heartbeatTimer);
      _state.heartbeatTimer = null;
    }
  }

  // ── Trigger de aprobación detectada (polling o in-situ) ──────
  function _onAprobacionDetectada(porQuien) {
    _state.estado = 'ACTIVO';
    _detenerPolling();
    _ocultarOverlay();
    // Toast + sonido + vibración (PROACTIVO según user)
    _toastAprobado('✅ Aprobado por ' + porQuien + ' · iniciando...');
    _sonidoAprobado();
    _vibrar([100, 50, 100, 50, 100]);
    _guardarCacheExitoso(_fechaHoyLima(), _state.verifyVersion);
    // [v1.0.3 FIX] Disparar evento custom para que Vue de la app pueda
    // actualizar su ref `dispositivoAutorizado` INMEDIATAMENTE sin esperar
    // al reload. Sin esto, Vue mostraba "verificando dispositivo" durante
    // 1.2s entre la aprobación y el reload (porque dispositivoAutorizado
    // seguía en null).
    try {
      var evt = new CustomEvent('deviceauth:authorized', { detail: { porQuien: porQuien } });
      window.dispatchEvent(evt);
    } catch(_) {}
    if (_config.onAuth) try { _config.onAuth(); } catch(_){}
    // Wizard de permisos / setup post-aprobación
    setTimeout(function() {
      if (_config.onAprobado) try { _config.onAprobado(); } catch(_){}
    }, 700);
    _arrancarHeartbeat();
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
    // Suscribirse a visibilitychange
    if (!_state.visibilityHandler) {
      _state.visibilityHandler = _onVisibilityChange;
      document.addEventListener('visibilitychange', _state.visibilityHandler);
    }
    // [v1.0.13] Resolver el deviceId RESILIENTE (multi-store) ANTES de verificar.
    // Es async (IndexedDB/Cache), por eso init ahora encadena la verificación.
    // Mientras resuelve, mostramos el overlay "verificando" (fail-closed visual).
    _state.estado = 'VERIFICANDO';
    _mostrarUI('VERIFICANDO');
    return _resolverDeviceId().then(function(id) {
      _state.deviceId = id;
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
