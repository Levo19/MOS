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
    endpointPrefix: 'wh_'
  };

  // ── Estado del lote en curso ────────────────────────────────
  var _state = null;
  // _state = { idLote, total, completadas, status, tipo, descripcion, tInicio }

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
      '.ms-emoji{font-size:36px;line-height:1}',
      '.ms-h1{font-size:14px;font-weight:900;color:#fbbf24;letter-spacing:.8px}',
      '.ms-sub{font-size:11px;color:#94a3b8;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
      '.ms-body{padding:20px 22px;display:flex;flex-direction:column;gap:14px}',
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
    if (counter) counter.textContent = _state.completadas + ' / ' + _state.total;
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
    div.innerHTML = '🏷 ' + _state.completadas + '/' + _state.total;
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
          _toast('✅ ' + (d.total || _state.total) + ' adhesivos impresos · ' + (_state.tipo === 'MEMBRETE_ME' ? 'recoger en almacén' : 'OK'));
          _state.polling = false;
          setTimeout(function() { cerrarModal(); _state = null; _renderBadge(); }, 2500);
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
  }

  // Imprimir lote de adhesivos de envasado (legacy, mantiene compat)
  function imprimirAdhesivoEnvasado(opts) {
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
      _render();
      _arrancarPolling();
      return d;
    }).catch(function(e) {
      if (_state) { _state.status = 'PAUSADO_ERROR'; _state.ultimoError = e.message; _render(); }
      sonidos.error();
    });
  }

  // Imprimir membretes (ME o WH) — items = array de productos
  function imprimirMembrete(opts) {
    var tipo = opts.tipo;  // 'MEMBRETE_ME' | 'MEMBRETE_WH'
    var items = opts.items || [];
    var idempotencyKey = 'mem_' + Date.now() + '_' + Math.random().toString(36).slice(2, 6);
    sonidos.click();
    var desc = tipo === 'MEMBRETE_ME'
      ? items.length + ' productos · góndola'
      : items.length + ' productos · andamio';
    _abrirModalProgreso({
      idLote: '', total: items.length, tipo: tipo, descripcion: desc
    });
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
      _render();
      _arrancarPolling();
      return d;
    }).catch(function(e) {
      if (_state) { _state.status = 'PAUSADO_ERROR'; _state.ultimoError = e.message; _render(); }
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

  function aplicarDrift(mmDesviados, basadoEnPrints) {
    return _api('aplicarDriftDetectado', {
      mmDesviados: mmDesviados,
      basadoEnPrints: basadoEnPrints || 10
    }).then(function(d) {
      sonidos.completado();
      _toast('✅ Drift aplicado: ' + d.driftDotsPorPrint + ' dots/print');
      return d;
    }).catch(function(e) { sonidos.error(); _toast('❌ ' + e.message, { error: true }); });
  }

  function estadoActual() {
    return _state;
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
    cerrarModal:          cerrarModal,
    estadoActual:         estadoActual,
    sonidos:              sonidos,
    toast:                _toast
  };
})();
