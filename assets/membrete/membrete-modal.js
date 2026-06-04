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
          // [v1.2 FIX] Texto correcto: MEMBRETE_ME = para góndola tienda, MEMBRETE_WH = para andamio almacén
          _toast('✅ ' + (d.total || _state.total) + ' adhesivos impresos · ' + (_state.tipo === 'MEMBRETE_ME' ? 'recoger en almacén' : 'listos en andamio'));
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
    if (_state && _state.idLote && ['CREADO','ENCOLADO','IMPRIMIENDO','CALIBRANDO'].indexOf(_state.status) >= 0) {
      _toast('⚠ Ya hay un lote en curso · esperá a que termine', { error: true });
      sonidos.error();
      return Promise.reject(new Error('Lote en curso'));
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
  function imprimirMembrete(opts) {
    // [AUDIT FIX #2] Guard contra dobles clicks / lotes simultáneos.
    if (_state && _state.idLote && ['CREADO','ENCOLADO','IMPRIMIENDO','CALIBRANDO'].indexOf(_state.status) >= 0) {
      _toast('⚠ Ya hay un lote en curso · esperá a que termine', { error: true });
      sonidos.error();
      return Promise.reject(new Error('Lote en curso'));
    }
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
      // [AUDIT FIX #1] Resetear polling=false para permitir re-arranque.
      // Antes _state.polling quedaba en true del primer intento con idLote=''
      // y el segundo _arrancarPolling() retornaba sin loopear.
      _state.polling = false;
      _render();
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
      +     '<div class="ms-body" id="msCalBody">'
      +       '<div style="text-align:center;color:#94a3b8;padding:20px">cargando estado…</div>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    _calRefrescar();
  }
  function _calRefrescar() {
    estadoCalibracion().then(function(d) {
      var body = document.getElementById('msCalBody');
      if (!body) return;
      var calibrado    = d.calibrado;
      var driftDots    = parseFloat(d.driftDotsPorPrint) || 0;
      var driftMm      = +(driftDots / 8).toFixed(2);
      var prints       = parseInt(d.printsDesdeCal) || 0;
      var necesitaRec  = d.necesitaRecalibrar;
      var fechaCal     = String(d.fechaCalibrado || '').substring(0, 16);
      body.innerHTML = ''
        + '<div class="ms-stat">'
        +   '<div class="ms-chip ' + (calibrado ? 'ms-chip-ok' : 'ms-chip-error') + '">'
        +     (calibrado ? '🟢 Calibrado' : '🔴 Sin calibrar')
        +   '</div>'
        +   '<div class="ms-counter">' + prints + ' prints</div>'
        + '</div>'
        + '<div class="ms-info">'
        +   '<span>drift: ' + driftDots + ' dots/print (' + driftMm + ' mm)</span>'
        +   '<span>' + (fechaCal || '—') + '</span>'
        + '</div>'
        + (necesitaRec ? '<div class="ms-err">⚠ >500 prints sin recalibrar · considerá nuevo rollo</div>' : '')
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
        + '<div style="display:flex;gap:8px;align-items:center">'
        +   '<input id="msCalMm" type="number" step="0.5" min="0" placeholder="mm en #10" '
        +     'style="flex:1;padding:9px;background:#0a1424;border:1px solid #1e293b;color:#f1f5f9;border-radius:8px;font-size:13px">'
        +   '<button class="ms-btn ms-btn-primary" style="width:auto;padding:9px 16px" onclick="MembreteSystem._calAplicarMm()">Aplicar</button>'
        + '</div>'
        + '<div style="height:1px;background:#1e293b;margin:6px 0"></div>'
        + '<button class="ms-btn ms-btn-warn" onclick="MembreteSystem._calCerrar()">Cerrar</button>';
    }).catch(function(e) {
      var body = document.getElementById('msCalBody');
      if (body) body.innerHTML = '<div class="ms-err">⚠ Error: ' + _escapeHtml(e.message) + '</div>';
    });
  }
  function _calCambiarRollo() {
    if (!confirm('¿Calibrar rollo nuevo?\n\nGasta ~3 etiquetas en blanco mientras la impresora mide el GAP físico. Después reseteamos contador y drift.')) return;
    calibrarRollo().then(function() { setTimeout(_calRefrescar, 1500); });
  }
  function _calImprimirCals() {
    imprimirCalibradores({ cantidad: 10 }).then(function() { setTimeout(_calRefrescar, 1500); });
  }
  function _calAplicarMm() {
    var inp = document.getElementById('msCalMm');
    var mm = parseFloat(inp && inp.value);
    if (isNaN(mm) || mm < 0) { _toast('⚠ Ingresá los mm de desvío', { error: true }); return; }
    aplicarDrift(mm, 10).then(function() { if (inp) inp.value = ''; setTimeout(_calRefrescar, 800); });
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
      +     '<div class="ms-body" style="max-height:65vh;overflow-y:auto">'
      +       '<input id="msColaBusq" type="text" placeholder="🔍 Buscar producto por código o descripción..." '
      +         'oninput="MembreteSystem._colaBusqInput(this.value)" '
      +         'style="width:100%;padding:10px 12px;background:#0a1424;border:1px solid #1e293b;color:#f1f5f9;border-radius:10px;font-size:13px;margin-bottom:8px">'
      +       '<div id="msColaSugs" style="max-height:120px;overflow-y:auto;display:none;background:#0a1424;border-radius:8px;padding:4px;margin-bottom:8px"></div>'
      +       '<div id="msColaLista"></div>'
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
    lista.innerHTML = items.map(function(it, i) {
      var precioBlock = tipo === 'MEMBRETE_ME'
        ? '<div style="font-size:14px;font-weight:900;color:#fbbf24;font-family:monospace">S/ ' + (parseFloat(it.precio) || 0).toFixed(2) + '</div>'
        : '';
      return ''
        + '<div style="display:flex;align-items:center;gap:10px;padding:10px;background:rgba(15,23,42,.4);border-radius:8px;margin-bottom:6px;border:1px solid #1e293b">'
        +   '<div style="flex:1;min-width:0">'
        +     '<div style="font-size:13px;font-weight:700;color:#f1f5f9;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + _escapeHtml(it.descripcion || '') + '</div>'
        +     '<div style="font-size:11px;color:#94a3b8;font-family:monospace">▌' + _escapeHtml(it.codigoBarra || '') + '</div>'
        +   '</div>'
        +   precioBlock
        +   '<button onclick="MembreteSystem._colaQuitar(' + i + ')" style="background:rgba(248,113,113,.12);color:#fca5a5;border:1px solid rgba(248,113,113,.35);border-radius:6px;padding:4px 8px;cursor:pointer;font-size:14px">✕</button>'
        + '</div>';
    }).join('');
  }
  function _colaBusqInput(q) {
    q = String(q || '').trim().toLowerCase();
    var sugs = document.getElementById('msColaSugs');
    if (!sugs) return;
    if (q.length < 2) { sugs.style.display = 'none'; return; }
    // Buscar productos via API (usar getCatalogo o equivalente cacheado)
    // Fallback: si la app tiene cache de productos en window, usarlo
    var fuente = null;
    try {
      if (window.S && Array.isArray(window.S.catalogo)) fuente = window.S.catalogo;
      else if (window.OfflineManager && OfflineManager.getProductosCache) fuente = OfflineManager.getProductosCache();
    } catch(_) {}
    if (!fuente || fuente.length === 0) {
      sugs.innerHTML = '<div style="padding:8px;font-size:12px;color:#fbbf24">No hay catálogo cargado · cargá productos en MOS o WH primero</div>';
      sugs.style.display = 'block';
      return;
    }
    var matches = fuente.filter(function(p) {
      var desc = String(p.descripcion || p.nombre || '').toLowerCase();
      var cb   = String(p.codigoBarra || p.idProducto || '').toLowerCase();
      var sku  = String(p.skuBase || '').toLowerCase();
      return desc.indexOf(q) >= 0 || cb.indexOf(q) >= 0 || sku.indexOf(q) >= 0;
    }).slice(0, 8);
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
    sugs.innerHTML = window._msColaSugItems.map(function(it, i) {
      return ''
        + '<div onclick="MembreteSystem._colaAgregarIdx(' + i + ')"'
        +   ' style="padding:8px 10px;cursor:pointer;border-radius:6px;font-size:12px;color:#cbd5e1"'
        +   ' onmouseover="this.style.background=\'rgba(251,191,36,.10)\'"'
        +   ' onmouseout="this.style.background=\'transparent\'">'
        +   '<span style="font-weight:700">' + _escapeHtml(it.descripcion) + '</span> '
        +   '<span style="font-family:monospace;color:#94a3b8">▌' + _escapeHtml(it.codigoBarra) + '</span>'
        +   (it.precio > 0 ? ' <span style="color:#fbbf24;font-weight:700;float:right">S/ ' + it.precio.toFixed(2) + '</span>' : '')
        + '</div>';
    }).join('');
    sugs.style.display = 'block';
  }
  function _colaAgregar(cb, desc, precio, sku) {
    var tipo = _colaTipo();
    var items = _colaCargar(tipo);
    if (items.find(function(it) { return it.codigoBarra === cb; })) {
      _toast('⚠ Ya está en la cola', { error: true });
      return;
    }
    items.push({ codigoBarra: cb, descripcion: desc, precio: precio, skuBase: sku });
    _colaGuardar(tipo, items);
    sonidos.subjobDone();
    var inp = document.getElementById('msColaBusq');
    if (inp) inp.value = '';
    var sugs = document.getElementById('msColaSugs');
    if (sugs) sugs.style.display = 'none';
    _colaRefrescarLista();
  }

  // [AUDIT FIX #A] handler robusto via índice — no requiere escapar inline
  function _colaAgregarIdx(idx) {
    var items = window._msColaSugItems || [];
    var it = items[idx];
    if (!it) return;
    _colaAgregar(it.codigoBarra, it.descripcion, it.precio, it.skuBase);
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
    _colaCerrar();
    imprimirMembrete({ tipo: tipo, items: items }).then(function() {
      _colaGuardar(tipo, []);  // limpiar cola tras éxito
    });
  }
  function _colaCerrar() {
    var ov = document.getElementById('msColaOverlay');
    if (ov) { ov.style.animation = 'ms-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // ── MENÚ rápido para card de producto (ME o WH) ──────────────
  // [v1.2 FIX] Si la app NO es MOS (admin), auto-imprime el tipo correcto
  // sin mostrar menú. Solo MOS muestra el menú con ambas opciones.
  function abrirMenuProductoCard(producto) {
    _injectCss();
    sonidos.click();
    // Auto-imprimir según origen: WH→andamio, ME→góndola
    if (_config.origen === 'WH') {
      window._msMenuProd = producto;
      _menuImprimir('MEMBRETE_WH');
      return;
    }
    if (_config.origen === 'ME') {
      window._msMenuProd = producto;
      _menuImprimir('MEMBRETE_ME');
      return;
    }
    // Solo MOS muestra el menú con ambas opciones
    if (document.getElementById('msMenuOverlay')) return;
    var precio = parseFloat(producto.precio || producto.precioVenta) || 0;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="ms-overlay" id="msMenuOverlay" onclick="if(event.target===this)MembreteSystem._menuCerrar()">'
      +   '<div class="ms-modal" style="max-width:420px">'
      +     '<div class="ms-head">'
      +       '<div class="ms-emoji">🏷</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="ms-h1">IMPRIMIR MEMBRETE</div>'
      +         '<div class="ms-sub">' + _escapeHtml(producto.descripcion || producto.codigoBarra) + '</div>'
      +       '</div>'
      +     '</div>'
      +     '<div class="ms-body">'
      +       '<button class="ms-btn ms-btn-primary" onclick="MembreteSystem._menuImprimir(\'MEMBRETE_ME\')">'
      +         '🏪 ME · Góndola tienda'
      +         (precio > 0 ? '<div style="font-size:11px;font-weight:600;margin-top:2px;opacity:.85">Precio: S/ ' + precio.toFixed(2) + '</div>' : '')
      +       '</button>'
      +       '<button class="ms-btn ms-btn-info" onclick="MembreteSystem._menuImprimir(\'MEMBRETE_WH\')">'
      +         '📦 WH · Andamio almacén'
      +         '<div style="font-size:11px;font-weight:600;margin-top:2px;opacity:.85">Multi-código si tiene equivalentes</div>'
      +       '</button>'
      +       '<button class="ms-btn ms-btn-warn" onclick="MembreteSystem._menuCerrar()">Cancelar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    window._msMenuProd = producto;
  }
  function _menuImprimir(tipo) {
    var p = window._msMenuProd;
    if (!p) return;
    _menuCerrar();
    var item = {
      codigoBarra: String(p.codigoBarra || p.idProducto || ''),
      descripcion: String(p.descripcion || p.nombre || ''),
      precio:      parseFloat(p.precio || p.precioVenta) || 0,
      skuBase:     String(p.skuBase || ''),
      esSkuBase:   false,
      codigos:     Array.isArray(p.codigos) ? p.codigos : null
    };
    imprimirMembrete({ tipo: tipo, items: [item] });
  }
  function _menuCerrar() {
    var ov = document.getElementById('msMenuOverlay');
    if (ov) { ov.style.animation = 'ms-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
    // [v1.2 FIX] Limpiar referencia global para evitar reuso accidental
    try { delete window._msMenuProd; } catch(_) { window._msMenuProd = null; }
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
    _api('getMembretesMePendientes', { limit: 50 }).then(function(d) {
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
    });
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
  var _badgeAlertasTimer = null;
  function arrancarBadgeAlertas() {
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
    // Internals (expuestos para handlers inline en HTML)
    _calCambiarRollo:     _calCambiarRollo,
    _calImprimirCals:     _calImprimirCals,
    _calAplicarMm:        _calAplicarMm,
    _calCerrar:           _calCerrar,
    _colaBusqInput:       _colaBusqInput,
    _colaAgregar:         _colaAgregar,
    _colaAgregarIdx:      _colaAgregarIdx,
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
