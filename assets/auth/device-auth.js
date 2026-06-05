// ════════════════════════════════════════════════════════════════════
// DeviceAuth — módulo compartido de verificación de dispositivos
// v1.0.0 — 2026-06-04
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
    fechaUltimaVerifLima: null,
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

  function _generarOLeerDeviceId() {
    var key = _config.storageKeys.deviceId;
    var existing = _lsGet(key);
    if (existing) return existing;
    var nuevo = (window.crypto && crypto.randomUUID)
      ? crypto.randomUUID()
      : ('D-' + Date.now() + '-' + Math.random().toString(36).substring(2, 10));
    _lsSet(key, nuevo);
    return nuevo;
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
    var existing = document.getElementById(OVERLAY_ID);
    if (existing) existing.remove();
    var ov = document.createElement('div');
    ov.id = OVERLAY_ID;
    var devShort = (_state.deviceId || '').substring(0, 12) + '...';
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
      + '<div class="da-dev" title="ID del dispositivo">' + devShort + '</div>'
      + (actions ? '<div class="da-actions">' + actions + '</div>' : '');
    _appendCuandoListo(ov);
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
    ov.innerHTML = ''
      + '<div class="da-insitu-modal">'
      +   '<h3>' + titulo + '</h3>'
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
    // ENTER en clave → confirmar
    document.getElementById('daIsClave').addEventListener('keydown', function(e) {
      if (e.key === 'Enter') _confirmarInSitu(esReactivar, ov);
    });
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
    var payload = {
      action:       endpoint,
      deviceId:     _state.deviceId,
      claveAdmin:   clave,
      app:          _config.app,
      userAgent:    ua
    };
    if (!esReactivar) payload.nombreEquipo = nombre || ('Mobile ' + _state.deviceId.substring(0, 6));

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
        modal.remove();
        _ocultarOverlay();
        _onAprobacionDetectada(d.aprobadoPor || 'admin');
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

    // R4: cache válido por día calendario Lima — entra OPTIMISTA + refresh bg
    if (_cacheValidoHoy()) {
      _state.estado = 'ACTIVO';
      _ocultarOverlay();
      if (_config.onAuth) try { _config.onAuth(); } catch(_){}
      _arrancarHeartbeat();
      // Refresh background con timeout corto, fail-soft (no rompe)
      setTimeout(function() {
        _consultarBackend(true).catch(function(){});
      }, 1500);
      return Promise.resolve('ACTIVO');
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
        if (serverVer > storedVer && serverVer > 0) {
          _invalidarCache();
          // Si era refresh background, no re-disparar (evitar loop). Frontend
          // tomará efecto en el siguiente boot natural.
        }

        _state.verifyVersion = serverVer;

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
          return 'INACTIVO';
        }
        if (d.estado === 'SUSPENDIDO') {
          _state.estado = 'SUSPENDIDO';
          _invalidarCache();
          _mostrarUI('SUSPENDIDO', d.error);
          if (_config.onSuspended) try { _config.onSuspended(); } catch(_){}
          return 'SUSPENDIDO';
        }
        if (d.estado === 'NO_REGISTRADO') {
          _state.estado = 'NO_REGISTRADO';
          _mostrarUI('NO_REGISTRADO');
          if (_config.onNoRegistered) try { _config.onNoRegistered(); } catch(_){}
          return 'NO_REGISTRADO';
        }
        // Estado desconocido → fail-CLOSED
        _state.estado = 'SIN_VERIFICAR';
        _mostrarUI('SIN_VERIFICAR', 'Estado desconocido: ' + d.estado);
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
      _consultarBackend(true).catch(function(){});  // _consultarBackend ya cambia el estado y dispara onAprobacionDetectada si pasa a ACTIVO
    }, 15000);
  }
  function _detenerPolling() {
    if (_state.pollingTimer) {
      clearInterval(_state.pollingTimer);
      _state.pollingTimer = null;
    }
  }

  // ── Heartbeat 1h: consulta Forzar_ReVerify + bump verifyVersion ──
  function _arrancarHeartbeat() {
    if (_state.heartbeatTimer) return;
    _state.heartbeatTimer = setInterval(function() {
      var url = _config.mosGasUrl
        + '?action=consultarEstadoDispositivo'
        + '&deviceId=' + encodeURIComponent(_state.deviceId);
      fetch(url).then(function(r){ return r.json(); }).then(function(j) {
        var d = j && j.data;
        if (!d) return;
        // [BUG B FIX] Detectar TODOS los casos que requieren bloquear:
        //   - forzar_reverify: master forzó manualmente
        //   - INACTIVO/SUSPENDIDO: revocación
        //   - NO_REGISTRADO: master eliminó el row de la sheet
        //   - verifyVersion mayor: bump global
        var serverVer = parseInt(d.verifyVersion || 0, 10);
        var storedVer = parseInt(_lsGet(_config.storageKeys.verifyVersion) || '0', 10);
        var verBump = serverVer > 0 && serverVer > storedVer;
        var debeBloquear = d.forzar_reverify === true
                        || d.estado === 'INACTIVO'
                        || d.estado === 'SUSPENDIDO'
                        || d.estado === 'NO_REGISTRADO'
                        || verBump;
        if (debeBloquear) {
          _invalidarCache();
          _detenerHeartbeat();
          _verificar();
        }
      }).catch(function(){});
    }, 60 * 60 * 1000);
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
    _state.deviceId = _generarOLeerDeviceId();
    // Suscribirse a visibilitychange
    if (!_state.visibilityHandler) {
      _state.visibilityHandler = _onVisibilityChange;
      document.addEventListener('visibilitychange', _state.visibilityHandler);
    }
    return _verificar();
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
      if (_state.visibilityHandler) {
        document.removeEventListener('visibilitychange', _state.visibilityHandler);
        _state.visibilityHandler = null;
      }
      _ocultarOverlay();
    }
  };
})();
