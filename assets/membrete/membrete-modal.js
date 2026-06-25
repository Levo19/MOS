/* ============================================================
 *  membrete-modal.js   [v1.0.0]
 *  ============================================================
 *
 *  Módulo standalone — UI unificada de membretes/adhesivos para
 *  MOS, WH y ME. Cargar via <script src="...">.
 *
 *  API pública en window.MembreteSystem:
 *    iniciar({ apiPost, usuario, origen, unwrapData, endpointPrefix })
 *    imprimirUnitario({ tipo, producto })
 *    imprimirCola({ tipo, productos })
 *    imprimirCalibradores({ cantidad })
 *    abrirModalCalibrar()
 *    estadoActual()
 *
 *  Estilos y sonidos se inyectan dinámicamente al cargar.
 * ============================================================ */
(function() {
  'use strict';
  if (window.MembreteSystem && window.MembreteSystem.__loaded) return;

  // ── Config inyectada por cada app ───────────────────────────
  var _config = {
    apiPost:        null,
    usuario:        function() { return ''; },
    origen:         'MOS',
    unwrapData:     true,
    endpointPrefix: 'wh_',
    // [v1.9] La app puede inyectar un provider del catálogo. Útil para ME
    // donde el catálogo vive dentro de Vue (db.value.PRODUCTO_BASE) y no
    // es accesible vía window.
    catalogoProvider: null  // function() { return { productos: [...], equivalencias: [...] } }
  };

  // ── [v1.10] Cache de prefetch (TTL 60s) — UX optimista ─────
  // Al login se llaman los endpoints en paralelo y se guardan acá.
  // Los modales muestran el cache instantáneo + refrescan en background.
  var _cache = {
    calibracion:    { ts: 0, data: null, inFlight: false },
    alertasPrecio:  { ts: 0, data: null, inFlight: false },
    lotesHistorial: { ts: 0, data: null, inFlight: false }
  };
  var CACHE_TTL_MS = 60000;  // 1 minuto

  // Helper: obtener datos del cache o hacer fetch nuevo. Si hay cache fresco
  // ejecuta onCache() inmediato. Si no o si está stale, hace fetch en background.
  function _conCache(key, fetcher, onCache, onFresh) {
    var slot = _cache[key];
    var ahora = Date.now();
    var freshAge = ahora - slot.ts;
    // Si hay cache (aunque sea stale), entregar inmediato
    if (slot.data) {
      try { onCache && onCache(slot.data, freshAge < CACHE_TTL_MS); } catch(_) {}
    }
    // Si está fresh y no se pidió forzar, listo
    if (freshAge < CACHE_TTL_MS && !slot.inFlight) {
      try { onFresh && onFresh(slot.data); } catch(_) {}
      return Promise.resolve(slot.data);
    }
    if (slot.inFlight) return slot.inFlight;
    slot.inFlight = fetcher().then(function(d) {
      slot.data = d;
      slot.ts = Date.now();
      slot.inFlight = false;
      try { onFresh && onFresh(d); } catch(_) {}
      return d;
    }).catch(function(e) {
      slot.inFlight = false;
      throw e;
    });
    return slot.inFlight;
  }

  // [v1.10] Prefetch al login — carga los 3 endpoints en paralelo en background.
  // Se llama desde iniciar() automático tras inyectar config.
  function prefetchTodo() {
    try {
      // Calibración (no aplica para ME — solo MOS/WH manejan rollo)
      if (_config.origen !== 'ME') {
        _conCache('calibracion', function() { return _api('estadoCalibracionRollo', {}); });
      }
      // Alertas precio (solo MOS y ME — WH no maneja precios)
      if (_config.origen !== 'WH') {
        _conCache('alertasPrecio', function() { return _api('getMembretesMePendientes', { limit: 50 }); });
      }
      // Lotes historial — sin filtro (todos los tipos)
      _conCache('lotesHistorial', function() {
        return Promise.all([
          _api('getLotesAdhesivoHistorial', { tipoEtiqueta: '', limit: 30 }),
          _api('diagnosticoTriggerLotes', {}).catch(function() { return null; })
        ]).then(function(arr) { return { historial: arr[0], diag: arr[1] }; });
      });
    } catch(_) {}
  }

  // ── [v2.43.142] BANNER DE ROLLO ─────────────────────────────
  // El operador clickea "Calibrar rollo nuevo" SOLO cuando pone un rollo nuevo
  // (le avisamos en el confirm). Desde ahí el sistema cuenta hasta 1000 y
  // muestra el estado en todos los modales para que sepa cuándo cambiar sin
  // tener que ir a buscar la info. Estados: ok (<800), warn (800-950), error (>950).
  function _rolloBannerHtml() {
    if (_config.origen === 'ME') return '';  // ME no maneja rollo físico
    var slot = _cache.calibracion;
    if (!slot || !slot.data) {
      return '<div class="ms-rollo-banner ms-rollo-loading">📋 Cargando estado del rollo…</div>';
    }
    // _api devuelve d.data directo, sin envoltura {ok,data}
    var d = slot.data;
    var prints   = parseInt(d.printsDesdeCal) || 0;
    var capRollo = parseInt(d.capacidadRollo) || 1000;
    if (!capRollo || isNaN(capRollo)) capRollo = 1000;
    if (isNaN(prints) || prints < 0) prints = 0;
    var restantes = Math.max(0, capRollo - prints);
    var pct       = Math.round((prints / capRollo) * 100);
    var calibrado = d.calibrado === true || d.calibrado === 'true';
    var nivel, icono, mensaje;
    // [v2.43.163] Si el clamp del drift se activó → drift mal medido o muchos
    // prints sin recalibrar → priorizar esta alerta sobre las demás.
    if (d.clampActivo === true) {
      nivel = 'error'; icono = '⚠';
      mensaje = 'Drift fuera de rango (' + (d.offsetSinClamp || 0) + ' dots) · resetá y re-medí';
    } else if (!calibrado) {
      nivel = 'warn';  icono = '⚠';
      mensaje = 'Sin calibrar — clickeá "Calibrar rollo nuevo" cuando lo pongas';
    } else if (pct >= 95) {
      nivel = 'error'; icono = '🔴';
      mensaje = 'CAMBIAR ROLLO YA · quedan ~' + restantes + ' etiquetas';
    } else if (pct >= 80) {
      nivel = 'warn';  icono = '🟡';
      mensaje = 'Quedan ~' + restantes + ' · prepará rollo nuevo';
    } else {
      nivel = 'ok';    icono = '🟢';
      mensaje = 'Rollo OK · quedan ~' + restantes;
    }
    return ''
      + '<div class="ms-rollo-banner ms-rollo-' + nivel + '">'
      +   '<span style="font-size:14px">' + icono + '</span>'
      +   '<span style="font-weight:800">' + prints + '/' + capRollo + '</span>'
      +   '<span style="opacity:.92;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + mensaje + '</span>'
      + '</div>';
  }
  // Refresca el banner en todos los modales abiertos. Llamar tras calibrar,
  // tras completar un lote, o cuando se sospecha que el contador cambió.
  function _rolloRefrescarBanners() {
    var nodos = document.querySelectorAll('.ms-rollo-banner');
    if (nodos.length === 0) return;  // Nada que refrescar
    _cache.calibracion.ts = 0;  // invalida TTL → fuerza fetch fresco
    _conCache('calibracion',
      function() { return _api('estadoCalibracionRollo', {}); },
      null,
      function() {
        var html = _rolloBannerHtml();
        if (!html) return;
        var tmp = document.createElement('div');
        tmp.innerHTML = html;
        var nuevo = tmp.firstChild;
        if (!nuevo) return;
        nodos.forEach(function(n) {
          n.className = nuevo.className;
          n.innerHTML = nuevo.innerHTML;
        });
      }
    ).catch(function() {});
  }

  // ── Estado del lote en curso ────────────────────────────────
  var _state = null;
  // _state = { idLote, total, completadas, status, tipo, descripcion, tInicio }
  // [v1.6] Lotes lanzados en paralelo (mientras el actual estaba activo).
  // El backend los procesa en cola FIFO; el frontend solo trackea el más reciente.
  var _lotesEnBackground = [];

  // ── INYECCIÓN DE CSS ────────────────────────────────────────
  function _injectCss() {
    if (document.getElementById('membrete-modal-css')) return;
    var s = document.createElement('style');
    s.id = 'membrete-modal-css';
    s.textContent = [
      '.ms-overlay{position:fixed;inset:0;background:rgba(2,6,23,.78);backdrop-filter:blur(12px);z-index:99995;display:flex;align-items:center;justify-content:center;padding:16px;animation:ms-in .25s ease-out}',
      '@keyframes ms-in{from{opacity:0}to{opacity:1}}',
      '@keyframes ms-out{to{opacity:0;transform:scale(.96)}}',
      '.ms-modal{width:100%;max-width:560px;background:linear-gradient(180deg,#0a1424,#070d18);border:1px solid rgba(251,191,36,.35);border-radius:18px;box-shadow:0 30px 70px -10px rgba(251,191,36,.25);display:flex;flex-direction:column;max-height:92vh;overflow:hidden;animation:ms-pop .35s cubic-bezier(.34,1.56,.64,1)}',
      '@keyframes ms-pop{from{transform:scale(.9);opacity:0}to{transform:scale(1);opacity:1}}',
      '.ms-head{padding:18px 22px;border-bottom:1px solid #1e293b;background:linear-gradient(135deg,rgba(251,191,36,.10),rgba(245,158,11,.04));display:flex;align-items:center;gap:14px}',
      // [v2.43.142] Banner persistente del rollo de adhesivos en todos los modales.
      // El operador siempre ve cuánto queda sin tener que abrir el panel de calibración.
      '.ms-rollo-banner{padding:8px 16px;display:flex;align-items:center;gap:8px;font-size:12px;border-bottom:1px solid #1e293b;background:rgba(15,23,42,.6);font-family:system-ui,sans-serif}',
      '.ms-rollo-ok{color:#86efac;background:rgba(52,211,153,.06);border-bottom-color:rgba(52,211,153,.18)}',
      '.ms-rollo-warn{color:#fbbf24;background:rgba(251,191,36,.10);border-bottom-color:rgba(251,191,36,.28)}',
      '.ms-rollo-error{color:#fca5a5;background:rgba(248,113,113,.13);border-bottom-color:rgba(248,113,113,.35);animation:ms-rollo-pulse 1.6s ease-in-out infinite}',
      '.ms-rollo-loading{color:#64748b;font-style:italic}',
      '@keyframes ms-rollo-pulse{50%{opacity:.65}}',
      '.ms-emoji{font-size:36px;line-height:1}',
      '.ms-h1{font-size:14px;font-weight:900;color:#fbbf24;letter-spacing:.8px}',
      '.ms-sub{font-size:11px;color:#94a3b8;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
      '.ms-body{padding:20px 22px;display:flex;flex-direction:column;gap:14px}',
      '.ms-cola-body{gap:8px}',
      '.ms-scroll{scrollbar-width:thin;scrollbar-color:rgba(251,191,36,.45) transparent}',
      '.ms-scroll::-webkit-scrollbar{width:8px;height:8px}',
      '.ms-scroll::-webkit-scrollbar-track{background:transparent}',
      '.ms-scroll::-webkit-scrollbar-thumb{background:rgba(251,191,36,.35);border-radius:8px}',
      '.ms-scroll::-webkit-scrollbar-thumb:hover{background:rgba(251,191,36,.65)}',
      '.ms-stat{display:flex;align-items:center;justify-content:space-between;gap:10px}',
      '.ms-chip{padding:5px 12px;border-radius:9999px;font-size:12px;font-weight:800;border:1px solid}',
      '.ms-chip-info{color:#94a3b8;border-color:rgba(148,163,184,.35);background:rgba(148,163,184,.08)}',
      '.ms-chip-warn{color:#fbbf24;border-color:rgba(251,191,36,.5);background:rgba(251,191,36,.12)}',
      '.ms-chip-ok{color:#34d399;border-color:rgba(52,211,153,.5);background:rgba(52,211,153,.12)}',
      '.ms-chip-error{color:#f87171;border-color:rgba(248,113,113,.5);background:rgba(248,113,113,.14)}',
      '.ms-counter{font-family:Consolas,monospace;font-size:22px;font-weight:900;color:#f1f5f9;letter-spacing:1px}',
      '.ms-bar{height:14px;background:rgba(15,23,42,.6);border-radius:9999px;overflow:hidden;border:1px solid rgba(251,191,36,.2)}',
      '.ms-bar-fill{height:100%;background:linear-gradient(90deg,#fbbf24,#f59e0b);box-shadow:0 0 16px rgba(251,191,36,.6);transition:width .35s ease-out;border-radius:9999px}',
      '.ms-info{display:flex;justify-content:space-between;font-size:11px;color:#64748b;font-family:Consolas,monospace}',
      '.ms-err{padding:8px 12px;background:rgba(248,113,113,.10);border:1px solid rgba(248,113,113,.35);border-radius:8px;font-size:12px;color:#fca5a5}',
      '.ms-actions{display:flex;flex-direction:column;gap:10px;margin-top:6px}',
      '.ms-btn{width:100%;padding:11px 16px;border-radius:10px;font-size:14px;font-weight:800;border:1px solid;cursor:pointer;transition:all .15s}',
      '.ms-btn:hover{transform:translateY(-1px)}',
      '.ms-btn-primary{background:linear-gradient(135deg,#fbbf24,#f59e0b);color:#0a1424;border-color:#fbbf24}',
      '.ms-btn-warn{background:rgba(248,113,113,.12);color:#fca5a5;border-color:rgba(248,113,113,.4)}',
      // [v1.9] Tabs de filtro dentro del modal Lotes
      '.ms-tab{padding:6px 12px;font-size:11px;font-weight:700;border:1px solid #1e293b;background:transparent;color:#64748b;border-radius:8px 8px 0 0;cursor:pointer;white-space:nowrap;transition:all .15s}',
      '.ms-tab:hover{color:#cbd5e1;border-color:#334155}',
      '.ms-tab-active{color:#fbbf24;border-color:rgba(251,191,36,.45);background:rgba(251,191,36,.10)}',
      '.ms-btn-info{background:rgba(99,102,241,.12);color:#a5b4fc;border-color:rgba(99,102,241,.4)}',
      '.ms-spin{display:inline-block;animation:ms-spin 1s linear infinite}',
      '@keyframes ms-spin{from{transform:rotate(0)}to{transform:rotate(360deg)}}',
      '.ms-badge-nav{position:fixed;bottom:16px;right:16px;z-index:99990;background:linear-gradient(135deg,#fbbf24,#f59e0b);color:#0a1424;padding:8px 14px;border-radius:9999px;font-size:12px;font-weight:900;cursor:pointer;box-shadow:0 10px 24px -4px rgba(251,191,36,.55);animation:ms-pulse 2s ease-in-out infinite}',
      '@keyframes ms-pulse{0%,100%{box-shadow:0 10px 24px -4px rgba(251,191,36,.55)}50%{box-shadow:0 14px 36px -4px rgba(251,191,36,.85)}}',
      '.ms-toast{position:fixed;top:16px;right:16px;z-index:99996;background:linear-gradient(180deg,#1e293b,#0f172a);border:1px solid rgba(52,211,153,.4);border-radius:12px;padding:14px 18px;color:#f1f5f9;font-size:13px;font-weight:600;max-width:340px;animation:ms-slide-in .4s cubic-bezier(.34,1.56,.64,1);box-shadow:0 20px 40px -10px rgba(0,0,0,.6)}',
      '.ms-toast-error{border-color:rgba(248,113,113,.5)}',
      '@keyframes ms-slide-in{from{opacity:0;transform:translateX(40px)}to{opacity:1;transform:translateX(0)}}'
    ].join('\n');
    document.head.appendChild(s);
  }

  // ── SONIDOS Web Audio sintetizados ──────────────────────────
  var _audioCtx = null;
  function _getAudioCtx() {
    if (!_audioCtx) {
      try { _audioCtx = new (window.AudioContext || window.webkitAudioContext)(); }
      catch(_) { return null; }
    }
    return _audioCtx;
  }
  function _beep(freq, durationMs, type) {
    if (localStorage.getItem('mos_sound_off') === '1') return;
    var ctx = _getAudioCtx();
    if (!ctx) return;
    try {
      var osc = ctx.createOscillator();
      var g = ctx.createGain();
      osc.type = type || 'sine';
      osc.frequency.setValueAtTime(freq, ctx.currentTime);
      g.gain.setValueAtTime(.18, ctx.currentTime);
      g.gain.exponentialRampToValueAtTime(.001, ctx.currentTime + durationMs / 1000);
      osc.connect(g); g.connect(ctx.destination);
      osc.start(ctx.currentTime);
      osc.stop(ctx.currentTime + durationMs / 1000);
    } catch(_){}
  }
  var sonidos = {
    click:        function() { _beep(800, 60); },
    start:        function() { _beep(440, 100, 'square'); setTimeout(function(){_beep(880, 100, 'square');}, 100); },
    subjobDone:   function() { _beep(660, 80); },
    completado:   function() { [880,1320,1760].forEach(function(f,i){ setTimeout(function(){_beep(f,180);}, i*120); }); },
    error:        function() { _beep(220, 220, 'sawtooth'); setTimeout(function(){_beep(110, 280, 'sawtooth');}, 160); },
    calibracion:  function() { _beep(660, 120); setTimeout(function(){_beep(990, 160);}, 130); }
  };

  // ── TOAST ────────────────────────────────────────────────────
  function _toast(msg, opts) {
    opts = opts || {};
    _injectCss();
    var div = document.createElement('div');
    div.className = 'ms-toast' + (opts.error ? ' ms-toast-error' : '');
    div.innerHTML = msg;
    document.body.appendChild(div);
    setTimeout(function() {
      div.style.animation = 'ms-slide-in .4s reverse';
      setTimeout(function() { div.remove(); }, 400);
    }, opts.duracion || 4000);
  }

  // ── HELPERS API ──────────────────────────────────────────────
  function _api(action, params) {
    if (!_config.apiPost) {
      return Promise.reject(new Error('MembreteSystem no inicializado · falta apiPost en config'));
    }
    var fullAction = _config.endpointPrefix + action;
    var p = _config.apiPost(fullAction, params || {});
    return Promise.resolve(p).then(function(r) {
      if (r && r.ok === false) throw new Error(r.error || 'Backend rechazó');
      return _config.unwrapData ? r : (r && r.data ? r.data : r);
    });
  }

  function _escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
    });
  }

  // ── MODAL DE PROGRESO ───────────────────────────────────────
  function _abrirModalProgreso(meta) {
    _injectCss();
    _state = {
      idLote:      meta.idLote || '',
      total:       meta.total || 0,
      completadas: 0,
      tipo:        meta.tipo,
      descripcion: meta.descripcion || '',
      status:      'CREADO',
      ultimoError: '',
      tInicio:     Date.now(),
      polling:     false
    };
    var tipoLabel = meta.tipo === 'MEMBRETE_ME' ? '🏪 MEMBRETE TIENDA'
                  : meta.tipo === 'MEMBRETE_WH' ? '📦 MEMBRETE ALMACÉN'
                  : meta.tipo === 'CALIBRADOR'  ? '🔧 CALIBRADORES'
                  :                                '🏷 LOTE DE IMPRESIÓN';

    var html = ''
      + '<div class="ms-overlay" id="msOverlay">'
      +   '<div class="ms-modal">'
      +     '<div class="ms-head">'
      +       '<div class="ms-emoji">🏷</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="ms-h1">' + tipoLabel + '</div>'
      +         '<div class="ms-sub">' + _escapeHtml(_state.descripcion) + '</div>'
      +       '</div>'
      +     '</div>'
      +     '<div class="ms-body">'
      +       '<div class="ms-stat">'
      +         '<div class="ms-chip" id="msChip"><span class="ms-spin">◐</span> preparando…</div>'
      +         '<div class="ms-counter" id="msCounter">0 / ' + _state.total + '</div>'
      +       '</div>'
      +       '<div class="ms-bar"><div class="ms-bar-fill" id="msFill" style="width:0%"></div></div>'
      +       '<div class="ms-info"><span id="msVel">— etq/min</span><span id="msEta">estimado: —</span></div>'
      +       '<div class="ms-err" id="msErr" style="display:none"></div>'
      +       '<div class="ms-actions" id="msActions">'
      +         '<button class="ms-btn ms-btn-info" onclick="MembreteSystem.cerrarModal()">Cerrar (sigue en background)</button>'
      +       '</div>'
      +     '</div>'
      +   '</div>'
      + '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
    sonidos.start();
    _render();
    _renderBadge();
    _arrancarPolling();
  }

  function _render() {
    if (!_state) return;
    var pct = _state.total > 0 ? (_state.completadas / _state.total * 100) : 0;
    var fill = document.getElementById('msFill');
    if (fill) fill.style.width = pct.toFixed(1) + '%';
    var counter = document.getElementById('msCounter');
    // [v2.43.169 UX] Mostrar porcentaje al lado del contador X/N para
    // feedback inmediato del progreso, especialmente útil en lotes grandes.
    if (counter) counter.textContent = _state.completadas + ' / ' + _state.total + ' · ' + pct.toFixed(0) + '%';
    // [v2.43.169 UX] Sonido + vibración cuando el lote se completa.
    // _prevStatus guarda el estado anterior para detectar la transición
    // CREADO/ENCOLADO/IMPRIMIENDO → COMPLETADO (one-shot, no repite).
    var prevStatus = _state._prevStatus;
    _state._prevStatus = _state.status;
    if (_state.status === 'COMPLETADO' && prevStatus !== 'COMPLETADO') {
      try { sonidos.completado && sonidos.completado(); } catch(_){}
      try { navigator.vibrate && navigator.vibrate([100, 50, 100, 50, 200]); } catch(_){}
    }
    // [v2.43.169 UX] También sonido distinto cuando entra en estado de error
    // (papel agotado, error de impresora). Reemplaza el feedback silencioso.
    if ((_state.status === 'PAUSADO_OUT_PAPER' || _state.status === 'PAUSADO_ERROR') &&
        prevStatus !== 'PAUSADO_OUT_PAPER' && prevStatus !== 'PAUSADO_ERROR') {
      try { sonidos.error && sonidos.error(); } catch(_){}
      try { navigator.vibrate && navigator.vibrate([200, 100, 200, 100, 200]); } catch(_){}
    }
    var chip = document.getElementById('msChip');
    if (chip) {
      var map = {
        CREADO:            { cls: 'ms-chip-info',   txt: '<span class="ms-spin">◐</span> preparando…' },
        ENCOLADO:          { cls: 'ms-chip-warn',   txt: '<span class="ms-spin">◐</span> en cola…' },
        IMPRIMIENDO:       { cls: 'ms-chip-ok',     txt: '🖨 imprimiendo' },
        CALIBRANDO:        { cls: 'ms-chip-warn',   txt: '<span class="ms-spin">◐</span> calibrando…' },
        PAUSADO_USUARIO:   { cls: 'ms-chip-warn',   txt: '⏸ pausado' },
        PAUSADO_OUT_PAPER: { cls: 'ms-chip-error',  txt: '🛑 rollo agotado' },
        PAUSADO_ERROR:     { cls: 'ms-chip-error',  txt: '❌ error' },
        COMPLETADO:        { cls: 'ms-chip-ok',     txt: '✅ completado' },
        CANCELADO:         { cls: 'ms-chip-warn',   txt: '⊘ cancelado' }
      };
      var m = map[_state.status] || { cls: 'ms-chip-info', txt: _state.status };
      chip.className = 'ms-chip ' + m.cls;
      chip.innerHTML = m.txt;
    }
    var elapsedSec = (Date.now() - _state.tInicio) / 1000;
    if (_state.completadas > 0 && elapsedSec > 1) {
      var velMin = (_state.completadas / elapsedSec * 60).toFixed(0);
      var restante = _state.total - _state.completadas;
      var segRest = restante / (_state.completadas / elapsedSec);
      var vel = document.getElementById('msVel');
      var eta = document.getElementById('msEta');
      if (vel) vel.textContent = velMin + ' etq/min';
      if (eta) eta.textContent = 'estimado: ' + Math.ceil(segRest) + ' seg';
    }
    var err = document.getElementById('msErr');
    if (err) {
      if (_state.ultimoError) { err.style.display = 'block'; err.textContent = '⚠ ' + _state.ultimoError; }
      else { err.style.display = 'none'; }
    }
  }

  function _renderBadge() {
    var existing = document.getElementById('msBadgeNav');
    if (existing) existing.remove();
    if (!_state) return;
    if (['COMPLETADO','CANCELADO'].indexOf(_state.status) >= 0) return;
    var overlay = document.getElementById('msOverlay');
    if (overlay) return;  // si el modal está abierto, no mostrar badge
    var div = document.createElement('div');
    div.id = 'msBadgeNav';
    div.className = 'ms-badge-nav';
    // [v1.6] Si hay lotes en background, mostrarlos también
    var extraBg = (_lotesEnBackground && _lotesEnBackground.length) || 0;
    var sufijo = extraBg > 0 ? ' (+' + extraBg + ' en cola)' : '';
    div.innerHTML = '🏷 ' + _state.completadas + '/' + _state.total + sufijo;
    div.onclick = function() { _reabrirModal(); };
    document.body.appendChild(div);
  }

  function _reabrirModal() {
    if (!_state) return;
    var existing = document.getElementById('msOverlay');
    if (existing) return;
    _abrirModalProgreso({ idLote: _state.idLote, total: _state.total, tipo: _state.tipo, descripcion: _state.descripcion });
    _state.completadas = _state.completadas; // re-render preserva
    _render();
  }

  function cerrarModal() {
    var ov = document.getElementById('msOverlay');
    if (ov) {
      ov.style.animation = 'ms-out .22s ease-out forwards';
      setTimeout(function() { ov.remove(); }, 220);
    }
    _renderBadge();  // si lote sigue activo, mostrar badge
  }

  // ── POLLING al estado del lote (cada 3s) ────────────────────
  function _arrancarPolling() {
    if (!_state || _state.polling) return;
    _state.polling = true;
    var idLote = _state.idLote;
    var loop = function() {
      if (!_state || _state.idLote !== idLote || !idLote) { return; }
      _api('getEstadoLoteAdhesivo', { idLote: idLote }).then(function(d) {
        if (!_state || _state.idLote !== idLote) return;
        var status = String(d.status || _state.status);
        var completadas = parseInt(d.completadas) || _state.completadas;
        var statusCambio = status !== _state.status;
        _state.completadas = completadas;
        _state.status = status;
        _state.ultimoError = d.ultimoError || '';
        _render();
        _renderBadge();
        if (status === 'COMPLETADO') {
          sonidos.completado();
          // [v1.2 FIX] Texto correcto: MEMBRETE_ME = para góndola tienda, MEMBRETE_WH = para andamio almacén
          _toast('✅ ' + (d.total || _state.total) + ' adhesivos impresos · ' + (_state.tipo === 'MEMBRETE_ME' ? 'recoger en almacén' : 'listos en andamio'));
          // [v2.43.142] Refrescar banner del rollo — el contador subió N etiquetas.
          // El operador ve el nuevo "restantes" en cualquier modal abierto.
          _rolloRefrescarBanners();
          _state.polling = false;
          setTimeout(function() {
            cerrarModal();
            // [v1.6] Promover el siguiente lote en background a actual (si lo hay)
            if (_lotesEnBackground && _lotesEnBackground.length) {
              var next = _lotesEnBackground.shift();
              _state = {
                idLote: next.idLote, total: next.total, completadas: 0,
                status: 'IMPRIMIENDO', tipo: next.tipo,
                descripcion: 'siguiente lote · ' + next.total + ' adhesivos',
                polling: false
              };
              _arrancarPolling();
            } else {
              _state = null;
            }
            _renderBadge();
          }, 2500);
          return;
        }
        if (['CANCELADO','PAUSADO_OUT_PAPER','PAUSADO_ERROR'].indexOf(status) >= 0) {
          sonidos.error();
          _state.polling = false;
          return;
        }
        if (statusCambio && status === 'IMPRIMIENDO') sonidos.subjobDone();
        setTimeout(loop, 3000);
      }).catch(function(e) {
        if (_state) _state.ultimoError = 'Sin conexión polling';
        _render();
        setTimeout(loop, 5000);
      });
    };
    loop();
  }

  // ── API PÚBLICA ─────────────────────────────────────────────
  function iniciar(config) {
    if (config) {
      Object.keys(config).forEach(function(k) { _config[k] = config[k]; });
    }
    _injectCss();
    // [v1.10] Prefetch optimista: cargar datos de los 3 modales en background
    // tras 1.5s del login para no competir con el load inicial de la app.
    // El usuario los abre y los ve instantáneo desde cache.
    setTimeout(function() {
      try { prefetchTodo(); } catch(_) {}
    }, 1500);
  }

  // Imprimir lote de adhesivos de envasado (legacy, mantiene compat)
  // [v1.6] Mismo comportamiento que imprimirMembrete: lotes en paralelo,
  // no bloquea si hay otro en curso.
  function imprimirAdhesivoEnvasado(opts) {
    if (_state && _state.idLote && ['CREADO','ENCOLADO','IMPRIMIENDO','CALIBRANDO'].indexOf(_state.status) >= 0) {
      _state.polling = false;
      _lotesEnBackground.push({ idLote: _state.idLote, total: _state.total, tipo: _state.tipo });
      _toast('➕ Lote anterior sigue en cola · este se encola detrás');
    }
    var idempotencyKey = 'mem_' + Date.now() + '_' + Math.random().toString(36).slice(2, 6);
    sonidos.click();
    _abrirModalProgreso({
      idLote:      '',
      total:       opts.total || 1,
      tipo:        'ADHESIVO_ENVASADO',
      descripcion: opts.descripcion || ''
    });
    return _api('crearLoteAdhesivo', {
      codigoBarra:     opts.codigoBarra,
      descripcion:     opts.descripcion,
      total:           opts.total,
      usuario:         _config.usuario(),
      origen:          _config.origen,
      fechaEnvasado:   opts.fechaEnvasado || '',
      idempotencyKey:  idempotencyKey
    }).then(function(d) {
      if (!_state) return;
      _state.idLote = d.idLote;
      _state.total  = d.total || _state.total;
      // Re-arranque del polling con idLote real
      _state.polling = false;
      _render();
      _arrancarPolling();
      return d;
    }).catch(function(e) {
      // [AUDIT FIX #B] Reset polling=false en error para permitir reintentos
      if (_state) { _state.status = 'PAUSADO_ERROR'; _state.ultimoError = e.message; _state.polling = false; _render(); }
      sonidos.error();
    });
  }

  // Imprimir membretes (ME o WH) — items = array de productos
  // [v1.6 FIX] Permitir lanzar MÚLTIPLES lotes seguidos. El backend los
  // procesa en cola FIFO via el trigger procesarLotesPendientes. El usuario
  // no tiene que esperar — solo se reemplaza el state del frontend con el
  // lote nuevo (el anterior sigue procesándose en background).
  function imprimirMembrete(opts) {
    var tipo = opts.tipo;  // 'MEMBRETE_ME' | 'MEMBRETE_WH'
    var items = opts.items || [];
    var idempotencyKey = 'mem_' + Date.now() + '_' + Math.random().toString(36).slice(2, 6);
    sonidos.click();
    var desc = tipo === 'MEMBRETE_ME'
      ? items.length + ' productos · góndola'
      : items.length + ' productos · andamio';
    // [v1.6] Si ya hay un lote en curso, detener polling del anterior y guardarlo
    // como "lote en background". El badge mostrará la cantidad acumulada.
    if (_state && _state.idLote && ['CREADO','ENCOLADO','IMPRIMIENDO','CALIBRANDO'].indexOf(_state.status) >= 0) {
      _state.polling = false;  // detener polling del lote viejo
      _lotesEnBackground.push({ idLote: _state.idLote, total: _state.total, tipo: _state.tipo });
      // Toast para feedback de que el anterior sigue
      _toast('➕ Lote anterior sigue en cola · este se encola detrás');
    }
    _abrirModalProgreso({
      idLote: '', total: items.length, tipo: tipo, descripcion: desc
    });
    // [v2.0 · 100% Supabase] Si la app inyectó edgeCall → imprimir vía Edge `print-adhesivo`
    // (mode:'crear-membrete'): crea el lote ATÓMICO + imprime server-side (reserve-first → items
    // exactos, sin doble-print, sin lock largo de GAS). Fallback a GAS si no hay edgeCall o si el
    // flag server WH_LOTE_ADHESIVO_DIRECTO está OFF (la RPC devuelve *_OFF). En error real/red NO
    // cae a GAS (evita doble impresión); reintento seguro por idempotencyKey.
    if (typeof _config.edgeCall === 'function') {
      _config.edgeCall({
        mode: 'crear-membrete', tipo: tipo, items: items,
        usuario: _config.usuario(), origen: _config.origen, idempotencyKey: idempotencyKey
      }).then(function(ed) {
        if (!_state) return;
        if (ed && ed.ok && ed.data) {
          var d = ed.data;
          _state.idLote = d.idLote || _state.idLote;
          _state.total  = d.total  || _state.total;
          var st = String(d.status || '');
          if (st === 'COMPLETADO') {
            _state.completadas = _state.total; _state.status = 'COMPLETADO'; _state.polling = false; _render();
            _toast('✅ ' + _state.total + ' adhesivos impresos · ' + (tipo === 'MEMBRETE_ME' ? 'góndola tienda' : 'andamio almacén'));
            setTimeout(function() { if (_state && _state.status === 'COMPLETADO') cerrarModal(); }, 2500);
          } else if (st.indexOf('PAUSADO') === 0) {
            _state.status = st; _state.ultimoError = d.error || 'Pausado'; _state.polling = false; _render(); sonidos.error();
          } else {
            _state.status = 'IMPRIMIENDO'; _render();   // PRESUPUESTO_AGOTADO (lote enorme): el cron retoma
          }
          return;
        }
        if (ed && ed.ok === false && !/_OFF/.test(String(ed.error || ''))) {
          // [fix data-loss] El backend RECHAZÓ y NO creó el lote → restaurar la cola (los membretes NO se
          // imprimieron NI quedan en historial). Sin esto se perdían en silencio (cola vaciada optimista).
          if (opts && typeof opts.onReject === 'function') { try { opts.onReject(); } catch(_){} }
          _state.status = 'PAUSADO_ERROR'; _state.ultimoError = 'Edge: ' + (ed.error || 'error'); _state.polling = false; _render(); sonidos.error();
          return;
        }
        // *_OFF → fallback GAS (kill-switch)
        _imprimirMembreteGas(tipo, items, idempotencyKey);
      }).catch(function(e) {
        if (!_state) return;
        _state.status = 'PAUSADO_ERROR'; _state.ultimoError = 'Sin confirmación de impresión: ' + ((e && e.message) || 'red') + ' — reintenta';
        _state.polling = false; _render(); sonidos.error();
      });
      return;
    }
    return _imprimirMembreteGas(tipo, items, idempotencyKey);
  }

  // Flujo GAS histórico (fallback): crea lote en la hoja + dispara sub-lote + pollea estado.
  function _imprimirMembreteGas(tipo, items, idempotencyKey) {
    return _api('crearLoteMembrete', {
      tipo:           tipo,
      items:          items,
      usuario:        _config.usuario(),
      origen:         _config.origen,
      idempotencyKey: idempotencyKey
    }).then(function(d) {
      if (!_state) return;
      _state.idLote = d.idLote;
      _state.total  = d.total || _state.total;  // backend expande WH multi-codigo
      _state.polling = false;
      _render();
      // Disparo inmediato (el trigger cada 1 min es failsafe). Fire-and-forget.
      _api('imprimirSubLoteMembrete', { idLote: d.idLote }).catch(function(){});
      _arrancarPolling();
      return d;
    }).catch(function(e) {
      if (_state) { _state.status = 'PAUSADO_ERROR'; _state.ultimoError = e.message; _state.polling = false; _render(); }
      sonidos.error();
    });
  }

  // Calibradores — imprime N adhesivos con regla vertical
  function imprimirCalibradores(opts) {
    opts = opts || {};
    var cantidad = opts.cantidad || 10;
    sonidos.click();
    _toast('🔧 Imprimiendo ' + cantidad + ' calibradores...');
    return _api('imprimirCalibradoresAdhesivo', { cantidad: cantidad }).then(function(d) {
      sonidos.calibracion();
      _toast('✅ ' + d.enviados + '/' + d.total + ' calibradores enviados. Cuando salgan, mide el desvío del #' + cantidad + ' e ingrésalo.');
      return d;
    }).catch(function(e) {
      sonidos.error();
      _toast('❌ ' + e.message, { error: true });
    });
  }

  function estadoCalibracion() {
    return _api('estadoCalibracionRollo', {});
  }

  function calibrarRollo() {
    sonidos.click();
    return _api('calibrarImpresoraAdhesivo', {}).then(function(d) {
      sonidos.calibracion();
      _toast('🔧 Calibración enviada · ~3 etiquetas blancas saldrán');
      return d;
    }).catch(function(e) { sonidos.error(); _toast('❌ ' + e.message, { error: true }); });
  }

  function aplicarDrift(mmDesviados, basadoEnPrints, direccion) {
    return _api('aplicarDriftDetectado', {
      mmDesviados:    mmDesviados,
      basadoEnPrints: basadoEnPrints || 10,
      direccion:      direccion || 'arriba'   // [v2.43.161]
    }).then(function(d) {
      sonidos.completado();
      _toast('✅ Drift ' + (d.direccion || direccion) + ' aplicado: ' + d.driftDotsPorPrint + ' dots/print');
      return d;
    }).catch(function(e) { sonidos.error(); _toast('❌ ' + e.message, { error: true }); });
  }
  // [v2.43.161] Reset de emergencia — limpia drift/offset/contador en backend.
  function resetearDriftEmergencia() {
    return _api('resetearDriftEmergencia', {}).then(function(d) {
      sonidos.completado();
      _toast('🆘 Drift y offset reseteados a 0');
      return d;
    }).catch(function(e) { sonidos.error(); _toast('❌ ' + e.message, { error: true }); });
  }

  function estadoActual() {
    return _state;
  }

  // ════════════════════════════════════════════════════════════
  // [v1.1] UI EMBEBIDAS — modal calibrar + cola + menú card
  // ════════════════════════════════════════════════════════════

  // Cola persistente en localStorage. Cada item = producto a imprimir.
  var COLA_KEY = 'mos_membrete_cola_';

  function _colaCargar(tipo) {
    try { return JSON.parse(localStorage.getItem(COLA_KEY + tipo) || '[]'); } catch(_) { return []; }
  }
  function _colaGuardar(tipo, arr) {
    try { localStorage.setItem(COLA_KEY + tipo, JSON.stringify(arr || [])); } catch(_) {}
  }

  // ── MODAL CALIBRAR ────────────────────────────────────────
  function abrirCalibrador() {
    _injectCss();
    sonidos.click();
    if (document.getElementById('msCalOverlay')) return;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="ms-overlay" id="msCalOverlay">'
      +   '<div class="ms-modal">'
      +     '<div class="ms-head">'
      +       '<div class="ms-emoji">🔧</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="ms-h1">CALIBRACIÓN INTELIGENTE</div>'
      +         '<div class="ms-sub">drift compensation por print</div>'
      +       '</div>'
      +     '</div>'
      +     _rolloBannerHtml()
      +     '<div class="ms-body" id="msCalBody">'
      +       '<div style="text-align:center;color:#94a3b8;padding:20px">cargando estado…</div>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    _calRefrescar();
  }
  function _calRefrescar() {
    // [v1.10] Optimista: render desde cache si existe, refrescar en background
    var render = function(d) {
      var body = document.getElementById('msCalBody');
      if (!body || !d) return;
      _renderCalibradorBody(body, d);
    };
    _conCache('calibracion',
      function() { return estadoCalibracion(); },
      function(cached) { render(cached); },                   // onCache
      function(fresh)  { render(fresh); }                      // onFresh
    ).catch(function(e) {
      var body = document.getElementById('msCalBody');
      if (body) body.innerHTML = '<div class="ms-err">⚠ ' + _escapeHtml(e.message) + '</div>';
    });
  }
  function _renderCalibradorBody(body, d) {
      var calibrado    = d.calibrado;
      var driftDots    = parseFloat(d.driftDotsPorPrint) || 0;
      var driftMm      = +(driftDots / 8).toFixed(2);
      var prints       = parseInt(d.printsDesdeCal) || 0;
      var necesitaRec  = d.necesitaRecalibrar;
      var rolloCasiAg  = d.rolloCasiAgotado;
      var capRollo     = parseInt(d.capacidadRollo) || 1000;
      // [v1.5 FIX] Defensa contra NaN / 0
      if (!capRollo || isNaN(capRollo) || capRollo <= 0) capRollo = 1000;
      if (isNaN(prints) || prints < 0) prints = 0;
      var fechaCal     = String(d.fechaCalibrado || '').substring(0, 16);
      // [v1.3] Barra visual de progreso del rollo
      var pctRollo     = Math.min(100, Math.max(0, Math.round((prints / capRollo) * 100)));
      var barColor     = pctRollo >= 95 ? '#f87171' : (pctRollo >= 80 ? '#fbbf24' : '#34d399');
      body.innerHTML = ''
        + '<div class="ms-stat">'
        +   '<div class="ms-chip ' + (calibrado ? 'ms-chip-ok' : 'ms-chip-error') + '">'
        +     (calibrado ? '🟢 Calibrado' : '🔴 Sin calibrar')
        +   '</div>'
        +   '<div class="ms-counter">' + prints + '/' + capRollo + ' prints</div>'
        + '</div>'
        + '<div style="height:6px;background:#1e293b;border-radius:4px;overflow:hidden;margin:6px 0">'
        +   '<div style="height:100%;width:' + pctRollo + '%;background:' + barColor + ';transition:width .4s"></div>'
        + '</div>'
        + '<div class="ms-info">'
        +   '<span>drift: ' + driftDots + ' dots/print (' + driftMm + ' mm)</span>'
        +   '<span>' + (fechaCal || '—') + '</span>'
        + '</div>'
        + (rolloCasiAg ? '<div class="ms-err">🔴 Rollo casi agotado (>950/1000) · prepará rollo nuevo</div>'
           : necesitaRec ? '<div class="ms-err" style="background:rgba(251,191,36,.1);color:#fbbf24">⚠ >800 prints · rollo cerca del final</div>' : '')
        + '<div style="height:1px;background:#1e293b;margin:6px 0"></div>'
        + '<div style="font-size:12px;color:#cbd5e1;font-weight:700;letter-spacing:.5px">🆕 CAMBIASTE EL ROLLO?</div>'
        + '<button class="ms-btn ms-btn-primary" onclick="MembreteSystem._calCambiarRollo()">🔧 Calibrar rollo nuevo</button>'
        + '<div style="font-size:11px;color:#64748b">Gasta ~3 etiquetas, resetea drift</div>'
        + '<div style="height:1px;background:#1e293b;margin:6px 0"></div>'
        + '<div style="font-size:12px;color:#cbd5e1;font-weight:700;letter-spacing:.5px">⚡ AUTO-DETECTAR DRIFT</div>'
        + '<div style="font-size:11px;color:#94a3b8;line-height:1.4">'
        +   'Paso 1: imprimir 10 calibradores. '
        +   'Paso 2: mirar #10 y contar mm de desvío de la regla.'
        + '</div>'
        + '<button class="ms-btn ms-btn-info" onclick="MembreteSystem._calImprimirCals()">🖨 Imprimir 10 calibradores</button>'
        // [v2.43.161] Selector de dirección — antes solo se ingresaba magnitud y
        // se asumía siempre "drift hacia arriba". Si era al revés el operador
        // amplificaba el bug. Ahora explícito.
        + '<div style="font-size:11px;color:#cbd5e1;font-weight:600">¿En qué dirección se movió en el #10?</div>'
        + '<div style="display:flex;gap:6px">'
        +   '<label style="flex:1;padding:8px;background:#0a1424;border:1px solid #1e293b;border-radius:8px;cursor:pointer;display:flex;align-items:center;gap:6px;font-size:12px;color:#f1f5f9">'
        +     '<input type="radio" name="msCalDir" value="arriba" checked> ⬆ Subió'
        +   '</label>'
        +   '<label style="flex:1;padding:8px;background:#0a1424;border:1px solid #1e293b;border-radius:8px;cursor:pointer;display:flex;align-items:center;gap:6px;font-size:12px;color:#f1f5f9">'
        +     '<input type="radio" name="msCalDir" value="abajo"> ⬇ Bajó'
        +   '</label>'
        + '</div>'
        + '<div style="display:flex;gap:8px;align-items:center">'
        +   '<input id="msCalMm" type="number" step="0.5" min="0" placeholder="mm de desvío en #10" '
        +     'style="flex:1;padding:9px;background:#0a1424;border:1px solid #1e293b;color:#f1f5f9;border-radius:8px;font-size:13px">'
        +   '<button class="ms-btn ms-btn-primary" style="width:auto;padding:9px 16px" onclick="MembreteSystem._calAplicarMm()">Aplicar</button>'
        + '</div>'
        + '<div style="height:1px;background:#1e293b;margin:6px 0"></div>'
        // [v2.43.161] Reset de emergencia — para deshacer un drift mal configurado
        // (caso reportado: drift+offset arrastraron a -48 dots y los adhesivos
        // salieron rotos). Vuelve todo a 0 sin tocar la calibración física.
        + '<div style="font-size:12px;color:#fca5a5;font-weight:700;letter-spacing:.5px">🆘 RESETEO DE EMERGENCIA</div>'
        + '<div style="font-size:11px;color:#94a3b8;line-height:1.4">'
        +   'Si los adhesivos están saliendo descuadrados, esto limpia drift y offset '
        +   'a 0 (sin gastar etiquetas). Después podés re-medir desde cero.'
        + '</div>'
        + '<button class="ms-btn ms-btn-warn" style="background:rgba(248,113,113,.15);border-color:rgba(248,113,113,.4);color:#fca5a5" onclick="MembreteSystem._calResetEmergencia()">🆘 Resetear drift y offset a 0</button>'
        + '<div style="height:1px;background:#1e293b;margin:6px 0"></div>'
        + '<button class="ms-btn ms-btn-warn" onclick="MembreteSystem._calCerrar()">Cerrar</button>';
  }
  function _calCambiarRollo() {
    // [v2.43.142] Confirmación reforzada: "calibrar = rollo nuevo".
    // Antes del fix algunos operadores re-calibraban a mitad del rollo
    // "por las dudas" y reseteaban el contador, perdiendo el tracking real.
    var slot = _cache.calibracion;
    var prints = 0, capRollo = 1000;
    if (slot && slot.data) {
      prints   = parseInt(slot.data.printsDesdeCal) || 0;
      capRollo = parseInt(slot.data.capacidadRollo) || 1000;
    }
    var alertaMitadRollo = '';
    if (prints > 0 && prints < 600) {
      alertaMitadRollo = '⚠ OJO: el contador actual está en ' + prints + '/' + capRollo
        + ' — según el sistema aún te quedan ~' + (capRollo - prints) + ' etiquetas en este rollo.\n\n';
    }
    var msg = alertaMitadRollo
      + '🆕 ¿Realmente pusiste un ROLLO NUEVO?\n\n'
      + 'SI → gasta ~3 etiquetas calibrando GAP, resetea contador a 0 y guarda fecha.\n'
      + 'NO → cancelá. Si solo querés re-medir GAP sin cambiar rollo, no uses este botón.';
    if (!confirm(msg)) return;
    calibrarRollo().then(function() {
      setTimeout(_calRefrescar, 1500);
      setTimeout(_rolloRefrescarBanners, 1700);
    });
  }
  function _calImprimirCals() {
    imprimirCalibradores({ cantidad: 10 }).then(function() { setTimeout(_calRefrescar, 1500); });
  }
  function _calAplicarMm() {
    var inp = document.getElementById('msCalMm');
    var mm = parseFloat(inp && inp.value);
    if (isNaN(mm) || mm < 0) { _toast('⚠ Ingresá los mm de desvío', { error: true }); return; }
    // [v2.43.161] Leer dirección seleccionada (default 'arriba').
    var dirInputs = document.querySelectorAll('input[name="msCalDir"]');
    var direccion = 'arriba';
    dirInputs.forEach(function(r) { if (r.checked) direccion = r.value; });
    aplicarDrift(mm, 10, direccion).then(function() {
      if (inp) inp.value = '';
      setTimeout(_calRefrescar, 800);
      setTimeout(_rolloRefrescarBanners, 1000);
    });
  }
  function _calResetEmergencia() {
    if (!confirm('🆘 ¿Resetear drift y offset a 0?\n\n'
      + 'Esto limpia la compensación acumulada que pueda estar rompiendo los adhesivos. '
      + 'No gasta etiquetas. Después podés re-medir desde cero imprimiendo 10 calibradores.')) return;
    resetearDriftEmergencia().then(function() {
      setTimeout(_calRefrescar, 800);
      setTimeout(_rolloRefrescarBanners, 1000);
    });
  }
  function _calCerrar() {
    var ov = document.getElementById('msCalOverlay');
    if (ov) { ov.style.animation = 'ms-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // ── MODAL COLA MEMBRETE ──────────────────────────────────────
  function abrirCola(tipo) {
    _injectCss();
    sonidos.click();
    tipo = tipo || 'MEMBRETE_ME';
    if (document.getElementById('msColaOverlay')) return;
    var emoji = tipo === 'MEMBRETE_ME' ? '🏪' : '📦';
    var label = tipo === 'MEMBRETE_ME' ? 'COLA MEMBRETES ME (góndola)' : 'COLA MEMBRETES WH (andamio)';
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="ms-overlay" id="msColaOverlay" data-tipo="' + tipo + '">'
      +   '<div class="ms-modal" style="max-width:620px">'
      +     '<div class="ms-head">'
      +       '<div class="ms-emoji">' + emoji + '</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="ms-h1">' + label + '</div>'
      +         '<div class="ms-sub" id="msColaSub">0 productos en cola</div>'
      +       '</div>'
      +     '</div>'
      +     _rolloBannerHtml()
      +     '<div class="ms-body ms-cola-body" style="display:flex;flex-direction:column;max-height:72vh;overflow:hidden">'
               // ── Buscador + sugerencias: FIJO arriba (no se encoge al crecer la cola) ──
      +       '<div style="flex-shrink:0">'
      +       '<div style="display:flex;gap:6px;margin-bottom:8px">'
      +       '<input id="msColaBusq" type="text" placeholder="🔍 Buscar por nombre o código (ej: hojuela avena)..." '
      +         'oninput="MembreteSystem._colaBusqInput(this.value)" '
      +         'style="flex:1;min-width:0;padding:10px 12px;background:#0a1424;border:1px solid #1e293b;color:#f1f5f9;border-radius:10px;font-size:13px">'
      +       ((_config && typeof _config.scanProvider === 'function')
                  ? '<button onclick="MembreteSystem._colaEscanear()" title="Escanear con cámara" style="flex-shrink:0;width:48px;background:linear-gradient(135deg,#0ea5e9,#0369a1);color:#fff;border:none;border-radius:10px;font-size:20px;cursor:pointer;-webkit-tap-highlight-color:transparent">📷</button>'
                  : '')
      +       '</div>'
               // sugerencias: alto fijo para ~5-6 productos + scroll moderno si hay más
      +       '<div id="msColaSugs" class="ms-scroll" style="max-height:236px;overflow-y:auto;display:none;background:#0a1424;border-radius:8px;padding:4px;margin-bottom:8px"></div>'
      +       '</div>'
               // ── Cola: toma el espacio RESTANTE, scroll propio, SIN límite de cantidad ──
      +       '<div id="msColaLista" class="ms-scroll" style="flex:1 1 auto;overflow-y:auto;min-height:110px;padding-right:2px"></div>'
      +     '</div>'
      +     '<div class="ms-actions" style="padding:0 22px 18px">'
      +       '<button class="ms-btn ms-btn-primary" id="msColaImprimir" onclick="MembreteSystem._colaImprimir()" disabled>'
      +         '🖨 Cola vacía'
      +       '</button>'
      +       '<button class="ms-btn ms-btn-warn" onclick="MembreteSystem._colaCerrar()">Cerrar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    _colaRefrescarLista();
  }
  function _colaTipo() {
    var ov = document.getElementById('msColaOverlay');
    return ov ? ov.getAttribute('data-tipo') : 'MEMBRETE_ME';
  }
  function _colaRefrescarLista() {
    var tipo = _colaTipo();
    var items = _colaCargar(tipo);
    var lista = document.getElementById('msColaLista');
    var sub   = document.getElementById('msColaSub');
    var btn   = document.getElementById('msColaImprimir');
    if (sub) sub.textContent = items.length + ' productos en cola';
    if (btn) {
      btn.disabled = items.length === 0;
      btn.innerHTML = items.length === 0 ? '🖨 Cola vacía'
                    : '🖨 IMPRIMIR ' + items.length + ' MEMBRETE' + (items.length > 1 ? 'S' : '');
    }
    if (!lista) return;
    if (items.length === 0) {
      lista.innerHTML = '<div style="text-align:center;color:#64748b;padding:24px 0;font-size:13px">Buscá un producto arriba para agregarlo a la cola</div>';
      return;
    }
    // [v2026-06-05 UX góndola] MEMBRETE_ME: en góndola SOLO importa precio + nombre.
    // El código de barras NO se muestra en la cola — confunde al operador (no es
    // un dato útil para él, sí lo es solo para el barcode impreso). Para WH sí
    // mostramos código (almacén lo necesita para identificar bin/equivalentes).
    lista.innerHTML = items.map(function(it, i) {
      var esME = tipo === 'MEMBRETE_ME';
      var precioBlock = esME
        ? '<div style="font-size:16px;font-weight:900;color:#fbbf24;font-family:monospace;text-shadow:0 1px 2px rgba(0,0,0,.4)">S/ ' + (parseFloat(it.precio) || 0).toFixed(2) + '</div>'
        : '';
      var codigoLinea = esME
        ? ''
        : '<div style="font-size:11px;color:#94a3b8;font-family:monospace">▌' + _escapeHtml(it.codigoBarra || '') + '</div>';
      return ''
        + '<div style="display:flex;align-items:center;gap:10px;padding:10px;background:rgba(15,23,42,.4);border-radius:8px;margin-bottom:6px;border:1px solid #1e293b">'
        +   '<div style="flex:1;min-width:0">'
        +     '<div style="font-size:13px;font-weight:700;color:#f1f5f9;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + _escapeHtml(it.descripcion || '') + '</div>'
        +     codigoLinea
        +   '</div>'
        +   precioBlock
        +   '<button onclick="MembreteSystem._colaQuitar(' + i + ')" style="background:rgba(248,113,113,.12);color:#fca5a5;border:1px solid rgba(248,113,113,.35);border-radius:6px;padding:4px 8px;cursor:pointer;font-size:14px">✕</button>'
        + '</div>';
    }).join('');
  }
  // [v1.8] Resolver fuente de catálogo según la app (MOS/WH/ME).
  // Devuelve { productos: [...], equivalencias: [...] } o null si no hay cache.
  function _resolverCatalogo() {
    try {
      // [v1.9] Provider inyectado por la app tiene prioridad (ME via Vue ref).
      if (typeof _config.catalogoProvider === 'function') {
        var prov = _config.catalogoProvider();
        if (prov && Array.isArray(prov.productos) && prov.productos.length) return prov;
      }
      // MOS — S.productos (canónicos) + S.equivMap {skuBase: [equivs]}
      if (window.S && Array.isArray(window.S.productos) && window.S.productos.length) {
        var equivsArr = [];
        if (window.S.equivMap) {
          Object.keys(window.S.equivMap).forEach(function(sku) {
            (window.S.equivMap[sku] || []).forEach(function(e) {
              equivsArr.push({ skuBase: sku, codigoBarra: e.codigoBarra || e, activo: e.activo });
            });
          });
        }
        return { productos: window.S.productos, equivalencias: equivsArr, origen: 'MOS' };
      }
      // WH — OfflineManager
      if (window.OfflineManager && OfflineManager.getProductosCache) {
        var prods = OfflineManager.getProductosCache() || [];
        if (prods.length) {
          var eq = (OfflineManager.getEquivalenciasCache && OfflineManager.getEquivalenciasCache()) || [];
          return { productos: prods, equivalencias: eq, origen: 'WH' };
        }
      }
      // ME — Vue db.value.PRODUCTO_BASE
      if (window.db && window.db.value && Array.isArray(window.db.value.PRODUCTO_BASE) && window.db.value.PRODUCTO_BASE.length) {
        var prodsME = window.db.value.PRODUCTO_BASE.map(function(p) {
          return {
            idProducto: p.SKU_Base, skuBase: p.SKU_Base,
            descripcion: p.Descripcion || p.Producto, codigoBarra: p.Codigo_Principal || p.SKU_Base,
            precio: parseFloat(p.Precio_Venta) || 0
          };
        });
        var eqME = (window.db.value.EQUIVALENCIAS || []).map(function(e) {
          return { skuBase: e.SKU_Base, codigoBarra: e.Codigo_Equivalente, activo: e.Activo };
        });
        return { productos: prodsME, equivalencias: eqME, origen: 'ME' };
      }
    } catch(_) {}
    return null;
  }

  // [busqueda] normaliza: minúsculas + SIN acentos (para encontrar "avena" en "avéna").
  function _msNorm(s) {
    return String(s == null ? '' : s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  }
  function _colaBusqInput(q) {
    var qn = _msNorm(q).trim();
    var sugs = document.getElementById('msColaSugs');
    if (!sugs) return;
    if (qn.length < 2) { sugs.style.display = 'none'; return; }
    // [v1.8] Resolver fuente según la app actual
    var cat = _resolverCatalogo();
    if (!cat || !cat.productos || cat.productos.length === 0) {
      sugs.innerHTML = '<div style="padding:8px;font-size:12px;color:#fbbf24">No hay catálogo cargado en esta sesión · refresca la app</div>';
      sugs.style.display = 'block';
      return;
    }
    // [busqueda inteligente] partir la query en PALABRAS → match si TODAS están en el nombre,
    // sin importar el orden ni los conectores ("hojuela avena" encuentra "HOJUELA DE AVENA").
    var tokens = qn.split(/\s+/).filter(Boolean);
    var skusPorEquiv = {};
    cat.equivalencias.forEach(function(e) {
      var cbe = _msNorm(e.codigoBarra);
      if (cbe && cbe.indexOf(qn) >= 0) skusPorEquiv[String(e.skuBase || '')] = true;
    });
    var matches = cat.productos.filter(function(p) {
      var desc = _msNorm(p.descripcion || p.nombre);
      var cb   = _msNorm(p.codigoBarra || p.idProducto);
      var sku  = _msNorm(p.skuBase || p.idProducto);
      var descMatch = tokens.length > 0 && tokens.every(function(t) { return desc.indexOf(t) >= 0; });
      return descMatch
          || cb.indexOf(qn) >= 0
          || sku.indexOf(qn) >= 0
          || skusPorEquiv[String(p.skuBase || p.idProducto || '')];
    }).slice(0, 40);   // [b] más resultados; la lista de sugerencias scrollea
    if (matches.length === 0) {
      sugs.innerHTML = '<div style="padding:8px;font-size:12px;color:#94a3b8">Sin resultados para "' + _escapeHtml(q) + '"</div>';
      sugs.style.display = 'block';
      return;
    }
    // [AUDIT FIX #A] Stash de candidatos en un Map en memoria para evitar
    // inyectar strings con apóstrofes/comillas/HTML en el onclick inline.
    // El handler usa data-idx para recuperar el item desde _msColaSugs.
    window._msColaSugItems = matches.map(function(p) {
      return {
        codigoBarra: String(p.codigoBarra || p.idProducto || ''),
        descripcion: String(p.descripcion || p.nombre || ''),
        precio:      parseFloat(p.precio || p.precioVenta) || 0,
        skuBase:     String(p.skuBase || '')
      };
    });
    // [v2026-06-05 UX góndola] MEMBRETE_ME: en sugerencias SOLO descripción + precio.
    // Quitar ▌codigoBarra — no le sirve al operador en góndola, lo confunde y
    // mete ruido visual. WH (almacén) sí muestra código abajo en chico.
    var esME = _colaTipo() === 'MEMBRETE_ME';
    sugs.innerHTML = window._msColaSugItems.map(function(it, i) {
      var precioHtml = it.precio > 0
        ? ' <span style="color:#fbbf24;font-weight:900;float:right;font-size:14px;font-family:monospace">S/ ' + it.precio.toFixed(2) + '</span>'
        : '';
      var codigoHtml = esME
        ? ''
        : ' <span style="font-family:monospace;color:#94a3b8">▌' + _escapeHtml(it.codigoBarra) + '</span>';
      return ''
        + '<div onclick="MembreteSystem._colaAgregarIdx(' + i + ')"'
        +   ' style="padding:10px 12px;cursor:pointer;border-radius:6px;font-size:13px;color:#cbd5e1"'
        +   ' onmouseover="this.style.background=\'rgba(251,191,36,.10)\'"'
        +   ' onmouseout="this.style.background=\'transparent\'">'
        +   '<span style="font-weight:700">' + _escapeHtml(it.descripcion) + '</span>'
        +   codigoHtml
        +   precioHtml
        + '</div>';
    }).join('');
    sugs.style.display = 'block';
  }
  // [v2026-06-05 SENIOR AUDIT FIX] Helper compartido para construir un item
  // completo con codigos[] + esSkuBase. Misma lógica que _menuImprimir usa.
  // Resuelve equivalencias del catálogo para que el backend sepa si imprimir
  // 1 (ME góndola) o N+1 (WH andamio multi-código).
  function _construirItemCompleto(p) {
    var skuB = String(p.skuBase || p.idProducto || '');
    var codigosDelGrupo = (Array.isArray(p.codigos) && p.codigos.length > 0)
      ? p.codigos.slice()
      : null;
    if (!codigosDelGrupo) {
      var cat = _resolverCatalogo();
      if (cat && cat.equivalencias && skuB) {
        var equivActivos = cat.equivalencias.filter(function(e) {
          return String(e.skuBase || '') === skuB && (e.activo === true || e.activo === undefined || e.activo === '');
        }).map(function(e) { return String(e.codigoBarra || ''); }).filter(Boolean);
        codigosDelGrupo = [String(p.codigoBarra || p.idProducto || skuB)].concat(equivActivos);
      } else {
        codigosDelGrupo = [String(p.codigoBarra || p.idProducto || skuB)].filter(Boolean);
      }
    }
    // dedup (el provider ME puede emitir alias+real por equivalencia → evitar repetidos)
    codigosDelGrupo = (codigosDelGrupo || []).map(String).filter(Boolean)
      .filter(function(c, i, a) { return a.indexOf(c) === i; });
    var totalCodigos = codigosDelGrupo.length || 1;
    return {
      codigoBarra: String(p.codigoBarra || p.idProducto || ''),
      descripcion: String(p.descripcion || p.nombre || ''),
      precio:      parseFloat(p.precio || p.precioVenta) || 0,
      unidad:      String(p.unidad || p.unidadMedida || p.Unidad_Medida || ''),  // góndola: medida c/u · /kg
      skuBase:     skuB,
      esSkuBase:   totalCodigos > 1,
      codigos:     codigosDelGrupo
    };
  }

  // _colaAgregar legacy: recibe campos sueltos. NO calcula equivalencias —
  // solo usado por código antiguo que pasa los 4 args. Para flow nuevo usar
  // _colaAgregarProducto(p) que sí construye item completo.
  function _colaAgregar(cb, desc, precio, sku) {
    _colaAgregarProducto({
      codigoBarra: cb,
      descripcion: desc,
      precio: precio,
      skuBase: sku || cb,
      idProducto: sku || cb
    });
  }

  // [v2026-06-05 SENIOR AUDIT FIX] Agrega un producto completo a la cola
  // resolviendo equivalencias y construyendo item con codigos[]+esSkuBase.
  // Backend usa esos campos para decidir si imprimir 1 (ME) o N+1 (WH).
  function _colaAgregarProducto(p) {
    var tipo = _colaTipo();
    var items = _colaCargar(tipo);
    var item = _construirItemCompleto(p);
    if (items.find(function(it) { return it.codigoBarra === item.codigoBarra && it.skuBase === item.skuBase; })) {
      _toast('⚠ Ya está en la cola', { error: true });
      return;
    }
    items.push(item);
    _colaGuardar(tipo, items);
    sonidos.subjobDone();
    var inp = document.getElementById('msColaBusq');
    if (inp) inp.value = '';
    var sugs = document.getElementById('msColaSugs');
    if (sugs) sugs.style.display = 'none';
    _colaRefrescarLista();
  }

  // [AUDIT FIX #A] handler robusto via índice — no requiere escapar inline
  // [v2026-06-05 SENIOR AUDIT FIX] Usa _colaAgregarProducto para construir
  // item completo con codigos[]+esSkuBase (resuelve equivalentes del catálogo).
  // Antes: pasaba solo 4 campos sueltos sin resolver equivalencias → ME
  // imprimía con codigoBarra de UNA presentación en vez del SKU_Base maestro
  // cuando el producto tenía varios equivalentes (regla MEMBRETE_ME violada).
  function _colaAgregarIdx(idx) {
    var items = window._msColaSugItems || [];
    var it = items[idx];
    if (!it) return;
    _colaAgregarProducto(it);
  }

  // [cámara · solo si la app inyecta _config.scanProvider — hoy solo ME] Escanea un
  // código con la cámara, lo resuelve en el catálogo (codigoBarra / skuBase / equivalente)
  // y lo agrega a la cola. Optimista (feedback inmediato) + sin duplicados
  // (_colaAgregarProducto rechaza si ya está). NO toca presentaciones, solo canónico/equiv.
  async function _colaEscanear() {
    if (!_config || typeof _config.scanProvider !== 'function') return;
    var code = null;
    try { code = await _config.scanProvider(); } catch (_) { code = null; }
    if (!code) return;   // canceló o no leyó
    code = String(code).trim();
    var cat = _resolverCatalogo();
    if (!cat || !Array.isArray(cat.productos)) { _toast('Catálogo no disponible', { error: true }); return; }
    var q = code.toLowerCase();
    var prod = cat.productos.find(function (p) {
      return String(p.codigoBarra || '').toLowerCase() === q ||
             String(p.skuBase || p.idProducto || '').toLowerCase() === q;
    });
    if (!prod) {   // buscar por código equivalente → resolver al canónico (skuBase)
      var eq = (cat.equivalencias || []).find(function (e) { return String(e.codigoBarra || '').toLowerCase() === q; });
      if (eq) prod = cat.productos.find(function (p) { return String(p.skuBase) === String(eq.skuBase); });
    }
    if (!prod) { try { sonidos.error && sonidos.error(); } catch (_) {} _toast('Código no encontrado: ' + code, { error: true }); return; }
    _colaAgregarProducto(prod);   // dedupea + sonido + refresca (optimista)
  }
  function _colaQuitar(idx) {
    var tipo = _colaTipo();
    var items = _colaCargar(tipo);
    items.splice(idx, 1);
    _colaGuardar(tipo, items);
    _colaRefrescarLista();
  }
  function _colaImprimir() {
    var tipo = _colaTipo();
    var items = _colaCargar(tipo);
    if (items.length === 0) return;
    // [v2026-06-05 SENIOR AUDIT FIX] Reconstruir items para garantizar que
    // tengan codigos[]+esSkuBase. Defensa contra items legacy guardados en
    // localStorage antes del fix (cuando _colaAgregar solo guardaba 4 campos).
    var itemsCompletos = items.map(function(it) {
      // Si ya tiene codigos+esSkuBase, usar como está (item nuevo)
      if (Array.isArray(it.codigos) && it.codigos.length > 0 && typeof it.esSkuBase === 'boolean') {
        return it;
      }
      // Sino reconstruir resolviendo equivalencias del catálogo actual
      return _construirItemCompleto(it);
    });
    // Limpiar la cola optimista (UX). Si el backend RECHAZA el lote (no se creó), `onReject` la RESTAURA →
    // los membretes NO se pierden. En éxito el lote queda en historial; en red-incierta (.catch) el modal
    // muestra PAUSADO_ERROR con reintento idempotente (mismo idempotencyKey → sin duplicar).
    var _backupCola = itemsCompletos.slice();
    _colaGuardar(tipo, []);
    _colaCerrar();
    imprimirMembrete({
      tipo: tipo, items: itemsCompletos,
      onReject: function () {
        try { _colaGuardar(tipo, _backupCola); } catch (_) {}
        try { _toast('⚠ No se pudo crear el lote — los membretes siguen en la cola'); } catch (_) {}
      }
    });
  }
  function _colaCerrar() {
    var ov = document.getElementById('msColaOverlay');
    if (ov) { ov.style.animation = 'ms-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // ── MENÚ rápido para card de producto (ME o WH) ──────────────
  // [v1.2 FIX] Si la app NO es MOS (admin), auto-imprime el tipo correcto
  // sin mostrar menú. Solo MOS muestra el menú con ambas opciones.
  // [v1.3 FIX] Pasar producto directo a _menuImprimir para evitar race condition
  // con window._msMenuProd cuando hay doble-click rápido.
  function abrirMenuProductoCard(producto) {
    _injectCss();
    sonidos.click();
    // Auto-imprimir según origen: WH→andamio, ME→góndola (sin tocar global)
    if (_config.origen === 'WH') return _menuImprimir('MEMBRETE_WH', producto);
    if (_config.origen === 'ME') return _menuImprimir('MEMBRETE_ME', producto);
    // Solo MOS muestra el menú con ambas opciones
    if (document.getElementById('msMenuOverlay')) return;
    var precio = parseFloat(producto.precio || producto.precioVenta) || 0;

    // [v2026-06-05 PREVIEW] Construir item completo para mostrar previews ME/WH
    // ANTES de imprimir. Admin ve VISUALMENTE qué saldrá del rollo. Usa el mismo
    // helper que _menuImprimir → garantía que preview == lo que se imprimirá.
    var item = _construirItemCompleto(producto);
    // Para MEMBRETE_WH multi-código: mostramos la CABECERA (skuBase) como primer
    // adhesivo de la serie. Total = códigos.length + 1 (cabecera + N).
    var totalWh = (item.codigos && item.codigos.length > 1) ? (item.codigos.length + 1) : 1;

    // Inyectar CSS de previews membrete (idempotente)
    var previewDisponible = !!(window.AdhesivoPreview && AdhesivoPreview.renderMembreteMeHtml);
    if (previewDisponible) {
      try { AdhesivoPreview.inyectarCssMembretes(); } catch(_) {}
    }

    var meSvgId = 'msPrevMeBc_' + Date.now();
    var whSvgId = 'msPrevWhBc_' + Date.now() + '_w';

    // Render HTML de cada preview (escalado al 55% para caber en modal ~720px)
    var previewMeHtml = '';
    var previewWhHtml = '';
    if (previewDisponible) {
      previewMeHtml = AdhesivoPreview.renderMembreteMeHtml({
        codigoBarra: item.esSkuBase ? item.skuBase : item.codigoBarra,
        descripcion: item.descripcion,
        precio:      item.precio,
        skuBase:     item.skuBase,
        esSkuBase:   item.esSkuBase    // ⧉ canónico en el preview
      }, { svgId: meSvgId });
      previewWhHtml = AdhesivoPreview.renderMembreteWhHtml({
        codigoBarra: item.esSkuBase ? item.skuBase : item.codigoBarra,
        descripcion: item.descripcion,
        skuBase:     item.skuBase,
        esCabecera:  item.esSkuBase,
        indice:      1,
        total:       totalWh
      }, { svgId: whSvgId });
    } else {
      previewMeHtml = '<div style="padding:24px;text-align:center;color:#94a3b8;font-size:12px">Preview no disponible<br><small>Falta cargar AdhesivoPreview</small></div>';
      previewWhHtml = previewMeHtml;
    }

    // Estilo del card de preview (wrapper + escala)
    var cardCss = 'position:relative;background:#0f172a;border-radius:14px;padding:24px 14px 14px;border:1px solid #1e293b;overflow:hidden;display:flex;flex-direction:column;align-items:center;gap:14px';
    var scaleWrapCss = 'transform:scale(.55);transform-origin:top center;width:600px;height:300px;margin-bottom:-135px';  // -135 compensa scale(.55)
    var btnsCss = 'display:grid;grid-template-columns:1fr 1fr;gap:14px';

    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="ms-overlay" id="msMenuOverlay" onclick="if(event.target===this)MembreteSystem._menuCerrar()">'
      +   '<div class="ms-modal" style="max-width:760px">'
      +     '<div class="ms-head">'
      +       '<div class="ms-emoji">🏷</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="ms-h1">¿QUÉ MEMBRETE IMPRIMIR?</div>'
      +         '<div class="ms-sub">' + _escapeHtml(producto.descripcion || producto.codigoBarra) + '</div>'
      +       '</div>'
      +     '</div>'
      +     _rolloBannerHtml()
      +     '<div class="ms-body">'
      +       '<div style="' + btnsCss + '">'
      // ─── Card ME ───
      +         '<div style="' + cardCss + '">'
      +           '<div style="' + scaleWrapCss + '">' + previewMeHtml + '</div>'
      +           '<button class="ms-btn ms-btn-primary" style="margin:0;width:100%" onclick="MembreteSystem._menuImprimir(\'MEMBRETE_ME\')">'
      +             '🏪 IMPRIMIR ME · Góndola'
      +             (precio > 0 ? '<div style="font-size:11px;font-weight:600;margin-top:2px;opacity:.85">Precio S/ ' + precio.toFixed(2) + '</div>' : '')
      +           '</button>'
      +         '</div>'
      // ─── Card WH ───
      +         '<div style="' + cardCss + '">'
      +           '<div style="' + scaleWrapCss + '">' + previewWhHtml + '</div>'
      +           '<button class="ms-btn ms-btn-info" style="margin:0;width:100%" onclick="MembreteSystem._menuImprimir(\'MEMBRETE_WH\')">'
      +             '📦 IMPRIMIR WH · Andamio'
      +             '<div style="font-size:11px;font-weight:600;margin-top:2px;opacity:.85">'
      +               (totalWh > 1 ? ('Imprime ' + totalWh + ' adhesivos (cabecera + ' + (totalWh - 1) + ' códigos)') : 'Imprime 1 adhesivo')
      +             + '</div>'
      +           '</button>'
      +         '</div>'
      +       '</div>'
      +       '<button class="ms-btn ms-btn-warn" style="margin-top:14px" onclick="MembreteSystem._menuCerrar()">Cancelar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    window._msMenuProd = producto;

    // Dibujar barcodes después de que el DOM esté pintado (next tick)
    if (previewDisponible) {
      setTimeout(function() {
        try {
          var svgMe = document.getElementById(meSvgId);
          var svgWh = document.getElementById(whSvgId);
          var codigoMe = item.esSkuBase ? item.skuBase : item.codigoBarra;
          var codigoWh = item.esSkuBase ? item.skuBase : item.codigoBarra;
          if (svgMe) AdhesivoPreview.dibujarBarcode(svgMe, codigoMe);
          if (svgWh) AdhesivoPreview.dibujarBarcode(svgWh, codigoWh);
        } catch(e) {
          console.warn('[membrete-modal] error dibujando preview barcode:', e.message);
        }
      }, 50);
    }
  }
  function _menuImprimir(tipo, productoDirecto) {
    // [v1.3 FIX] Aceptar producto directo (auto-mode) o usar global (modal MOS)
    var p = productoDirecto || window._msMenuProd;
    if (!p) return;
    _menuCerrar();
    // [v2026-06-05 REFACTOR] Construcción del item delegada al helper
    // _construirItemCompleto (DRY con _colaAgregarProducto). Mismo flow:
    // resolver equivalentes del catálogo, construir codigos[]+esSkuBase.
    var item = _construirItemCompleto(p);
    if (!item.codigos || item.codigos.length === 0) {
      _toast('⚠ El producto no tiene código de barras para imprimir', { error: true });
      sonidos.error();
      return;
    }
    imprimirMembrete({ tipo: tipo, items: [item] });
  }
  function _menuCerrar() {
    var ov = document.getElementById('msMenuOverlay');
    if (ov) { ov.style.animation = 'ms-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
    // [v1.2 FIX] Limpiar referencia global para evitar reuso accidental
    try { delete window._msMenuProd; } catch(_) { window._msMenuProd = null; }
  }

  // ── [v1.4] HISTORIAL de lotes (incluye Envasados, WH, ME) ──────
  // Muestra pendientes (en curso) + últimos N completados.
  // [v1.12] El filtro inicial Y los tabs disponibles dependen del origen:
  // - ME  → solo MEMBRETE_ME (sin tabs)
  // - WH  → MEMBRETE_WH + ADHESIVO_ENVASADO (2 tabs)
  // - MOS → todos los tipos (4 tabs)
  function abrirHistorialLotes(tipoFiltro) {
    _injectCss();
    sonidos.click();
    if (document.getElementById('msHistOverlay')) return;
    // [v1.12] Forzar filtro según origen (excepto si el caller pidió uno específico)
    var origen = String(_config.origen || 'MOS').toUpperCase();
    if (origen === 'ME' && !tipoFiltro) tipoFiltro = 'MEMBRETE_ME';
    tipoFiltro = String(tipoFiltro || '').toUpperCase();
    var emoji = tipoFiltro === 'MEMBRETE_ME' ? '🏪'
              : tipoFiltro === 'MEMBRETE_WH' ? '📦'
              : tipoFiltro === 'ADHESIVO_ENVASADO' ? '🏭'
              : '🏷';
    var titulo = tipoFiltro === 'MEMBRETE_ME' ? 'COLA MEMBRETES ME (góndola)'
               : tipoFiltro === 'MEMBRETE_WH' ? 'COLA MEMBRETES WH (andamio)'
               : tipoFiltro === 'ADHESIVO_ENVASADO' ? 'LOTES DE ADHESIVOS · ENVASADOS'
               : 'TODOS LOS LOTES';
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="ms-overlay" id="msHistOverlay" data-tipo="' + tipoFiltro + '">'
      +   '<div class="ms-modal" style="max-width:720px">'
      +     '<div class="ms-head">'
      +       '<div class="ms-emoji">' + emoji + '</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="ms-h1">' + titulo + '</div>'
      +         '<div class="ms-sub" id="msHistSub">cargando…</div>'
      +       '</div>'
      +     '</div>'
      +     _rolloBannerHtml()
      // [v1.12] Tabs filtrados según origen — solo se ven los que aplican a la app
      +     (origen === 'MOS' ?
        '<div style="display:flex;gap:4px;padding:8px 18px 4px;border-bottom:1px solid #1e293b;overflow-x:auto">'
        + '<button onclick="MembreteSystem._histCambiarFiltro(\'\')" class="ms-tab" data-tab="">📋 Todos</button>'
        + '<button onclick="MembreteSystem._histCambiarFiltro(\'MEMBRETE_ME\')" class="ms-tab" data-tab="MEMBRETE_ME">🏪 ME góndola</button>'
        + '<button onclick="MembreteSystem._histCambiarFiltro(\'MEMBRETE_WH\')" class="ms-tab" data-tab="MEMBRETE_WH">📦 WH andamio</button>'
        + '<button onclick="MembreteSystem._histCambiarFiltro(\'ADHESIVO_ENVASADO\')" class="ms-tab" data-tab="ADHESIVO_ENVASADO">🏭 Envasados</button>'
        + '</div>'
      : origen === 'WH' ?
        '<div style="display:flex;gap:4px;padding:8px 18px 4px;border-bottom:1px solid #1e293b;overflow-x:auto">'
        + '<button onclick="MembreteSystem._histCambiarFiltro(\'MEMBRETE_WH\')" class="ms-tab" data-tab="MEMBRETE_WH">📦 WH andamio</button>'
        + '<button onclick="MembreteSystem._histCambiarFiltro(\'ADHESIVO_ENVASADO\')" class="ms-tab" data-tab="ADHESIVO_ENVASADO">🏭 Envasados</button>'
        + '</div>'
      : ''  // ME: sin tabs — solo ve sus lotes ME por default
      )
      +     '<div class="ms-body" style="max-height:60vh;overflow-y:auto" id="msHistBody">'
      +       '<div style="text-align:center;color:#94a3b8;padding:20px"><span style="display:inline-block;animation:ms-spin 1s linear infinite">◐</span> cargando…</div>'
      +     '</div>'
      +     '<div class="ms-actions" style="padding:0 22px 18px">'
      +       '<button class="ms-btn ms-btn-info" onclick="MembreteSystem._histRefrescar()">↻</button>'
      // [v1.13] Botón diagnóstico impresora — útil cuando los lotes no avanzan
      +       (origen !== 'ME' ? '<button class="ms-btn ms-btn-info" onclick="MembreteSystem._diagnosticoImpresoraAdhesivo()" title="Verificar qué impresora está configurada y si responde">🔍 Impresora</button>' : '')
      +       '<button class="ms-btn ms-btn-warn" onclick="MembreteSystem._histCerrar()">Cerrar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    // [v1.9] Marcar tab activo según tipoFiltro inicial
    setTimeout(function() {
      document.querySelectorAll('#msHistOverlay .ms-tab').forEach(function(b) {
        if (b.getAttribute('data-tab') === tipoFiltro) b.classList.add('ms-tab-active');
      });
    }, 20);
    _histRefrescar();
  }
  function _histRefrescar() {
    var ov = document.getElementById('msHistOverlay');
    if (!ov) return;
    var tipoFiltro = ov.getAttribute('data-tipo') || '';
    // [v1.12] En ME forzar tipo MEMBRETE_ME aunque el atributo sea ''
    if (String(_config.origen || '').toUpperCase() === 'ME') tipoFiltro = 'MEMBRETE_ME';
    // En WH, si llega sin filtro, default a 'MEMBRETE_WH' (más útil que ver todo)
    else if (String(_config.origen || '').toUpperCase() === 'WH' && !tipoFiltro) tipoFiltro = 'MEMBRETE_WH';
    var body = document.getElementById('msHistBody');
    var sub  = document.getElementById('msHistSub');
    // [v1.10] Optimista: si hay cache, NO mostrar spinner — render directo.
    // Si no hay cache, sí mostrar spinner mientras espera el fetch.
    var slot = _cache.lotesHistorial;
    if (!slot.data && body) {
      body.innerHTML = '<div style="text-align:center;color:#94a3b8;padding:20px"><span style="display:inline-block;animation:ms-spin 1s linear infinite">◐</span> cargando…</div>';
    }
    var render = function(payload) {
      var d = (payload && payload.historial) || {};
      var diag = payload && payload.diag;
      var pendientes = (d && d.pendientes) || [];
      var historial = (d && d.historial) || [];
      // Aplicar filtro local del lado cliente si tipoFiltro no es vacío
      if (tipoFiltro) {
        pendientes = pendientes.filter(function(x) { return String(x.tipoEtiqueta || '').toUpperCase() === tipoFiltro; });
        historial  = historial.filter(function(x) { return String(x.tipoEtiqueta || '').toUpperCase() === tipoFiltro; });
      }
      _renderHistorialBody({ pendientes: pendientes, historial: historial, diag: diag });
    };
    _conCache('lotesHistorial',
      function() {
        var timeoutPromise = new Promise(function(_, reject) {
          setTimeout(function() { reject(new Error('Timeout 12s · red lenta')); }, 12000);
        });
        return Promise.race([
          Promise.all([
            _api('getLotesAdhesivoHistorial', { tipoEtiqueta: '', limit: 30 }),
            _api('diagnosticoTriggerLotes', {}).catch(function() { return null; })
          ]).then(function(arr) { return { historial: arr[0], diag: arr[1] }; }),
          timeoutPromise
        ]);
      },
      function(cached) { render(cached); },
      function(fresh)  { render(fresh); }
    ).catch(function(e) {
      var b = document.getElementById('msHistBody');
      if (b) b.innerHTML = '<div class="ms-err">⚠ ' + _escapeHtml(e.message) + '</div>';
    });
  }
  // [v1.13] Diagnóstico PrintNode: muestra qué impresora está configurada,
  // su estado online/offline, y los últimos 10 jobs enviados.
  function _diagnosticoImpresoraAdhesivo() {
    sonidos.click();
    _toast('🔍 Consultando PrintNode...');
    _api('diagnosticoPrintNodeAdhesivo', {}).then(function(d) {
      _injectCss();
      var inf = d.impresoraInfo;
      var errs = (d.errores || []).join('<br>');
      var html = ''
        + '<div class="ms-overlay" id="msDiagOverlay" style="z-index:99998">'
        +   '<div class="ms-modal" style="max-width:560px">'
        +     '<div class="ms-head">'
        +       '<div class="ms-emoji">🔍</div>'
        +       '<div style="flex:1"><div class="ms-h1">DIAGNÓSTICO IMPRESORA ADHESIVO</div></div>'
        +     '</div>'
        +     '<div class="ms-body" style="max-height:60vh;overflow-y:auto">'
        +       '<div style="font-size:12px;color:#cbd5e1;margin-bottom:6px">Impresora configurada:</div>'
        +       (inf ?
            '<div class="seg-card" style="padding:12px;background:rgba(15,23,42,.4);border:1px solid #1e293b;border-radius:8px;margin-bottom:10px">'
            + '<div style="font-size:13px;font-weight:800;color:#f1f5f9">' + _escapeHtml(inf.name || '?') + '</div>'
            + '<div style="font-size:11px;color:#94a3b8">ID: ' + _escapeHtml(String(inf.id || d.printerId)) + ' · PC: ' + _escapeHtml(inf.computer || '?') + '</div>'
            + '<div style="margin-top:8px;font-size:13px;font-weight:900;color:' + (inf.online ? '#34d399' : '#f87171') + '">'
            + (inf.online ? '🟢 ONLINE' : '🔴 OFFLINE/' + _escapeHtml(inf.state || 'unknown'))
            + '</div>'
            + (inf.description ? '<div style="font-size:10px;color:#64748b;margin-top:4px">' + _escapeHtml(inf.description) + '</div>' : '')
            + '</div>'
          : '<div class="ms-err">⚠ No se pudo obtener info de la impresora · printerId=' + _escapeHtml(d.printerId || 'NULL') + '</div>')
        +       (errs ? '<div class="ms-err">' + errs + '</div>' : '')
        +       '<div style="font-size:12px;color:#cbd5e1;margin:10px 0 6px">Últimos jobs enviados (PrintNode):</div>'
        +       ((d.jobsRecientes && d.jobsRecientes.length) ?
            d.jobsRecientes.map(function(j) {
              var sCol = j.state === 'done' ? '#34d399' : (j.state === 'error' || j.state === 'expired' ? '#f87171' : '#fbbf24');
              return '<div style="padding:6px 8px;margin-bottom:4px;background:rgba(15,23,42,.4);border-left:3px solid ' + sCol + ';border-radius:4px;font-size:11px">'
                + '<div style="font-weight:700;color:#f1f5f9">' + _escapeHtml(j.title) + '</div>'
                + '<div style="color:#94a3b8;font-family:monospace">#' + j.id + ' · <b style="color:' + sCol + '">' + _escapeHtml(j.state) + '</b> · ' + _escapeHtml(String(j.createTimestamp).substring(5, 16)) + '</div>'
                + '</div>';
            }).join('')
          : '<div style="color:#64748b;font-size:11px">— sin jobs recientes —</div>')
        +     '</div>'
        +     '<div class="ms-actions" style="padding:0 22px 18px">'
        +       '<button class="ms-btn ms-btn-warn" onclick="document.getElementById(\'msDiagOverlay\').remove()">Cerrar</button>'
        +     '</div>'
        +   '</div>'
        + '</div>';
      document.body.insertAdjacentHTML('beforeend', html);
    }).catch(function(e) {
      sonidos.error();
      _toast('❌ ' + _escapeHtml(e.message), { error: true });
    });
  }

  // [v1.11] Forzar procesamiento manual de TODOS los lotes pendientes ahora.
  // Llamado desde el botón ⚡ en el banner del modal Lotes.
  function _procesarAhoraTodos() {
    sonidos.click();
    _toast('⚡ Forzando procesamiento de todos los lotes pendientes...');
    _api('procesarAhoraTodos', {}).then(function(d) {
      var msg = '';
      if (d && d.intentados !== undefined) {
        msg = '✅ Procesados ' + d.ok + '/' + d.intentados + ' lotes';
        if (d.errores > 0) msg += ' · ' + d.errores + ' con error';
      } else {
        msg = '✅ Solicitud enviada';
      }
      _toast(msg, { duracion: 6000 });
      // Invalidar cache de lotes para que el siguiente refresh traiga estado real
      try { _cache.lotesHistorial.ts = 0; } catch(_) {}
      setTimeout(_histRefrescar, 1500);
    }).catch(function(e) {
      sonidos.error();
      _toast('❌ ' + _escapeHtml(e.message), { error: true });
    });
  }
  // [v1.10] Refactor: renderHistorialBody recibe payload ya filtrado
  function _renderHistorialBody(arg) {
    var ovStill = document.getElementById('msHistOverlay');
    var body = document.getElementById('msHistBody');
    var sub  = document.getElementById('msHistSub');
    if (!ovStill || !body) return;
    var pendientes = (arg && arg.pendientes) || [];
    var historial  = (arg && arg.historial) || [];
    var diag = arg && arg.diag;
    if (sub) sub.textContent = pendientes.length + ' en curso · ' + historial.length + ' completados';
      // Si trigger NO está instalado y hay encolados → mostrar banner crítico
      var bannerTrigger = '';
      if (diag && diag.triggerInstalado === false) {
        bannerTrigger = ''
          + '<div class="ms-err" style="background:rgba(248,113,113,.15);border:1px solid #f87171;padding:10px;margin-bottom:10px">'
          +   '<div style="font-weight:900;color:#f87171">⚠ TRIGGER PROCESADOR APAGADO</div>'
          +   '<div style="font-size:11px;color:#fca5a5;margin-top:4px">Los lotes quedan en cola pero nadie los procesa.</div>'
          +   '<button class="ms-btn ms-btn-primary" style="margin-top:8px" onclick="MembreteSystem._activarTriggerLotes()">'
          +     '🔧 Activar trigger ahora'
          +   '</button>'
          + '</div>';
      } else if (diag && diag.triggerInstalado === true && diag.lotesEncolados > 0) {
        bannerTrigger = ''
          + '<div style="background:rgba(251,191,36,.1);border:1px solid rgba(251,191,36,.3);padding:8px;border-radius:6px;margin-bottom:10px;font-size:11px;color:#fbbf24;display:flex;align-items:center;gap:8px;flex-wrap:wrap">'
          +   '<span style="flex:1">⏱ ' + diag.lotesEncolados + ' lote(s) encolado(s) — auto cada 1 min</span>'
          // [v1.11] Botón para forzar procesamiento manual ahora
          +   '<button class="ms-btn ms-btn-primary" style="padding:6px 12px;font-size:11px;width:auto" onclick="MembreteSystem._procesarAhoraTodos()">⚡ Procesar todos ahora</button>'
          + '</div>';
      }
      var fmtHora = function(iso) {
        if (!iso) return '—';
        try { return String(iso).substring(5, 16).replace('T', ' '); } catch(_) { return '—'; }
      };
      var rowHtml = function(lote, esPendiente) {
        var pct = lote.totalEtq > 0 ? Math.round((lote.completadas / lote.totalEtq) * 100) : 0;
        var statusColor = lote.status === 'COMPLETADO' ? '#34d399'
                       : lote.status === 'CANCELADO'  ? '#94a3b8'
                       : String(lote.status || '').indexOf('PAUSADO') === 0 ? '#f87171'
                       : '#fbbf24';
        var statusIcon = lote.status === 'COMPLETADO' ? '✅'
                       : lote.status === 'CANCELADO'  ? '🗑'
                       : String(lote.status || '').indexOf('PAUSADO') === 0 ? '⏸'
                       : '🖨';
        return ''
          + '<div style="padding:10px;background:rgba(15,23,42,.4);border:1px solid #1e293b;border-radius:8px;margin-bottom:6px">'
          +   '<div style="display:flex;align-items:center;gap:8px;margin-bottom:4px">'
          +     '<span style="font-size:14px">' + statusIcon + '</span>'
          +     '<div style="flex:1;min-width:0">'
          +       '<div style="font-size:12px;font-weight:700;color:#f1f5f9;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'
          +         _escapeHtml(lote.descripcion || lote.codigoBarra || lote.idLote)
          +       '</div>'
          +       '<div style="font-size:10px;color:#64748b">'
          // [v1.5 FIX] Escape XSS — usuario/origen vienen del sheet, podrían tener < > "
          +         _escapeHtml(lote.usuario || '') + ' · ' + _escapeHtml(lote.origen || '') + ' · ' + fmtHora(lote.fechaCreacion)
          +       '</div>'
          +     '</div>'
          +     '<div style="text-align:right">'
          +       '<div style="font-size:13px;font-weight:900;color:' + statusColor + ';font-family:monospace">'
          +         lote.completadas + '/' + lote.totalEtq
          +       '</div>'
          +       '<div style="font-size:9px;color:#64748b">' + lote.status + '</div>'
          +     '</div>'
          +   '</div>'
          +   (esPendiente ? '<div style="height:4px;background:#0f172a;border-radius:2px;overflow:hidden;margin-top:4px"><div style="height:100%;width:' + pct + '%;background:' + statusColor + '"></div></div>' : '')
          +   (lote.ultimoError ? '<div style="font-size:10px;color:#f87171;margin-top:4px">⚠ ' + _escapeHtml(lote.ultimoError) + '</div>' : '')
          + '</div>';
      };
      var html = '';
      if (pendientes.length) {
        html += '<div style="font-size:11px;color:#fbbf24;font-weight:800;margin:4px 0 6px;letter-spacing:.5px">⏳ EN CURSO (' + pendientes.length + ')</div>';
        html += pendientes.map(function(l){ return rowHtml(l, true); }).join('');
      }
      if (historial.length) {
        html += '<div style="font-size:11px;color:#94a3b8;font-weight:800;margin:12px 0 6px;letter-spacing:.5px">📜 HISTORIAL (últimos ' + historial.length + ')</div>';
        html += historial.map(function(l){ return rowHtml(l, false); }).join('');
      }
      if (!pendientes.length && !historial.length) {
        html = '<div style="text-align:center;color:#64748b;padding:30px 0;font-size:13px">— sin lotes registrados —</div>';
      }
      if (body) body.innerHTML = bannerTrigger + html;
  }
  function _histCerrar() {
    var ov = document.getElementById('msHistOverlay');
    if (ov) { ov.style.animation = 'ms-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }
  // [v1.9] Cambiar filtro desde tabs internos (optimista: actualiza UI ya)
  function _histCambiarFiltro(nuevoTipo) {
    sonidos.click();
    var ov = document.getElementById('msHistOverlay');
    if (!ov) return;
    ov.setAttribute('data-tipo', String(nuevoTipo || '').toUpperCase());
    // Resaltar tab activo
    document.querySelectorAll('#msHistOverlay .ms-tab').forEach(function(b) {
      if (b.getAttribute('data-tab') === String(nuevoTipo || '').toUpperCase()) b.classList.add('ms-tab-active');
      else b.classList.remove('ms-tab-active');
    });
    _histRefrescar();
  }
  // [v1.4] Activador del trigger desde frontend cuando diagnóstico detecta falta
  function _activarTriggerLotes() {
    sonidos.click();
    _toast('🔧 Instalando trigger procesador...');
    _api('asegurarTriggerLotes', {}).then(function(d) {
      sonidos.completado();
      _toast('✅ Trigger activo · los lotes se procesarán en próximo minuto', { duracion: 5000 });
      setTimeout(_histRefrescar, 1500);
    }).catch(function(e) {
      sonidos.error();
      _toast('❌ ' + _escapeHtml(e.message), { error: true });
    });
  }

  // ── MODAL alertas precio cambiado (ME) ──────────────────────
  function abrirAlertasPrecio() {
    _injectCss();
    sonidos.click();
    if (document.getElementById('msAlertOverlay')) return;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="ms-overlay" id="msAlertOverlay">'
      +   '<div class="ms-modal" style="max-width:540px">'
      +     '<div class="ms-head">'
      +       '<div class="ms-emoji">🚨</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="ms-h1">PRECIOS ACTUALIZADOS</div>'
      +         '<div class="ms-sub" id="msAlertSub">cargando…</div>'
      +       '</div>'
      +     '</div>'
      +     '<div class="ms-body" style="max-height:60vh;overflow-y:auto" id="msAlertBody">'
      +       '<div style="text-align:center;color:#94a3b8;padding:20px">cargando…</div>'
      +     '</div>'
      +     '<div class="ms-actions" style="padding:0 22px 18px">'
      +       '<button class="ms-btn ms-btn-primary" id="msAlertImpBtn" onclick="MembreteSystem._alertImprimir()" disabled>🖨 Imprimir seleccionados</button>'
      +       '<button class="ms-btn ms-btn-info" onclick="MembreteSystem._alertIgnorar()" id="msAlertIgnBtn" disabled>🗑 Ignorar seleccionados</button>'
      +       '<button class="ms-btn ms-btn-warn" onclick="MembreteSystem._alertCerrar()">Cerrar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    _alertCargar();
  }
  function _alertCargar() {
    // [v1.10] Optimista con cache prefetched
    var render = function(d) { _renderAlertasBody(d); };
    _conCache('alertasPrecio',
      function() {
        // Fetch con timeout 10s para no colgarse
        var timeoutP = new Promise(function(_, reject) {
          setTimeout(function() { reject(new Error('Timeout · sin respuesta del backend')); }, 10000);
        });
        return Promise.race([_api('getMembretesMePendientes', { limit: 50 }), timeoutP]);
      },
      function(cached) { render(cached); },
      function(fresh)  { render(fresh); }
    ).catch(function(e) {
      var body = document.getElementById('msAlertBody');
      var sub  = document.getElementById('msAlertSub');
      if (sub) sub.textContent = 'error';
      if (body) body.innerHTML = '<div class="ms-err" style="text-align:center;padding:20px">⚠ ' + _escapeHtml(e.message || 'error backend') + '<div style="font-size:11px;color:#64748b;margin-top:6px">El endpoint getMembretesMePendientes solo existe en MOS. Si abriste desde WH, esta función no aplica.</div></div>';
    });
  }
  function _renderAlertasBody(d) {
      var items = (d && d.items) || [];
      window._msAlerts = items;
      var body = document.getElementById('msAlertBody');
      var sub  = document.getElementById('msAlertSub');
      if (sub) sub.textContent = items.length + ' productos cambiaron de precio';
      if (!body) return;
      if (items.length === 0) {
        body.innerHTML = '<div style="text-align:center;color:#34d399;padding:30px 0;font-size:14px">✅ No hay precios pendientes</div>';
        return;
      }
      body.innerHTML = '<div style="margin-bottom:10px"><label style="font-size:12px;color:#94a3b8;cursor:pointer"><input type="checkbox" id="msAlertAll" onchange="MembreteSystem._alertToggleAll(this.checked)" style="margin-right:6px"> Seleccionar todos</label></div>'
        + items.map(function(it, i) {
        var anterior = parseFloat(it.precioAnterior) || 0;
        var nuevo    = parseFloat(it.precioNuevo) || 0;
        var delta    = nuevo - anterior;
        return ''
          + '<label style="display:flex;align-items:center;gap:10px;padding:10px;background:rgba(15,23,42,.4);border-radius:8px;margin-bottom:6px;border:1px solid #1e293b;cursor:pointer">'
          +   '<input type="checkbox" class="msAlertChk" data-idx="' + i + '" onchange="MembreteSystem._alertUpdBtns()">'
          +   '<div style="flex:1;min-width:0">'
          +     '<div style="font-size:13px;font-weight:700;color:#f1f5f9">' + _escapeHtml(it.descripcion || '') + '</div>'
          +     '<div style="font-size:11px;color:#94a3b8;font-family:monospace">▌' + _escapeHtml(it.codigoBarra || '') + '</div>'
          +   '</div>'
          +   '<div style="text-align:right;font-family:monospace;font-size:12px">'
          +     '<div style="color:#94a3b8;text-decoration:line-through">S/ ' + anterior.toFixed(2) + '</div>'
          +     '<div style="color:' + (delta > 0 ? '#34d399' : '#f87171') + ';font-weight:900;font-size:14px">S/ ' + nuevo.toFixed(2) + '</div>'
          +   '</div>'
          + '</label>';
      }).join('');
  }
  function _alertCargarLegacyErr(e) {
      // catch genérico (compatibilidad — el manejo nuevo está en _alertCargar arriba)
      var body = document.getElementById('msAlertBody');
      var sub  = document.getElementById('msAlertSub');
      if (sub) sub.textContent = 'error';
      if (body) body.innerHTML = '<div class="ms-err" style="text-align:center;padding:20px">⚠ ' + _escapeHtml(e.message || 'error backend') + '</div>';
  }
  function _alertSeleccionados() {
    var sel = [];
    var lista = window._msAlerts || [];
    document.querySelectorAll('.msAlertChk:checked').forEach(function(c) {
      // [v1.2 FIX] Validar idx antes de acceder al array
      var idx = parseInt(c.dataset.idx);
      if (!isNaN(idx) && lista[idx]) sel.push(lista[idx]);
    });
    return sel;
  }
  function _alertToggleAll(on) {
    document.querySelectorAll('.msAlertChk').forEach(function(c) { c.checked = on; });
    _alertUpdBtns();
  }
  function _alertUpdBtns() {
    var sel = _alertSeleccionados();
    var imp = document.getElementById('msAlertImpBtn');
    var ign = document.getElementById('msAlertIgnBtn');
    if (imp) { imp.disabled = sel.length === 0; imp.innerHTML = sel.length === 0 ? '🖨 Imprimir seleccionados' : ('🖨 Imprimir ' + sel.length); }
    if (ign) { ign.disabled = sel.length === 0; ign.innerHTML = sel.length === 0 ? '🗑 Ignorar seleccionados' : ('🗑 Ignorar ' + sel.length); }
  }
  function _alertImprimir() {
    var sel = _alertSeleccionados();
    if (sel.length === 0) return;
    var items = sel.map(function(s) {
      return {
        codigoBarra: String(s.codigoBarra || ''),
        descripcion: String(s.descripcion || ''),
        precio:      parseFloat(s.precioNuevo) || 0,
        skuBase:     String(s.skuBase || ''),
        esSkuBase:   false
      };
    });
    var ids = sel.map(function(s) { return String(s.idAlerta); });
    _alertCerrar();
    imprimirMembrete({ tipo: 'MEMBRETE_ME', items: items }).then(function(d) {
      _api('marcarMembreteMeImpreso', { idAlertas: ids, idLote: (d && d.idLote) || '' }).catch(function(){});
    });
  }
  function _alertIgnorar() {
    var sel = _alertSeleccionados();
    if (sel.length === 0) return;
    if (!confirm('¿Ignorar ' + sel.length + ' precio(s)? No volverán a aparecer hasta que cambien de nuevo.')) return;
    var ids = sel.map(function(s) { return String(s.idAlerta); });
    _api('ignorarMembreteMe', { idAlertas: ids }).then(function() {
      sonidos.subjobDone();
      _toast('🗑 ' + ids.length + ' alertas ignoradas');
      _alertCargar();
    });
  }
  function _alertCerrar() {
    var ov = document.getElementById('msAlertOverlay');
    if (ov) { ov.style.animation = 'ms-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // ── Badge flotante de alertas precio (auto-refresh cada 60s) ────
  // [v1.7 FIX] Solo aplica en MOS y ME (el endpoint getMembretesMePendientes
  // vive en MOS). En WH no tiene sentido — el operario de almacén no maneja precios.
  var _badgeAlertasTimer = null;
  function arrancarBadgeAlertas() {
    // Saltar si origen es WH (alertas de precio son admin/cajero, no almacén)
    if (_config.origen === 'WH') return;
    // [v1.2 FIX] Si ya hay timer, limpiarlo antes de crear nuevo (idempotente)
    if (_badgeAlertasTimer) { try { clearInterval(_badgeAlertasTimer); } catch(_){} _badgeAlertasTimer = null; }
    var refresh = function() {
      _api('getMembretesMePendientes', { limit: 1 }).then(function(d) {
        var count = (d && d.count) || 0;
        var existing = document.getElementById('msBadgeAlertas');
        if (count === 0) { if (existing) existing.remove(); return; }
        if (!existing) {
          var div = document.createElement('div');
          div.id = 'msBadgeAlertas';
          div.className = 'ms-badge-nav';
          div.style.background = 'linear-gradient(135deg,#f87171,#ef4444)';
          div.style.bottom = '70px';
          div.onclick = abrirAlertasPrecio;
          document.body.appendChild(div);
          existing = div;
        }
        existing.innerHTML = '🚨 ' + count + ' precio' + (count > 1 ? 's' : '');
      }).catch(function(){});
    };
    refresh();
    _badgeAlertasTimer = setInterval(refresh, 60000);
  }

  // ── EXPORT ──────────────────────────────────────────────────
  window.MembreteSystem = {
    __loaded:             true,
    iniciar:              iniciar,
    imprimirAdhesivoEnvasado: imprimirAdhesivoEnvasado,
    imprimirMembrete:     imprimirMembrete,
    imprimirCalibradores: imprimirCalibradores,
    estadoCalibracion:    estadoCalibracion,
    calibrarRollo:        calibrarRollo,
    aplicarDrift:         aplicarDrift,
    resetearDriftEmergencia: resetearDriftEmergencia,  // [v2.43.161]
    cerrarModal:          cerrarModal,
    estadoActual:         estadoActual,
    sonidos:              sonidos,
    toast:                _toast,
    // UI embebidas
    abrirCalibrador:      abrirCalibrador,
    abrirCola:            abrirCola,
    abrirMenuProductoCard: abrirMenuProductoCard,
    abrirAlertasPrecio:   abrirAlertasPrecio,
    arrancarBadgeAlertas: arrancarBadgeAlertas,
    // [v1.4] Historial de lotes (botón Cola Envasados/WH/ME)
    abrirHistorialLotes:  abrirHistorialLotes,
    _histRefrescar:       _histRefrescar,
    _histCerrar:          _histCerrar,
    _histCambiarFiltro:   _histCambiarFiltro,
    _activarTriggerLotes: _activarTriggerLotes,
    _procesarAhoraTodos:  _procesarAhoraTodos,
    _diagnosticoImpresoraAdhesivo: _diagnosticoImpresoraAdhesivo,
    // Internals (expuestos para handlers inline en HTML)
    _calCambiarRollo:     _calCambiarRollo,
    _calImprimirCals:     _calImprimirCals,
    _calAplicarMm:        _calAplicarMm,
    _calResetEmergencia:  _calResetEmergencia,  // [v2.43.161]
    _calCerrar:           _calCerrar,
    _colaBusqInput:       _colaBusqInput,
    _colaAgregar:         _colaAgregar,
    _colaAgregarIdx:      _colaAgregarIdx,
    _colaEscanear:        _colaEscanear,
    _colaQuitar:          _colaQuitar,
    _colaImprimir:        _colaImprimir,
    _colaCerrar:          _colaCerrar,
    _menuImprimir:        _menuImprimir,
    _menuCerrar:          _menuCerrar,
    _alertToggleAll:      _alertToggleAll,
    _alertUpdBtns:        _alertUpdBtns,
    _alertImprimir:       _alertImprimir,
    _alertIgnorar:        _alertIgnorar,
    _alertCerrar:         _alertCerrar
  };
})();
