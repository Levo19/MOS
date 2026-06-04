/* ============================================================
 *  seguridad-modal.js   [v1.0.0]
 *  Sistema centralizado de Seguridad (dispositivos + horarios).
 *  Standalone — cargado por MOS, WH, ME via script tag.
 * ============================================================ */
(function() {
  'use strict';
  if (window.SeguridadSystem && window.SeguridadSystem.__loaded) return;

  var _config = {
    apiPost: null,
    usuario:    function() { return ''; },
    rol:        function() { return ''; },
    idPersonal: function() { return ''; },
    app:        'MOS',
    unwrapData: true,
    endpointPrefix: ''
  };

  // ── CSS inyectado ──────────────────────────────────────────
  function _injectCss() {
    if (document.getElementById('seg-css')) return;
    var s = document.createElement('style');
    s.id = 'seg-css';
    s.textContent = [
      '.seg-overlay{position:fixed;inset:0;background:rgba(2,6,23,.78);backdrop-filter:blur(12px);z-index:99994;display:flex;align-items:center;justify-content:center;padding:16px;animation:seg-in .25s ease-out}',
      '@keyframes seg-in{from{opacity:0}to{opacity:1}}',
      '@keyframes seg-out{to{opacity:0;transform:scale(.96)}}',
      '.seg-modal{width:100%;max-width:640px;background:linear-gradient(180deg,#0a1424,#070d18);border:1px solid rgba(99,102,241,.4);border-radius:18px;box-shadow:0 30px 70px -10px rgba(99,102,241,.25);display:flex;flex-direction:column;max-height:92vh;overflow:hidden;animation:seg-pop .35s cubic-bezier(.34,1.56,.64,1)}',
      '@keyframes seg-pop{from{transform:scale(.9);opacity:0}to{transform:scale(1);opacity:1}}',
      '.seg-head{padding:18px 22px;border-bottom:1px solid #1e293b;background:linear-gradient(135deg,rgba(99,102,241,.12),rgba(99,102,241,.04));display:flex;align-items:center;gap:14px}',
      '.seg-emoji{font-size:36px;line-height:1}',
      '.seg-h1{font-size:14px;font-weight:900;color:#a5b4fc;letter-spacing:.8px}',
      '.seg-sub{font-size:11px;color:#94a3b8;margin-top:3px}',
      '.seg-tabs{display:flex;gap:4px;padding:10px 22px;border-bottom:1px solid #1e293b;background:#0a1424}',
      '.seg-tab{padding:8px 14px;border-radius:8px 8px 0 0;font-size:12px;font-weight:700;color:#64748b;cursor:pointer;border:none;background:transparent;transition:all .15s}',
      '.seg-tab.active{color:#a5b4fc;background:rgba(99,102,241,.12);border-bottom:2px solid #a5b4fc}',
      '.seg-tab:hover:not(.active){background:rgba(99,102,241,.06);color:#cbd5e1}',
      '.seg-body{padding:18px 22px;display:flex;flex-direction:column;gap:12px;max-height:60vh;overflow-y:auto}',
      '.seg-card{padding:14px;background:rgba(15,23,42,.4);border:1px solid #1e293b;border-radius:12px;transition:all .15s}',
      '.seg-card:hover{border-color:rgba(99,102,241,.3);transform:translateY(-1px)}',
      '.seg-card-titulo{font-size:13px;font-weight:800;color:#f1f5f9}',
      '.seg-card-sub{font-size:11px;color:#94a3b8;margin-top:2px}',
      '.seg-card-row{display:flex;align-items:center;gap:10px;margin-bottom:8px}',
      '.seg-card-actions{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}',
      '.seg-chip{padding:3px 10px;border-radius:9999px;font-size:10px;font-weight:800;border:1px solid;display:inline-block}',
      '.seg-chip-info{color:#94a3b8;border-color:rgba(148,163,184,.35);background:rgba(148,163,184,.08)}',
      '.seg-chip-warn{color:#fbbf24;border-color:rgba(251,191,36,.5);background:rgba(251,191,36,.12)}',
      '.seg-chip-ok{color:#34d399;border-color:rgba(52,211,153,.5);background:rgba(52,211,153,.12)}',
      '.seg-chip-error{color:#f87171;border-color:rgba(248,113,113,.5);background:rgba(248,113,113,.14)}',
      '.seg-btn{padding:8px 14px;border-radius:8px;font-size:12px;font-weight:800;border:1px solid;cursor:pointer;transition:all .15s}',
      '.seg-btn:hover{transform:translateY(-1px)}',
      '.seg-btn-primary{background:linear-gradient(135deg,#6366f1,#4f46e5);color:#fff;border-color:#6366f1}',
      '.seg-btn-ok{background:rgba(52,211,153,.12);color:#34d399;border-color:rgba(52,211,153,.45)}',
      '.seg-btn-warn{background:rgba(248,113,113,.12);color:#fca5a5;border-color:rgba(248,113,113,.4)}',
      '.seg-btn-info{background:rgba(99,102,241,.12);color:#a5b4fc;border-color:rgba(99,102,241,.4)}',
      '.seg-input{width:100%;padding:9px 12px;background:#0a1424;border:1px solid #1e293b;color:#f1f5f9;border-radius:8px;font-size:13px}',
      '.seg-input:focus{outline:none;border-color:#6366f1}',
      '.seg-spin{display:inline-block;animation:seg-spin 1s linear infinite}',
      '@keyframes seg-spin{from{transform:rotate(0)}to{transform:rotate(360deg)}}',
      // Badge admin alertas
      '.seg-badge{position:fixed;top:16px;right:16px;z-index:99988;background:linear-gradient(135deg,#dc2626,#b91c1c);color:#fff;padding:10px 16px;border-radius:9999px;font-size:13px;font-weight:900;cursor:pointer;box-shadow:0 10px 24px -4px rgba(220,38,38,.6);animation:seg-pulse-red 2s ease-in-out infinite;display:flex;align-items:center;gap:8px}',
      '@keyframes seg-pulse-red{0%,100%{box-shadow:0 10px 24px -4px rgba(220,38,38,.6)}50%{box-shadow:0 14px 36px -4px rgba(220,38,38,.95)}}',
      // Widget dashboard horario
      '.seg-widget{display:inline-flex;align-items:center;gap:10px;padding:8px 14px;border-radius:12px;background:linear-gradient(135deg,rgba(251,191,36,.15),rgba(245,158,11,.08));border:1px solid rgba(251,191,36,.4);box-shadow:0 0 16px rgba(251,191,36,.2);animation:seg-pulse-amber 3s ease-in-out infinite;cursor:pointer;transition:all .15s}',
      '.seg-widget:hover{transform:scale(1.04)}',
      '.seg-widget.urgente{background:linear-gradient(135deg,rgba(248,113,113,.18),rgba(220,38,38,.08));border-color:rgba(248,113,113,.6);box-shadow:0 0 18px rgba(248,113,113,.35);animation:seg-pulse-red 1.5s ease-in-out infinite}',
      '@keyframes seg-pulse-amber{0%,100%{box-shadow:0 0 16px rgba(251,191,36,.2)}50%{box-shadow:0 0 24px rgba(251,191,36,.5)}}',
      '.seg-widget-icono{font-size:18px}',
      '.seg-widget-text{display:flex;flex-direction:column;line-height:1.1}',
      '.seg-widget-titulo{font-size:10px;font-weight:700;color:#fbbf24;text-transform:uppercase;letter-spacing:.5px}',
      '.seg-widget.urgente .seg-widget-titulo{color:#fca5a5}',
      '.seg-widget-tiempo{font-size:14px;font-weight:900;color:#f1f5f9;font-family:Consolas,monospace}',
      // Toast
      '.seg-toast{position:fixed;top:16px;right:16px;z-index:99996;background:linear-gradient(180deg,#1e293b,#0f172a);border:1px solid rgba(99,102,241,.4);border-radius:12px;padding:14px 18px;color:#f1f5f9;font-size:13px;font-weight:600;max-width:340px;animation:seg-slide .4s cubic-bezier(.34,1.56,.64,1);box-shadow:0 20px 40px -10px rgba(0,0,0,.6)}',
      '@keyframes seg-slide{from{opacity:0;transform:translateX(40px)}to{opacity:1;transform:translateX(0)}}',
      '.seg-toast-success{border-color:rgba(52,211,153,.5)}',
      '.seg-toast-error{border-color:rgba(248,113,113,.5)}',
      // Pinpad
      '.seg-pinpad{display:flex;gap:6px;justify-content:center;margin:8px 0}',
      '.seg-pin-dot{width:14px;height:14px;border-radius:50%;border:2px solid #1e293b;background:transparent}',
      '.seg-pin-dot.filled{background:#a5b4fc;border-color:#a5b4fc}'
    ].join('\n');
    document.head.appendChild(s);
  }

  // ── Sonidos Web Audio ──────────────────────────────────────
  var _audioCtx = null;
  function _ac() {
    if (!_audioCtx) {
      try { _audioCtx = new (window.AudioContext || window.webkitAudioContext)(); }
      catch(_) { return null; }
    }
    return _audioCtx;
  }
  function _beep(freq, durMs, type) {
    if (localStorage.getItem('mos_sound_off') === '1') return;
    var ctx = _ac(); if (!ctx) return;
    try {
      var osc = ctx.createOscillator();
      var g = ctx.createGain();
      osc.type = type || 'sine';
      osc.frequency.setValueAtTime(freq, ctx.currentTime);
      g.gain.setValueAtTime(.16, ctx.currentTime);
      g.gain.exponentialRampToValueAtTime(.001, ctx.currentTime + durMs / 1000);
      osc.connect(g); g.connect(ctx.destination);
      osc.start(ctx.currentTime);
      osc.stop(ctx.currentTime + durMs / 1000);
    } catch(_) {}
  }
  var sonidos = {
    click:        function() { _beep(900, 50); },
    alerta:       function() { [880,1100].forEach(function(f,i){ setTimeout(function(){ _beep(f, 100, 'sine'); }, i*100); }); },
    urgente:      function() { [1100,1100,1100].forEach(function(f,i){ setTimeout(function(){ _beep(f, 150, 'square'); }, i*180); }); },
    aprobado:     function() { [660,990,1320].forEach(function(f,i){ setTimeout(function(){ _beep(f, 200); }, i*150); }); },
    rechazado:    function() { _beep(220, 280, 'sawtooth'); setTimeout(function(){ _beep(110, 320, 'sawtooth'); }, 220); },
    warning:      function() { _beep(440, 180, 'triangle'); }
  };

  // ── Toast ──────────────────────────────────────────────────
  function _toast(msg, opts) {
    opts = opts || {};
    _injectCss();
    var div = document.createElement('div');
    div.className = 'seg-toast' + (opts.error ? ' seg-toast-error' : (opts.success ? ' seg-toast-success' : ''));
    div.innerHTML = msg;
    document.body.appendChild(div);
    setTimeout(function() {
      div.style.animation = 'seg-slide .4s reverse';
      setTimeout(function() { div.remove(); }, 400);
    }, opts.duracion || 4000);
  }

  // ── Modales nativos sustitutos (memoria: prohibido prompt/confirm/alert) ──
  function _modalPrompt(opts) {
    return new Promise(function(resolve) {
      _injectCss();
      var id = 'segPrompt_' + Date.now();
      var defaultVal = opts.default || '';
      var html = ''
        + '<div class="seg-overlay" id="' + id + '" style="z-index:99998">'
        +   '<div class="seg-modal" style="max-width:420px">'
        +     '<div class="seg-head">'
        +       '<div class="seg-emoji">' + (opts.emoji || '✏') + '</div>'
        +       '<div style="flex:1"><div class="seg-h1">' + _esc(opts.title || 'Ingresar') + '</div>'
        +         (opts.subtitle ? '<div class="seg-sub">' + _esc(opts.subtitle) + '</div>' : '') + '</div>'
        +     '</div>'
        +     '<div class="seg-body">'
        +       (opts.label ? '<label style="font-size:11px;color:#94a3b8;font-weight:700">' + _esc(opts.label) + '</label>' : '')
        +       '<input class="seg-input" id="' + id + '_in" type="' + (opts.type || 'text') + '" '
        +         'value="' + _esc(defaultVal) + '" placeholder="' + _esc(opts.placeholder || '') + '" '
        +         (opts.maxlength ? 'maxlength="' + opts.maxlength + '" ' : '')
        +         'style="font-size:14px">'
        +     '</div>'
        +     '<div style="padding:14px 22px;border-top:1px solid #1e293b;display:flex;gap:8px">'
        +       '<button class="seg-btn seg-btn-warn" style="flex:1" id="' + id + '_cn">Cancelar</button>'
        +       '<button class="seg-btn seg-btn-primary" style="flex:2" id="' + id + '_ok">Aceptar</button>'
        +     '</div>'
        +   '</div>'
        + '</div>';
      document.body.insertAdjacentHTML('beforeend', html);
      var inp = document.getElementById(id + '_in');
      setTimeout(function() { inp && inp.focus(); inp && inp.select(); }, 50);
      var cerrar = function(valor) {
        var ov = document.getElementById(id);
        if (ov) { ov.style.animation = 'seg-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
        resolve(valor);
      };
      document.getElementById(id + '_ok').onclick = function() { cerrar(inp.value); };
      document.getElementById(id + '_cn').onclick = function() { cerrar(null); };
      inp.onkeydown = function(e) {
        if (e.key === 'Enter') cerrar(inp.value);
        else if (e.key === 'Escape') cerrar(null);
      };
    });
  }
  function _modalConfirm(opts) {
    return new Promise(function(resolve) {
      _injectCss();
      var id = 'segConfirm_' + Date.now();
      var html = ''
        + '<div class="seg-overlay" id="' + id + '" style="z-index:99998">'
        +   '<div class="seg-modal" style="max-width:420px;border-color:rgba(248,113,113,.4)">'
        +     '<div class="seg-head" style="background:linear-gradient(135deg,rgba(248,113,113,.12),rgba(220,38,38,.04))">'
        +       '<div class="seg-emoji">' + (opts.emoji || '⚠') + '</div>'
        +       '<div style="flex:1"><div class="seg-h1" style="color:#fca5a5">' + _esc(opts.title || 'Confirmar') + '</div></div>'
        +     '</div>'
        +     '<div class="seg-body"><div style="font-size:13px;color:#cbd5e1;padding:8px 0">'
        +       _esc(opts.message || '¿Estás seguro?') + '</div></div>'
        +     '<div style="padding:14px 22px;border-top:1px solid #1e293b;display:flex;gap:8px">'
        +       '<button class="seg-btn seg-btn-warn" style="flex:1" id="' + id + '_cn">' + _esc(opts.cancelLabel || 'Cancelar') + '</button>'
        +       '<button class="seg-btn seg-btn-primary" style="flex:2" id="' + id + '_ok">' + _esc(opts.okLabel || 'Confirmar') + '</button>'
        +     '</div>'
        +   '</div>'
        + '</div>';
      document.body.insertAdjacentHTML('beforeend', html);
      var cerrar = function(v) {
        var ov = document.getElementById(id);
        if (ov) { ov.style.animation = 'seg-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
        resolve(v);
      };
      document.getElementById(id + '_ok').onclick = function() { cerrar(true); };
      document.getElementById(id + '_cn').onclick = function() { cerrar(false); };
    });
  }

  // ── Helpers API ────────────────────────────────────────────
  function _api(action, params) {
    if (!_config.apiPost) return Promise.reject(new Error('SeguridadSystem no inicializado'));
    var fullAction = _config.endpointPrefix + action;
    var p = _config.apiPost(fullAction, params || {});
    return Promise.resolve(p).then(function(r) {
      if (r && r.ok === false) throw new Error(r.error || 'Backend rechazó');
      return _config.unwrapData ? r : (r && r.data ? r.data : r);
    });
  }
  function _esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
    });
  }
  function _humanizarFecha(iso) {
    if (!iso) return '—';
    try {
      var d = new Date(iso);
      var diff = (Date.now() - d.getTime()) / 1000;
      if (diff < 60) return 'hace ' + Math.floor(diff) + 's';
      if (diff < 3600) return 'hace ' + Math.floor(diff / 60) + 'min';
      if (diff < 86400) return 'hace ' + Math.floor(diff / 3600) + 'h';
      return 'hace ' + Math.floor(diff / 86400) + 'd';
    } catch(_) { return iso ? String(iso).substring(0, 16) : '—'; }
  }

  // ════════════════════════════════════════════════════════════
  // BADGE FLOTANTE alertas admin
  // ════════════════════════════════════════════════════════════
  var _badgeTimer = null;
  // [v1.0.1 FIX] Persistir último count visto en localStorage por usuario para que
  // el sonido NO suene en cada recarga de página con alertas ya conocidas.
  function _badgeCountVisto() {
    try { return parseInt(localStorage.getItem('seg_badge_count_visto') || '0') || 0; }
    catch(_) { return 0; }
  }
  function _badgeCountVistoSet(n) {
    try { localStorage.setItem('seg_badge_count_visto', String(n)); } catch(_) {}
  }
  function arrancarBadgeAlertas() {
    // [v1.0.3 FIX] Si ya hay timer, limpiarlo antes de crear uno nuevo.
    // Antes el early return aceptaba un timer huérfano si el flujo era irregular.
    if (_badgeTimer) { try { clearInterval(_badgeTimer); } catch(_){} _badgeTimer = null; }
    _injectCss();
    var primerRefresh = true;
    var refresh = function() {
      _api('getSeguridadAlertas', { limit: 1 }).then(function(d) {
        var count = (d && d.count) || 0;
        var existing = document.getElementById('segBadge');
        if (count === 0) {
          if (existing) existing.remove();
          _badgeCountVistoSet(0);
          return;
        }
        if (!existing) {
          var div = document.createElement('div');
          div.id = 'segBadge';
          div.className = 'seg-badge';
          div.onclick = abrirModalAlertas;
          document.body.appendChild(div);
          existing = div;
        }
        // Sonar SOLO si: (a) refresh posterior y count subió, o
        // (b) primer refresh y hay MÁS alertas que la última vez que el admin
        // las vio (persistido en localStorage)
        var ultimoVisto = _badgeCountVisto();
        if (!primerRefresh && count > ultimoVisto) {
          sonidos.alerta();
        } else if (primerRefresh && count > ultimoVisto) {
          sonidos.alerta();
        }
        primerRefresh = false;
        _badgeCountVistoSet(count);
        existing.innerHTML = '🚨 <span>' + count + ' alerta' + (count > 1 ? 's' : '') + ' de seguridad</span>';
      }).catch(function() {});
    };
    refresh();
    _badgeTimer = setInterval(refresh, 60000);
  }

  // ════════════════════════════════════════════════════════════
  // MODAL Alertas Dispositivos (3 tabs)
  // ════════════════════════════════════════════════════════════
  var _alertasState = { tab: 'pendientes', items: [], dispositivos: [] };

  function abrirModalAlertas() {
    _injectCss();
    if (document.getElementById('segAlertasOverlay')) return;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="seg-overlay" id="segAlertasOverlay">'
      +   '<div class="seg-modal">'
      +     '<div class="seg-head">'
      +       '<div class="seg-emoji">🔔</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="seg-h1">ALERTAS DE SEGURIDAD</div>'
      +         '<div class="seg-sub" id="segAlertasSub">cargando…</div>'
      +       '</div>'
      +     '</div>'
      +     '<div class="seg-tabs">'
      +       '<button class="seg-tab active" id="segTabPend"  onclick="SeguridadSystem._alertasTab(\'pendientes\')">Pendientes</button>'
      +       '<button class="seg-tab"        id="segTabSusp"  onclick="SeguridadSystem._alertasTab(\'suspendidos\')">Suspendidos</button>'
      +       '<button class="seg-tab"        id="segTabTodos" onclick="SeguridadSystem._alertasTab(\'todos\')">Todos</button>'
      +     '</div>'
      +     '<div class="seg-body" id="segAlertasBody">'
      +       '<div style="text-align:center;color:#94a3b8;padding:20px">cargando…</div>'
      +     '</div>'
      +     '<div style="padding:14px 22px;border-top:1px solid #1e293b">'
      +       '<button class="seg-btn seg-btn-warn" style="width:100%" onclick="SeguridadSystem._alertasCerrar()">Cerrar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    _alertasCargar();
  }
  function _alertasTab(tab) {
    _alertasState.tab = tab;
    document.querySelectorAll('.seg-tab').forEach(function(b) { b.classList.remove('active'); });
    var btnId = { pendientes: 'segTabPend', suspendidos: 'segTabSusp', todos: 'segTabTodos' }[tab];
    var btn = document.getElementById(btnId);
    if (btn) btn.classList.add('active');
    _alertasCargar();
  }
  function _alertasCargar() {
    var body = document.getElementById('segAlertasBody');
    if (!body) return;
    body.innerHTML = '<div style="text-align:center;color:#94a3b8;padding:20px"><span class="seg-spin">◐</span> cargando…</div>';
    Promise.all([
      _api('getSeguridadAlertas', { limit: 100 }).catch(function() { return { items: [], count: 0 }; }),
      _api('getDispositivos', {}).catch(function() { return []; })
    ]).then(function(arr) {
      var alertas = (arr[0] && arr[0].items) || [];
      var disps = Array.isArray(arr[1]) ? arr[1] : ((arr[1] && arr[1].data) || []);
      _alertasState.items = alertas;
      _alertasState.dispositivos = disps;
      _alertasRender();
    });
  }
  function _alertasRender() {
    var body = document.getElementById('segAlertasBody');
    var sub  = document.getElementById('segAlertasSub');
    if (!body) return;
    var tab = _alertasState.tab;
    var disps = _alertasState.dispositivos || [];
    var lista = [];
    if (tab === 'pendientes') {
      lista = disps.filter(function(d) { return String(d.Estado || '').toUpperCase() === 'PENDIENTE_APROBACION'; });
    } else if (tab === 'suspendidos') {
      lista = disps.filter(function(d) { return String(d.Estado || '').toUpperCase() === 'SUSPENDIDO'; });
    } else {
      lista = disps.slice();
    }
    if (sub) sub.textContent = lista.length + ' · tab "' + tab + '"';
    if (lista.length === 0) {
      body.innerHTML = '<div style="text-align:center;color:#34d399;padding:30px 0;font-size:14px">✅ Nada en esta categoría</div>';
      return;
    }
    body.innerHTML = lista.map(function(d) {
      var est = String(d.Estado || '').toUpperCase();
      var chipCls = est === 'ACTIVO' ? 'seg-chip-ok'
                  : est === 'PENDIENTE_APROBACION' ? 'seg-chip-warn'
                  : est === 'SUSPENDIDO' ? 'seg-chip-error'
                  : 'seg-chip-info';
      var diasInactivo = '';
      if (d.Ultima_Conexion) {
        var ms = Date.now() - new Date(d.Ultima_Conexion).getTime();
        if (!isNaN(ms)) diasInactivo = Math.floor(ms / (24 * 60 * 60 * 1000)) + 'd';
      }
      var actions = '';
      if (est === 'PENDIENTE_APROBACION') {
        actions = ''
          + '<button class="seg-btn seg-btn-ok" onclick="SeguridadSystem._aprobar(\'' + _esc(d.ID_Dispositivo) + '\')">✓ Aprobar</button>'
          + '<button class="seg-btn seg-btn-info" onclick="SeguridadSystem._renombrar(\'' + _esc(d.ID_Dispositivo) + '\')">✏ Renombrar</button>'
          + '<button class="seg-btn seg-btn-warn" onclick="SeguridadSystem._rechazar(\'' + _esc(d.ID_Dispositivo) + '\')">✗ Rechazar</button>';
      } else if (est === 'SUSPENDIDO') {
        actions = ''
          + '<button class="seg-btn seg-btn-ok" onclick="SeguridadSystem._reactivar(\'' + _esc(d.ID_Dispositivo) + '\')">✓ Reactivar</button>'
          + '<button class="seg-btn seg-btn-warn" onclick="SeguridadSystem._desbloqueoTemp(\'' + _esc(d.ID_Dispositivo) + '\',\'' + _esc(d.Nombre_Equipo || '') + '\')">🚨 Desbloqueo temp</button>';
      } else {
        actions = ''
          + '<button class="seg-btn seg-btn-warn" onclick="SeguridadSystem._desbloqueoTemp(\'' + _esc(d.ID_Dispositivo) + '\',\'' + _esc(d.Nombre_Equipo || '') + '\')">🚨 Desbloqueo temp</button>';
      }
      return ''
        + '<div class="seg-card">'
        +   '<div class="seg-card-row">'
        +     '<div style="flex:1;min-width:0">'
        +       '<div class="seg-card-titulo">'
        +         (String(d.App || '').toUpperCase() === 'MOS' ? '🛡 ' : String(d.App || '').toUpperCase() === 'WAREHOUSEMOS' ? '💻 ' : '📱 ')
        +         _esc(d.Nombre_Equipo || 'Sin nombre')
        +         ' <span style="font-weight:400;color:#94a3b8">· ' + _esc(d.App || '') + '</span>'
        +       '</div>'
        +       '<div class="seg-card-sub">UUID: ' + _esc(String(d.ID_Dispositivo || '').substring(0, 8)) + '… · última: ' + _humanizarFecha(d.Ultima_Conexion) + (diasInactivo ? ' (' + diasInactivo + ')' : '') + '</div>'
        +     '</div>'
        +     '<span class="seg-chip ' + chipCls + '">' + est + '</span>'
        +   '</div>'
        +   '<div class="seg-card-actions">' + actions + '</div>'
        + '</div>';
    }).join('');
  }
  function _alertasCerrar() {
    var ov = document.getElementById('segAlertasOverlay');
    if (ov) { ov.style.animation = 'seg-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // Acciones admin — optimistas (feedback inmediato + fire-and-forget + rollback en error)
  var _accionEnVuelo = {};   // lock anti doble-click por deviceId+action
  function _aprobar(id) {
    var lockKey = 'aprobar_' + id;
    if (_accionEnVuelo[lockKey]) return;
    _accionEnVuelo[lockKey] = true;
    sonidos.click();
    sonidos.aprobado();
    _toast('✅ Dispositivo aprobado', { success: true });
    // Optimista: remover de la lista local inmediatamente
    _alertasState.dispositivos = (_alertasState.dispositivos || []).filter(function(d) { return String(d.ID_Dispositivo) !== String(id); });
    _alertasRender();
    // [v1.0.3 FIX] Usar Promise.prototype.finally para garantizar liberación
    // del lock aunque el .catch lance error síncrono
    // [v1.0.5 FIX] delete en vez de set false (evita acumulación de keys)
    var _libera = function() { delete _accionEnVuelo[lockKey]; };
    _api('aprobarDispositivoPendiente', { ID_Dispositivo: id, aprobadoPor: _config.usuario() })
      .then(function() { _alertasCargar(); })
      .catch(function(e) {
        try { sonidos.rechazado(); _toast('❌ ' + _esc(e.message), { error: true }); _alertasCargar(); } catch(_){}
      })
      .then(_libera, _libera);  // ambos paths liberan
  }
  function _renombrar(id) {
    _modalPrompt({
      title: 'Renombrar dispositivo',
      label: 'Nuevo nombre:',
      placeholder: 'Ej: Caja 1 · TV Almacén',
      emoji: '✏'
    }).then(function(nombre) {
      if (!nombre || !nombre.trim()) return;
      sonidos.click();
      _api('aprobarDispositivoPendiente', { ID_Dispositivo: id, Nombre_Equipo: nombre, aprobadoPor: _config.usuario() }).then(function() {
        sonidos.aprobado();
        _toast('✅ Dispositivo aprobado como "' + _esc(nombre) + '"', { success: true });
        _alertasCargar();
      }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
    });
  }
  function _rechazar(id) {
    _modalConfirm({
      title: 'Rechazar dispositivo',
      message: 'El dispositivo quedará bloqueado y no podrá acceder.',
      okLabel: 'Rechazar',
      emoji: '✗'
    }).then(function(ok) {
      if (!ok) return;
      sonidos.click();
      _api('rechazarDispositivoPendiente', { ID_Dispositivo: id }).then(function() {
        _toast('🗑 Dispositivo rechazado');
        _alertasCargar();
      }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
    });
  }
  function _reactivar(id) {
    sonidos.click();
    _api('reactivarDispositivoSuspendido', { deviceId: id }).then(function() {
      sonidos.aprobado();
      _toast('✅ Dispositivo reactivado', { success: true });
      _alertasCargar();
    }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
  }

  // ════════════════════════════════════════════════════════════
  // MODAL Desbloqueo Temporal de Emergencia
  // ════════════════════════════════════════════════════════════
  function _desbloqueoTemp(deviceId, nombre) {
    _injectCss();
    if (document.getElementById('segDesbOverlay')) return;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="seg-overlay" id="segDesbOverlay" style="z-index:99996">'
      +   '<div class="seg-modal" style="max-width:480px;border-color:rgba(248,113,113,.5)">'
      +     '<div class="seg-head" style="background:linear-gradient(135deg,rgba(248,113,113,.15),rgba(220,38,38,.05))">'
      +       '<div class="seg-emoji">🚨</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="seg-h1" style="color:#fca5a5">DESBLOQUEO TEMPORAL</div>'
      +         '<div class="seg-sub">' + _esc(nombre || String(deviceId || '').substring(0, 12)) + '</div>'
      +       '</div>'
      +     '</div>'
      +     '<div class="seg-body">'
      +       '<div style="background:rgba(248,113,113,.08);border:1px solid rgba(248,113,113,.3);border-radius:8px;padding:10px;font-size:12px;color:#fca5a5">'
      +         '⚠ Solo para emergencias (sospecha de fraude, soporte temporal, etc). Después del periodo el dispositivo VUELVE a bloquearse automáticamente.'
      +       '</div>'
      +       '<div><label style="font-size:11px;color:#94a3b8;font-weight:700">Razón:</label>'
      +       '<textarea class="seg-input" id="segDesbRazon" rows="2" placeholder="Ej: cliente reclamó, soporte tec urgente..."></textarea></div>'
      +       '<div><label style="font-size:11px;color:#94a3b8;font-weight:700">Duración:</label>'
      +       '<div style="display:flex;gap:6px;margin-top:4px">'
      +         '<button class="seg-btn seg-btn-info" onclick="SeguridadSystem._desbDur(0.5)" id="segDesbB05">30 min</button>'
      +         '<button class="seg-btn seg-btn-info" onclick="SeguridadSystem._desbDur(2)" id="segDesbB2">2 horas</button>'
      +         '<button class="seg-btn seg-btn-info" onclick="SeguridadSystem._desbDur(12)" id="segDesbB12">Hasta fin del día</button>'
      +       '</div></div>'
      +       '<div><label style="font-size:11px;color:#94a3b8;font-weight:700">Clave Admin (8 dig):</label>'
      +       '<input class="seg-input" id="segDesbClave" type="password" maxlength="8" placeholder="• • • • • • • •" style="text-align:center;letter-spacing:6px;font-family:monospace;font-size:18px"></div>'
      +     '</div>'
      +     '<div style="padding:14px 22px;border-top:1px solid #1e293b;display:flex;gap:8px">'
      +       '<button class="seg-btn seg-btn-warn" style="flex:1" onclick="SeguridadSystem._desbCerrar()">Cancelar</button>'
      +       '<button class="seg-btn seg-btn-primary" style="flex:2" onclick="SeguridadSystem._desbConfirmar(\'' + _esc(deviceId) + '\')">Confirmar desbloqueo</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    window._segDesbDuracion = 2;
    _desbDur(2);
  }
  function _desbDur(h) {
    window._segDesbDuracion = h;
    document.querySelectorAll('#segDesbOverlay .seg-btn-info, #segDesbOverlay .seg-btn-primary').forEach(function(b) {
      if (b.id && b.id.indexOf('segDesbB') === 0) {
        b.classList.remove('seg-btn-primary');
        b.classList.add('seg-btn-info');
      }
    });
    var id = h === 0.5 ? 'segDesbB05' : h === 2 ? 'segDesbB2' : 'segDesbB12';
    var b = document.getElementById(id);
    if (b) { b.classList.remove('seg-btn-info'); b.classList.add('seg-btn-primary'); }
  }
  function _desbConfirmar(deviceId) {
    var razon = (document.getElementById('segDesbRazon') || {}).value || '';
    var clave = (document.getElementById('segDesbClave') || {}).value || '';
    if (!razon.trim()) { _toast('⚠ Ingresa una razón', { error: true }); return; }
    if (!/^\d{8}$/.test(clave)) { _toast('⚠ Clave debe ser 8 dígitos', { error: true }); return; }
    sonidos.click();
    _api('desbloquearTemporalDispositivo', {
      deviceId: deviceId, claveAdmin: clave, razon: razon,
      duracionHoras: window._segDesbDuracion || 2
    }).then(function(d) {
      if (d && d.autorizado === false) {
        sonidos.rechazado();
        _toast('❌ ' + _esc(d.error || 'Clave incorrecta'), { error: true });
        return;
      }
      sonidos.aprobado();
      _toast('✅ Desbloqueo temporal hasta ' + String(d.hasta).substring(11, 16), { success: true });
      _desbCerrar();
      if (document.getElementById('segAlertasOverlay')) _alertasCargar();
    }).catch(function(e) { sonidos.rechazado(); _toast('❌ ' + _esc(e.message), { error: true }); });
  }
  function _desbCerrar() {
    var ov = document.getElementById('segDesbOverlay');
    if (ov) { ov.style.animation = 'seg-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
    // [v1.0.3 FIX] Limpiar duración global para que no contamine la próxima invocación
    try { delete window._segDesbDuracion; } catch(_) { window._segDesbDuracion = undefined; }
  }

  // ════════════════════════════════════════════════════════════
  // MODAL Solicitar Acceso (operador WH/ME)
  // ════════════════════════════════════════════════════════════
  function abrirModalSolicitarAcceso(opts) {
    opts = opts || {};
    _injectCss();
    if (document.getElementById('segSolOverlay')) return;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="seg-overlay" id="segSolOverlay">'
      +   '<div class="seg-modal" style="max-width:520px">'
      +     '<div class="seg-head">'
      +       '<div class="seg-emoji">📱</div>'
      +       '<div style="flex:1;min-width:0">'
      +         '<div class="seg-h1">DISPOSITIVO NO AUTORIZADO</div>'
      +         '<div class="seg-sub">Pide aprobación para acceder a la app</div>'
      +       '</div>'
      +     '</div>'
      +     '<div class="seg-body">'
      +       '<div class="seg-card" style="border-color:rgba(99,102,241,.4)">'
      +         '<div class="seg-card-titulo">🔓 IN-SITU (admin presente)</div>'
      +         '<div class="seg-card-sub" style="margin-bottom:8px">El admin escribe su clave 8 dig en este dispositivo.</div>'
      +         '<input class="seg-input" id="segSolClave" type="password" maxlength="8" placeholder="• • • • • • • •" style="text-align:center;letter-spacing:6px;font-family:monospace;font-size:18px;margin-bottom:8px">'
      +         '<button class="seg-btn seg-btn-primary" style="width:100%" onclick="SeguridadSystem._solInSitu()">Aprobar in-situ</button>'
      +       '</div>'
      +       '<div class="seg-card" style="border-color:rgba(251,191,36,.4)">'
      +         '<div class="seg-card-titulo">🌐 REMOTO (admin a distancia)</div>'
      +         '<div class="seg-card-sub" style="margin-bottom:8px">Le envío al admin · él aprueba desde MOS · esperas aquí hasta recibir aprobación.</div>'
      +         '<button class="seg-btn seg-btn-primary" style="width:100%;background:linear-gradient(135deg,#fbbf24,#f59e0b);border-color:#fbbf24;color:#0a1424" onclick="SeguridadSystem._solRemoto()">Enviar solicitud al admin</button>'
      +       '</div>'
      +     '</div>'
      +   '</div>'
      + '</div>');
  }
  function _solInSitu() {
    var clave = (document.getElementById('segSolClave') || {}).value || '';
    if (!/^\d{8}$/.test(clave)) { _toast('⚠ Clave debe ser 8 dígitos', { error: true }); return; }
    sonidos.click();
    // [v1.0.1 FIX] aprobarDispositivoEnSitu vive en MOS GAS. apiPost del cliente
    // debe apuntar a MOS (WH lo hace via bridge wh_; ME apunta directo a MOS).
    var apiAction = 'aprobarDispositivoEnSitu';
    var deviceId = (window.WH_CONFIG && window.WH_CONFIG.deviceId)
                || localStorage.getItem('mosexpress_deviceId')
                || localStorage.getItem('wh_device_id') || '';
    _config.apiPost(apiAction, {
      deviceId: deviceId,
      claveAdmin: clave,
      app: _config.app,
      nombreEquipo: navigator.userAgent.substring(0, 60),
      userAgent: navigator.userAgent
    }).then(function(r) {
      var d = (_config.unwrapData ? r : (r && r.data ? r.data : r));
      if (d && d.autorizado === false) {
        sonidos.rechazado();
        _toast('❌ ' + _esc(d.error || 'Clave incorrecta'), { error: true });
        return;
      }
      sonidos.aprobado();
      _toast('✅ Aprobado por ' + (d.aprobadoPor || 'admin') + '. Recargando...', { success: true });
      setTimeout(function() { window.location.reload(); }, 1800);
    }).catch(function(e) { sonidos.rechazado(); _toast('❌ ' + _esc(e.message), { error: true }); });
  }
  function _solRemoto() {
    sonidos.click();
    // El registro como PENDIENTE ya se hizo en consultarEstadoDispositivo
    // (auto-crea PENDIENTE_APROBACION cuando consulta un deviceId nuevo).
    // Acá solo cambiamos la UI a "esperando aprobación" + polling.
    document.getElementById('segSolOverlay').remove();
    _esperandoAprobacion();
  }
  function _esperandoAprobacion() {
    // [v1.0.3 FIX] Limpiar timer huérfano de invocación previa
    if (window._segEspTimer) { try { clearInterval(window._segEspTimer); } catch(_){} window._segEspTimer = null; }
    window._segEspPollingActive = false;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="seg-overlay" id="segEspOverlay">'
      +   '<div class="seg-modal" style="max-width:460px">'
      +     '<div class="seg-head">'
      +       '<div class="seg-emoji"><span class="seg-spin">◐</span></div>'
      +       '<div style="flex:1"><div class="seg-h1">ESPERANDO APROBACIÓN</div><div class="seg-sub" id="segEspSub">enviada · 0 seg</div></div>'
      +     '</div>'
      +     '<div class="seg-body">'
      +       '<div style="text-align:center;padding:20px 0">'
      +         '<div style="font-size:48px"><span class="seg-spin">◐</span></div>'
      +         '<div style="margin-top:14px;font-size:13px;color:#cbd5e1">Tu solicitud llegó al admin.</div>'
      +         '<div style="margin-top:4px;font-size:13px;color:#cbd5e1">Esperando que la apruebe.</div>'
      +         '<div style="margin-top:14px;font-size:11px;color:#64748b">Cuando te aprueben sonará un chime y entrarás automático.</div>'
      +       '</div>'
      +     '</div>'
      +     '<div style="padding:14px 22px;border-top:1px solid #1e293b">'
      +       '<button class="seg-btn seg-btn-warn" style="width:100%" onclick="SeguridadSystem._espCerrar()">Cancelar y volver</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    window._segEspInicio = Date.now();
    window._segEspTimer = setInterval(function() {
      var sec = Math.floor((Date.now() - window._segEspInicio) / 1000);
      var sub = document.getElementById('segEspSub');
      if (sub) sub.textContent = 'enviada · ' + (sec < 60 ? sec + ' seg' : Math.floor(sec / 60) + ' min ' + (sec % 60) + ' seg');
      // [v1.0.3 FIX] Anti-overlap: si polling anterior aún en vuelo, saltar tick
      if (window._segEspPollingActive) return;
      window._segEspPollingActive = true;
      // Polling: chequear estado del dispositivo (consultarEstadoDispositivo
      // existe en WH y MOS; apiPost del cliente lo resuelve al GAS correcto)
      var apiAction = 'consultarEstadoDispositivo';
      var deviceId = (window.WH_CONFIG && window.WH_CONFIG.deviceId)
                  || localStorage.getItem('mosexpress_deviceId')
                  || localStorage.getItem('wh_device_id') || '';
      _config.apiPost(apiAction, { ID_Dispositivo: deviceId, deviceId: deviceId }).then(function(r) {
        var d = (_config.unwrapData ? r : (r && r.data ? r.data : r));
        if (d && String(d.estado).toUpperCase() === 'ACTIVO') {
          clearInterval(window._segEspTimer);
          window._segEspTimer = null;
          sonidos.aprobado();
          var sub2 = document.getElementById('segEspOverlay');
          if (sub2) sub2.innerHTML = ''
            + '<div class="seg-modal" style="max-width:460px;text-align:center;padding:40px">'
            +   '<div style="font-size:72px">🎉</div>'
            +   '<div style="font-size:18px;font-weight:900;color:#34d399;margin-top:10px">¡APROBADO!</div>'
            +   '<div style="font-size:12px;color:#cbd5e1;margin-top:10px">Iniciando aplicación…</div>'
            + '</div>';
          setTimeout(function() { window.location.reload(); }, 2000);
        }
      }).catch(function() {})
        .then(function() { window._segEspPollingActive = false; });
    }, 3000);
  }
  function _espCerrar() {
    if (window._segEspTimer) clearInterval(window._segEspTimer);
    var ov = document.getElementById('segEspOverlay');
    if (ov) ov.remove();
  }

  // ════════════════════════════════════════════════════════════
  // WIDGET "Mi horario" en dashboard WH
  // ════════════════════════════════════════════════════════════
  var _widgetTimer = null;
  var _widgetCierreHoy = null;  // "HH:MM" string
  var _widgetAlertas30 = false;
  var _widgetAlertas5 = false;
  var _widgetUltimoDia = null;  // [v1.0.1 FIX] YYYY-MM-DD para resetear alertas al cambiar de día

  function arrancarWidgetMiHorario(containerId) {
    _injectCss();
    var refresh = function() {
      _api('verificarHorario', { idPersonal: _config.idPersonal(), rol: _config.rol() }).then(function(d) {
        if (!d || !d.permitido) { _widgetCierreHoy = null; _widgetRender(containerId); return; }
        _widgetCierreHoy = d.cierre || null;
        _widgetRender(containerId);
      }).catch(function() {});
    };
    refresh();
    if (_widgetTimer) clearInterval(_widgetTimer);
    _widgetTimer = setInterval(function() { _widgetRender(containerId); }, 60000);
  }
  function _widgetRender(containerId) {
    var cont = document.getElementById(containerId);
    if (!cont) return;
    if (!_widgetCierreHoy) {
      cont.innerHTML = '<div class="seg-widget"><span class="seg-widget-icono">🕐</span><div class="seg-widget-text"><span class="seg-widget-titulo">Sin horario</span><span class="seg-widget-tiempo">—</span></div></div>';
      return;
    }
    var partes = String(_widgetCierreHoy).split(':');
    var hh = parseInt(partes[0]) || 0;
    var mm = parseInt(partes[1]) || 0;
    var ahora = new Date();
    // [v1.0.1 FIX] Resetear flags de alerta si cambió el día calendario
    // [v1.0.4 FIX] padStart para consistencia ('2026-6-3' vs '2026-06-03')
    var hoyKey = ahora.getFullYear() + '-'
               + String(ahora.getMonth() + 1).padStart(2, '0') + '-'
               + String(ahora.getDate()).padStart(2, '0');
    if (_widgetUltimoDia !== hoyKey) {
      _widgetAlertas30 = false;
      _widgetAlertas5 = false;
      _widgetUltimoDia = hoyKey;
    }
    var cierreFecha = new Date();
    cierreFecha.setHours(hh, mm, 0, 0);
    // [v1.0.2 FIX] Si el cierre es ANTES que ahora (cruza medianoche),
    // sumar 1 día al cierre (turno noche 14:00-02:00, son las 23:00 → cierre mañana 02:00)
    if (cierreFecha.getTime() < ahora.getTime() && hh < 12) {
      cierreFecha.setDate(cierreFecha.getDate() + 1);
    }
    var diff = (cierreFecha.getTime() - ahora.getTime()) / 60000;  // min
    if (diff <= 0) {
      cont.innerHTML = '<div class="seg-widget urgente" onclick="SeguridadSystem.abrirModalHorarioOperador()"><span class="seg-widget-icono">🌙</span><div class="seg-widget-text"><span class="seg-widget-titulo">Fuera de horario</span><span class="seg-widget-tiempo">Cerrado</span></div></div>';
      return;
    }
    var horasRest = Math.floor(diff / 60);
    var minRest   = Math.floor(diff % 60);
    var texto = horasRest > 0 ? (horasRest + 'h ' + minRest + 'm') : (minRest + ' min');
    var urgente = diff < 30;
    // [v1.0.3 FIX] Alertas con umbral: dispara una vez al ENTRAR a la ventana.
    // Antes era ventana 1 min (29 < diff < 31), que con polling 60s podía saltarse.
    if (diff <= 30 && !_widgetAlertas30) {
      _widgetAlertas30 = true;
      _toast('⚠ Quedan ' + Math.ceil(diff) + ' min para cerrar tu jornada', { error: true });
      sonidos.warning();
    }
    if (diff <= 5 && !_widgetAlertas5) {
      _widgetAlertas5 = true;
      _toast('🚨 Quedan ' + Math.ceil(diff) + ' min para cerrar tu jornada', { error: true, duracion: 8000 });
      sonidos.urgente();
    }
    cont.innerHTML = ''
      + '<div class="seg-widget' + (urgente ? ' urgente' : '') + '" onclick="SeguridadSystem.abrirModalHorarioOperador()">'
      +   '<span class="seg-widget-icono">' + (urgente ? '⚠' : '🕐') + '</span>'
      +   '<div class="seg-widget-text">'
      +     '<span class="seg-widget-titulo">' + (urgente ? 'CIERRE PRÓXIMO' : 'Tu jornada') + '</span>'
      +     '<span class="seg-widget-tiempo">' + texto + '</span>'
      +   '</div>'
      + '</div>';
  }

  function abrirModalHorarioOperador() {
    _injectCss();
    if (document.getElementById('segHorOverlay')) return;
    _api('verificarHorario', { idPersonal: _config.idPersonal(), rol: _config.rol() }).then(function(d) {
      var permitido = d && d.permitido;
      var apertura = d && d.apertura || '—';
      var cierre   = d && d.cierre || '—';
      var fuente   = d && d.fuente || 'app';
      document.body.insertAdjacentHTML('beforeend', ''
        + '<div class="seg-overlay" id="segHorOverlay">'
        +   '<div class="seg-modal" style="max-width:440px">'
        +     '<div class="seg-head">'
        +       '<div class="seg-emoji">🕐</div>'
        +       '<div style="flex:1"><div class="seg-h1">TU HORARIO</div><div class="seg-sub">' + (fuente === 'custom' ? 'Horario personalizado' : 'Horario general de la app') + '</div></div>'
        +     '</div>'
        +     '<div class="seg-body" style="text-align:center">'
        +       '<div style="font-size:13px;color:#94a3b8">Hoy</div>'
        +       '<div style="font-size:32px;font-weight:900;color:#fbbf24;font-family:Consolas,monospace;margin:8px 0">' + apertura + ' — ' + cierre + '</div>'
        +       (permitido ? '<div class="seg-chip seg-chip-ok">🟢 Estás en horario</div>' : '<div class="seg-chip seg-chip-error">🔴 Fuera de horario</div>')
        +     '</div>'
        +     '<div style="padding:14px 22px;border-top:1px solid #1e293b">'
        +       '<button class="seg-btn seg-btn-warn" style="width:100%" onclick="SeguridadSystem._horCerrar()">Cerrar</button>'
        +     '</div>'
        +   '</div>'
        + '</div>');
    });
  }
  function _horCerrar() {
    var ov = document.getElementById('segHorOverlay');
    if (ov) { ov.style.animation = 'seg-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // ════════════════════════════════════════════════════════════
  // MODAL Fuera de horario + solicitar extensión + notif al abrir
  // ════════════════════════════════════════════════════════════
  function abrirModalFueraHorario(motivo, apertura, cierre) {
    _injectCss();
    if (document.getElementById('segFueraOverlay')) return;
    var msg = motivo === 'antes_apertura'
      ? 'Podés acceder a partir de ' + (apertura || '—')
      : motivo === 'despues_cierre'
      ? 'Tu jornada cerró a las ' + (cierre || '—')
      : motivo === 'dia_cerrado'
      ? 'Hoy no es día laboral'
      : 'No tienes permiso ahora';
    sonidos.rechazado();
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="seg-overlay" id="segFueraOverlay">'
      +   '<div class="seg-modal" style="max-width:480px">'
      +     '<div class="seg-head" style="background:linear-gradient(135deg,rgba(148,163,184,.15),rgba(99,102,241,.05))">'
      +       '<div class="seg-emoji">🌙</div>'
      +       '<div style="flex:1"><div class="seg-h1">FUERA DE HORARIO</div><div class="seg-sub">' + _esc(msg) + '</div></div>'
      +     '</div>'
      +     '<div class="seg-body">'
      +       '<div style="text-align:center;font-size:11px;color:#64748b;padding:8px 0">'
      +         'Tu horario: <b style="color:#fbbf24">' + (apertura || '—') + ' a ' + (cierre || '—') + '</b>'
      +       '</div>'
      +       '<button class="seg-btn seg-btn-primary" style="width:100%" onclick="SeguridadSystem._fueraSolicitarExtension()">⏰ Solicitar extensión al admin</button>'
      +       '<button class="seg-btn seg-btn-info" style="width:100%" onclick="SeguridadSystem._fueraNotificarme(\'' + _esc(apertura || '') + '\')">🔔 Notificarme cuando abra</button>'
      +     '</div>'
      +     '<div style="padding:14px 22px;border-top:1px solid #1e293b">'
      +       '<button class="seg-btn seg-btn-warn" style="width:100%" onclick="SeguridadSystem._fueraCerrar()">Cerrar y volver</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
  }
  function _fueraSolicitarExtension() {
    _modalPrompt({
      title: 'Solicitar extensión',
      label: '¿Cuántos minutos extra necesitas?',
      default: '60',
      type: 'number',
      emoji: '⏰'
    }).then(function(minRaw) {
      if (!minRaw) return;
      var min = parseInt(minRaw) || 0;
      if (min <= 0 || min > 240) { _toast('⚠ Entre 1 y 240 min', { error: true }); return; }
      _modalPrompt({
        title: 'Motivo',
        label: 'Explícale al admin por qué necesitas la extensión:',
        placeholder: 'Ej: cliente importante, inventario...',
        emoji: '📝'
      }).then(function(motivo) {
        if (!motivo || !motivo.trim()) { _toast('⚠ Ingresa un motivo', { error: true }); return; }
        sonidos.click();
        _api('solicitarExtensionHorario', { idPersonal: _config.idPersonal(), minutos: min, motivo: motivo }).then(function() {
          _toast('✅ Solicitud enviada al admin', { success: true });
          _fueraCerrar();
        }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
      });
    });
  }
  function _fueraNotificarme(apertura) {
    sonidos.click();
    _api('notificarmeCuandoAbra', { idPersonal: _config.idPersonal(), apertura: apertura }).then(function() {
      _toast('🔔 Te avisaremos cuando abra', { success: true });
    }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
  }
  function _fueraCerrar() {
    var ov = document.getElementById('segFueraOverlay');
    if (ov) { ov.style.animation = 'seg-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // ════════════════════════════════════════════════════════════
  // MODAL Configurar Horarios (admin MOS) — 3 tabs
  // ════════════════════════════════════════════════════════════
  var _cfgState = { tab: 'porApp', horarios: null, excepciones: [] };
  var APPS_CONOCIDAS = [
    { key: 'mosExpress',   label: '🛒 MosExpress' },
    { key: 'warehouseMos', label: '📦 Warehouse' },
    { key: 'MOS',          label: '🛡 MOS' }
  ];
  var DIAS = [
    { k: 'lun', label: 'Lun' }, { k: 'mar', label: 'Mar' }, { k: 'mie', label: 'Mié' },
    { k: 'jue', label: 'Jue' }, { k: 'vie', label: 'Vie' }, { k: 'sab', label: 'Sáb' },
    { k: 'dom', label: 'Dom' }
  ];

  function abrirModalConfigHorarios() {
    _injectCss();
    if (document.getElementById('segCfgOverlay')) return;
    document.body.insertAdjacentHTML('beforeend', ''
      + '<div class="seg-overlay" id="segCfgOverlay">'
      +   '<div class="seg-modal" style="max-width:760px">'
      +     '<div class="seg-head">'
      +       '<div class="seg-emoji">🕐</div>'
      +       '<div style="flex:1"><div class="seg-h1">CONFIGURAR HORARIOS</div><div class="seg-sub">por app · excepciones · extender hoy</div></div>'
      +     '</div>'
      +     '<div class="seg-tabs">'
      +       '<button class="seg-tab active" id="segCfgTabApp" onclick="SeguridadSystem._cfgTab(\'porApp\')">Por App</button>'
      +       '<button class="seg-tab"        id="segCfgTabExc" onclick="SeguridadSystem._cfgTab(\'excepciones\')">Excepciones</button>'
      +       '<button class="seg-tab"        id="segCfgTabHoy" onclick="SeguridadSystem._cfgTab(\'extenderHoy\')">Extender HOY</button>'
      +     '</div>'
      +     '<div class="seg-body" id="segCfgBody">'
      +       '<div style="text-align:center;color:#94a3b8;padding:30px"><span class="seg-spin">◐</span> cargando…</div>'
      +     '</div>'
      +     '<div style="padding:14px 22px;border-top:1px solid #1e293b">'
      +       '<button class="seg-btn seg-btn-warn" style="width:100%" onclick="SeguridadSystem._cfgCerrar()">Cerrar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>');
    _cfgCargar();
  }
  function _cfgTab(tab) {
    _cfgState.tab = tab;
    ['segCfgTabApp', 'segCfgTabExc', 'segCfgTabHoy'].forEach(function(id) {
      var b = document.getElementById(id); if (b) b.classList.remove('active');
    });
    var btnId = { porApp: 'segCfgTabApp', excepciones: 'segCfgTabExc', extenderHoy: 'segCfgTabHoy' }[tab];
    var btn = document.getElementById(btnId);
    if (btn) btn.classList.add('active');
    _cfgRender();
  }
  function _cfgCargar() {
    var body = document.getElementById('segCfgBody');
    if (!body) return;
    body.innerHTML = '<div style="text-align:center;color:#94a3b8;padding:30px"><span class="seg-spin">◐</span> cargando…</div>';
    Promise.all([
      _api('getHorariosApps', {}).catch(function() { return {}; }),
      _api('getPersonalConHorarioCustom', {}).catch(function() { return []; })
    ]).then(function(arr) {
      _cfgState.horarios = arr[0] || {};
      _cfgState.excepciones = Array.isArray(arr[1]) ? arr[1] : ((arr[1] && arr[1].data) || []);
      _cfgRender();
    }).catch(function(e) {
      body.innerHTML = '<div style="color:#f87171;padding:20px;text-align:center">❌ ' + _esc(e.message) + '</div>';
    });
  }
  function _cfgRender() {
    var body = document.getElementById('segCfgBody');
    if (!body) return;
    if (_cfgState.tab === 'porApp')           body.innerHTML = _cfgRenderApps();
    else if (_cfgState.tab === 'excepciones') body.innerHTML = _cfgRenderExcepciones();
    else                                      body.innerHTML = _cfgRenderExtenderHoy();
  }
  function _cfgRenderApps() {
    var html = '<div style="font-size:11px;color:#64748b;margin-bottom:6px">Horario global aplicado a TODOS los usuarios de cada app (salvo excepciones).</div>';
    APPS_CONOCIDAS.forEach(function(app) {
      var h = (_cfgState.horarios && _cfgState.horarios[app.key]) || {};
      var dias = h.dias || {};
      html += ''
        + '<div class="seg-card">'
        +   '<div class="seg-card-titulo">' + app.label + '</div>'
        +   '<div style="display:grid;grid-template-columns:repeat(7,1fr);gap:4px;margin-top:8px">'
        +   DIAS.map(function(d) {
              var v = dias[d.k] || {};
              var act = v.activo !== false;
              return ''
                + '<div style="text-align:center">'
                +   '<div style="font-size:10px;color:#94a3b8">' + d.label + '</div>'
                +   '<input type="checkbox" ' + (act ? 'checked' : '') + ' id="seg_' + app.key + '_' + d.k + '_act" style="margin:4px 0">'
                +   '<input class="seg-input" type="time" value="' + (v.apertura || '07:00') + '" id="seg_' + app.key + '_' + d.k + '_ap" style="padding:3px;font-size:10px;margin-bottom:2px">'
                +   '<input class="seg-input" type="time" value="' + (v.cierre   || '19:00') + '" id="seg_' + app.key + '_' + d.k + '_ci" style="padding:3px;font-size:10px">'
                + '</div>';
            }).join('')
        +   '</div>'
        +   '<button class="seg-btn seg-btn-primary" style="width:100%;margin-top:10px" onclick="SeguridadSystem._cfgGuardarApp(\'' + app.key + '\')">Guardar ' + _esc(app.label) + '</button>'
        + '</div>';
    });
    return html;
  }
  function _cfgGuardarApp(appKey) {
    sonidos.click();
    var dias = {};
    DIAS.forEach(function(d) {
      dias[d.k] = {
        activo: !!(document.getElementById('seg_' + appKey + '_' + d.k + '_act') || {}).checked,
        apertura: (document.getElementById('seg_' + appKey + '_' + d.k + '_ap') || {}).value || '07:00',
        cierre:   (document.getElementById('seg_' + appKey + '_' + d.k + '_ci') || {}).value || '19:00'
      };
    });
    _api('setHorarioApp', { app: appKey, dias: dias }).then(function() {
      sonidos.aprobado();
      _toast('✅ Horario guardado para ' + appKey, { success: true });
      _cfgCargar();
    }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
  }
  function _cfgRenderExcepciones() {
    var html = '<div style="font-size:11px;color:#64748b;margin-bottom:8px">Excepciones por usuario (típico WH: turno noche, envasador 14-23h).</div>';
    if (!_cfgState.excepciones.length) {
      html += '<div style="text-align:center;color:#94a3b8;padding:14px">— Sin excepciones configuradas —</div>';
    } else {
      _cfgState.excepciones.forEach(function(p) {
        var hc = {};
        try { hc = typeof p.horarioCustom === 'string' ? JSON.parse(p.horarioCustom) : (p.horarioCustom || {}); } catch(_) {}
        var activo = hc.activo !== false;
        html += ''
          + '<div class="seg-card">'
          +   '<div class="seg-card-row">'
          +     '<div style="flex:1">'
          +       '<div class="seg-card-titulo">' + _esc(p.nombre || p.idPersonal) + '</div>'
          +       '<div class="seg-card-sub">' + _esc(p.rol || '—') + ' · ' + _esc(hc.motivo || 'sin motivo') + '</div>'
          +     '</div>'
          +     '<span class="seg-chip ' + (activo ? 'seg-chip-ok' : 'seg-chip-info') + '">' + (activo ? 'ACTIVO' : 'INACTIVO') + '</span>'
          +   '</div>'
          +   '<div class="seg-card-actions">'
          +     '<button class="seg-btn seg-btn-info" onclick="SeguridadSystem._cfgEditExc(\'' + _esc(p.idPersonal) + '\')">✏ Editar</button>'
          +     '<button class="seg-btn seg-btn-warn" onclick="SeguridadSystem._cfgQuitarExc(\'' + _esc(p.idPersonal) + '\')">🗑 Quitar</button>'
          +   '</div>'
          + '</div>';
      });
    }
    html += '<button class="seg-btn seg-btn-primary" style="width:100%;margin-top:10px" onclick="SeguridadSystem._cfgNuevaExc()">+ Nueva excepción</button>';
    return html;
  }
  function _cfgNuevaExc() {
    _modalPrompt({
      title: 'Nueva excepción',
      label: 'idPersonal del usuario:',
      placeholder: 'Ej: P001 · P012',
      emoji: '➕'
    }).then(function(idP) {
      if (!idP || !idP.trim()) return;
      _cfgEditExc(idP.trim());
    });
  }
  function _cfgEditExc(idPersonal) {
    sonidos.click();
    var p = _cfgState.excepciones.find(function(x) { return x.idPersonal === idPersonal; }) || {};
    var hc = {};
    try { hc = typeof p.horarioCustom === 'string' ? JSON.parse(p.horarioCustom) : (p.horarioCustom || {}); } catch(_) {}
    _modalPrompt({
      title: 'Motivo',
      label: '¿Por qué este usuario tiene horario distinto?',
      default: hc.motivo || 'turno noche',
      placeholder: 'Ej: envasador turno noche',
      emoji: '📝'
    }).then(function(motivo) {
      if (motivo === null) return;
      _modalPrompt({
        title: 'Apertura',
        label: 'Hora de apertura (HH:MM):',
        default: (hc.dias && hc.dias.lun && hc.dias.lun.apertura) || '14:00',
        type: 'time',
        emoji: '🌅'
      }).then(function(ap) {
        if (!ap) return;
        _modalPrompt({
          title: 'Cierre',
          label: 'Hora de cierre (HH:MM):',
          default: (hc.dias && hc.dias.lun && hc.dias.lun.cierre) || '23:00',
          type: 'time',
          emoji: '🌙'
        }).then(function(ci) {
          if (!ci) return;
          var dias = {};
          DIAS.forEach(function(d) {
            dias[d.k] = { activo: d.k !== 'dom', apertura: ap, cierre: ci };
          });
          _api('setHorarioCustomPersonal', {
            idPersonal: idPersonal,
            horarioCustom: { activo: true, dias: dias, motivo: motivo, ts: new Date().toISOString() }
          }).then(function() {
            sonidos.aprobado();
            _toast('✅ Excepción guardada', { success: true });
            _cfgCargar();
          }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
        });
      });
    });
  }
  function _cfgQuitarExc(idPersonal) {
    _modalConfirm({
      title: 'Quitar excepción',
      message: 'El usuario volverá al horario general de la app.',
      okLabel: 'Quitar',
      emoji: '🗑'
    }).then(function(ok) {
      if (!ok) return;
      sonidos.click();
      _api('setHorarioCustomPersonal', { idPersonal: idPersonal, horarioCustom: { activo: false } }).then(function() {
        _toast('🗑 Excepción quitada');
        _cfgCargar();
      }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
    });
  }
  function _cfgRenderExtenderHoy() {
    return ''
      + '<div style="font-size:11px;color:#64748b;margin-bottom:8px">Empuja el cierre del horario SOLO para hoy. A las 00:00 vuelve a lo normal.</div>'
      + '<div class="seg-card">'
      +   '<div class="seg-card-titulo">Extender cierre de hoy</div>'
      +   '<div style="margin-top:10px"><label style="font-size:11px;color:#94a3b8">App:</label>'
      +     '<select class="seg-input" id="segExtApp">'
      +       APPS_CONOCIDAS.map(function(a) { return '<option value="' + a.key + '">' + a.label + '</option>'; }).join('')
      +     '</select></div>'
      +   '<div style="margin-top:8px"><label style="font-size:11px;color:#94a3b8">Nuevo cierre (HH:MM):</label>'
      +     '<input class="seg-input" type="time" id="segExtCierre" value="23:00"></div>'
      +   '<div style="margin-top:8px"><label style="font-size:11px;color:#94a3b8">Razón:</label>'
      +     '<input class="seg-input" type="text" id="segExtRazon" placeholder="Inventario, evento..."></div>'
      +   '<button class="seg-btn seg-btn-primary" style="width:100%;margin-top:10px" onclick="SeguridadSystem._cfgExtenderHoy()">Aplicar extensión HOY</button>'
      + '</div>';
  }
  function _cfgExtenderHoy() {
    var app    = (document.getElementById('segExtApp')    || {}).value || 'warehouseMos';
    var cierre = (document.getElementById('segExtCierre') || {}).value || '';
    var razon  = (document.getElementById('segExtRazon')  || {}).value || '';
    if (!/^\d{2}:\d{2}$/.test(cierre)) { _toast('⚠ Cierre inválido', { error: true }); return; }
    if (!razon.trim()) { _toast('⚠ Ingresa una razón', { error: true }); return; }
    sonidos.click();
    _api('extenderHorarioHoy', { app: app, cierre: cierre, razon: razon }).then(function() {
      sonidos.aprobado();
      _toast('✅ Cierre extendido hoy hasta ' + cierre, { success: true });
    }).catch(function(e) { _toast('❌ ' + _esc(e.message), { error: true }); });
  }
  function _cfgCerrar() {
    var ov = document.getElementById('segCfgOverlay');
    if (ov) { ov.style.animation = 'seg-out .22s ease-out forwards'; setTimeout(function(){ ov.remove(); }, 220); }
  }

  // ── INICIAR ────────────────────────────────────────────────
  function iniciar(config) {
    if (config) {
      Object.keys(config).forEach(function(k) { _config[k] = config[k]; });
    }
    _injectCss();
  }

  // ── EXPORT ─────────────────────────────────────────────────
  window.SeguridadSystem = {
    __loaded:                 true,
    iniciar:                  iniciar,
    arrancarBadgeAlertas:     arrancarBadgeAlertas,
    abrirModalAlertas:        abrirModalAlertas,
    abrirModalSolicitarAcceso: abrirModalSolicitarAcceso,
    abrirModalFueraHorario:   abrirModalFueraHorario,
    abrirModalHorarioOperador: abrirModalHorarioOperador,
    abrirModalConfigHorarios: abrirModalConfigHorarios,
    arrancarWidgetMiHorario:  arrancarWidgetMiHorario,
    sonidos:                  sonidos,
    toast:                    _toast,
    // Internals
    _alertasTab:           _alertasTab,
    _alertasCerrar:        _alertasCerrar,
    _aprobar:              _aprobar,
    _renombrar:            _renombrar,
    _rechazar:             _rechazar,
    _reactivar:            _reactivar,
    _desbloqueoTemp:       _desbloqueoTemp,
    _desbDur:              _desbDur,
    _desbConfirmar:        _desbConfirmar,
    _desbCerrar:           _desbCerrar,
    _solInSitu:            _solInSitu,
    _solRemoto:            _solRemoto,
    _espCerrar:            _espCerrar,
    _horCerrar:            _horCerrar,
    _fueraSolicitarExtension: _fueraSolicitarExtension,
    _fueraNotificarme:     _fueraNotificarme,
    _fueraCerrar:          _fueraCerrar,
    _cfgTab:               _cfgTab,
    _cfgCerrar:            _cfgCerrar,
    _cfgGuardarApp:        _cfgGuardarApp,
    _cfgEditExc:           _cfgEditExc,
    _cfgQuitarExc:         _cfgQuitarExc,
    _cfgNuevaExc:          _cfgNuevaExc,
    _cfgExtenderHoy:       _cfgExtenderHoy
  };
})();
