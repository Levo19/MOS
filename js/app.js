// MOS Admin — app.js
// Full app logic: navigation, views, charts, CRUD

const MOS = (() => {
  // ── STATE ────────────────────────────────────────────────────
  const SESSION_KEY = 'MOS_SESSION';
  let S = {
    view: 'dashboard',
    catTab: 'base',
    almTab: 'stock',
    provSelId: null,
    productos: [],
    proveedores: [],
    stock: [],
    mermas: [],
    vencimientos: { criticos: [], alertas: [] },
    envasados: [],
    alertas: [],
    charts: {},
    loaded: {},
    session: null,
    equivMap: {},
    _editingPrecioId: null,
    _ecoData: null,
    pnPendientes: [],
    categorias: []
  };

  function _getSession()      { try { return JSON.parse(localStorage.getItem(SESSION_KEY)); } catch { return null; } }
  function _saveSession(s)    { localStorage.setItem(SESSION_KEY, JSON.stringify(s)); }
  function _clearSession()    { localStorage.removeItem(SESSION_KEY); }

  // ── AUDIT CONTEXT — quién/cuándo/dónde para auditoría ──────────
  function _getOrCreateDeviceId() {
    let id = localStorage.getItem('mos_deviceId');
    if (!id) {
      id = (crypto && crypto.randomUUID) ? crypto.randomUUID()
         : 'DEV-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
      localStorage.setItem('mos_deviceId', id);
    }
    return id;
  }
  function _generaIdSesion() {
    return 'SES-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
  }
  // Exposición global para que api.js pueda leer el contexto en cada POST
  window.__MOS_AUDIT = window.__MOS_AUDIT || {
    app:           'MOS',
    idDispositivo: _getOrCreateDeviceId(),
    idSesion:      null,    // se setea al login
    usuario:       null,
    idPersonal:    null,
    rol:           null,
    userAgent:     (navigator.userAgent || '').slice(0, 200)
  };
  function _refreshAuditCtx() {
    const a = window.__MOS_AUDIT;
    a.usuario    = S.session?.nombre || null;
    a.idPersonal = S.session?.idPersonal || null;
    a.rol        = S.session?.rol || null;
    a.idSesion   = S.session?.idSesion || a.idSesion || null;
    a.url        = (window.location && window.location.hash) || '';
  }

  // ── HELPERS ─────────────────────────────────────────────────
  const $  = id => document.getElementById(id);
  const fmtMoney = v => 'S/. ' + parseFloat(v || 0).toFixed(2);
  const fmtDate  = v => v ? String(v).substring(0, 10) : '—';
  const today    = () => { const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0'); };

  function toast(msg, type = 'info') {
    const el = $('toast');
    el.textContent = msg;
    el.style.background = type === 'error' ? '#450a0a' : type === 'ok' ? '#052e16' : '#1e293b';
    el.style.borderColor = type === 'error' ? '#7f1d1d' : type === 'ok' ? '#14532d' : '#334155';
    el.style.color        = type === 'error' ? '#fca5a5' : type === 'ok' ? '#86efac'  : '#e2e8f0';
    el.classList.remove('hide');
    clearTimeout(el._t);
    el._t = setTimeout(() => el.classList.add('hide'), type === 'error' ? 10000 : 3500);
  }

  function setStatus(connected) {
    const dot   = $('statusDot');
    const label = $('statusLabel');
    const dotM  = $('statusDotMob');
    const cls   = connected ? 'dot-green' : 'dot-gray';
    if (dot)   { dot.className = cls; }
    if (dotM)  { dotM.className = cls; }
    if (label) { label.textContent = connected ? 'Conectado' : 'Sin configurar'; }
  }

  function renderChart(id, config) {
    const canvas = $(id);
    if (!canvas) return;
    if (S.charts[id]) S.charts[id].destroy();
    S.charts[id] = new Chart(canvas, config);
  }

  // ── NAVIGATION ──────────────────────────────────────────────
  function nav(viewName) {
    if (S.view === viewName) return;

    document.querySelectorAll('.view').forEach(v => {
      v.classList.remove('active');
      v.classList.add('hidden');
    });
    const tgt = $('view-' + viewName);
    if (tgt) { tgt.classList.remove('hidden'); tgt.classList.add('active'); }

    // Sidebar items
    document.querySelectorAll('#sidebar .nav-item').forEach(b =>
      b.classList.toggle('active', b.dataset.view === viewName));

    // Bottom nav
    document.querySelectorAll('#bottomnav .bnav-btn').forEach(b =>
      b.classList.toggle('active', b.dataset.view === viewName));

    const titles = { dashboard:'Dashboard', catalogo:'Catálogo', almacen:'Almacén', proveedores:'Proveedores', cajas:'Cajas', finanzas:'Finanzas', config:'Configuración' };
    const t = titles[viewName] || viewName;
    const pt = $('pageTitle'); if (pt) pt.textContent = t;
    const ptd = $('pageTitleDesktop'); if (ptd) ptd.textContent = t;

    // FAB visibility
    const fab = $('fab');
    if (fab) fab.classList.toggle('visible', viewName === 'proveedores');

    // Config: show first panel
    if (viewName === 'config') {
      setCfgTab(S.cfgTab || 'zonas');
    }

    S.view = viewName;
    if (!S.loaded[viewName]) loadView(viewName);
  }

  function fabAction() {
    if (S.view === 'catalogo')    abrirModalProducto(null);
    if (S.view === 'proveedores') abrirModalProveedor(null);
  }

  // ── INIT ────────────────────────────────────────────────────
  function init() {
    Chart.defaults.color = '#64748b';
    Chart.defaults.borderColor = '#1e293b';
    Chart.defaults.font.family = 'system-ui, -apple-system, sans-serif';

    setStatus(true);

    // Set today on date inputs
    const pf = $('pagoFecha'); if (pf) pf.value = today();

    // Búsqueda catálogo: expandir al focus, contraer al blur si está vacío
    const searchInp = $('searchCatalogo');
    if (searchInp) {
      const toolbar = searchInp.closest('.cat-toolbar');
      if (toolbar) {
        searchInp.addEventListener('focus', () => toolbar.classList.add('search-active'));
        searchInp.addEventListener('blur',  () => { if (!searchInp.value) toolbar.classList.remove('search-active'); });
      }
    }

    // Session check
    const saved = _getSession();
    if (saved && saved.idPersonal && saved.nombre) {
      // Si es sesión vieja sin idSesion, generar uno
      if (!saved.idSesion) { saved.idSesion = _generaIdSesion(); _saveSession(saved); }
      S.session = saved;
      _applySession();
      _refreshAuditCtx();
      const overlay = $('loginOverlay');
      if (overlay) overlay.classList.add('hidden');
      nav('dashboard');
      loadView('dashboard');
    } else {
      _showLogin();
    }
  }

  // ── LOGIN / LOCK ─────────────────────────────────────────────
  let _loginPersonal   = [];
  let _loginSelectedId = null;
  let _pinValue        = '';
  let _pinMode         = 'login'; // 'login' | 'lock'
  let _pinChecking     = false;   // bloqueo durante validación
  const _PIN_MAX       = 4;       // 4 dígitos exactos

  // ── Numpad ───────────────────────────────────────────────────
  function _np(key) {
    if (_pinChecking) return;     // evitar input durante validación
    if (key === 'del') {
      _pinValue = _pinValue.slice(0, -1);
      _updatePinDots();
    } else if (key === 'ok') {
      // Compatibilidad: si manualmente presionan ✓ con 4 dígitos
      if (_pinValue.length === _PIN_MAX) confirmarPin();
    } else {
      if (_pinValue.length >= _PIN_MAX) return;
      _pinValue += key;
      _updatePinDots();
      // Auto-validar al cuarto dígito
      if (_pinValue.length === _PIN_MAX) {
        _pinChecking = true;
        setTimeout(() => { confirmarPin(); }, 100);
      }
    }
  }

  function _updatePinDots(opts) {
    const isLock = _pinMode === 'lock';
    const id = isLock ? 'lockPinDots' : 'loginPinDots';
    const el = $(id); if (!el) return;
    const errorMode = opts && opts.error;
    el.innerHTML = Array.from({ length: _PIN_MAX }, (_, i) => {
      let cls = 'pin-dot';
      if (i < _pinValue.length) cls += errorMode ? ' filled error' : (isLock ? ' filled lock' : ' filled');
      return `<div class="${cls}"></div>`;
    }).join('');
  }

  function _pinErrorAnim() {
    const id = _pinMode === 'lock' ? 'lockPinDots' : 'loginPinDots';
    const el = $(id); if (!el) return;
    _updatePinDots({ error: true });
    el.classList.remove('shake');
    void el.offsetWidth;          // force reflow
    el.classList.add('shake');
    if (navigator.vibrate) { try { navigator.vibrate([80, 60, 80]); } catch {} }
    setTimeout(() => {
      _pinValue = '';
      _updatePinDots();
      el.classList.remove('shake');
      _pinChecking = false;
    }, 480);
  }

  // Keyboard support (desktop)
  document.addEventListener('keydown', e => {
    const overlay = $('loginOverlay');
    if (!overlay || overlay.classList.contains('hidden')) return;
    if (_pinMode === 'login' && $('loginStep1') && !$('loginStep1').classList.contains('hidden')) return;
    if (e.key >= '0' && e.key <= '9') _np(e.key);
    else if (e.key === 'Backspace') _np('del');
    else if (e.key === 'Enter') _np('ok');
  });

  async function _showLogin() {
    _pinValue = '';
    const overlay = $('loginOverlay');
    if (overlay) overlay.classList.remove('hidden');

    if (S.session && S.session.idPersonal) {
      // Mostrar pantalla de bloqueo
      _pinMode = 'lock';
      $('scLogin')?.classList.add('hidden');
      $('scLock')?.classList.remove('hidden');
      const ini = (S.session.nombre || '?')[0].toUpperCase();
      const av = $('lockUserAvatar');
      if (av) { av.textContent = ini; av.style.background = S.session.color || '#6366f1'; }
      const nm = $('lockUserName'); if (nm) nm.textContent = S.session.nombre;
      const err = $('lockPinError'); if (err) err.textContent = '';
      _updatePinDots();
    } else {
      // Mostrar pantalla de login
      _pinMode = 'login';
      $('scLogin')?.classList.remove('hidden');
      $('scLock')?.classList.add('hidden');
      $('loginStep1')?.classList.remove('hidden');
      $('loginStep2')?.classList.add('hidden');
      try {
        _loginPersonal = await API.get('getPersonalMaster', { appOrigen: 'MOS', estado: '1' });
        _renderLoginPersonal();
      } catch(e) {
        const err = $('loginStep1Error');
        if (err) err.textContent = 'Error al cargar usuarios: ' + e.message;
      }
    }
  }

  function lockScreen() {
    if (!S.session) return;
    _showLogin(); // con sesión activa muestra el lock
  }

  function _renderLoginPersonal() {
    const grid = $('loginPersonalGrid');
    if (!grid) return;
    if (!_loginPersonal || !_loginPersonal.length) {
      grid.innerHTML = '<p class="col-span-3 text-slate-400 text-sm text-center py-4">No hay usuarios MOS. Agrégalos en Configuración → Personal.</p>';
      return;
    }
    grid.innerHTML = _loginPersonal.map(p => {
      const ini = ((p.nombre||'?')[0] + (p.apellido||'?')[0]).toUpperCase();
      const rolCls = p.rol === 'master' ? 'badge-yellow' : 'badge-blue';
      return `<button onclick="MOS.seleccionarUsuario('${p.idPersonal}')"
        class="flex flex-col items-center gap-2 p-4 rounded-xl border border-slate-700 hover:border-indigo-500 transition-colors cursor-pointer"
        style="background:#0d1526">
        <div class="w-12 h-12 rounded-full flex items-center justify-center text-white font-bold text-lg"
             style="background:${p.color||'#6366f1'}">${ini}</div>
        <div class="text-sm font-medium text-slate-200">${p.nombre}</div>
        <span class="badge ${rolCls} text-xs">${p.rol}</span>
      </button>`;
    }).join('');
  }

  function seleccionarUsuario(id) {
    _loginSelectedId = id;
    _pinValue = '';
    const p = _loginPersonal.find(x => x.idPersonal === id);
    if (!p) return;
    $('loginStep1')?.classList.add('hidden');
    $('loginStep2')?.classList.remove('hidden');
    const ini = ((p.nombre||'?')[0] + (p.apellido||'?')[0]).toUpperCase();
    const av = $('loginUserAvatar');
    if (av) { av.textContent = ini; av.style.background = p.color || '#6366f1'; }
    const nm = $('loginUserName'); if (nm) nm.textContent = p.nombre;
    const rl = $('loginUserRol');
    if (rl) { rl.textContent = p.rol; rl.className = 'badge text-xs ' + (p.rol==='master'?'badge-yellow':'badge-blue'); }
    const err = $('loginPinError'); if (err) err.textContent = '';
    _updatePinDots();
  }

  function loginVolver() {
    _loginSelectedId = null;
    _pinValue = '';
    $('loginStep1')?.classList.remove('hidden');
    $('loginStep2')?.classList.add('hidden');
    const err = $('loginPinError'); if (err) err.textContent = '';
  }

  async function confirmarPin() {
    if (_pinValue.length < 4) {
      _pinChecking = false;
      _pinErrorAnim();
      return;
    }
    const pin    = _pinValue;
    const userId = _pinMode === 'lock' ? S.session?.idPersonal : _loginSelectedId;

    if (_pinMode === 'lock') {
      const err = $('lockPinError'); if (err) err.textContent = '';
      try {
        const res = await API.post('verificarPinPersonal', { idPersonal: userId, pin });
        if (!res?.autorizado) {
          if ($('lockPinError')) $('lockPinError').textContent = '';
          toast('PIN incorrecto', 'error');
          _pinErrorAnim();
          return;
        }
        $('loginOverlay')?.classList.add('hidden');
        _pinChecking = false;
      } catch(e) {
        toast('Error: ' + e.message, 'error');
        _pinErrorAnim();
      }
    } else {
      const err = $('loginPinError'); if (err) err.textContent = '';
      try {
        const res = await API.post('verificarPinPersonal', { idPersonal: userId, pin });
        if (!res?.autorizado) {
          toast('PIN incorrecto', 'error');
          _pinErrorAnim();
          return;
        }
        S.session = { idPersonal: userId, nombre: res.nombre, rol: res.rol, idSesion: _generaIdSesion() };
        _saveSession(S.session);
        _applySession();
        _refreshAuditCtx();
        // Mostrar welcome screen + iniciar carga en background
        _showWelcome(res.nombre, res.rol);
        $('loginOverlay')?.classList.add('hidden');
        _pinChecking = false;
        nav('dashboard');
        loadView('dashboard');
        if (window._SWDailyCheck) window._SWDailyCheck();
        // Push: notificar login + registrar token (askPermission=true porque viene de gesto del usuario)
        _pushInit(res.nombre, res.rol, true);
      } catch(e) {
        toast('Error: ' + (e.message || 'No se pudo validar PIN'), 'error');
        _pinErrorAnim();
      }
    }
  }

  // ── Welcome screen post-login ────────────────────────────────
  const _WEL_MSGS = [
    'El control es tuyo. Vamos.',
    'Hoy es un gran día para crecer.',
    'Tu equipo cuenta contigo.',
    'Las decisiones importantes te esperan.',
    'Que sea un día productivo.',
    'Listo para liderar.',
    'Vamos a hacer que las cosas pasen.'
  ];
  function _greetingByHour() {
    const h = new Date().getHours();
    if (h >= 5 && h < 12)  return '¡Buenos días!';
    if (h >= 12 && h < 19) return '¡Buenas tardes!';
    return '¡Buenas noches!';
  }
  function _showWelcome(nombre, rol) {
    const overlay = $('welcomeScreen');
    if (!overlay) return;
    // Texto
    $('welGreeting').textContent = _greetingByHour();
    $('welName').textContent     = (nombre || 'Admin').split(' ')[0];
    const rolLabel = (rol || '').toLowerCase() === 'master' ? '— Master Admin —' : '— Administrador —';
    $('welRol').textContent  = rolLabel;
    $('welMsg').textContent  = _WEL_MSGS[Math.floor(Math.random() * _WEL_MSGS.length)];
    // Partículas (12 puntos con drift random)
    const pcont = $('welParticles');
    if (pcont) {
      const N = 14;
      pcont.innerHTML = Array.from({ length: N }, () => {
        const left  = Math.random() * 100;
        const dur   = 5 + Math.random() * 5;
        const delay = -Math.random() * dur;
        const drift = (Math.random() * 80 - 40) + 'px';
        const size  = (4 + Math.random() * 8) | 0;
        return `<span style="left:${left}%;width:${size}px;height:${size}px;animation-duration:${dur}s;animation-delay:${delay}s;--drift:${drift}"></span>`;
      }).join('');
    }
    // Progress de 5 fases simulado (~3.5s total)
    const fases = ['Catálogo', 'Stock', 'Cajas', 'Promociones', 'Personal'];
    const dots = document.querySelectorAll('#welProgressDots .wel-progress-dot');
    const lbl  = $('welProgressLabel');
    fases.forEach((fase, i) => {
      setTimeout(() => {
        if (dots[i]) dots[i].classList.add('done');
        if (lbl) lbl.textContent = 'Cargando ' + fase + '…';
        if (i === fases.length - 1) {
          setTimeout(() => { if (lbl) lbl.textContent = 'Todo listo · Toca para entrar'; }, 400);
        }
      }, 350 + i * 600);
    });
    // Mostrar (limpiar cualquier display:none previo)
    overlay.style.display = '';
    overlay.classList.remove('hide');
    overlay.classList.add('show');
  }
  function _dismissWelcome() {
    const overlay = $('welcomeScreen');
    if (!overlay || !overlay.classList.contains('show')) return;
    overlay.classList.remove('show');
    overlay.classList.add('hide');
    setTimeout(() => { overlay.style.display = 'none'; overlay.classList.remove('hide'); }, 400);
  }

  function _applySession() {
    if (!S.session) return;
    const isMaster = (S.session.rol || '').toLowerCase() === 'master';
    // Iniciar pre-carga en background al autenticar
    _startCajasRefresh();
    _startCatRefresh();
    _startFinanzasRefresh();
    _refreshPNPendientes(); // PN pendientes — pre-carga inmediata
    _startPNAutoRefresh();   // refresca cada 90s automáticamente
    loadProveedores().catch(() => {}); // pre-carga proveedores
    _startProvRefresh();
    _auditCheckBanner().catch(() => {}); // banner de alertas de integridad
    _prefetchAlmacen();                  // precarga endpoints pesados de almacén
    // Pre-carga promociones desde cache (sin bloquear)
    const _pc = _promoLoadCache();
    if (_pc) _promoState.lista = _pc;
    // Fetch fresco en background
    API.get('getPromociones', {}).then(r => {
      _promoState.lista = Array.isArray(r) ? r : (r && r.data) || [];
      _promoSaveCache(_promoState.lista);
    }).catch(() => {});
    _pushInit(S.session.nombre, S.session.rol);
    // Sidebar session display
    const av = $('sessionAvatar');
    const nm = $('sessionName');
    const rl = $('sessionRol');
    const initial = ((S.session.nombre||'?')[0]).toUpperCase();
    if (av) { av.textContent = initial; av.style.background = S.session.color || '#6366f1'; }
    if (nm) nm.textContent = S.session.nombre;
    if (rl) rl.textContent = S.session.rol;
    // Sync avatar en header móvil
    const avMob = $('sessionAvatarMob');
    if (avMob) { avMob.textContent = initial; avMob.style.background = S.session.color || '#6366f1'; }
    // Init SVG traveling border on sidebar avatar
    requestAnimationFrame(() => _initAvatarTrigSvg());
    // Hide Config for admin role (sidebar + bottom nav + avatar menu)
    document.querySelectorAll('[data-view="config"]').forEach(b => {
      b.style.display = isMaster ? '' : 'none';
    });
    const btnAvCfg = $('btnAvatarConfig');
    if (btnAvCfg) btnAvCfg.classList.toggle('hidden', !isMaster);
  }

  function logout() {
    _stopCajasRefresh();
    _stopCatRefresh();
    _stopFinanzasRefresh();
    _finPL = null;
    _clearSession();
    S.session = null;
    S.loaded = {};
    S._cajasLoaded = false; S._todasCajas = null; S._todosTickets = null;
    _showLogin();
  }

  async function loadView(viewName) {
    S.loaded[viewName] = true;
    try {
      switch (viewName) {
        case 'dashboard':    await loadDashboard();   break;
        case 'catalogo':     await loadCatalogo();    break;
        case 'almacen':      await loadAlmacen();     break;
        case 'config':       await loadConfig();      break;
        case 'proveedores':  await loadProveedores();  break;
        case 'cajas':        await loadCajas(true);    break;
        case 'finanzas':     await _loadFinanzas();    break;
        case 'evaluacion':   await loadEvaluacion();   break;
        case 'promociones':  await loadPromociones();  break;
      }
    } catch (e) {
      // Reload allowed next time
      S.loaded[viewName] = false;
      if (e.message && e.message.includes('URL no configurada')) {
        // already showing banner
      } else {
        toast('Error al cargar ' + viewName + ': ' + e.message, 'error');
      }
    }
  }

  function refresh() {
    S.loaded[S.view] = false;
    S.loaded['dashboard'] = false;
    loadView(S.view);
    if (S.view !== 'dashboard') loadView('dashboard');
  }

  // ── ECO STATUS (llamada independiente, se puede refrescar sola) ─
  let _ecoRefreshTimer = null;

  function _setEcoDots(eco) {
    const ecoWhDot   = $('ecoWhDot');
    const ecoWhLabel = $('ecoWhLabel');
    const ecoMeDot   = $('ecoMeDot');
    const ecoMeLabel = $('ecoMeLabel');

    const _colorClass = c => c === 'green' ? 'dot-green' : c === 'yellow' ? 'dot-yellow' : c === 'red' ? 'dot-red' : 'dot-gray';
    const _colorLabel = (c, err) => {
      if (err) return err.includes('_SS_ID') || err.includes('no configurado') ? 'Sin configurar' : 'Error';
      return c === 'green' ? 'Activo' : c === 'yellow' ? 'Sin actividad' : c === 'red' ? 'Error' : '—';
    };

    if (eco && eco.wh) {
      if (ecoWhDot) ecoWhDot.className = _colorClass(eco.wh.color);
      if (ecoWhLabel) ecoWhLabel.textContent = _colorLabel(eco.wh.color, eco.wh.error);
      if (eco.wh.color !== 'red') setStatus(true);
    } else {
      if (ecoWhDot) { ecoWhDot.className = 'dot-red'; }
      if (ecoWhLabel) ecoWhLabel.textContent = 'Error';
    }

    if (eco && eco.me) {
      if (ecoMeDot) ecoMeDot.className = _colorClass(eco.me.color);
      if (ecoMeLabel) ecoMeLabel.textContent = _colorLabel(eco.me.color, eco.me.error);
    } else {
      if (ecoMeDot) { ecoMeDot.className = 'dot-red'; }
      if (ecoMeLabel) ecoMeLabel.textContent = 'Error';
    }
  }

  function _setEcoLoading() {
    const ecoWhDot   = $('ecoWhDot');
    const ecoWhLabel = $('ecoWhLabel');
    const ecoMeDot   = $('ecoMeDot');
    const ecoMeLabel = $('ecoMeLabel');
    if (ecoWhDot)   ecoWhDot.className = 'dot-loading';
    if (ecoWhLabel) ecoWhLabel.textContent = 'Conectando...';
    if (ecoMeDot)   ecoMeDot.className = 'dot-loading';
    if (ecoMeLabel) ecoMeLabel.textContent = 'Conectando...';
  }

  async function _refreshEcoStatus() {
    try {
      const eco = await API.get('getEcoStatus', {});
      S._ecoData = eco || null;
      _setEcoDots(eco);
    } catch(e) {
      S._ecoData = null;
      const ecoWhDot = $('ecoWhDot'); if (ecoWhDot) ecoWhDot.className = 'dot-red';
      const ecoWhLabel = $('ecoWhLabel'); if (ecoWhLabel) ecoWhLabel.textContent = 'Error';
      const ecoMeDot = $('ecoMeDot'); if (ecoMeDot) ecoMeDot.className = 'dot-red';
      const ecoMeLabel = $('ecoMeLabel'); if (ecoMeLabel) ecoMeLabel.textContent = 'Error';
    }
  }

  function _startEcoAutoRefresh() {
    if (_ecoRefreshTimer) clearInterval(_ecoRefreshTimer);
    _ecoRefreshTimer = setInterval(_refreshEcoStatus, 60000); // cada 60s
  }

  // ── DASHBOARD ───────────────────────────────────────────────
  async function loadDashboard() {
    if (!API.isConfigured()) return;

    // Mostrar "Conectando..." inmediatamente en los dots
    _setEcoLoading();

    // Load in parallel (eco independiente para no bloquear KPIs)
    const [rotRes, alertasRes, mermasRes, prodRes] = await Promise.allSettled([
      API.get('getRotacion', {}),
      API.get('getAlertasWarehouse', {}),
      API.get('getMermasWarehouse', { estado: 'PENDIENTE' }),
      API.get('getProductos', { estado: '1' })
    ]);

    // Eco status en paralelo pero sin bloquear el resto
    _refreshEcoStatus();
    _startEcoAutoRefresh();

    // KPI — stock bajo
    const rot = rotRes.status === 'fulfilled' ? rotRes.value : [];
    const stockBajo = Array.isArray(rot) ? rot.filter(r => r.alertaMinimo).length : 0;
    const kpiSV = $('kpiStockVal');
    if (kpiSV) { kpiSV.textContent = stockBajo; }
    if (stockBajo > 0) {
      const b = $('kpiStockBadge'); if (b) b.classList.remove('hidden');
    }

    // KPI — vencimientos
    const alertas = alertasRes.status === 'fulfilled' ? alertasRes.value : { criticos: [], alertas: [] };
    const criticos = (alertas.criticos || []).length;
    const kpiVV = $('kpiVencVal');
    if (kpiVV) kpiVV.textContent = criticos;
    if (criticos > 0) { const b = $('kpiVencBadge'); if (b) b.classList.remove('hidden'); }

    // KPI — mermas
    const mermas = mermasRes.status === 'fulfilled' ? (mermasRes.value || []) : [];
    const kpiMV = $('kpiMermasVal'); if (kpiMV) kpiMV.textContent = mermas.length;

    // KPI — productos
    const prods = prodRes.status === 'fulfilled' ? (prodRes.value || []) : [];
    const kpiPV = $('kpiProductosVal'); if (kpiPV) kpiPV.textContent = prods.length;
    S.productos = prods;

    // Charts
    renderRotacionChart(rot);
    renderStockChart(rot);

    // Alertas list
    renderAlertas([
      ...((alertas.criticos || []).slice(0, 3).map(a => ({ tipo: 'CRITICO', msg: (a.codigoProducto || a.descripcion || '—') + ' vence en ' + (a.diasRestantes || 0) + 'd' }))),
      ...((alertas.alertas  || []).slice(0, 2).map(a => ({ tipo: 'ALERTA',  msg: (a.codigoProducto || a.descripcion || '—') + ' vence en ' + (a.diasRestantes || 0) + 'd' }))),
      ...(mermas.slice(0, 2).map(m => ({ tipo: 'MERMA', msg: 'Merma pendiente: ' + (m.codigoProducto || '—') })))
    ].slice(0, 6));
  }

  function renderRotacionChart(rot) {
    if (!rot || !rot.length) {
      const e = $('chartRotacionEmpty'); if (e) { e.classList.remove('hidden'); }
      return;
    }
    const top = rot.filter(r => r.diasCobertura !== null).slice(0, 8);
    if (!top.length) { const e = $('chartRotacionEmpty'); if (e) e.classList.remove('hidden'); return; }

    const labels = top.map(r => (r.descripcion || r.codigoProducto || '').substring(0, 20));
    const dias   = top.map(r => r.diasCobertura);
    const colors = dias.map(d => d <= 7 ? '#f87171' : d <= 15 ? '#fbbf24' : '#4ade80');

    renderChart('chartRotacion', {
      type: 'bar',
      data: {
        labels,
        datasets: [{ label: 'Días de cobertura', data: dias, backgroundColor: colors, borderRadius: 6, borderWidth: 0 }]
      },
      options: {
        indexAxis: 'y',
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: {
          x: { grid: { color: '#1e293b' }, ticks: { color: '#64748b', font: { size: 11 } } },
          y: { grid: { display: false }, ticks: { color: '#94a3b8', font: { size: 11 } } }
        }
      }
    });
  }

  function renderStockChart(rot) {
    if (!rot || !rot.length) {
      const e = $('chartStockEmpty'); if (e) e.classList.remove('hidden');
      return;
    }
    // Show top products near or below minimum
    const near = rot.filter(r => r.alertaMinimo || (r.diasCobertura !== null && r.diasCobertura < 20)).slice(0, 8);
    if (!near.length) { const e = $('chartStockEmpty'); if (e) e.classList.remove('hidden'); return; }

    const labels = near.map(r => (r.descripcion || r.codigoProducto || '').substring(0, 18));
    renderChart('chartStock', {
      type: 'bar',
      data: {
        labels,
        datasets: [
          { label: 'Stock actual', data: near.map(r => parseFloat(r.stockActual) || 0), backgroundColor: '#6366f1', borderRadius: 5, borderWidth: 0 },
          { label: 'Stock mínimo', data: near.map(() => 0), backgroundColor: '#ef4444', borderRadius: 5, borderWidth: 0, type: 'line', borderColor: '#ef4444', borderDash: [4,3], pointRadius: 0 }
        ]
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: true, labels: { color: '#64748b', font: { size: 11 }, boxWidth: 12 } } },
        scales: {
          x: { grid: { display: false }, ticks: { color: '#64748b', font: { size: 10 }, maxRotation: 35 } },
          y: { grid: { color: '#1e293b' }, ticks: { color: '#64748b', font: { size: 11 } } }
        }
      }
    });
  }

  function renderAlertas(items) {
    const el = $('listAlertas');
    if (!el) return;
    if (!items.length) { el.innerHTML = '<p class="text-slate-500 text-sm text-center py-4">Sin alertas activas</p>'; return; }
    el.innerHTML = items.map(a => {
      const color = a.tipo === 'CRITICO' ? 'badge-red' : a.tipo === 'MERMA' ? 'badge-yellow' : 'badge-yellow';
      const icon  = a.tipo === 'CRITICO' ? '🔴' : a.tipo === 'MERMA' ? '🗑️' : '🟡';
      return `<div class="flex items-start gap-2 text-sm">
        <span>${icon}</span>
        <span class="text-slate-300 flex-1">${a.msg}</span>
      </div>`;
    }).join('');
  }

  // ── CATÁLOGO ─────────────────────────────────────────────────
  const CAT_CACHE_KEY = 'MOS_CAT_CACHE';
  let _catTimer  = null;
  let _catGroups = {}; // { [skuBase]: { base, pres[] } } — para acceso desde guardarPrecioRapido

  // ── Política de precios — resolver y calcular margen ──────
  // Política efectiva: override del producto > política de la categoría > default global.
  function _resolverPoliticaProd(producto) {
    const oModo = String(producto.modoVenta || '').toUpperCase();
    const VALIDOS = ['MARGEN','FIJO','COMPETITIVO','LIBRE'];
    const idCat = String(producto.idCategoria || '').toUpperCase();
    const cat = (S.categorias || []).find(c => c && String(c.idCategoria || '').toUpperCase() === idCat);
    const oMarg = (producto.margenPct !== '' && producto.margenPct !== undefined && producto.margenPct !== null) ? parseFloat(producto.margenPct) : null;
    const oTope = (producto.precioTope !== '' && producto.precioTope !== undefined && producto.precioTope !== null) ? parseFloat(producto.precioTope) : null;

    const modo  = (VALIDOS.indexOf(oModo) >= 0) ? oModo : (cat ? String(cat.modoVenta || 'MARGEN').toUpperCase() : 'MARGEN');
    const margen = (oMarg !== null && !isNaN(oMarg)) ? oMarg : (cat ? (parseFloat(cat.margenPct) || 25) : 25);
    const tope  = (oTope !== null && !isNaN(oTope) && oTope > 0) ? oTope : (cat ? (parseFloat(cat.precioTope) || 0) : 0);
    const origen = oModo ? 'producto' : (cat ? 'categoría' : 'default');
    return { modo, margen, tope, origen, categoria: cat };
  }

  // Render seguro del badge de margen (cualquier error aquí no debe romper el catálogo)
  function _renderMargenBadge(producto) {
    try {
      const mi = _calcularMargenInfo(producto);
      if (!mi) return '';
      const cls = mi.estado === 'bajo' ? 'text-rose-400' : mi.estado === 'sin-regla' ? 'text-slate-500' : 'text-emerald-400';
      const icon = mi.estado === 'bajo' ? '⚠' : '';
      const tip = (mi.modo === 'FIJO' || mi.modo === 'LIBRE')
        ? 'Modo ' + mi.modo + ' (sin objetivo)'
        : 'Objetivo ' + (parseFloat(mi.objetivo) || 0).toFixed(1) + '%';
      return '<div class="text-[10px] ' + cls + '" title="' + tip + '">Margen: ' + mi.margen.toFixed(1) + '% ' + icon + '</div>';
    } catch (_) { return ''; }
  }

  // Calcula info de margen actual + estado vs política. Retorna null si no aplica.
  function _calcularMargenInfo(producto) {
    const venta = parseFloat(producto.precioVenta) || 0;
    const costo = parseFloat(producto.precioCosto) || 0;
    if (venta <= 0 || costo <= 0) return null;
    const margenReal = ((venta - costo) / venta) * 100;
    const pol = _resolverPoliticaProd(producto);
    let estado = 'ok'; // ok | bajo | sin-regla
    if (pol.modo === 'FIJO' || pol.modo === 'LIBRE') {
      // No hay objetivo — solo alerta si margen < 10% (gancho permitido pero no a pérdida grave)
      if (margenReal < 10) estado = 'bajo';
      else estado = 'sin-regla';
    } else {
      // MARGEN o COMPETITIVO: alerta si está por debajo del objetivo - 5pts
      if (margenReal < pol.margen - 5) estado = 'bajo';
    }
    return {
      margen: margenReal,
      objetivo: pol.margen,
      modo: pol.modo,
      estado: estado
    };
  }

  async function loadCatalogo(force = false) {
    // Si el timer ya precargó datos frescos y no se forzó, renderizar sin fetch
    if (!force && S.productos && S.productos.length > 0) {
      populateCatFiltro();
      renderCatalogo();
      return;
    }

    // Fallback: cache local → render inmediato, luego fetch fresco
    const cached = _catLoadCache();
    if (!force && cached) {
      S.productos = cached.productos || cached;
      S.equivMap  = cached.equivMap  || {};
      populateCatFiltro();
      renderCatalogo();
    }

    // Fetch fresco (si no lo hizo el timer aún, o si se forzó)
    try {
      const [freshProd, freshEquiv, freshCats] = await Promise.all([
        API.get('getProductos', {}),
        API.get('getEquivalencias', { activo: '1' }).catch(() => []),
        API.get('getCategorias', {}).catch(() => [])  // tolera GAS no redesplegado
      ]);
      S.categorias = Array.isArray(freshCats) ? freshCats : [];
      const productos = freshProd || [];
      const equivMap  = {};
      (freshEquiv || []).forEach(e => {
        const k = e.skuBase || e.idProducto;
        if (k && e.codigoBarra) { if (!equivMap[k]) equivMap[k] = []; equivMap[k].push(e.codigoBarra); }
      });
      const changed = JSON.stringify(productos) !== JSON.stringify(S.productos);
      S.productos = productos;
      S.equivMap  = equivMap;
      _catSaveCache({ productos, equivMap });
      if (force || changed || !cached) { populateCatFiltro(); renderCatalogo(); }
    } catch(e) {
      if (!cached && !(S.productos && S.productos.length)) {
        const el = $('listCatalogo');
        if (el) el.innerHTML = `<p class="text-red-400 text-sm text-center py-8">${e.message}</p>`;
        throw e;
      }
    }
    // PN pendientes (fire-and-forget — no bloquea)
    _refreshPNPendientes();
  }

  // ── Refresh silencioso del catálogo cada 60s ────────────────
  let _catRefreshTimer = null;

  async function _catalogoRefreshSilencioso() {
    if (!API.isConfigured()) return;
    // PN pendientes en paralelo (sin bloquear)
    _refreshPNPendientes().catch(() => {});
    try {
      const [freshProd, freshEquiv] = await Promise.all([
        API.get('getProductos', {}),
        API.get('getEquivalencias', { activo: '1' }).catch(() => [])
      ]);
      const productos = freshProd || [];

      // Reconstruir equivMap
      const equivMap = {};
      (freshEquiv || []).forEach(e => {
        const k = e.skuBase || e.idProducto;
        if (k && e.codigoBarra) { if (!equivMap[k]) equivMap[k] = []; equivMap[k].push(e.codigoBarra); }
      });

      // ── Diff: qué cambió ──────────────────────────────────
      const prevMap = {};
      (S.productos || []).forEach(p => { prevMap[p.idProducto] = p; });
      const prevIds = new Set(Object.keys(prevMap));
      const newIds  = new Set(productos.map(p => p.idProducto));

      const added   = productos.filter(p => !prevIds.has(p.idProducto));
      const removed = (S.productos||[]).filter(p => !newIds.has(p.idProducto));
      const changed = productos.filter(p => {
        const prev = prevMap[p.idProducto];
        if (!prev) return false;
        return String(prev.precioVenta) !== String(p.precioVenta)
            || String(prev.precioCosto) !== String(p.precioCosto)
            || String(prev.descripcion) !== String(p.descripcion)
            || String(prev.estado)      !== String(p.estado);
      });

      const sinCambios = added.length === 0 && removed.length === 0 && changed.length === 0
                      && JSON.stringify(equivMap) === JSON.stringify(S.equivMap);
      if (sinCambios) return; // nada que hacer

      // ── Actualizar estado ─────────────────────────────────
      S.productos = productos;
      S.equivMap  = equivMap;
      _catSaveCache({ productos, equivMap });

      // ── Actualizar dashboard KPI si visible ───────────────
      const kpiProd = $('dashTotalProductos');
      if (kpiProd) {
        const activos = productos.filter(p => _isProdActivo(p)).length;
        _setVal('dashTotalProductos', activos, kpiProd.textContent !== String(activos));
      }

      // ── Si no estamos en catálogo, terminar aquí ──────────
      if (S.view !== 'catalogo') return;

      const container = $('listCatalogo');
      if (!container) return;

      // ── Actualización in-place (solo precios/costos) ──────
      // Si no hay nuevos ni eliminados, actualizar solo las celdas que cambiaron
      if (added.length === 0 && removed.length === 0 && changed.length > 0) {
        let allInPlace = true;
        changed.forEach(p => {
          const priceEl = document.querySelector(`[data-cat-precio="${p.idProducto}"]`);
          const costoEl = document.querySelector(`[data-cat-costo="${p.idProducto}"]`);
          const cardEl  = document.querySelector(`[data-cat-id="${p.idProducto}"]`);
          if (priceEl) {
            const nuevo = fmtMoney(p.precioVenta);
            if (priceEl.textContent !== nuevo) {
              priceEl.textContent = nuevo;
              priceEl.classList.remove('val-flash'); priceEl.offsetHeight; priceEl.classList.add('val-flash');
            }
          } else { allInPlace = false; } // no está visible (filtrado/fuera de viewport)
          if (costoEl) {
            const nuevo = 'Costo: ' + fmtMoney(p.precioCosto);
            if (costoEl.textContent !== nuevo) { costoEl.textContent = nuevo; }
          }
          // Si cambió estado (activo/inactivo), actualizar clase de la card
          if (cardEl) {
            cardEl.classList.toggle('cat-inactive', !_isProdActivo(p));
          }
        });

        // Si todos los cambios fueron in-place, solo notificar discretamente
        if (allInPlace || changed.length <= 5) {
          const msg = changed.length === 1
            ? `Precio actualizado: ${changed[0].descripcion || changed[0].idProducto}`
            : `${changed.length} precios actualizados`;
          toast(msg, 'ok');
          return;
        }
      }

      // ── Re-render suave (nuevos, eliminados, o cambios masivos) ──
      const scrollY = container.scrollTop;
      container.style.transition = 'opacity .18s ease';
      container.style.opacity    = '0';
      await new Promise(r => setTimeout(r, 180));

      populateCatFiltro();
      renderCatalogo();
      container.scrollTop = scrollY;

      // Fade in
      container.style.opacity = '1';
      setTimeout(() => { container.style.transition = ''; }, 200);

      // Highlight cards nuevas
      added.forEach(p => {
        const card = document.querySelector(`[data-cat-id="${p.idProducto}"]`);
        if (card) { card.style.animation = 'cardSlideIn .4s ease'; }
      });

      // Toast informativo
      const msgs = [];
      if (added.length)   msgs.push(`+${added.length} nuevo${added.length>1?'s':''}`);
      if (removed.length) msgs.push(`−${removed.length} eliminado${removed.length>1?'s':''}`);
      if (changed.length && !added.length && !removed.length) msgs.push(`${changed.length} precio${changed.length>1?'s':''} actualizado${changed.length>1?'s':''}`);
      if (msgs.length) toast('Catálogo: ' + msgs.join(', '), 'ok');

    } catch(e) { console.warn('[CatRefresh]', e.message); }
  }

  function _startCatRefresh() {
    _stopCatRefresh();
    _catalogoRefreshSilencioso(); // precarga inmediata
    _catRefreshTimer = setInterval(_catalogoRefreshSilencioso, 60000);
  }
  function _stopCatRefresh() {
    if (_catRefreshTimer) { clearInterval(_catRefreshTimer); _catRefreshTimer = null; }
  }

  function _catLoadCache() {
    try {
      const raw = localStorage.getItem(CAT_CACHE_KEY);
      if (!raw) return null;
      const obj = JSON.parse(raw);
      // TTL: 30 minutos
      if (!obj || !obj.ts || !obj.data || Date.now() - obj.ts > 30 * 60 * 1000) return null;
      return obj.data;
    } catch { return null; }
  }
  function _catSaveCache(data) {
    try { localStorage.setItem(CAT_CACHE_KEY, JSON.stringify({ ts: Date.now(), data })); } catch {}
  }

  // ── Estado de filtros del catálogo ─────────────────────────
  const _catFiltros = { categoria: '', tipos: new Set(), soloAlertas: false };

  // ¿Este grupo tiene alguna alerta?
  // El producto canónico es el que tiene factor=1. Solo puede haber 1 por grupo.
  // Tipo A: múltiples canónicos (>1 con factor=1)
  // Tipo B: sin canónico (0 con factor=1)
  // Tipo C1: factor<1 → precioActual < canónico × factor (vendiendo muy barato la fracción)
  // Tipo C2: factor>1 → precioActual > canónico × factor (no tiene sentido cobrar más)
  // Tipo C3: factor>1 → precioActual ≤ costo × factor (vendes a pérdida)
  function _groupHasAlert(g) {
    if (!g.base) return false;
    const canonicos = g.__canonicos || [];
    if (canonicos.length === 0) return true;
    if (canonicos.length > 1)   return true;
    if (!g.pres || !g.pres.length) return false;
    const basePrecio = parseFloat(g.base.precioVenta) || 0;
    const baseCosto  = parseFloat(g.base.precioCosto) || 0;
    return g.pres.some(d => {
      const factor = parseFloat(d.factorConversion) || 1;
      if (factor === 1) return false;
      const precioActual = parseFloat(d.precioVenta) || 0;
      if (factor < 1) {
        const minimo = basePrecio * factor;
        return basePrecio > 0 && precioActual < minimo;
      }
      const maximo      = basePrecio * factor;
      const minimoCosto = baseCosto  * factor;
      if (basePrecio > 0 && precioActual > maximo) return true;
      if (baseCosto  > 0 && precioActual <= minimoCosto) return true;
      return false;
    });
  }

  // Construye la lista detallada de alertas para mostrar en el popover
  // tipo: 'sinbase' | 'dup' | 'bajo' | 'alto' | 'perdida'
  function _groupAlertList(g) {
    const list = [];
    if (!g.base) return list;
    const canonicos = g.__canonicos || [];
    if (canonicos.length === 0) {
      list.push({
        tipo: 'sinbase', tag: 'SIN BASE', nombre: '',
        titulo: 'Sin producto base',
        detalle: 'Ningún producto del grupo tiene factor = 1 (la unidad base)'
      });
    }
    if (canonicos.length > 1) {
      const nombres = canonicos.map(p => p.descripcion || p.codigoBarra || p.idProducto).join(' · ');
      list.push({
        tipo: 'dup', tag: 'DUPLICADO', nombre: '',
        titulo: 'Múltiples canónicos (' + canonicos.length + ')',
        detalle: 'Solo puede existir un producto con factor=1. Encontrados: ' + nombres
      });
    }
    if (g.pres && g.pres.length) {
      const basePrecio = parseFloat(g.base.precioVenta) || 0;
      const baseCosto  = parseFloat(g.base.precioCosto) || 0;
      g.pres.forEach(d => {
        const factor = parseFloat(d.factorConversion) || 1;
        if (factor === 1) return;
        const precioActual = parseFloat(d.precioVenta) || 0;
        const nombre = d.descripcion || d.codigoBarra || d.idProducto;

        if (factor < 1) {
          const minimo = basePrecio * factor;
          if (basePrecio > 0 && precioActual < minimo) {
            list.push({
              tipo: 'bajo', tag: 'BAJO', nombre,
              titulo: nombre,
              detalle: 'Cobra ' + fmtMoney(precioActual) + ' · mínimo ' + fmtMoney(minimo) + ' (canónico × ' + factor + ')'
            });
          }
        } else {
          const maximo      = basePrecio * factor;
          const minimoCosto = baseCosto  * factor;
          if (basePrecio > 0 && precioActual > maximo) {
            list.push({
              tipo: 'alto', tag: 'ALTO', nombre,
              titulo: nombre,
              detalle: 'Cobra ' + fmtMoney(precioActual) + ' · máximo ' + fmtMoney(maximo) + ' (canónico × ' + factor + ')'
            });
          }
          if (baseCosto > 0 && precioActual <= minimoCosto) {
            list.push({
              tipo: 'perdida', tag: 'PÉRDIDA', nombre,
              titulo: nombre,
              detalle: 'Cobra ' + fmtMoney(precioActual) + ' ≤ ' + fmtMoney(minimoCosto) + ' (costo × ' + factor + '). Vendes a pérdida.'
            });
          }
        }
      });
    }
    return list;
  }

  function toggleFiltroAlertas() {
    _catFiltros.soloAlertas = !_catFiltros.soloAlertas;
    const btn = $('btnAlertasCat');
    if (btn) btn.classList.toggle('active', _catFiltros.soloAlertas);
    renderCatalogo();
  }

  // Cache de alertas por eid (poblada en renderCatalogo)
  const _catAlertCache = new Map();

  // Crear el popover global una sola vez (evita problemas con overflow:hidden de la card)
  function _ensureGlobalAlertPop() {
    let el = document.getElementById('globalAlertPop');
    if (!el) {
      el = document.createElement('div');
      el.id = 'globalAlertPop';
      el.className = 'cat-alert-pop';
      el.addEventListener('click', e => e.stopPropagation());
      document.body.appendChild(el);
    }
    return el;
  }

  function toggleAlertPop(eid, ev) {
    const target = _ensureGlobalAlertPop();
    const sameOpen = target.classList.contains('show') && target.dataset.eid === eid;
    target.classList.remove('show');
    if (sameOpen) return;

    const list = _catAlertCache.get(eid) || [];
    if (!list.length) return;

    target.innerHTML = `
      <div class="cat-alert-pop-head">
        <span>⚠</span> ${list.length} alerta${list.length !== 1 ? 's' : ''}
      </div>
      <div class="cat-alert-pop-body">
        ${list.map(a => `
          <div class="cat-alert-item cat-alert-${a.tipo}">
            <div class="cat-alert-item-title">
              <span class="cat-alert-tag">${a.tag}</span>
              <span>${a.titulo}</span>
            </div>
            <div class="cat-alert-item-detail">${a.detalle}</div>
          </div>
        `).join('')}
      </div>`;
    target.dataset.eid = eid;

    // Posicionar relativo al botón clickeado
    const btn = ev?.currentTarget || ev?.target?.closest?.('.cat-alert-icon');
    if (btn) {
      const rect = btn.getBoundingClientRect();
      const popW = 280, margin = 10;
      let top  = rect.bottom + 10;
      let left = rect.right - popW;
      if (left < margin) left = margin;
      if (left + popW > window.innerWidth - margin) left = window.innerWidth - popW - margin;
      const popH = Math.min(360, list.length * 70 + 60);
      if (top + popH > window.innerHeight - margin) {
        top = rect.top - popH - 10;
        if (top < margin) top = margin;
      }
      target.style.top  = top + 'px';
      target.style.left = left + 'px';
    }
    target.classList.add('show');
  }

  // Click fuera cierra
  document.addEventListener('click', e => {
    if (e.target.closest('#globalAlertPop, .cat-alert-icon')) return;
    document.getElementById('globalAlertPop')?.classList.remove('show');
  });
  // Scroll cierra (la posición fixed quedaría desfasada)
  window.addEventListener('scroll', () => {
    document.getElementById('globalAlertPop')?.classList.remove('show');
  }, { passive: true, capture: true });

  function populateCatFiltro() {
    const cats = [...new Set(S.productos.map(p => p.idCategoria).filter(Boolean))].sort();
    const catOpts = '<option value="">— elegir —</option>' + cats.map(c => `<option value="${c}">${c}</option>`).join('');
    const prodCat = $('prodCategoria');
    if (prodCat) prodCat.innerHTML = '<option value="">— seleccionar —</option>' + cats.map(c => `<option value="${c}">${c}</option>`).join('');
    const pnCat = $('pnCategoria');
    if (pnCat) pnCat.innerHTML = catOpts;
    _renderFiltroCategList(cats);
  }

  function _renderFiltroCategList(cats) {
    const list = $('filtroCategList');
    if (!list) return;
    const cur = _catFiltros.categoria;
    list.innerHTML = `<div class="filtro-radio${!cur ? ' active' : ''}" onclick="MOS.setFiltroCategoria('')">Todas las categorías</div>`
      + cats.map(c => `<div class="filtro-radio${cur === c ? ' active' : ''}" onclick="MOS.setFiltroCategoria('${c}')">${c}</div>`).join('');
  }

  function _updateFiltroBadge() {
    const count = (_catFiltros.categoria ? 1 : 0) + _catFiltros.tipos.size;
    const badge = $('filtrosBadge');
    if (badge) { badge.textContent = count; badge.classList.toggle('hidden', count === 0); }

    const tipoLabels = { envasable:'⚗️ Envasable', conPres:'📦 Con pres.', derivado:'🔗 Derivado', inactivo:'🚫 Inactivos' };
    const chips = $('catFiltroChips');
    if (chips) {
      const parts = [];
      if (_catFiltros.categoria) parts.push(`<span class="cat-chip">📂 ${_catFiltros.categoria} <button onclick="MOS.setFiltroCategoria('')">×</button></span>`);
      _catFiltros.tipos.forEach(t => parts.push(`<span class="cat-chip">${tipoLabels[t]} <button onclick="MOS.toggleFiltroTipo('${t}')">×</button></span>`));
      if (count > 1) parts.push(`<span class="cat-chip cat-chip-clear">Limpiar todo <button onclick="MOS.limpiarFiltrosCat()">×</button></span>`);
      chips.innerHTML = parts.join('');
      chips.classList.toggle('hidden', count === 0);
    }

    ['envasable','conPres','derivado','inactivo'].forEach(t => {
      const el = $('fchk' + t.charAt(0).toUpperCase() + t.slice(1));
      if (el) el.classList.toggle('active', _catFiltros.tipos.has(t));
    });
  }

  function toggleFiltroCat() {
    const panel = $('catFiltroPanel');
    if (!panel) return;
    const isOpen = !panel.classList.contains('hidden');
    if (isOpen) { panel.classList.add('hidden'); return; }
    const productos = Array.isArray(S.productos) ? S.productos : [];
    const cats = [...new Set(productos.map(p => p && p.idCategoria).filter(Boolean))].sort();
    _renderFiltroCategList(cats);
    panel.classList.remove('hidden');
    setTimeout(() => document.addEventListener('click', _closeFiltroOnOutside, { once: true }), 0);
  }
  function _closeFiltroOnOutside(e) {
    const wrap = $('catFiltroWrap');
    if (wrap && !wrap.contains(e.target)) $('catFiltroPanel')?.classList.add('hidden');
    else setTimeout(() => document.addEventListener('click', _closeFiltroOnOutside, { once: true }), 0);
  }

  function setFiltroCategoria(cat) {
    _catFiltros.categoria = cat;
    _updateFiltroBadge();
    const cats = [...new Set(S.productos.map(p => p.idCategoria).filter(Boolean))].sort();
    _renderFiltroCategList(cats);
    renderCatalogo();
  }

  function toggleFiltroTipo(tipo) {
    if (_catFiltros.tipos.has(tipo)) _catFiltros.tipos.delete(tipo);
    else _catFiltros.tipos.add(tipo);
    _updateFiltroBadge();
    renderCatalogo();
  }

  function limpiarFiltrosCat() {
    _catFiltros.categoria = '';
    _catFiltros.tipos.clear();
    _updateFiltroBadge();
    const cats = [...new Set(S.productos.map(p => p.idCategoria).filter(Boolean))].sort();
    _renderFiltroCategList(cats);
    renderCatalogo();
    $('catFiltroPanel')?.classList.add('hidden');
  }

  function filterCatalogo() {
    clearTimeout(_catTimer);
    _catTimer = setTimeout(() => renderCatalogo(), 160);
  }

  function setCatTab(tab) { S.catTab = tab; renderCatalogo(); } // kept for compat

  // ── Search scoring ──────────────────────────────────────────
  function _norm(s) {
    return (s || '').toString().toLowerCase().normalize('NFD').replace(/\p{Mn}/gu, '');
  }
  function _catScore(p, qn, words) {
    if (!qn) return 1;
    const desc = _norm(p.descripcion);
    const cb   = _norm(p.codigoBarra);
    const sku  = _norm(p.skuBase || p.idProducto);
    if (cb === qn || sku === qn)                         return 100;
    if (cb.startsWith(qn))                               return 93;
    if (desc === qn)                                     return 88;
    if (desc.startsWith(qn))                             return 82;
    if (words.length > 1 && words.every(w => desc.includes(w))) return 76;
    if (cb.includes(qn))                                 return 68;
    if (desc.includes(qn))                               return 62;
    if (_norm(p.idCategoria).includes(qn))               return 38;
    if (words.some(w => desc.includes(w) || cb.includes(w))) return 22;
    return 0;
  }
  function _highlight(text, words) {
    if (!words.length || !text) return text || '';
    let r = String(text);
    words.forEach(w => {
      if (!w) return;
      const re = new RegExp('(' + w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
      r = r.replace(re, '<mark>$1</mark>');
    });
    return r;
  }

  // ── Render ──────────────────────────────────────────────────
  function renderCatalogo() {
    const container = $('listCatalogo');
    if (!container) return;

    const rawQ = ($('searchCatalogo')?.value || '').trim();
    const qn   = _norm(rawQ);
    const words = qn.split(/\s+/).filter(Boolean);

    // Build groups: agrupar por skuBase
    // Base = producto donde idProducto === skuBase (auto-referencia)
    // Presentación = producto donde skuBase apunta a otro idProducto
    const groups = {};
    S.productos.forEach(p => {
      const sku = String(p.skuBase || p.idProducto).trim();
      if (!groups[sku]) groups[sku] = { base: null, pres: [], __canonicos: [] };
      const factor = parseFloat(p.factorConversion) || 1;
      // El canónico del grupo es el que tiene factor=1 (la unidad base)
      const esCanonico = factor === 1;
      if (esCanonico) groups[sku].__canonicos.push(p);
      // Base = primer canónico encontrado (o se decide en fallback)
      if (esCanonico && !groups[sku].base) groups[sku].base = p;
      else if (!esCanonico)                 groups[sku].pres.push(p);
      else                                  groups[sku].pres.push(p); // canónico extra → también va a pres para que se muestre
    });
    // Fallback + orden de presentaciones por factor
    Object.values(groups).forEach(g => {
      if (!g.base && g.pres.length) g.base = g.pres.shift();
      g.pres.sort((a, b) => (parseFloat(a.factorConversion)||1) - (parseFloat(b.factorConversion)||1));
    });
    _catGroups = groups; // guardar para acceso externo (ajuste de precios)

    // Calcular alertas globalmente (independiente de filtros) para el botón y badge nav
    const allGroups = Object.values(groups).filter(g => g.base);
    let totalAlertas = 0;
    allGroups.forEach(g => { g.__hasAlert = _groupHasAlert(g); if (g.__hasAlert) totalAlertas++; });
    const btnAlert = $('btnAlertasCat');
    const cntAlert = $('alertaCount');
    if (btnAlert) btnAlert.classList.toggle('hidden', totalAlertas === 0);
    if (cntAlert) cntAlert.textContent = totalAlertas;
    // Badge de alerta en íconos del nav (sidebar y mobile)
    ['catAlertBadge', 'catAlertBadgeMob'].forEach(id => {
      const el = $(id);
      if (el) el.style.display = totalAlertas > 0 ? 'flex' : 'none';
    });
    // Si se desactivan todas las alertas, también apagar el filtro
    if (totalAlertas === 0 && _catFiltros.soloAlertas) {
      _catFiltros.soloAlertas = false;
      btnAlert?.classList.remove('active');
    }

    // Score and filter
    const _tipos = _catFiltros.tipos;
    let result = allGroups.map(g => {
      // Filtro categoría
      if (_catFiltros.categoria && g.base.idCategoria !== _catFiltros.categoria) return null;
      // Filtro alertas
      if (_catFiltros.soloAlertas && !g.__hasAlert) return null;
      // Filtro tipo (OR entre los seleccionados)
      if (_tipos.size > 0) {
        const isEnvasable = String(g.base.esEnvasable) === '1';
        const hasConPres  = g.pres.length > 0;
        const isDeriv     = !!(g.base.codigoProductoBase);
        const isInactivo  = !_isProdActivo(g.base);
        const ok = (_tipos.has('envasable') && isEnvasable) ||
                   (_tipos.has('conPres')   && hasConPres)  ||
                   (_tipos.has('derivado')  && isDeriv)     ||
                   (_tipos.has('inactivo')  && isInactivo);
        if (!ok) return null;
      }
      const baseScore = _catScore(g.base, qn, words);
      const presScore = g.pres.reduce((mx, p) => Math.max(mx, _catScore(p, qn, words)), 0);
      const score = Math.max(baseScore, presScore);
      if (qn && score === 0) return null;
      return { ...g, score };
    }).filter(Boolean);

    // Sort: by score desc, then by description
    result.sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      const da = String(a.base.descripcion || '');
      const db = String(b.base.descripcion || '');
      return da < db ? -1 : da > db ? 1 : 0;
    });

    // Stats
    const stats = $('catStats');
    if (stats) {
      const total = Object.keys(groups).filter(k => groups[k].base).length;
      stats.textContent = qn
        ? `${result.length} resultado${result.length !== 1 ? 's' : ''} de ${total} productos`
        : `${total} grupos · ${S.productos.length} ítems`;
    }

    if (!result.length) {
      container.innerHTML = `<div class="text-center py-16 text-slate-500">
        <div class="text-4xl mb-3">🔍</div>
        <div class="font-medium">Sin resultados para "<span class="text-slate-300">${rawQ}</span>"</div>
        <div class="text-xs mt-1">Prueba con el código de barra o parte del nombre</div>
      </div>`;
      return;
    }

    container.innerHTML = result.map(g => {
      const { base, pres, score } = g;
      const eid   = CSS.escape(base.idProducto);
      const activo = _isProdActivo(base);
      const hlDesc = _highlight(base.descripcion || '—', words);

      // Badges
      const badgeCat  = base.idCategoria ? `<span class="badge badge-gray text-xs">${base.idCategoria}</span>` : '';
      const badgeEnv  = base.esEnvasable == '1' ? `<span class="badge badge-yellow text-xs">⚗️ Envasable</span>` : '';
      const badgePres = pres.length ? `<span class="badge badge-blue text-xs cursor-pointer" onclick="event.stopPropagation();MOS.togglePresentaciones('${base.idProducto}')">📦 ${pres.length} presentacion${pres.length !== 1 ? 'es' : ''}</span>` : '';
      const badgeInac = activo ? '' : `<span class="badge badge-gray text-xs">Inactivo</span>`;

      // Equivalencias para el skuBase
      const equivList = S.equivMap[base.skuBase || base.idProducto] || [];

      // Meta tags: barcode + equivalencias + brand + unidad
      const barcodeTag = base.codigoBarra
        ? `<span class="cat-barcode">▌${base.codigoBarra}</span>` : '';
      const equivTags  = equivList.map((cb, i) =>
        `<span class="cat-equiv-bar cat-equiv-bar-${Math.min(i, 3)}" title="Equivalencia">▌${cb}</span>`
      ).join('');
      const brandTag   = base.marca
        ? `<span class="cat-brand">${base.marca}</span>` : '';
      const unidadNorm = _normalizarUnidad(base.unidad || base.Unidad_Medida);
      const unidadCls  = unidadNorm === 'KGM' ? 'cat-unidad cat-unidad-granel' : 'cat-unidad';
      const unidadTag  = `<span class="${unidadCls}" title="${unidadNorm === 'KGM' ? 'Producto a granel (por peso)' : 'Unidad de medida SUNAT'}">${_unidadDisplay(base.unidad || base.Unidad_Medida)}</span>`;

      // Pre-computar alertas de cada presentación con la nueva lógica
      const basePrecio = parseFloat(base.precioVenta) || 0;
      const baseCosto  = parseFloat(base.precioCosto) || 0;
      const presInfo = pres.map(d => {
        const factor       = parseFloat(d.factorConversion) || 1;
        const precioActual = parseFloat(d.precioVenta) || 0;
        const alerts       = [];
        if (factor < 1) {
          const minimo = basePrecio * factor;
          if (basePrecio > 0 && precioActual < minimo) {
            alerts.push({ tipo: 'bajo', tag: 'BAJO', sufijo: 'mín ' + fmtMoney(minimo) });
          }
        } else if (factor > 1) {
          const maximo      = basePrecio * factor;
          const minimoCosto = baseCosto  * factor;
          if (basePrecio > 0 && precioActual > maximo) {
            alerts.push({ tipo: 'alto', tag: 'ALTO', sufijo: 'máx ' + fmtMoney(maximo) });
          }
          if (baseCosto > 0 && precioActual <= minimoCosto) {
            alerts.push({ tipo: 'perdida', tag: 'PÉRDIDA', sufijo: '≤ ' + fmtMoney(minimoCosto) });
          }
        }
        return { d, factor, precioActual, alerts };
      });
      const alertList = _groupAlertList(g);
      const hasAnyAlert = alertList.length > 0;
      if (hasAnyAlert) _catAlertCache.set(eid, alertList);
      else             _catAlertCache.delete(eid);

      // Presentaciones con expand animado
      const presHtml = pres.length ? `
        <div class="pres-wrap" id="pres-${eid}">
          <div class="pres-inner">
            <div class="px-4 pb-4 pt-3 border-t border-slate-800/80 space-y-2">
              <div class="text-xs text-slate-500 font-medium mb-2">📦 Presentaciones (${pres.length})</div>
              ${presInfo.map(({ d, factor, precioActual, alerts }) => {
                const hlD       = _highlight(d.descripcion || d.idProducto, words);
                const hasAlert  = alerts.length > 0;
                const presActivo = _isProdActivo(d);
                const precioClass = hasAlert ? 'pres-price-err' : 'pres-price-ok';
                const alertHtml = alerts.map(a =>
                  `<span class="pres-alert-pill cat-alert-${a.tipo}"><span class="cat-alert-tag">${a.tag}</span>${a.sufijo}</span>`
                ).join('');
                const presUnidad = _normalizarUnidad(d.unidad || d.Unidad_Medida);
                const presUniIcon = presUnidad === 'KGM' ? '⚖️' : '';
                const presUniBg = presUnidad === 'KGM'
                  ? 'background:rgba(245,158,11,.15);color:#fbbf24'
                  : 'background:rgba(167,139,250,.12);color:#a78bfa';
                return `<div class="pres-chip${hasAlert ? ' border-amber-900/50' : ''}${presActivo ? '' : ' pres-inactive'}" data-pres-id="${d.idProducto}">
                  <div class="min-w-0 flex-1">
                    <div class="text-xs font-semibold text-slate-200 truncate">${hlD}</div>
                    <div class="flex items-center gap-2 mt-0.5">
                      ${d.codigoBarra ? `<span class="pres-code">▌${d.codigoBarra}</span>` : ''}
                      <span class="pres-factor">×${factor}</span>
                      <span class="pres-factor" style="${presUniBg}">${presUniIcon} ${presUnidad}</span>
                    </div>
                    ${alertHtml ? `<div class="flex flex-wrap items-center gap-1 mt-1">${alertHtml}</div>` : ''}
                  </div>
                  <div class="flex items-center gap-2 shrink-0">
                    <div class="${precioClass}">${fmtMoney(precioActual)}</div>
                    <button type="button" class="toggle-sw sm ${presActivo ? 'on' : ''}" data-pid="${d.idProducto}"
                            onclick="event.stopPropagation();MOS.toggleProductoActivo('${d.idProducto}', false)"
                            title="${presActivo ? 'Apagar' : 'Prender'}"><span class="toggle-sw-knob"></span></button>
                    <button class="cat-btn cat-btn-edit sm" onclick="event.stopPropagation();MOS.abrirModalProducto('${d.idProducto}')" title="Editar">✏️</button>
                    <button class="cat-btn cat-btn-price sm" onclick="event.stopPropagation();MOS.abrirModalPrecioRapido('${d.idProducto}')" title="Precio">💰</button>
                  </div>
                </div>`;
              }).join('')}
            </div>
          </div>
        </div>` : '';

      return `<div class="cat-card mb-3${activo ? '' : ' cat-inactive'}" id="fc-${eid}" data-cat-id="${base.idProducto}">
        <!-- Header -->
        <div class="p-4 cursor-pointer select-none" onclick="MOS.togglePresentaciones('${base.idProducto}')">
          <div class="flex items-start gap-3">
            <div class="flex-1 min-w-0">
              <div class="flex flex-wrap gap-1 mb-2">${badgeCat}${badgeEnv}${badgePres}${badgeInac}</div>
              <div class="font-semibold text-slate-100 text-sm leading-snug mb-2">${hlDesc}</div>
              <div class="flex flex-wrap items-center gap-1.5">
                ${barcodeTag}${equivTags}${brandTag}${unidadTag}
              </div>
            </div>
            <div class="flex flex-col items-end gap-1.5 shrink-0 ml-2">
              <div class="flex items-center gap-1.5">
                ${hasAnyAlert ? `<button type="button" class="cat-alert-icon" onclick="event.stopPropagation();MOS.toggleAlertPop('${eid}', event)" aria-label="Ver detalle de alertas">⚠</button>` : ''}
                <div class="cat-price" data-cat-precio="${base.idProducto}">${fmtMoney(base.precioVenta)}</div>
              </div>
              ${base.precioCosto > 0 ? `<div class="cat-cost" data-cat-costo="${base.idProducto}">Costo: ${fmtMoney(base.precioCosto)}</div>` : ''}
              ${_renderMargenBadge(base)}
              <div class="flex gap-1.5 mt-1 items-center">
                <button type="button" class="toggle-sw ${activo ? 'on' : ''}" data-pid="${base.idProducto}"
                        onclick="event.stopPropagation();MOS.toggleProductoActivo('${base.idProducto}', true)"
                        title="${activo ? 'Apagar producto' : 'Prender producto'}">
                  <span class="toggle-sw-knob"></span>
                </button>
                <button class="cat-btn cat-btn-edit"
                        onclick="event.stopPropagation();MOS.abrirModalProducto('${base.idProducto}')"
                        title="Editar producto">✏️</button>
                <button class="cat-btn cat-btn-price"
                        onclick="event.stopPropagation();MOS.abrirModalPrecioRapido('${base.idProducto}')"
                        title="Cambiar precio">💰</button>
                <button class="cat-btn" style="font-size:.8rem"
                        onclick="event.stopPropagation();MOS.abrirAnalitica('${base.idProducto}')"
                        title="Ver analítica" style="border-color:rgba(99,102,241,.3)">📊</button>
              </div>
            </div>
          </div>
        </div>
        ${presHtml}
      </div>`;
    }).join('');
  }

  function togglePresentaciones(idProducto) {
    const el = document.getElementById('pres-' + CSS.escape(idProducto));
    if (el) el.classList.toggle('open');
  }

  function toggleDerivs(id) { togglePresentaciones(id); } // backward compat

  // ── Productos Nuevos (aprobación desde WH) ──────────────────

  const PN_CACHE_KEY = 'mos_pn_cache';
  // Cache MUY corto para PN (60s) — el WH puede borrar/aprobar PNs en cualquier momento
  const PN_CACHE_TTL_MS = 60 * 1000;
  function _pnLoadCache() {
    try {
      const raw = localStorage.getItem(PN_CACHE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (Date.now() - (parsed.ts || 0) > PN_CACHE_TTL_MS) return null;
      return parsed.data;
    } catch { return null; }
  }
  function _pnSaveCache(data) {
    try { localStorage.setItem(PN_CACHE_KEY, JSON.stringify({ ts: Date.now(), data })); } catch {}
  }
  function _pnBustCache() {
    try { localStorage.removeItem(PN_CACHE_KEY); } catch {}
  }

  async function _refreshPNPendientes(force) {
    // Render inmediato desde cache si existe (excepto si force=true)
    if (!force) {
      const cached = _pnLoadCache();
      if (cached && (!S.pnPendientes || !S.pnPendientes.length)) {
        S.pnPendientes = cached;
        _updatePNBadge();
        renderPNBanner();
      }
    }
    try {
      const lista = await API.getProductosNuevosWH({ estado: 'PENDIENTE' });
      const fresh = lista || [];
      const changed = JSON.stringify(fresh) !== JSON.stringify(S.pnPendientes);
      S.pnPendientes = fresh;
      _pnSaveCache(fresh);
      if (changed || force) { _updatePNBadge(); renderPNBanner(); }
    } catch(e) {
      S.pnPendientes = S.pnPendientes || [];
    }
    _updatePNBadge();
    renderPNBanner();
  }

  // Auto-refresh periódico (cada 90s) mientras el usuario está logueado
  let _pnRefreshTimer = null;
  function _startPNAutoRefresh() {
    if (_pnRefreshTimer) clearInterval(_pnRefreshTimer);
    _pnRefreshTimer = setInterval(() => {
      // Solo refresh si la app sigue activa (visible) y hay sesión
      if (!S.session) return;
      if (document.visibilityState !== 'visible') return;
      _refreshPNPendientes().catch(() => {});
    }, 90 * 1000);  // 90 segundos
  }
  // Refresh manual desde el banner — bypassa cache local
  async function refreshPNManual() {
    _pnBustCache();
    toast('Actualizando productos nuevos…', 'info');
    await _refreshPNPendientes(true);
    toast('Lista actualizada ✓', 'ok');
  }

  function _updatePNBadge() {
    const n = (S.pnPendientes || []).length;
    const txt = n > 0 ? String(n > 99 ? '99+' : n) : '';
    ['pnNavBadge', 'pnNavBadgeMob'].forEach(id => {
      const el = $(id);
      if (!el) return;
      if (n > 0) {
        el.textContent = txt;
        el.style.display = 'flex';
      } else {
        el.style.display = 'none';
      }
    });
  }

  function renderPNBanner() {
    const banner = $('pnBannerCat');
    if (!banner) return;
    const lista = S.pnPendientes || [];
    if (!lista.length) { banner.style.display = 'none'; banner.innerHTML = ''; return; }

    banner.style.display = 'block';
    banner.innerHTML = `
      <div style="border:1px solid rgba(217,119,6,.35);background:rgba(120,53,15,.12);border-radius:12px;padding:12px 14px;margin-bottom:4px">
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px">
          <span style="background:#92400e;color:#fde68a;font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">N ${lista.length}</span>
          <span style="font-size:13px;font-weight:600;color:#fcd34d;flex:1">Productos nuevos pendientes de aprobación</span>
          <button onclick="MOS.refreshPNManual()" title="Refrescar lista (ignora cache)" style="background:transparent;border:1px solid rgba(217,119,6,.4);color:#fbbf24;border-radius:6px;padding:3px 8px;font-size:11px;cursor:pointer">↺</button>
        </div>
        <div style="display:flex;flex-direction:column;gap:8px">
          ${lista.map(pn => {
            const guiaLabel = pn.guia ? `Guía ${pn.guia.tipo || ''} · ${pn.guia.fecha || ''}` : `Guía ${pn.idGuia}`;
            const fotoHtml = pn.foto
              ? `<img src="${pn.foto}" style="width:42px;height:42px;border-radius:8px;object-fit:cover;flex-shrink:0">`
              : `<div style="width:42px;height:42px;border-radius:8px;background:#1e293b;display:flex;align-items:center;justify-content:center;flex-shrink:0;font-size:18px">📦</div>`;
            return `<div style="display:flex;align-items:center;gap:10px;background:rgba(0,0,0,.2);border-radius:8px;padding:8px 10px">
              ${fotoHtml}
              <div style="flex:1;min-width:0">
                <div style="font-size:13px;font-weight:600;color:#f1f5f9;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${pn.descripcion || '(sin nombre)'}</div>
                <div style="font-size:11px;color:#94a3b8;margin-top:1px">${pn.codigoBarra || 'sin código'} · ${pn.marca || ''}</div>
                <div style="font-size:11px;color:#64748b">${guiaLabel}</div>
              </div>
              <button onclick="MOS.abrirModalPN('${pn.idProductoNuevo}')" style="flex-shrink:0;background:#b45309;color:#fff;border:none;border-radius:8px;padding:6px 12px;font-size:12px;font-weight:600;cursor:pointer">Revisar</button>
            </div>`;
          }).join('')}
        </div>
      </div>`;
  }

  function abrirModalPN(idProductoNuevo) {
    const pn = (S.pnPendientes || []).find(p => String(p.idProductoNuevo) === String(idProductoNuevo));
    if (!pn) return;

    $('pnId').value             = pn.idProductoNuevo;
    $('pnIdGuia').value          = pn.idGuia || '';
    $('pnCodigoOriginal').value  = pn.codigoBarra || '';
    $('pnUsuario').value         = pn.usuario || '';

    // Header info
    $('pnCodigoWH').textContent  = pn.codigoBarra || '—';
    $('pnFechaVenc').textContent = pn.fechaVencimiento || '—';
    const guiaLabel = (pn.usuario || 'Operador') + ' · ' + (pn.fechaCreacion || '');
    $('pnGuiaInfo').textContent = guiaLabel;

    const obs = $('pnObservaciones');
    if (pn.observaciones) { obs.textContent = pn.observaciones; obs.style.display = 'block'; }
    else obs.style.display = 'none';

    const fotoBox = $('pnFotoPreview');
    if (pn.foto) {
      fotoBox.innerHTML = `<img src="${pn.foto}" style="width:100%;height:100%;object-fit:cover">`;
    } else {
      fotoBox.innerHTML = `<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#475569" stroke-width="1.5"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21,15 16,10 5,21"/></svg>`;
    }

    // Cantidad pre-cargada con la registrada en WH
    $('pnCantidad').value = pn.cantidad != null ? pn.cantidad : '';

    // Sección NUEVO pre-cargada
    $('pnDesc').value         = pn.descripcion || '';
    $('pnMarca').value        = pn.marca || '';
    $('pnCodigoFinal').value  = pn.codigoBarra || '';
    $('pnPrecioVenta').value  = '';
    $('pnPrecioCosto').value  = '';
    $('pnIGV').value          = '1';
    populateCatFiltro();
    const catSel = $('pnCategoria');
    if (catSel && pn.idCategoria) catSel.value = pn.idCategoria;
    const unidSel = $('pnUnidad');
    if (unidSel && pn.unidad) unidSel.value = pn.unidad;

    // Sección EQUIVALENTE limpia
    $('pnEquivBuscar').value = '';
    $('pnEquivResultados').innerHTML = '';
    $('pnEquivResultados').style.display = 'none';
    $('pnEquivSkuBase').value = '';
    $('pnEquivSeleccionado').classList.add('hidden');
    $('pnCodigoEquiv').value = pn.codigoBarra || '';
    $('pnDescEquiv').value   = pn.descripcion || '';

    // Reset radio a NUEVO
    document.querySelector('input[name="pnTipo"][value="NUEVO"]').checked = true;
    pnSetTipo('NUEVO');

    // Reset error y botón
    const errEl = $('pnError'); if (errEl) errEl.style.display = 'none';
    const btn = $('btnLanzarPN'); if (btn) { btn.disabled = false; btn.textContent = 'Aprobar y crear'; }

    const modal = $('modalPN');
    if (modal) { modal.classList.remove('hidden'); modal.classList.add('open'); }
  }

  function cerrarModalPN() {
    const modal = $('modalPN');
    if (modal) { modal.classList.add('hidden'); modal.classList.remove('open'); }
  }

  // Toggle sección NUEVO vs EQUIVALENTE
  function pnSetTipo(tipo) {
    $('pnSeccionNuevo').classList.toggle('hidden', tipo !== 'NUEVO');
    $('pnSeccionEquiv').classList.toggle('hidden', tipo !== 'EQUIVALENTE');
  }

  // Auto-genera código NMLEV en sección NUEVO
  function pnAutogenBarcode() {
    const ts = Date.now().toString().slice(-6);
    const rand = Math.floor(Math.random() * 900 + 100);
    $('pnCodigoFinal').value = 'NMLEV' + ts + rand;
  }

  // Búsqueda de producto base para modo EQUIVALENTE (con normalización + multi-palabra)
  function pnBuscarBase() {
    const raw = ($('pnEquivBuscar').value || '').trim();
    const resBox = $('pnEquivResultados');
    if (!raw) { resBox.style.display = 'none'; resBox.innerHTML = ''; return; }
    if (!S.productos || !S.productos.length) {
      resBox.innerHTML = '<div class="pn-result text-slate-500 italic">Cargando catálogo... abre Catálogo primero</div>';
      resBox.style.display = 'block';
      return;
    }
    const qn = _norm(raw);
    const palabras = qn.split(/\s+/).filter(Boolean);

    // 1. Solo canónicos: factorConversion = 1 (o vacío/null que cuenta como 1)
    const canonicos = (S.productos || []).filter(p => {
      const f = parseFloat(p.factorConversion);
      return !p.factorConversion || f === 1;
    });

    // 2. Scorear contra la query (descripción, código, SKU, marca)
    const scored = canonicos.map(p => {
      const desc  = _norm(p.descripcion || '');
      const cb    = _norm(p.codigoBarra || '');
      const sku   = _norm(p.skuBase || p.idProducto || '');
      const marca = _norm(p.marca || '');
      const haystack = desc + ' ' + cb + ' ' + sku + ' ' + marca;
      let score = 0;
      let allMatch = true;
      palabras.forEach(w => {
        if (haystack.indexOf(w) >= 0) score++;
        else allMatch = false;
      });
      if (cb === qn || sku === qn) score += 100;
      if (desc.startsWith(qn))     score += 10;
      return { p, score, allMatch };
    }).filter(x => x.allMatch).sort((a, b) => b.score - a.score).slice(0, 12);

    if (!scored.length) {
      resBox.innerHTML = '<div class="pn-result text-slate-500 italic">Sin resultados para "' + raw + '"</div>';
      resBox.style.display = 'block';
      return;
    }

    resBox.innerHTML = scored.map(({ p }) => {
      const skuBase  = p.skuBase || p.idProducto;
      const safeDesc = (p.descripcion || p.idProducto).replace(/'/g, "\\'").replace(/"/g, '&quot;');
      const safeCB   = (p.codigoBarra || '').replace(/'/g, "\\'");
      return `
        <div class="pn-result" onclick="MOS.pnSeleccionarBase('${skuBase}', '${safeDesc}', '${safeCB}')">
          <div class="text-slate-200 font-medium">${p.descripcion || p.idProducto}</div>
          <div class="text-slate-500 text-xs" style="font-family:monospace">▌${p.codigoBarra || '—'} · SKU ${skuBase}</div>
        </div>`;
    }).join('');
    resBox.style.display = 'block';
  }

  function pnSeleccionarBase(skuBase, descripcion, codigoBarra) {
    $('pnEquivSkuBase').value = skuBase;
    $('pnEquivSeleccionadoNombre').textContent = `${descripcion} (${codigoBarra || skuBase})`;
    $('pnEquivSeleccionado').classList.remove('hidden');
    $('pnEquivResultados').style.display = 'none';
    $('pnEquivBuscar').value = descripcion;
  }

  async function lanzarAProduccion() {
    const btn = $('btnLanzarPN');
    const errEl = $('pnError');
    if (errEl) errEl.style.display = 'none';

    const idProductoNuevo = $('pnId')?.value?.trim();
    const idGuia          = $('pnIdGuia')?.value || '';
    const codigoOriginal  = $('pnCodigoOriginal')?.value || '';
    const cantidadFinal   = parseFloat($('pnCantidad')?.value || '0') || 0;
    const tipo            = document.querySelector('input[name="pnTipo"]:checked')?.value || 'NUEVO';
    const usuario         = S.session?.nombre || 'MOS';

    if (cantidadFinal < 0) { mostrarPNError('Cantidad inválida'); return; }

    let params = { idProductoNuevo, idGuia, codigoOriginal, cantidadFinal, tipo, usuario, aprobadoPor: usuario };

    if (tipo === 'NUEVO') {
      const desc       = $('pnDesc')?.value?.trim();
      const codigoFinal= $('pnCodigoFinal')?.value?.trim();
      const marca      = $('pnMarca')?.value?.trim();
      const unidad     = $('pnUnidad')?.value;
      const catId      = $('pnCategoria')?.value;
      const pVenta     = parseFloat($('pnPrecioVenta')?.value || '0') || 0;
      const pCosto     = parseFloat($('pnPrecioCosto')?.value || '0') || 0;
      const igv        = $('pnIGV')?.value || '1';

      if (!desc)        { mostrarPNError('La descripción es obligatoria'); return; }
      if (!codigoFinal) { mostrarPNError('El código de barras es obligatorio'); return; }
      if (!catId)       { mostrarPNError('Selecciona una categoría'); return; }
      if (pVenta <= 0)  { mostrarPNError('Precio de venta requerido'); return; }

      Object.assign(params, {
        codigoFinal, descripcion: desc, marca,
        idCategoria: catId, unidad,
        precioVenta: pVenta, precioCosto: pCosto, Tipo_IGV: igv
      });
    } else {
      const skuBase   = $('pnEquivSkuBase')?.value;
      const codigoEq  = $('pnCodigoEquiv')?.value?.trim();
      const descEq    = $('pnDescEquiv')?.value?.trim();
      if (!skuBase)   { mostrarPNError('Selecciona el producto base'); return; }
      if (!codigoEq)  { mostrarPNError('Código equivalente requerido'); return; }
      Object.assign(params, {
        codigoFinal: codigoEq, skuBase,
        descripcionEquiv: descEq
      });
    }

    if (btn) { btn.disabled = true; btn.textContent = 'Procesando...'; }
    try {
      await API.post('lanzarProductoNuevo', params);
      S.pnPendientes = (S.pnPendientes || []).filter(p => String(p.idProductoNuevo) !== String(idProductoNuevo));
      _updatePNBadge();
      renderPNBanner();
      cerrarModalPN();
      toast(tipo === 'NUEVO' ? 'Producto creado en catálogo ✓' : 'Equivalencia agregada ✓', 'ok');
      setTimeout(() => loadCatalogo(true), 800);
    } catch(e) {
      mostrarPNError(e.message || 'Error al aprobar producto');
      if (btn) { btn.disabled = false; btn.textContent = 'Aprobar y crear'; }
    }
  }

  function mostrarPNError(msg) {
    const el = $('pnError');
    if (el) { el.textContent = msg; el.style.display = 'block'; }
  }

  function abrirModalPrecioRapido(idProducto) {
    const prod = S.productos.find(p => p.idProducto === idProducto);
    if (!prod) return;
    S._editingPrecioId = idProducto;
    const nombre = $('qpNombre');
    const inp    = $('qpInput');
    if (nombre) nombre.textContent = prod.descripcion || idProducto;
    if (inp) inp.value = parseFloat(prod.precioVenta || 0).toFixed(2);
    _qpRenderPresentaciones();
    const overlay = $('modalPrecioRapido');
    if (overlay) overlay.classList.add('active');
    setTimeout(() => { if (inp) { inp.focus(); inp.select(); } }, 280);
  }

  function cerrarModalPrecioRapido() {
    const overlay = $('modalPrecioRapido');
    if (overlay) overlay.classList.remove('active');
    S._editingPrecioId = null;
  }

  // Renderiza las filas de presentaciones (llamado al abrir el modal)
  function _qpRenderPresentaciones() {
    const idProducto = S._editingPrecioId;
    const section = $('qpPresSection');
    const list    = $('qpPresList');
    if (!section || !list) return;

    const prod  = S.productos.find(p => p.idProducto === idProducto);
    const sku   = prod ? (prod.skuBase || prod.idProducto) : idProducto;
    const grupo = _catGroups ? _catGroups[sku] : null;

    if (!grupo || !grupo.pres || !grupo.pres.length || !grupo.base || grupo.base.idProducto !== idProducto) {
      section.classList.add('hidden');
      list.innerHTML = '';
      return;
    }

    const precioBase = parseFloat($('qpInput')?.value || '0') || 0;
    section.classList.remove('hidden');
    list.innerHTML = grupo.pres.map((p, i) => {
      const factor   = parseFloat(p.factorConversion) || 1;
      const sugerido = precioBase * factor;
      const actual   = parseFloat(p.precioVenta) || 0;
      return `<label class="ajuste-row cursor-pointer" style="padding:.4rem .65rem">
        <input type="checkbox" class="ajuste-check" id="qpPres${i}"
               data-id="${p.idProducto}" data-factor="${factor}" checked>
        <div class="ajuste-info min-w-0">
          <div class="ajuste-name truncate" style="font-size:.74rem">${p.descripcion || p.idProducto}</div>
          <div class="ajuste-factor">×${factor}</div>
        </div>
        <div class="ajuste-prices">
          <div class="ajuste-current">${fmtMoney(actual)}</div>
          <div class="ajuste-suggest" id="qpSug${i}">→ ${fmtMoney(sugerido)}</div>
        </div>
      </label>`;
    }).join('');
  }

  // Actualiza solo los precios sugeridos mientras el usuario escribe (sin re-renderizar)
  function _qpSyncPresentaciones() {
    const idProducto = S._editingPrecioId;
    if (!idProducto) return;
    const precio = parseFloat($('qpInput')?.value || '0') || 0;
    const prod   = S.productos.find(p => p.idProducto === idProducto);
    const sku    = prod ? (prod.skuBase || prod.idProducto) : idProducto;
    const grupo  = _catGroups ? _catGroups[sku] : null;
    if (!grupo || !grupo.pres) return;
    grupo.pres.forEach((p, i) => {
      const factor   = parseFloat(p.factorConversion) || 1;
      const sugerido = precio * factor;
      const sug = $(`qpSug${i}`);
      if (sug) sug.textContent = '→ ' + fmtMoney(sugerido);
    });
  }

  async function guardarPrecioRapido() {
    const idProducto = S._editingPrecioId;
    if (!idProducto) return;
    const inp    = $('qpInput');
    const precio = parseFloat(inp ? inp.value : '');
    if (isNaN(precio) || precio < 0) { toast('Precio inválido', 'error'); return; }

    // Recoger presentaciones seleccionadas
    const checks = document.querySelectorAll('#qpPresList input[type=checkbox]:checked');
    const updates = [{ idProducto, precio }];
    checks.forEach(cb => {
      const factor   = parseFloat(cb.dataset.factor) || 1;
      updates.push({ idProducto: cb.dataset.id, precio: parseFloat((precio * factor).toFixed(2)) });
    });

    // Snapshot para rollback
    const prev = updates.map(u => {
      const p = S.productos.find(x => x.idProducto === u.idProducto);
      return { idProducto: u.idProducto, precio: p ? p.precioVenta : null };
    });

    // Optimistic update inmediato — todo en memoria de golpe
    updates.forEach(u => {
      const p = S.productos.find(x => x.idProducto === u.idProducto);
      if (p) p.precioVenta = u.precio;
    });
    _catSaveCache({ productos: S.productos, equivMap: S.equivMap });
    cerrarModalPrecioRapido();
    renderCatalogo(); // inmediato, sin esperar al GAS

    // API en paralelo en background
    try {
      await Promise.all(updates.map(u =>
        API.post('publicarPrecio', { _source: 'MOS_MODAL_PRECIO', idProducto: u.idProducto, precioNuevo: u.precio })
      ));
      const n = updates.length;
      toast(n > 1 ? `${n} precios actualizados` : 'Precio actualizado', 'ok');
    } catch(e) {
      prev.forEach(snap => {
        if (snap.precio === null) return;
        const p = S.productos.find(x => x.idProducto === snap.idProducto);
        if (p) p.precioVenta = snap.precio;
      });
      _catSaveCache({ productos: S.productos, equivMap: S.equivMap });
      toast('Error al guardar: ' + e.message, 'error');
      renderCatalogo();
    }
  }

  function _abrirAjustePrecios(idBase, nuevoPrecioBase, presentaciones) {
    $('ajusteBasePrecio').textContent = fmtMoney(nuevoPrecioBase);
    S._ajusteBase = { idBase, nuevoPrecioBase };
    const list = $('ajusteList');
    list.innerHTML = presentaciones.map((p, i) => {
      const factor   = parseFloat(p.factorConversion) || 1;
      const sugerido = nuevoPrecioBase * factor;
      const actual   = parseFloat(p.precioVenta) || 0;
      const id       = `ajCheck${i}`;
      return `<label class="ajuste-row cursor-pointer" for="${id}">
        <input type="checkbox" class="ajuste-check" id="${id}"
               data-id="${p.idProducto}" data-precio="${sugerido.toFixed(2)}" checked>
        <div class="ajuste-info min-w-0">
          <div class="ajuste-name truncate">${p.descripcion || p.idProducto}</div>
          <div class="ajuste-factor">Factor ×${factor} · ${p.unidad || 'UND'}</div>
        </div>
        <div class="ajuste-prices">
          <div class="ajuste-current">${fmtMoney(actual)}</div>
          <div class="ajuste-suggest">→ ${fmtMoney(sugerido)}</div>
        </div>
      </label>`;
    }).join('');
    openModal('modalAjustePrecios');
  }

  async function guardarAjustePrecios() {
    const checks = document.querySelectorAll('#ajusteList input[type=checkbox]:checked');
    if (!checks.length) { closeModal('modalAjustePrecios'); return; }
    const updates = [];
    checks.forEach(cb => updates.push({ idProducto: cb.dataset.id, precio: parseFloat(cb.dataset.precio) }));

    try {
      await Promise.all(updates.map(u =>
        API.post('publicarPrecio', { _source: 'MOS_MODAL_PRECIO', idProducto: u.idProducto, precioNuevo: u.precio })
          .then(() => {
            const p = S.productos.find(x => x.idProducto === u.idProducto);
            if (p) p.precioVenta = u.precio;
          })
      ));
      _catSaveCache({ productos: S.productos, equivMap: S.equivMap });
      toast(`${updates.length} precio${updates.length > 1 ? 's' : ''} actualizados`, 'ok');
      closeModal('modalAjustePrecios');
      renderCatalogo();
    } catch(e) {
      toast('Error al actualizar: ' + e.message, 'error');
    }
  }

  // ── ANALÍTICA DE PRODUCTO ───────────────────────────────────
  let _anState = { idProducto: null, dias: 30, data: null, charts: {} };

  function _anCurrentId() { return _anState.idProducto; }

  function stepperInc(id, step) {
    const el = $(id); if (!el) return;
    el.value = (parseFloat(el.value) || 0) + step;
    el.dispatchEvent(new Event('input'));
  }
  function stepperDec(id, step) {
    const el = $(id); if (!el) return;
    el.value = Math.max(0, (parseFloat(el.value) || 0) - step);
    el.dispatchEvent(new Event('input'));
  }

  function abrirAnalitica(idProducto) {
    _anState.idProducto = idProducto;
    _anState.dias = 30;
    _anState.data = null;
    // Mostrar nombre mientras carga
    const prod = S.productos.find(p => p.idProducto === idProducto);
    const lbl  = $('anLoadLabel');
    if (lbl && prod) lbl.textContent = prod.descripcion || 'Cargando analítica…';
    // Reset period buttons
    ['7','30','90'].forEach(d => {
      const b = $('anP' + d);
      if (b) b.classList.toggle('active', d === '30');
    });
    // Mostrar overlay
    const overlay = $('viewAnalitica');
    if (overlay) overlay.classList.add('active');
    document.body.style.overflow = 'hidden';
    // Mostrar loading
    $('anLoading').classList.remove('hidden');
    $('anContent').classList.add('hidden');
    _cargarAnalitica();
  }

  function cerrarAnalitica() {
    const overlay = $('viewAnalitica');
    if (overlay) overlay.classList.remove('active');
    document.body.style.overflow = '';
    // Destruir charts para liberar memoria
    Object.values(_anState.charts).forEach(c => { try { c.destroy(); } catch {} });
    _anState.charts = {};
  }

  function setAnPeriodo(dias) {
    _anState.dias = dias;
    ['7','30','90'].forEach(d => {
      const b = $('anP' + d);
      if (b) b.classList.toggle('active', String(d) === String(dias));
    });
    $('anLoading').classList.remove('hidden');
    $('anContent').classList.add('hidden');
    _cargarAnalitica();
  }

  async function _cargarAnalitica() {
    try {
      const d = await API.get('getAnaliticaProducto', {
        idProducto: _anState.idProducto,
        dias:       String(_anState.dias)
      });
      _anState.data = d;
      _renderAnalitica(d);
    } catch(e) {
      $('anLoading').innerHTML = `<div class="text-red-400 text-sm">Error: ${e.message}</div>`;
    }
  }

  function _renderAnalitica(d) {
    const p = d.producto;

    // Header
    $('anNombreProd').textContent  = p.descripcion;
    $('anSubtitleProd').textContent = `${p.idCategoria || 'Producto'} · ${_anState.dias}D`;

    // Conexiones badges
    const cb = $('anConexBadges');
    if (cb) {
      cb.classList.remove('hidden');
      cb.innerHTML = `
        <span class="an-conn-badge ${d.conexiones.me ? 'an-conn-on' : 'an-conn-off'}">ME ${d.conexiones.me ? '●' : '○'}</span>
        <span class="an-conn-badge ${d.conexiones.wh ? 'an-conn-on' : 'an-conn-off'}">WH ${d.conexiones.wh ? '●' : '○'}</span>`;
    }

    // Stock min/max en action bar
    const ami = $('anEditStockMin'), amx = $('anEditStockMax');
    if (ami) ami.value = p.stockMinimo || 0;
    if (amx) amx.value = p.stockMaximo || 0;
    ['anUndMin','anUndMax'].forEach(id => { const el = $(id); if (el) el.textContent = p.unidad; });

    // ── KPIs ────────────────────────────────────────────────────
    const dias = _anState.dias;
    const prom = d.ventas.totalUnidades > 0 ? (d.ventas.totalImporte / d.ventas.totalUnidades).toFixed(2) : '—';
    const margenColor = d.financiero.margenPct >= 30 ? '#22c55e' : d.financiero.margenPct >= 15 ? '#f59e0b' : '#ef4444';
    const stockColor  = d.stock.total <= d.stock.minimo ? '#ef4444'
                      : d.stock.total < d.stock.maximo  ? '#f59e0b' : '#22c55e';
    const cobColor    = !d.proyeccion.coberturaDias ? '#64748b'
                      : d.proyeccion.coberturaDias < 7  ? '#ef4444'
                      : d.proyeccion.coberturaDias < 14 ? '#f59e0b' : '#22c55e';

    $('anKpis').innerHTML = [
      { label: `Vendidas (${dias}D)`, value: _fmt(d.ventas.totalUnidades, 1), sub: `${p.unidad} · ${d.ventas.promDia.toFixed(1)}/día`, color: '#6366f1', icon: '📦' },
      { label: `Ingresos (${dias}D)`, value: fmtMoney(d.ventas.totalImporte), sub: `S/. ${prom} precio prom.`, color: '#f59e0b', icon: '💵' },
      { label: 'Utilidad bruta',      value: fmtMoney(d.financiero.utilidadBruta), sub: `${d.financiero.margenPct.toFixed(1)}% margen`, color: margenColor, icon: '📊' },
      { label: 'Stock actual',         value: _fmt(d.stock.total, 1), sub: `Min ${d.stock.minimo} · Max ${d.stock.maximo}`, color: stockColor, icon: '🏭' },
      { label: 'Cobertura',            value: d.proyeccion.coberturaDias !== null ? d.proyeccion.coberturaDias + 'd' : 'N/D', sub: `Proyección ${_fmt(d.proyeccion.unidades30dias,0)} uds/30D`, color: cobColor, icon: '📅' }
    ].map(k => `
      <div class="an-kpi" style="--kpi-color:${k.color}">
        <div class="an-kpi-icon">${k.icon}</div>
        <div class="an-kpi-label">${k.label}</div>
        <div class="an-kpi-value">${k.value}</div>
        <div class="an-kpi-sub">${k.sub}</div>
      </div>`).join('');

    // ── Chart Ventas ────────────────────────────────────────────
    if (_anState.charts.ventas) { _anState.charts.ventas.destroy(); delete _anState.charts.ventas; }
    const ctxV = $('chartVentas');
    if (ctxV) {
      const labels = d.ventas.serie.map(v => v.fecha.substring(5));
      const gradU  = ctxV.getContext('2d').createLinearGradient(0, 0, 0, 180);
      gradU.addColorStop(0, 'rgba(99,102,241,.35)');
      gradU.addColorStop(1, 'rgba(99,102,241,.01)');
      _anState.charts.ventas = new Chart(ctxV.getContext('2d'), {
        data: {
          labels,
          datasets: [
            { type: 'bar',  label: 'Unidades', data: d.ventas.serie.map(v => v.u),
              backgroundColor: 'rgba(99,102,241,.3)', borderColor: '#6366f1', borderRadius: 3, borderWidth: 1, yAxisID: 'y' },
            { type: 'line', label: 'Ingresos',  data: d.ventas.serie.map(v => v.imp),
              borderColor: '#f59e0b', tension: .45, pointRadius: 0, borderWidth: 2,
              fill: false, yAxisID: 'y2' }
          ]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            legend: { display: false },
            tooltip: {
              backgroundColor: '#0f172a', borderColor: '#334155', borderWidth: 1,
              callbacks: {
                label: ctx => ctx.datasetIndex === 0
                  ? ` ${ctx.parsed.y.toFixed(1)} ${p.unidad}`
                  : ` S/. ${ctx.parsed.y.toFixed(2)}`
              }
            }
          },
          scales: {
            x:  { grid: { color: '#0d1526' }, ticks: { color: '#475569', font: { size: 10 }, maxRotation: 0, maxTicksLimit: 8 } },
            y:  { grid: { color: '#1e293b' }, ticks: { color: '#6366f1', font: { size: 10 } }, beginAtZero: true },
            y2: { position: 'right', grid: { display: false }, ticks: { color: '#f59e0b', font: { size: 10 } }, beginAtZero: true }
          }
        }
      });
    }

    // ── Stock Gauge ─────────────────────────────────────────────
    const maximo  = d.stock.maximo || Math.max(d.stock.total * 1.5, 1);
    const fill    = Math.min(100, d.stock.total / maximo * 100);
    const minPct  = Math.min(100, d.stock.minimo / maximo * 100);
    const fillEl  = $('anGaugeFill');
    const numEl   = $('anStockNum');
    if (fillEl)   { fillEl.style.width = fill + '%'; fillEl.style.background = stockColor; }
    if (numEl)    { numEl.textContent = _fmt(d.stock.total, 1); numEl.style.color = stockColor; }
    const undEl = $('anStockUnd'); if (undEl) undEl.textContent = p.unidad;
    const zEl   = $('anStockZonas'); if (zEl) zEl.textContent = d.stock.zonas.length ? `${d.stock.zonas.length} zona${d.stock.zonas.length > 1 ? 's' : ''}` : 'Sin datos de WH';
    const minM  = $('anGaugeMin'); if (minM) { minM.style.left = minPct + '%'; $('anGaugeMinLbl').textContent = 'Mín ' + d.stock.minimo; }
    const maxM  = $('anGaugeMax');
    if (maxM) { maxM.style.left = '100%'; $('anGaugeMaxLbl').textContent = 'Máx ' + (d.stock.maximo || '—'); }

    const zonasList = $('anStockZonasList');
    if (zonasList) {
      zonasList.innerHTML = d.stock.zonas.length
        ? d.stock.zonas.map(z => `
            <div class="flex justify-between items-center text-xs py-1 border-b border-slate-800/60">
              <span class="text-slate-400">${z.idZona || 'Zona'}</span>
              <span class="font-bold text-slate-200">${_fmt(z.cantidadDisponible, 1)} ${p.unidad}</span>
            </div>`).join('')
        : '<div class="text-xs text-slate-600 italic">warehouseMos no conectado</div>';
    }

    // ── Ring margen ─────────────────────────────────────────────
    const ring = $('anRingFill');
    if (ring) {
      const circ = 251.2;
      const offset = circ - (Math.min(100, d.financiero.margenPct) / 100 * circ);
      ring.style.strokeDashoffset = offset;
      ring.style.stroke = margenColor;
    }
    $('anMargenPct').textContent = d.financiero.margenPct.toFixed(1) + '%';
    $('anRentRows').innerHTML = [
      { label: 'Precio venta',   value: fmtMoney(p.precioVenta) },
      { label: 'Precio costo',   value: fmtMoney(p.precioCosto) },
      { label: 'Utilidad/unidad',value: fmtMoney(p.precioVenta - p.precioCosto) },
      { label: `Utilidad (${dias}D)`, value: fmtMoney(d.financiero.utilidadBruta), bold: true }
    ].map(r => `
      <div class="an-proj-row">
        <span class="an-proj-label">${r.label}</span>
        <span class="an-proj-val${r.bold ? ' highlight' : ''}">${r.value}</span>
      </div>`).join('');

    // ── Proyección ───────────────────────────────────────────────
    const proy = d.proyeccion;
    const sugerClass = proy.sugerirComprar > 0 ? 'danger' : 'ok';
    $('anProyRows').innerHTML = [
      { label: 'Promedio diario',    value: proy.promDia.toFixed(1) + ' ' + p.unidad + '/día' },
      { label: 'Proyección 30 días', value: _fmt(proy.unidades30dias, 0) + ' ' + p.unidad, bold: true },
      { label: 'Stock hoy',          value: _fmt(d.stock.total, 1) + ' ' + p.unidad },
      { label: 'Sugerir comprar',    value: _fmt(proy.sugerirComprar, 0) + ' ' + p.unidad, cls: sugerClass, bold: true },
      { label: 'Cobertura estimada', value: proy.coberturaDias !== null ? proy.coberturaDias + ' días' : 'Sin ventas', cls: cobColor === '#ef4444' ? 'danger' : cobColor === '#f59e0b' ? 'highlight' : 'ok' }
    ].map(r => `
      <div class="an-proj-row">
        <span class="an-proj-label">${r.label}</span>
        <span class="an-proj-val${r.bold ? ' font-bold' : ''} ${r.cls || ''}">${r.value}</span>
      </div>`).join('');

    // ── Chart Precios ────────────────────────────────────────────
    if (_anState.charts.precios) { _anState.charts.precios.destroy(); delete _anState.charts.precios; }
    const ctxPr = $('chartPrecios');
    if (ctxPr && d.historialPrecios.length > 1) {
      _anState.charts.precios = new Chart(ctxPr.getContext('2d'), {
        type: 'line',
        data: {
          labels: d.historialPrecios.map(h => String(h.fecha || '').substring(5)),
          datasets: [
            { label: 'Precio venta', data: d.historialPrecios.map(h => h.nuevoPrecio || h.precioVenta || 0),
              borderColor: '#818cf8', tension: .3, pointRadius: 3, borderWidth: 2, fill: false }
          ]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          scales: {
            x: { grid: { color: '#0d1526' }, ticks: { color: '#475569', font: { size: 9 } } },
            y: { grid: { color: '#1e293b' }, ticks: { color: '#475569', font: { size: 9 } } }
          }
        }
      });
    } else if (ctxPr) {
      ctxPr.closest('.an-card').querySelector('.an-card-title').insertAdjacentHTML('afterend',
        '<div class="text-xs text-slate-600 italic py-4 text-center">Sin historial de precios</div>');
      ctxPr.style.display = 'none';
    }

    // ── Compras ──────────────────────────────────────────────────
    const comprasEl = $('anComprasList');
    if (comprasEl) {
      const pedidos = d.compras.pedidos;
      $('anComprasCount').textContent = pedidos.length ? `(${pedidos.length})` : '';
      if (!pedidos.length) {
        comprasEl.innerHTML = '<div class="text-xs text-slate-600 italic py-3">Sin pedidos registrados en el período</div>';
      } else {
        comprasEl.innerHTML = pedidos.map(ped => {
          const estadoClass = ped.estado === 'RECIBIDO' ? 'badge-green' : ped.estado === 'BORRADOR' ? 'badge-gray' : 'badge-yellow';
          return `<div class="an-compra-row">
            <span class="an-compra-fecha">${ped.fecha.substring(5) || '—'}</span>
            <span class="an-compra-qty">${_fmt(ped.cantidad, 1)} uds</span>
            <span class="an-compra-cost">${ped.costo > 0 ? fmtMoney(ped.costo) : '—'}</span>
            <span class="an-compra-estado badge ${estadoClass}">${ped.estado || 'BORRADOR'}</span>
          </div>`;
        }).join('');

        // Mini chart de compras si hay suficientes datos
        if (pedidos.length >= 3) {
          const cwrap = $('chartComprasWrap');
          if (cwrap) cwrap.style.display = 'block';
          if (_anState.charts.compras) { _anState.charts.compras.destroy(); delete _anState.charts.compras; }
          const ctxC = $('chartCompras');
          if (ctxC) {
            _anState.charts.compras = new Chart(ctxC.getContext('2d'), {
              type: 'bar',
              data: {
                labels: pedidos.slice(0,10).map(p => p.fecha.substring(5)),
                datasets: [
                  { label: 'Cant. comprada', data: pedidos.slice(0,10).map(p => p.cantidad),
                    backgroundColor: 'rgba(245,158,11,.3)', borderColor: '#f59e0b', borderWidth: 1, borderRadius: 3 }
                ]
              },
              options: {
                responsive: true, maintainAspectRatio: false,
                plugins: { legend: { display: false } },
                scales: {
                  x: { grid: { display: false }, ticks: { color: '#475569', font: { size: 9 } } },
                  y: { grid: { color: '#1e293b' }, ticks: { color: '#f59e0b', font: { size: 9 } }, beginAtZero: true }
                }
              }
            });
          }
        }
      }
    }

    // ── Proveedores ──────────────────────────────────────────────
    const provEl = $('anProvList');
    const provColors = ['#6366f1','#f59e0b','#22c55e','#ec4899','#14b8a6'];
    if (provEl) {
      if (!d.compras.proveedores.length) {
        provEl.innerHTML = '<div class="text-xs text-slate-600 italic py-3">Sin proveedores vinculados en pedidos</div>';
      } else {
        provEl.innerHTML = d.compras.proveedores.map((pr, i) => `
          <div class="an-prov-row">
            <div class="an-prov-dot" style="background:${provColors[i % provColors.length]}"></div>
            <span class="an-prov-name">${pr.nombre}</span>
            <span class="an-prov-forma">${pr.formaPago || '—'}</span>
          </div>`).join('');
      }
    }

    // Costo prom histórico proveedores
    const psEl = $('anProvStats');
    if (psEl && d.compras.pedidos.length) {
      const costos = d.compras.pedidos.filter(p => p.costo > 0).map(p => p.costo);
      if (costos.length) {
        const promCosto = costos.reduce((a, b) => a + b, 0) / costos.length;
        const minCosto  = Math.min(...costos);
        const maxCosto  = Math.max(...costos);
        psEl.innerHTML = `
          <div class="text-xs text-slate-500 font-semibold uppercase tracking-wider mb-2">Histórico de costos</div>
          <div class="flex gap-3 flex-wrap">
            <div><div class="text-xs text-slate-600">Mínimo</div><div class="text-sm font-bold text-green-400">${fmtMoney(minCosto)}</div></div>
            <div><div class="text-xs text-slate-600">Promedio</div><div class="text-sm font-bold text-slate-200">${fmtMoney(promCosto)}</div></div>
            <div><div class="text-xs text-slate-600">Máximo</div><div class="text-sm font-bold text-red-400">${fmtMoney(maxCosto)}</div></div>
          </div>`;
      }
    }

    // Mostrar contenido
    $('anLoading').classList.add('hidden');
    $('anContent').classList.remove('hidden');
  }

  async function guardarStockMinMax() {
    const id  = _anState.idProducto;
    const min = parseFloat($('anEditStockMin')?.value) || 0;
    const max = parseFloat($('anEditStockMax')?.value) || 0;
    if (!id) return;
    if (max > 0 && min > max) { toast('El mínimo no puede superar el máximo', 'error'); return; }
    try {
      await API.post('actualizarProducto', { _source: 'MOS_MODAL_PRODUCTO', idProducto: id, stockMinimo: min, stockMaximo: max });
      // Actualizar en memoria
      const p = S.productos.find(x => x.idProducto === id);
      if (p) { p.stockMinimo = min; p.stockMaximo = max; }
      toast('Stock mín/máx actualizado', 'ok');
      // Recargar analítica para reflejar cambio en gauge
      if (_anState.data) {
        _anState.data.producto.stockMinimo = min;
        _anState.data.producto.stockMaximo = max;
        _anState.data.stock.minimo = min;
        _anState.data.stock.maximo = max;
        _renderAnalitica(_anState.data);
      }
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  // Helpers
  function _fmt(val, decimals) {
    const n = parseFloat(val || 0);
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return n.toFixed(decimals);
  }

  // ── ALMACÉN ─────────────────────────────────────────────────
  async function loadAlmacen(forceRefresh) {
    if (!API.isConfigured()) return;
    const params = forceRefresh ? { _refresh: 'true' } : {};
    const params7 = forceRefresh ? { dias: 7, _refresh: 'true' } : { dias: 7 };
    const [catalogoRes, alertasRes, mermasRes, envRes] = await Promise.allSettled([
      API.get('getCatalogoStockResumen', params7),
      API.get('getAlertasWarehouse', {}),
      API.get('getMermasWarehouse', {}),
      API.get('getEnvasadosWarehouse', { limit: '50' })
    ]);
    if (catalogoRes.status === 'fulfilled') {
      const v = catalogoRes.value || {};
      S.catalogoStock = (v.productos) || [];
      S._catalogoGasOld = !v._almV || v._almV < 2;
    }
    if (alertasRes.status === 'fulfilled') S.vencimientos = alertasRes.value || { criticos: [], alertas: [] };
    if (mermasRes.status === 'fulfilled') S.mermas = mermasRes.value || [];
    if (envRes.status === 'fulfilled')    S.envasados = envRes.value || [];
    S.loaded['almacen'] = true;
    renderAlmTab(S.almTab);
  }

  async function almRefreshCatalogo() {
    toast('Refrescando catálogo de stock…', 'info');
    await loadAlmacen(true);
  }

  function setAlmTab(tab) {
    S.almTab = tab;
    ['resumen','stock','ops','zonas','venc','merma','env'].forEach(t => {
      const b = $('almTab' + t.charAt(0).toUpperCase() + t.slice(1));
      if (b) b.classList.toggle('active', t === tab);
      const p = $('almPanel' + t.charAt(0).toUpperCase() + t.slice(1));
      if (p) p.classList.toggle('hidden', t !== tab);
    });
    if (!S.loaded['almacen']) { loadAlmacen(); return; }
    renderAlmTab(tab);
  }

  function renderAlmTab(tab) {
    if (tab === 'resumen') almLoadResumen();
    if (tab === 'stock') renderStockTable();
    if (tab === 'ops')   almLoadOps();
    if (tab === 'zonas') almLoadZonas();
    if (tab === 'venc')  renderVencTable();
    if (tab === 'merma') renderMermasTable();
    if (tab === 'env')   renderEnvTable();
  }

  // ── ALMACÉN: pre-fetch al loguear para que el cache esté tibio ──
  function _prefetchAlmacen() {
    // Esperar 3s después del init para no competir con otras pre-cargas
    setTimeout(() => {
      if (!S.session) return;
      // Disparamos los 4 endpoints más usados sin esperar respuesta
      // CacheService los guardará → la próxima visita es instantánea
      const tasks = [
        () => API.get('getDashboardAlmacen', {}),
        () => API.get('getAlertasOperativas', {}),
        () => API.get('getGuiasYPreingresos', { dias: 7 }),
        () => API.get('getInsightsStock', { dias: 30 })
      ];
      tasks.forEach(t => t().catch(() => {}));
    }, 3000);
  }

  // ── ALMACÉN: RESUMEN (KPIs + insights + alertas operativas) ──
  async function almLoadResumen() {
    const [dashRes, insightsRes, alertasRes] = await Promise.allSettled([
      API.get('getDashboardAlmacen', {}),
      API.get('getInsightsStock', { dias: 30 }),
      API.get('getAlertasOperativas', {})
    ]);
    // KPIs
    if (dashRes.status === 'fulfilled') _almRenderKPIs(dashRes.value || {});
    else _almRenderKPIsError(dashRes.reason);
    // Insights
    if (insightsRes.status === 'fulfilled') _almRenderInsights((insightsRes.value || {}).insights || []);
    else _almRenderInsightsError(insightsRes.reason);
    // Alertas
    if (alertasRes.status === 'fulfilled') _almRenderAlertasOps((alertasRes.value || {}).alertas || []);
    else _almRenderAlertasOpsError(alertasRes.reason);
  }

  function _almRenderKPIsError(err) {
    const msg = err && err.message ? err.message : String(err || 'error');
    ['almKpiValor','almKpiCriticos','almKpiVenc','almKpiMermas'].forEach(id => { const el = $(id); if (el) el.textContent = '⚠'; });
    console.warn('[almLoadResumen] dashboard error:', msg);
  }
  function _almRenderInsightsError(err) {
    const el = $('almInsights'); if (!el) return;
    const msg = err && err.message ? err.message : String(err || 'error');
    el.innerHTML = `<div class="text-xs text-rose-400 italic py-3 text-center">⚠ ${msg}</div>
      <div class="text-[10px] text-slate-600 italic text-center">¿GAS de MOS desplegado como Nueva versión?</div>`;
  }
  function _almRenderAlertasOpsError(err) {
    const el = $('almAlertasOps'); if (!el) return;
    const msg = err && err.message ? err.message : String(err || 'error');
    el.innerHTML = `<div class="text-xs text-rose-400 italic py-3 text-center">⚠ ${msg}</div>`;
  }
  async function almRefreshResumen() {
    try { await API.get('bustAlmacenCache', {}); } catch(_){}
    toast('Cache limpiado, recargando…', 'info');
    almLoadResumen();
  }

  function _almRenderKPIs(data) {
    if ($('almKpiValor'))    $('almKpiValor').textContent    = 'S/ ' + (data.stockValor || 0).toLocaleString('es-PE', { maximumFractionDigits: 0 });
    if ($('almKpiCriticos')) $('almKpiCriticos').textContent = data.productosCriticos || 0;
    if ($('almKpiVenc'))     $('almKpiVenc').textContent     = data.vencCriticos || 0;
    if ($('almKpiMermas'))   $('almKpiMermas').textContent   = 'S/ ' + (data.mermasMes || 0).toLocaleString('es-PE', { maximumFractionDigits: 0 });
  }

  function _almRenderInsights(insights) {
    const el = $('almInsights'); if (!el) return;
    if (!insights || !insights.length) {
      el.innerHTML = '<div class="text-xs text-slate-600 italic py-3 text-center">✅ Sin sugerencias por ahora — todo en orden</div>';
      return;
    }
    const sevColor = { CRITICA: 'rose', ALTA: 'amber', MEDIA: 'indigo', BAJA: 'slate' };
    const sevIcon  = { CRITICA: '🚨', ALTA: '⚠️', MEDIA: '💡', BAJA: 'ℹ️' };
    el.innerHTML = insights.map(i => {
      const c = sevColor[i.severidad] || 'slate';
      const icon = sevIcon[i.severidad] || '•';
      // Botón "Crear pedido" para insights de reposición
      let actionBtn = '';
      if ((i.tipo === 'REPOSICION' || i.tipo === 'BAJO_MINIMO') && i.idProducto) {
        const safeDesc = (i.producto || '').replace(/'/g, "\\'");
        actionBtn = `<button class="btn-primary text-xs px-2 py-1 mt-2" onclick="MOS._almGenerarPedidoFromInsight('${i.idProducto}','${safeDesc}','','')">📋 Crear pedido borrador</button>`;
      }
      return `<div class="card-sm border-${c}-500/30 p-3" style="border-left:3px solid var(--accent)">
        <div class="flex items-start gap-2">
          <span>${icon}</span>
          <div class="flex-1 min-w-0">
            <div class="text-sm text-slate-200 font-medium">${i.mensaje}</div>
            ${i.accion ? `<div class="text-xs text-slate-500 mt-1">→ ${i.accion}</div>` : ''}
            ${actionBtn}
          </div>
          <span class="text-[10px] text-slate-600 font-mono shrink-0">${i.tipo || ''}</span>
        </div>
      </div>`;
    }).join('');
  }

  function _almRenderAlertasOps(alertas) {
    const el = $('almAlertasOps'); if (!el) return;
    if (!alertas || !alertas.length) {
      el.innerHTML = '<div class="text-xs text-slate-600 italic py-3 text-center">✅ Sin alertas operativas</div>';
      return;
    }
    const sevColor = { CRITICA: 'rose', ALTA: 'amber', MEDIA: 'indigo' };
    el.innerHTML = alertas.map(a => `
      <div class="card-sm p-3 border-${sevColor[a.severidad] || 'slate'}-500/30" style="border-left:3px solid #f59e0b">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <div class="text-sm font-semibold text-slate-200">${a.mensaje}</div>
            ${a.topItems ? `<div class="text-xs text-slate-500 mt-1">${a.topItems.slice(0,3).map(t => t.descripcion || t.codigoProducto).join(' · ')}${a.topItems.length > 3 ? ' …' : ''}</div>` : ''}
          </div>
          <span class="badge badge-${a.severidad === 'CRITICA' ? 'red' : 'yellow'} text-xs shrink-0">${a.cantidad}</span>
        </div>
      </div>
    `).join('');
  }

  // ── ALMACÉN: STOCK con barras + búsqueda ──
  function almFiltrarStock(q) {
    if (q !== undefined) S.almStockFilter = q;
    renderStockTable();
  }

  // ── ALMACÉN: OPERACIONES UNIFICADAS (WH + zonas) por día ──
  S._opsData = S._opsData || null;
  S._opsExpanded = S._opsExpanded || {};
  S._opsDetCache = S._opsDetCache || {};

  async function almLoadOps(forceRefresh) {
    const dias = parseInt($('almGuiasFiltro')?.value) || 7;
    const params = { dias };
    if (forceRefresh) params._refresh = 'true';
    try {
      // Llamamos en paralelo: operaciones unificadas + guias/preing (para resumen y preingresos)
      const [opsRes, gpRes] = await Promise.allSettled([
        API.get('getOperacionesUnificadas', params),
        API.get('getGuiasYPreingresos', params)
      ]);
      // Resumen del día (KPIs) + badge de preingresos pendientes
      if (gpRes.status === 'fulfilled') {
        const r = gpRes.value || {};
        const res = r.resumen || {};
        if ($('opsIngHoy'))   $('opsIngHoy').textContent   = res.ingresosHoy || 0;
        if ($('opsDesHoy'))   $('opsDesHoy').textContent   = res.despachosHoy || 0;
        if ($('opsEnvHoy'))   $('opsEnvHoy').textContent   = res.envasadosHoy || 0;
        if ($('opsMontoHoy')) $('opsMontoHoy').textContent = 'S/ ' + (res.montoIngresoHoy || 0).toLocaleString('es-PE', { maximumFractionDigits: 0 });
        // Solo mostramos un BADGE pequeño con el count, sin lista (ya aparecen en flujo)
        const preing = r.preingresosPendientes || [];
        const badge = $('almPreingBadge');
        if (badge) badge.classList.toggle('hidden', !preing.length);
        if ($('opsPreingCount')) $('opsPreingCount').textContent = preing.length;
      }
      // Operaciones unificadas
      if (opsRes.status === 'fulfilled') {
        S._opsData = opsRes.value || {};
        almRenderOps();
      } else {
        const lst = $('almOpsList');
        if (lst) lst.innerHTML = '<div class="text-xs text-rose-400 py-3 text-center">Error cargando operaciones</div>';
      }
    } catch(e) {
      console.warn('[almLoadOps] error:', e);
    }
  }

  async function almRefreshOps() {
    toast('Refrescando operaciones…', 'info');
    await almLoadOps(true);
  }

  function almRenderOps() {
    const list = $('almOpsList');
    if (!list) return;
    const data = S._opsData || {};
    const dias = data.porDia || [];
    const debugInfo = data._debug;
    // Sección debug colapsable al final
    const debugHtml = debugInfo ? `
      <details class="mt-3 text-[10px] text-slate-600">
        <summary class="cursor-pointer hover:text-slate-400">🔍 Debug fechas (verifica timezone)</summary>
        <div class="mt-1 p-2 rounded font-mono whitespace-pre-wrap" style="background:#060d1f;border:1px solid #1e293b">
          <div>Server TZ: <span class="text-emerald-300">${debugInfo.timezone}</span></div>
          <div>Server now: ${debugInfo.nowLocal} (${debugInfo.nowIso})</div>
          <div class="mt-1 text-slate-500">Últimas 3 fechas WH parseadas:</div>
          ${(debugInfo.primerasFechasWh || []).map(f =>
            `· raw="${f.raw}" → ${f.local} (${f.parsed})`
          ).join('<br>')}
        </div>
      </details>` : '';
    if (!dias.length) {
      list.innerHTML = '<div class="text-xs text-slate-600 italic py-3 text-center">Sin operaciones en el rango</div>' + debugHtml;
      return;
    }
    const filtroFuente = $('almOpsFiltroFuente')?.value || '';
    list.innerHTML = dias.map(dia => {
      const ops = dia.operaciones.filter(op => !filtroFuente || op.fuente === filtroFuente);
      if (!ops.length) return '';
      // Sub-agrupar por fuente: WH vs zonas (con sus canon)
      const byFuente = { WH: [], zonas: {} };
      ops.forEach(op => {
        if (op.fuente === 'WH') byFuente.WH.push(op);
        else {
          const zk = op.idZonaCanonId || 'sin-zona';
          if (!byFuente.zonas[zk]) byFuente.zonas[zk] = { nombre: op.idZonaCanonNom || op.idZona || 'Sin zona', ops: [] };
          byFuente.zonas[zk].ops.push(op);
        }
      });
      const fechaDisp = _formatFechaCorta(dia.fecha);
      const headerHtml = `<div class="flex items-center justify-between mb-2 sticky top-0 z-5" style="background:#0a1428;padding:6px 0">
          <div class="text-sm font-semibold text-slate-200">📅 ${fechaDisp}</div>
          <div class="text-xs text-slate-500">${ops.length} ops${dia.totalMonto > 0 ? ' · S/ ' + dia.totalMonto.toLocaleString('es-PE', { maximumFractionDigits: 0 }) : ''}</div>
        </div>`;
      let secciones = '';
      // Sección WH
      if (byFuente.WH.length) {
        secciones += `<div class="mb-3">
          <div class="text-[11px] font-semibold text-blue-400 uppercase mb-1.5 ml-2">🏭 Almacén central (${byFuente.WH.length})</div>
          <div class="space-y-1.5">${byFuente.WH.map(_renderOpCard).join('')}</div>
        </div>`;
      }
      // Sección zonas
      Object.keys(byFuente.zonas).forEach(zk => {
        const z = byFuente.zonas[zk];
        secciones += `<div class="mb-3">
          <div class="text-[11px] font-semibold text-emerald-400 uppercase mb-1.5 ml-2">🏪 ${z.nombre} (${z.ops.length})</div>
          <div class="space-y-1.5">${z.ops.map(_renderOpCard).join('')}</div>
        </div>`;
      });
      return `<div class="mb-4">${headerHtml}${secciones}</div>`;
    }).join('') + debugHtml;
  }

  function _renderOpCard(op) {
    const tipo = String(op.tipo || '').toUpperCase();
    let tipoLabel, tipoColor, borderCls = '', extraStyle = '';
    if (op.esPreingreso) {
      tipoLabel = '⏳ PREINGRESO';
      tipoColor = 'text-amber-400';
      borderCls = 'border-l-2 border-amber-500/50';
    } else if (tipo === 'INGRESO_PROVEEDOR') {
      // Resaltado: guías de proveedor son críticas (compromiso de pago / costos)
      tipoLabel = '🟢 INGRESO PROVEEDOR';
      tipoColor = 'text-emerald-300';
      borderCls = 'border-l-4 border-emerald-400';
      extraStyle = 'background:linear-gradient(90deg,rgba(16,185,129,.10) 0%,rgba(16,185,129,.02) 100%);box-shadow:0 0 0 1px rgba(16,185,129,.18) inset';
    } else if (tipo.indexOf('INGRESO') >= 0) { tipoLabel = '🟢 INGRESO'; tipoColor = 'text-emerald-400'; }
    else if (tipo.indexOf('SALIDA_VENTAS') >= 0 || tipo === 'SALIDA_VENTAS') { tipoLabel = '🛒 VENTAS'; tipoColor = 'text-purple-400'; }
    else if (tipo.indexOf('SALIDA_ZONA') >= 0 || tipo.indexOf('DESPACHO') >= 0) { tipoLabel = '📦 DESPACHO'; tipoColor = 'text-blue-400'; }
    else if (tipo.indexOf('ENVASADO') >= 0) { tipoLabel = '🏷️ ENVASADO'; tipoColor = 'text-purple-400'; }
    else if (tipo.indexOf('TRASLADO') >= 0) { tipoLabel = '🔄 TRASLADO'; tipoColor = 'text-amber-400'; }
    else { tipoLabel = '📋 ' + tipo; tipoColor = 'text-slate-400'; }
    const estadoCls = op.estado === 'CERRADA' || op.estado === 'CONFIRMADO' || op.estado === 'PROCESADO' ? 'text-slate-500'
                    : op.estado === 'ABIERTA' || op.estado === 'PENDIENTE' ? 'text-amber-400'
                    : 'text-slate-500';
    const expandKey = op.fuente + '_' + op.idGuia + (op.esPreingreso ? '_PRE' : '');
    const expanded = !!S._opsExpanded[expandKey];
    const monto = op.montoTotal > 0 ? `<span class="text-amber-400 ml-2">S/ ${op.montoTotal.toLocaleString('es-PE', { maximumFractionDigits: 0 })}</span>` : '';
    const usuarioStr = op.usuario ? ` · ${op.usuario}` : '';
    const provNombre = op.nombreProveedor || op.idProveedor;
    const provStr = provNombre ? ` · ${provNombre}` : '';
    const horaStr = (function(){ try { var d = new Date(op.fecha); return d.toLocaleTimeString('es-PE', { hour: '2-digit', minute: '2-digit' }); } catch(_){ return ''; }})();
    // Preingresos no tienen líneas en GUIA_DETALLE — solo mostrar info de cabecera al expandir
    const onclickAttr = op.esPreingreso
      ? `onclick="MOS.almToggleOpExpand('${op.fuente}','${op.idGuia}', true)"`
      : `onclick="MOS.almToggleOpExpand('${op.fuente}','${op.idGuia}')"`;
    // Botón "💰 Llenar costos" para guías INGRESO_PROVEEDOR con foto
    const esIngreso = op.fuente === 'WH' && tipo.indexOf('INGRESO') >= 0 && !op.esPreingreso;
    const tieneFoto = !!(op.foto && String(op.foto).trim());
    const llenarCostosBtn = (esIngreso && tieneFoto)
      ? `<button onclick="event.stopPropagation();MOS.abrirCostosGuia('${op.idGuia}', '${op.fuente}')" class="text-amber-400 hover:text-amber-300 text-base shrink-0 px-1" title="Llenar costos basándose en foto de factura">💰</button>`
      : '';

    return `<div class="card-sm p-2.5 ${borderCls}" ${extraStyle ? `style="${extraStyle}"` : ''}>
      <div class="flex items-center justify-between gap-2 cursor-pointer" ${onclickAttr}>
        <div class="min-w-0 flex-1">
          <div class="text-xs font-semibold ${tipoColor} truncate">${tipoLabel} · <span class="text-slate-300 font-mono">${op.idGuia}</span> ${monto}</div>
          <div class="text-[10px] text-slate-500 truncate">${horaStr}${usuarioStr}${provStr}${op.comentario ? ' · ' + op.comentario : ''}</div>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          ${llenarCostosBtn}
          <span class="text-[10px] ${estadoCls}">${op.estado || ''}</span>
          <span class="text-slate-500">${expanded ? '▴' : '▾'}</span>
        </div>
      </div>
      <div id="opExp_${expandKey}" class="${expanded ? '' : 'hidden'} mt-2 pt-2 border-t border-slate-800/50">
        ${expanded ? (op.esPreingreso ? _renderPreingresoDetalle(op) : _renderOpDetalle(op.fuente, op.idGuia)) : ''}
      </div>
    </div>`;
  }

  function _renderPreingresoDetalle(op) {
    // Preingreso: no hay líneas, mostrar info de cabecera + foto si existe
    return `
      <div class="text-[11px] space-y-1">
        <div class="text-slate-400">📋 Preingreso (sin líneas hasta que sea aprobado y se convierta en guía de ingreso)</div>
        ${op.idProveedor ? `<div class="text-slate-500"><span class="text-slate-600">Proveedor:</span> ${op.idProveedor}</div>` : ''}
        ${op.usuario ? `<div class="text-slate-500"><span class="text-slate-600">Usuario:</span> ${op.usuario}</div>` : ''}
        ${op.comentario ? `<div class="text-slate-500"><span class="text-slate-600">Comentario:</span> ${op.comentario}</div>` : ''}
        ${op.idGuiaGenerada ? `<div class="text-slate-500"><span class="text-slate-600">Guía generada:</span> <span class="font-mono text-emerald-400">${op.idGuiaGenerada}</span></div>` : ''}
        <div class="text-slate-500"><span class="text-slate-600">Estado:</span> <span class="text-amber-400 font-semibold">${op.estado || 'PENDIENTE'}</span></div>
      </div>`;
  }

  function _renderOpDetalle(fuente, idGuia) {
    const key = fuente + '_' + idGuia;
    const cached = S._opsDetCache[key];
    if (!cached) {
      _fetchOpDetalle(fuente, idGuia);
      return '<div class="text-xs text-slate-500 italic py-1">Cargando líneas…</div>';
    }
    if (cached.error) return `<div class="text-xs text-rose-400 italic py-1">Error: ${cached.error}</div>`;
    const lineas = cached.lineas || [];
    if (!lineas.length) return '<div class="text-[11px] text-slate-600 italic py-1">Sin líneas registradas</div>';
    const total = lineas.reduce((s, l) => s + (l.subtotal || 0), 0);
    return `
      <div class="text-[11px] text-slate-500 mb-1">${lineas.length} línea${lineas.length === 1 ? '' : 's'}${total > 0 ? ' · subtotal S/ ' + total.toFixed(2) : ''}</div>
      <div class="space-y-0.5">
        ${lineas.map(l => {
          const equivBadge = l.esEquivalencia ? ' <span class="text-[9px] text-purple-400 bg-purple-500/10 px-1 rounded">EQUIV</span>' : '';
          return `<div class="flex items-center justify-between gap-2 text-[11px] py-0.5">
            <div class="min-w-0 flex-1">
              <div class="text-slate-300 truncate">${l.descripcion || l.codigoProducto || l.codigoBarra}${equivBadge}</div>
              <div class="text-slate-600 font-mono text-[10px]">▌ ${l.codigoBarra || l.codigoProducto || '—'}${l.fechaVencimiento ? ' · venc ' + fmtDate(l.fechaVencimiento) : ''}</div>
            </div>
            <div class="text-right shrink-0">
              <div class="text-slate-300 font-semibold">${l.cantidad}u</div>
              ${l.subtotal > 0 ? `<div class="text-amber-400 text-[10px]">S/ ${l.subtotal.toFixed(2)}</div>` : ''}
            </div>
          </div>`;
        }).join('')}
      </div>`;
  }

  async function _fetchOpDetalle(fuente, idGuia) {
    const key = fuente + '_' + idGuia;
    try {
      const r = await API.get('getOperacionDetalle', { fuente, idGuia });
      S._opsDetCache[key] = r || {};
      const cont = $('opExp_' + key);
      if (cont && S._opsExpanded[key]) cont.innerHTML = _renderOpDetalle(fuente, idGuia);
    } catch(e) {
      S._opsDetCache[key] = { error: e.message };
      const cont = $('opExp_' + key);
      if (cont && S._opsExpanded[key]) cont.innerHTML = _renderOpDetalle(fuente, idGuia);
    }
  }

  function almToggleOpExpand(fuente, idGuia, esPreingreso) {
    const key = fuente + '_' + idGuia + (esPreingreso ? '_PRE' : '');
    S._opsExpanded[key] = !S._opsExpanded[key];
    almRenderOps();
  }

  // ── Llenar costos de guía (con foto de factura) ──
  // Toggles del modal:
  //   inputMode: 'TOTAL'     → el usuario escribe el total de la línea (factura típica)
  //              'UNITARIO'  → el usuario escribe el precio por unidad
  //   igvMode:   'INCLUIDO'  → el valor ingresado YA incluye IGV
  //              'SIN_IGV'   → el valor ingresado NO incluye IGV (se le agrega)
  // Política: precioCosto siempre se guarda CON IGV (bruto). Si el usuario
  // declaró Sin IGV, le sumamos el IGV antes de guardar.
  // Defaults: TOTAL + INCLUIDO (formato más común en facturas).
  S._costosGuiaState = S._costosGuiaState || {
    idGuia: null, fuente: null, lineas: [], foto: '',
    inputMode: 'TOTAL', igvMode: 'INCLUIDO'
  };
  const _IGV_RATE = 0.18;

  // Convierte el valor que tipeó el usuario en precio UNITARIO BRUTO (con IGV).
  // Es el valor que se guarda como precioCosto.
  function _costosGuiaCalcularBruto(linea, st) {
    const v = parseFloat(linea.inputValue) || 0;
    if (v <= 0) return 0;
    const cant = parseFloat(linea.cantidad) || 1;
    // 1) Si el usuario declaró "Sin IGV", el valor que metió es neto → agregarle IGV
    const valorConIgv = st.igvMode === 'INCLUIDO' ? v : v * (1 + _IGV_RATE);
    // 2) Si era el TOTAL de la línea, dividir entre la cantidad
    return st.inputMode === 'TOTAL' ? (valorConIgv / cant) : valorConIgv;
  }

  async function abrirCostosGuia(idGuia, fuente) {
    if (!idGuia) return;
    let foto = '', idProveedor = '', nombreProveedor = '';
    const data = S._opsData || {};
    (data.porDia || []).forEach(d => d.operaciones.forEach(op => {
      if (op.idGuia === idGuia && op.fuente === fuente) {
        foto = op.foto || '';
        idProveedor = op.idProveedor || '';
        nombreProveedor = op.nombreProveedor || op.idProveedor || '';
      }
    }));
    // Mantener defaults TOTAL + INCLUIDO en cada apertura
    S._costosGuiaState = {
      idGuia, fuente, lineas: [], foto, idProveedor, nombreProveedor,
      inputMode: 'TOTAL', igvMode: 'INCLUIDO'
    };
    $('costosGuiaInfo').textContent = idGuia + (nombreProveedor ? ' · ' + nombreProveedor : '');
    const body = $('costosGuiaBody');
    body.innerHTML = '<div class="text-xs text-slate-500 italic py-4">Cargando líneas…</div>';
    openModal('modalCostosGuia');
    try {
      const r = await API.get('getOperacionDetalle', { fuente, idGuia });
      const lineas = (r && r.lineas) || [];
      // Inicializar inputValue desde el precioUnitario existente (interpretado como bruto c/IGV).
      // Default modal: TOTAL + INCLUIDO → mostramos el total bruto = bruto * cant
      lineas.forEach(l => {
        const bruto = parseFloat(l.precioUnitario) || 0;
        l.inputValue = bruto > 0 ? +(bruto * (parseFloat(l.cantidad) || 1)).toFixed(2) : '';
      });
      S._costosGuiaState.lineas = lineas;
      _renderCostosGuiaBody();
    } catch(e) {
      body.innerHTML = `<div class="text-xs text-rose-400 py-4">Error: ${e.message}</div>`;
    }
  }

  function _costosGuiaSetMode(modo) {
    // Convertir inputValue actual al nuevo modo preservando el unitario bruto (c/IGV)
    const st = S._costosGuiaState;
    if (st.inputMode === modo) return;
    st.lineas.forEach(l => {
      const brutoUnit = _costosGuiaCalcularBruto(l, st);
      const cant = parseFloat(l.cantidad) || 1;
      // valor a mostrar según el régimen IGV declarado
      const valorBase = st.igvMode === 'INCLUIDO' ? brutoUnit : (brutoUnit / (1 + _IGV_RATE));
      l.inputValue = brutoUnit > 0 ? +(modo === 'TOTAL' ? valorBase * cant : valorBase).toFixed(2) : '';
    });
    st.inputMode = modo;
    _renderCostosGuiaBody();
  }

  function _costosGuiaSetIgv(modo) {
    const st = S._costosGuiaState;
    if (st.igvMode === modo) return;
    // Convertir inputValue al nuevo régimen IGV preservando el unitario bruto
    st.lineas.forEach(l => {
      const brutoUnit = _costosGuiaCalcularBruto(l, st);
      const cant = parseFloat(l.cantidad) || 1;
      const valorBase = modo === 'INCLUIDO' ? brutoUnit : (brutoUnit / (1 + _IGV_RATE));
      l.inputValue = brutoUnit > 0 ? +(st.inputMode === 'TOTAL' ? valorBase * cant : valorBase).toFixed(2) : '';
    });
    st.igvMode = modo;
    _renderCostosGuiaBody();
  }

  function _renderCostosGuiaBody() {
    const body = $('costosGuiaBody');
    if (!body) return;
    const st = S._costosGuiaState;
    const { lineas, foto, inputMode, igvMode } = st;
    if (!lineas.length) {
      body.innerHTML = '<div class="text-xs text-slate-500 italic py-4">Esta guía no tiene líneas registradas.</div>';
      return;
    }
    const fotoHtml = foto
      ? `<div class="mb-3">
          <div class="text-[10px] text-slate-500 uppercase mb-1">📸 Foto de factura</div>
          <a href="${foto}" target="_blank" rel="noopener">
            <img src="${foto}" alt="Factura" class="rounded-lg cursor-zoom-in" style="max-width:100%;max-height:280px;object-fit:contain;background:#020617;border:1px solid #1e293b">
          </a>
          <div class="text-[10px] text-slate-600 mt-1">Click para ampliar en pestaña nueva</div>
        </div>`
      : '<div class="text-xs text-amber-400 italic mb-3">Esta guía no tiene foto adjunta.</div>';

    const segBtn = (active, label, onclick) => `<button onclick="${onclick}"
      class="px-2.5 py-1 text-[11px] font-semibold rounded transition"
      style="${active ? 'background:#f59e0b;color:#0b1220' : 'background:#0f172a;color:#94a3b8;border:1px solid #1e293b'}">${label}</button>`;
    const togglesHtml = `
      <div class="flex flex-wrap items-center gap-3 mb-3 pb-3" style="border-bottom:1px dashed #1e293b">
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] text-slate-500 uppercase">Ingreso:</span>
          ${segBtn(inputMode === 'TOTAL',    'Total línea',  "MOS._costosGuiaSetMode('TOTAL')")}
          ${segBtn(inputMode === 'UNITARIO', 'Por unidad',   "MOS._costosGuiaSetMode('UNITARIO')")}
        </div>
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] text-slate-500 uppercase">IGV:</span>
          ${segBtn(igvMode === 'INCLUIDO', 'Incluido (18%)', "MOS._costosGuiaSetIgv('INCLUIDO')")}
          ${segBtn(igvMode === 'SIN_IGV',  'Sin IGV',        "MOS._costosGuiaSetIgv('SIN_IGV')")}
        </div>
      </div>`;

    let totalBruto = 0, totalNeto = 0;
    const filasHtml = lineas.map((l, i) => {
      const cant = parseFloat(l.cantidad) || 0;
      const brutoUnit = _costosGuiaCalcularBruto(l, st);
      const netoUnit  = brutoUnit / (1 + _IGV_RATE);
      const subBruto  = brutoUnit * cant;
      const subNeto   = netoUnit * cant;
      totalBruto += subBruto;
      totalNeto  += subNeto;
      const equivBadge = l.esEquivalencia ? ' <span class="text-[9px] text-purple-400 bg-purple-500/10 px-1 rounded">EQUIV</span>' : '';
      const placeholder = inputMode === 'TOTAL' ? 'Total línea' : 'P. unit.';
      const helperTxt = brutoUnit > 0
        ? `<div class="text-[10px] leading-tight">
             <div><span class="text-amber-500 font-semibold">Costo unit. c/IGV:</span> <span class="text-amber-400 font-mono font-bold">S/ ${brutoUnit.toFixed(4)}</span></div>
             <div><span class="text-slate-600">(neto: <span class="font-mono">S/ ${netoUnit.toFixed(4)}</span>)</span></div>
           </div>`
        : '<span class="text-[10px] text-slate-700">—</span>';
      return `<tr>
        <td class="py-2 pr-2">
          <div class="text-xs text-slate-200 truncate">${l.descripcion}${equivBadge}</div>
          <div class="text-[10px] text-slate-500 font-mono">▌ ${l.codigoProducto || '—'}</div>
        </td>
        <td class="py-2 pr-2 text-right text-xs text-slate-400 whitespace-nowrap">${cant}u</td>
        <td class="py-2 pr-2">
          <input type="number" step="0.01" min="0" class="inp text-xs text-right" style="width:100px"
                 value="${l.inputValue || ''}"
                 oninput="MOS._costosGuiaUpdLinea(${i}, this.value)" placeholder="${placeholder}">
        </td>
        <td class="py-2 text-right whitespace-nowrap" id="costoGuiaSubtot_${i}">
          ${helperTxt}
        </td>
      </tr>`;
    }).join('');
    const colHeaderInput = inputMode === 'TOTAL' ? 'Total línea' : 'Precio unit.';
    const colHeaderIgv   = igvMode === 'INCLUIDO' ? '(con IGV)'  : '(sin IGV)';
    body.innerHTML = `${fotoHtml}${togglesHtml}
      <div class="text-[10px] text-slate-500 uppercase mb-1">Líneas (${lineas.length})</div>
      <table class="w-full text-sm">
        <thead>
          <tr class="text-[10px] text-slate-600 uppercase border-b border-slate-800">
            <th class="text-left pb-1">Producto</th>
            <th class="text-right pb-1">Cant</th>
            <th class="text-right pb-1">${colHeaderInput} <span class="text-slate-700 normal-case">${colHeaderIgv}</span></th>
            <th class="text-right pb-1">Cálculo</th>
          </tr>
        </thead>
        <tbody>${filasHtml}</tbody>
        <tfoot>
          <tr class="border-t border-slate-800">
            <td colspan="4" class="pt-3">
              <div class="flex justify-end gap-4 text-[11px]">
                <div><span class="text-slate-500">Neto:</span> <span class="text-slate-300 font-mono" id="costosGuiaTotalNeto">S/ ${totalNeto.toFixed(2)}</span></div>
                <div><span class="text-slate-500">IGV:</span>  <span class="text-slate-300 font-mono" id="costosGuiaTotalIgv">S/ ${(totalBruto - totalNeto).toFixed(2)}</span></div>
                <div><span class="text-amber-400 font-semibold">Total:</span> <span class="text-amber-400 font-mono font-bold" id="costosGuiaTotalBruto">S/ ${totalBruto.toFixed(2)}</span></div>
              </div>
            </td>
          </tr>
        </tfoot>
      </table>`;
  }

  function _costosGuiaUpdLinea(idx, valor) {
    const st = S._costosGuiaState;
    const linea = st.lineas[idx];
    if (!linea) return;
    linea.inputValue = parseFloat(valor) || 0;
    const brutoUnit = _costosGuiaCalcularBruto(linea, st);
    const netoUnit  = brutoUnit / (1 + _IGV_RATE);
    const cell = $('costoGuiaSubtot_' + idx);
    if (cell) {
      cell.innerHTML = brutoUnit > 0
        ? `<div class="text-[10px] leading-tight">
             <div><span class="text-amber-500 font-semibold">Costo unit. c/IGV:</span> <span class="text-amber-400 font-mono font-bold">S/ ${brutoUnit.toFixed(4)}</span></div>
             <div><span class="text-slate-600">(neto: <span class="font-mono">S/ ${netoUnit.toFixed(4)}</span>)</span></div>
           </div>`
        : '<span class="text-[10px] text-slate-700">—</span>';
    }
    // Recalcular totales
    let totalBruto = 0;
    st.lineas.forEach(l => { totalBruto += _costosGuiaCalcularBruto(l, st) * (parseFloat(l.cantidad) || 0); });
    const totalNeto = totalBruto / (1 + _IGV_RATE);
    const elN = $('costosGuiaTotalNeto');  if (elN) elN.textContent = 'S/ ' + totalNeto.toFixed(2);
    const elI = $('costosGuiaTotalIgv');   if (elI) elI.textContent = 'S/ ' + (totalBruto - totalNeto).toFixed(2);
    const elB = $('costosGuiaTotalBruto'); if (elB) elB.textContent = 'S/ ' + totalBruto.toFixed(2);
  }

  function cerrarCostosGuia() { closeModal('modalCostosGuia'); }

  async function guardarCostosGuia() {
    const st = S._costosGuiaState;
    const { idGuia, lineas } = st;
    if (!idGuia) return;
    const items = lineas
      .map(l => ({
        idDetalle: l.idDetalle,
        codigoProducto: l.codigoProducto,
        precioUnitario: _costosGuiaCalcularBruto(l, st) // bruto c/IGV
      }))
      .filter(it => it.precioUnitario > 0);
    if (!items.length) {
      toast('No hay precios para guardar', 'error');
      return;
    }
    const updateMaster = !!$('costosGuiaUpdMaster')?.checked;
    closeModal('modalCostosGuia');
    toast('Guardando costos…', 'info');
    try {
      const resp = await API.post('llenarCostosGuia', {
        idGuia, items, actualizarPrecioCosto: updateMaster, usuario: S.session?.nombre || ''
      });
      toast('✓ ' + items.length + ' costos guardados' + (updateMaster ? ' + catálogo MOS actualizado' : ''), 'ok');
      await almLoadOps(true);

      // Si hay sugerencias relevantes, abrir panel de impacto
      const sugerencias = (resp && resp.sugerenciasPrecioVenta) || (resp && resp.data && resp.data.sugerenciasPrecioVenta) || [];
      const relevantes = sugerencias.filter(s => {
        // Mostrar solo si hay sugerencia activa Y precio sugerido difiere significativamente del actual
        if (s.precioVentaSugerido === null || s.precioVentaSugerido === undefined) return false;
        const actual = parseFloat(s.precioVentaActual) || 0;
        const sug = parseFloat(s.precioVentaSugerido) || 0;
        if (sug <= 0) return false;
        if (actual <= 0) return true; // sin precio antes → sugerir
        const deltaPct = Math.abs((sug - actual) / actual) * 100;
        return deltaPct >= 1; // ≥ 1% de diferencia
      });
      if (relevantes.length) {
        _mostrarPanelImpacto(relevantes, idGuia);
      }
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  // ── Panel: Impacto de costos en precios de venta ─────────
  S._impactoState = S._impactoState || { sugerencias: [], idGuia: null };

  function _mostrarPanelImpacto(sugerencias, idGuia) {
    // Inicializar cada una con seleccionado=true por default (excepto FIJO/LIBRE sin sugerencia)
    sugerencias.forEach(s => {
      s._seleccionado = (s.precioVentaSugerido !== null && s.precioVentaSugerido > 0);
      s._precioCustom = s.precioVentaSugerido; // editable
    });
    S._impactoState = { sugerencias, idGuia };
    const info = $('impactoCostosInfo');
    if (info) info.textContent = `Guía ${idGuia} · ${sugerencias.length} producto${sugerencias.length === 1 ? '' : 's'} con cambio relevante`;
    _renderImpactoBody();
    openModal('modalImpactoCostos');
  }

  function _renderImpactoBody() {
    const body = $('impactoCostosBody');
    if (!body) return;
    const { sugerencias } = S._impactoState;
    if (!sugerencias.length) {
      body.innerHTML = '<div class="text-xs text-slate-500 italic">Sin sugerencias relevantes.</div>';
      return;
    }
    body.innerHTML = sugerencias.map((s, i) => {
      const costoAnt = parseFloat(s.costoAnterior) || 0;
      const costoNue = parseFloat(s.costoNuevo) || 0;
      const deltaCosto = costoAnt > 0 ? ((costoNue - costoAnt) / costoAnt) * 100 : null;
      const deltaCostoStr = deltaCosto === null ? 'nuevo' : (deltaCosto >= 0 ? '+' : '') + deltaCosto.toFixed(1) + '%';
      const deltaCls = deltaCosto === null ? 'text-slate-500' : (deltaCosto > 0 ? 'text-rose-400' : 'text-emerald-400');

      const ventaAct = parseFloat(s.precioVentaActual) || 0;
      const ventaSug = parseFloat(s.precioVentaSugerido) || 0;
      const margenSug = s.margenSugerido !== null && s.margenSugerido !== undefined ? s.margenSugerido : null;
      const margenAct = s.margenActual !== null && s.margenActual !== undefined ? s.margenActual : null;

      // Lotización
      const lot = s.lotizacion || {};
      const desglose = lot.desglose || [];
      const lotHtml = (lot.hayLoteAnterior && desglose.length > 0)
        ? `<div class="mt-2 p-2 rounded text-[10px] text-amber-300" style="background:rgba(251,191,36,.07);border:1px dashed rgba(251,191,36,.3)">
             <div class="font-semibold mb-1">⚠️ Hay stock del lote anterior</div>
             <table class="w-full text-[10px]">
               <thead class="text-amber-500 opacity-70">
                 <tr><th class="text-left">Lote</th><th class="text-right">Cant</th><th class="text-right">Costo c/IGV</th></tr>
               </thead>
               <tbody>
                 ${desglose.map(d => `<tr ${d.esActual ? 'class="font-semibold"' : ''}>
                   <td class="py-0.5">${d.esActual ? 'Nuevo (esta guía)' : new Date(d.fecha).toLocaleDateString('es-PE', { month: 'short', day: 'numeric' })}</td>
                   <td class="text-right py-0.5">${d.cantidad}u</td>
                   <td class="text-right py-0.5 font-mono">S/ ${parseFloat(d.costo).toFixed(2)}</td>
                 </tr>`).join('')}
               </tbody>
             </table>
             <div class="mt-1 text-amber-400">Costo ponderado real: <span class="font-mono font-semibold">S/ ${(parseFloat(lot.costoPonderado) || 0).toFixed(4)}</span> · stock total ${lot.stockTotal || 0}u</div>
           </div>`
        : '';

      const sinSugerencia = (s.modoEfectivo === 'FIJO' || s.modoEfectivo === 'LIBRE' || ventaSug <= 0);
      const checked = s._seleccionado ? 'checked' : '';
      const disabledCheck = sinSugerencia ? 'disabled' : '';

      return `<div class="card-sm p-3 mb-2" style="border-left:3px solid ${sinSugerencia ? '#475569' : (deltaCosto && deltaCosto > 0 ? '#f43f5e' : '#10b981')}">
        <div class="flex items-start gap-3">
          <input type="checkbox" ${checked} ${disabledCheck} onchange="MOS._impactoTogglesel(${i}, this.checked)" class="mt-1">
          <div class="flex-1 min-w-0">
            <div class="text-sm font-semibold text-slate-200 truncate">${s.descripcion}</div>
            <div class="text-[10px] text-slate-500 font-mono">▌ ${s.codigoProducto}</div>
            <div class="grid grid-cols-2 gap-2 mt-2 text-[11px]">
              <div>
                <span class="text-slate-500">Costo:</span>
                <span class="font-mono">${costoAnt > 0 ? 'S/ ' + costoAnt.toFixed(2) : '—'} → <span class="text-amber-400 font-semibold">S/ ${costoNue.toFixed(2)}</span></span>
                <span class="${deltaCls}">(${deltaCostoStr})</span>
              </div>
              <div>
                <span class="text-slate-500">Margen:</span>
                <span>${margenAct !== null ? margenAct.toFixed(1) + '%' : '—'} → <span class="${margenSug !== null ? 'text-emerald-400 font-semibold' : 'text-slate-500'}">${margenSug !== null ? margenSug.toFixed(1) + '%' : '—'}</span></span>
              </div>
            </div>
            <div class="mt-2 flex items-center gap-2 text-[11px]">
              <span class="text-slate-500">Precio venta:</span>
              <span class="font-mono">${ventaAct > 0 ? 'S/ ' + ventaAct.toFixed(2) : '—'}</span>
              <span class="text-slate-600">→</span>
              ${sinSugerencia
                ? `<span class="text-slate-500 italic text-[10px]">${s.modoEfectivo} — sin sugerencia automática</span>`
                : `<input type="number" step="0.01" min="0" value="${(s._precioCustom || ventaSug).toFixed(2)}"
                   oninput="MOS._impactoSetPrecio(${i}, this.value)"
                   class="inp text-xs text-right" style="width:90px">
                   <span class="text-[9px] text-slate-600">obj. ${(parseFloat(s.margenObjetivo) || 0).toFixed(0)}% (${s.origenPolitica})</span>`}
            </div>
            ${lotHtml}
          </div>
        </div>
      </div>`;
    }).join('');

    // Resumen del footer
    const seleccionadas = sugerencias.filter(s => s._seleccionado).length;
    const resEl = $('impactoCostosResumen');
    if (resEl) resEl.textContent = `${seleccionadas} de ${sugerencias.length} seleccionados`;
  }

  function _impactoTogglesel(idx, checked) {
    if (S._impactoState.sugerencias[idx]) {
      S._impactoState.sugerencias[idx]._seleccionado = !!checked;
      _renderImpactoBody();
    }
  }

  function _impactoSetPrecio(idx, valor) {
    if (S._impactoState.sugerencias[idx]) {
      S._impactoState.sugerencias[idx]._precioCustom = parseFloat(valor) || 0;
    }
  }

  function cerrarImpactoCostos() { closeModal('modalImpactoCostos'); }

  async function aplicarSugerenciasSeleccionadas() {
    const { sugerencias, idGuia } = S._impactoState;
    const items = sugerencias
      .filter(s => s._seleccionado && s._precioCustom > 0)
      .map(s => ({
        idProducto: s.idProducto,
        precioNuevo: s._precioCustom,
        motivo: 'Ajuste por costo guía ' + (idGuia || '')
      }));
    if (!items.length) {
      toast('No hay sugerencias seleccionadas', 'error');
      return;
    }
    closeModal('modalImpactoCostos');
    toast('Aplicando precios…', 'info');
    try {
      const r = await API.post('aplicarPreciosVentaSugeridos', { items, usuario: S.session?.nombre || '' });
      const aplicados = (r && r.aplicados) || (r && r.data && r.data.aplicados) || 0;
      const errores = (r && r.errores) || (r && r.data && r.data.errores) || [];
      toast(`✓ ${aplicados} precios actualizados${errores.length ? ' · ' + errores.length + ' errores' : ''}`, errores.length ? 'error' : 'ok');
      // Refrescar catálogo si está cargado
      if (S.productos && S.productos.length) {
        await loadCatalogo(true);
      }
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  function _formatFechaCorta(yyyymmdd) {
    if (!yyyymmdd) return '';
    const parts = yyyymmdd.split('-');
    if (parts.length !== 3) return yyyymmdd;
    const d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
    const hoy = new Date(); hoy.setHours(0,0,0,0);
    const ayer = new Date(hoy.getTime() - 86400000);
    const dms = d.getTime();
    if (dms === hoy.getTime()) return 'Hoy';
    if (dms === ayer.getTime()) return 'Ayer';
    return d.toLocaleDateString('es-PE', { weekday: 'short', day: 'numeric', month: 'short' });
  }

  // ── ALMACÉN: ZONAS (ranking + sin venta) ──
  async function almLoadZonas(forceRefresh) {
    const dias = parseInt($('almZonasRango')?.value) || 30;
    const params = { dias };
    if (forceRefresh) params._refresh = 'true';
    try {
      const [rankRes, sinVentaRes] = await Promise.allSettled([
        API.get('getRankingZonas', params),
        API.get('getProductosSinVenta', params)
      ]);
      const warnEl = $('almZonasGasVersionWarn');
      let gasOld = false;
      if (rankRes.status === 'fulfilled') {
        const v = rankRes.value || {};
        if (!v._almV || v._almV < 2) gasOld = true;
        _almRenderRankingZonas(v);
      }
      if (sinVentaRes.status === 'fulfilled') {
        const v = sinVentaRes.value || {};
        if (!v._almV || v._almV < 2) gasOld = true;
        _almRenderSinVenta(v.productos || []);
      }
      if (warnEl) warnEl.classList.toggle('hidden', !gasOld);
    } catch(e) {
      console.warn('[almLoadZonas] error:', e);
    }
  }

  async function almRefreshZonas() {
    toast('Refrescando zonas (ignora cache)…', 'info');
    await almLoadZonas(true);
  }

  function _almRenderRankingZonas(data) {
    const el = $('almZonasRanking'); if (!el) return;
    const zonas = data.zonas || [];
    if (!zonas.length) {
      el.innerHTML = '<div class="text-xs text-slate-600 italic py-3 text-center">Sin zonas registradas en MOS o sin ventas en el rango</div>';
      return;
    }
    const max = Math.max(...zonas.map(z => z.ventas), 1);
    const totalStr = data.totalVentas ? 'S/ ' + data.totalVentas.toLocaleString('es-PE', { maximumFractionDigits: 0 }) : 'S/ 0';
    const fueraZonas = parseFloat(data.ventasFueraDeZonasRegistradas) || 0;
    const fueraTickets = parseInt(data.ticketsFueraDeZonasRegistradas) || 0;
    el.innerHTML = `
      <div class="card-sm p-4 mb-2">
        <div class="text-xs text-slate-500 uppercase mb-1">Total vendido (${data.rangoDias}d)</div>
        <div class="text-2xl font-bold text-emerald-400">${totalStr}</div>
        <div class="text-xs text-slate-500 mt-1">${data.totalTickets || 0} tickets · ticket prom S/ ${(data.ticketProm || 0).toFixed(2)}</div>
      </div>
      <div class="space-y-2">
        ${zonas.map(z => {
          const pct = (z.ventas / max) * 100;
          return `<div class="card-sm p-3">
            <div class="flex items-center justify-between mb-1.5 gap-2">
              <div class="text-sm font-semibold text-slate-200 truncate">${z.nombre}</div>
              <div class="text-sm font-bold text-amber-400 whitespace-nowrap">S/ ${z.ventas.toLocaleString('es-PE', { maximumFractionDigits: 0 })}</div>
            </div>
            <div class="h-2 bg-slate-800 rounded overflow-hidden">
              <div class="h-full" style="width:${pct}%;background:linear-gradient(to right,#10b981,#34d399)"></div>
            </div>
            <div class="flex items-center justify-between text-xs text-slate-500 mt-1.5">
              <span>${z.tickets} tickets · ${z.vendedores} vendedor${z.vendedores !== 1 ? 'es' : ''}</span>
              <span>${z.pctTotal}%</span>
            </div>
          </div>`;
        }).join('')}
        ${fueraZonas > 0 ? `<div class="card-sm p-3 border border-amber-500/30">
          <div class="flex items-center justify-between gap-2">
            <div class="min-w-0 flex-1">
              <div class="text-sm font-semibold text-amber-400">⚠ Ventas fuera de zonas registradas</div>
              <div class="text-xs text-slate-500 mt-0.5">${fueraTickets} tickets atribuidos a zonas que no existen en MOS.ZONAS — revisar configuración de estaciones</div>
            </div>
            <div class="text-sm font-bold text-amber-400 whitespace-nowrap">S/ ${fueraZonas.toLocaleString('es-PE', { maximumFractionDigits: 0 })}</div>
          </div>
        </div>` : ''}
      </div>
    `;
  }

  function _almRenderSinVenta(productos) {
    const el = $('almSinVenta'); if (!el) return;
    if (!productos.length) {
      el.innerHTML = '<div class="text-xs text-slate-600 italic py-3 text-center">✅ Todos los productos con stock se vendieron</div>';
      return;
    }
    // Hint para el usuario sobre el propósito
    const intro = '<div class="text-[11px] text-slate-500 italic mb-2 px-1">💡 Estos productos tienen stock pero no rotan — candidatos a promo o a botar</div>';
    el.innerHTML = intro + productos.slice(0, 30).map(p => {
      const breakdown = (p.breakdownZonas || []);
      const breakdownStr = breakdown.length
        ? breakdown.map(b => `<span class="text-slate-400">${b.nombre}: <span class="text-orange-300">${b.cantidad}u</span></span>`).join(' · ')
        : '<span class="text-slate-600 italic">sin desglose</span>';
      return `
        <div class="card-sm p-3 cursor-pointer hover:border-orange-500/40 transition-colors" onclick="MOS.almAbrirStockDetalle('${p.idProducto}')">
          <div class="flex items-center justify-between gap-2 mb-1">
            <div class="min-w-0 flex-1">
              <div class="text-sm font-semibold text-slate-200 truncate">${p.descripcion || p.idProducto}</div>
              <div class="text-xs text-slate-500 mt-0.5 font-mono truncate">▌ ${p.codigoBarra || '—'} · ${fmtMoney(p.precioVenta)}</div>
            </div>
            <div class="text-right shrink-0">
              <div class="text-sm font-bold text-orange-400">${p.stockEnZonas}u</div>
              <div class="text-[10px] text-slate-600">total en zonas</div>
            </div>
          </div>
          <div class="text-[11px] mt-1 pt-1 border-t border-slate-800/50">${breakdownStr}</div>
        </div>`;
    }).join('') + (productos.length > 30 ? `<div class="text-xs text-slate-600 italic text-center py-2">+ ${productos.length - 30} más…</div>` : '');
  }

  // ── ALMACÉN: STOCK detalle modal (WH + zonas) ──
  async function almAbrirStockDetalle(idProducto, forceRefresh) {
    if (!idProducto) return;
    S._stockDetCurrentId = idProducto;
    openModal('modalStockDetalle');
    const body = $('stockDetBody');
    if (body) body.innerHTML = '<div class="skel h-32 rounded"></div>';
    try {
      const params = { idProducto };
      if (forceRefresh) params._refresh = 'true';
      const r = await API.get('getStockUnificado', params);
      if (!r) throw new Error('Sin respuesta');
      const p = r.producto || {};
      $('stockDetTitle').textContent = '📦 ' + (p.descripcion || idProducto);
      $('stockDetSku').textContent = 'SKU ' + (p.skuBase || '—') + (p.codigoBarra ? ' · ▌ ' + p.codigoBarra : '');
      const zonasHtml = (r.zonas || []).map(z => {
        const isNeg = z.cantidad < 0;
        const isCero = z.cantidad === 0;
        const sinRegistro = !z.tieneRegistroStock;  // NO existe fila en STOCK_ZONAS para este producto
        // Stock display: distinguir sin registro / 0 / negativo / positivo
        let stockColor, stockDisplay;
        if (sinRegistro) {
          stockColor = 'text-slate-600 italic';
          stockDisplay = '— sin registro';
        } else if (isNeg) {
          stockColor = 'text-rose-500';
          stockDisplay = `⚠ ${z.cantidad}u`;
        } else if (isCero) {
          stockColor = 'text-slate-500';
          stockDisplay = '0u';
        } else {
          stockColor = (z.diasParaAcabar !== null && z.diasParaAcabar < 7)  ? 'text-rose-400' :
                       (z.diasParaAcabar !== null && z.diasParaAcabar < 14) ? 'text-amber-400' :
                       'text-slate-200';
          stockDisplay = z.cantidad + 'u';
        }
        // Línea de detalle: ventas / rotación
        let detailLine = '';
        if (sinRegistro && z.sinVentas) {
          detailLine = '<span class="text-slate-600 italic">Producto nunca registrado en esta zona</span>';
        } else if (z.sinVentas) {
          detailLine = '<span class="text-slate-600">Sin ventas en ' + (r.total?.rangoDiasConsultado || 7) + 'd</span>';
        } else {
          detailLine = 'Vende ' + z.rotacionDia + '/d';
          if (z.diasParaAcabar !== null) {
            const cls = z.diasParaAcabar < 7 ? 'text-rose-400' : z.diasParaAcabar < 14 ? 'text-amber-400' : 'text-slate-500';
            detailLine += ` · <span class="${cls}">alcanza ${z.diasParaAcabar}d</span>`;
          } else if (sinRegistro) {
            detailLine += ' · <span class="text-rose-400">⚠ vendiéndose sin estar registrado en stock</span>';
          } else if (isCero) {
            detailLine += ' · <span class="text-rose-400">⚠ stock agotado, reponer</span>';
          }
        }
        // Badge de alerta cuando hay ventas pero stock=0
        const warningBadge = (!sinRegistro && isCero && !z.sinVentas)
          ? '<span class="text-[10px] text-rose-400 ml-1">📍 stock agotado con ventas</span>' : '';
        return `<div class="flex items-center justify-between py-2 border-b border-slate-800/50 gap-2">
          <div class="min-w-0 flex-1">
            <div class="text-sm text-slate-200 truncate">🏪 ${z.nombre}${warningBadge}</div>
            <div class="text-xs text-slate-500">${detailLine}</div>
          </div>
          <div class="text-right shrink-0">
            <div class="text-base font-bold ${stockColor}">${stockDisplay}</div>
          </div>
        </div>`;
      }).join('');
      const insightsHtml = (r.insights || []).map(i => {
        const sevColor = { CRITICA: 'border-rose-500/40 bg-rose-500/5', ALTA: 'border-amber-500/40 bg-amber-500/5', MEDIA: 'border-indigo-500/40 bg-indigo-500/5' };
        return `<div class="card-sm p-2.5 border-l-2 ${sevColor[i.severidad] || 'border-slate-700'}">
          <div class="text-xs font-semibold text-slate-200">${i.mensaje}</div>
          ${i.accion ? `<div class="text-[11px] text-slate-500 mt-1">→ ${i.accion}</div>` : ''}
        </div>`;
      }).join('');
      const total = r.total || {};
      const minimo = p.stockMinimo || 0;
      const maximo = p.stockMaximo || (minimo * 2);
      const pct = maximo > 0 ? Math.min(100, (total.cantidad / maximo) * 100) : 0;
      const colorBar = total.cantidad < minimo ? '#f43f5e' : total.cantidad < minimo * 1.2 ? '#f59e0b' : '#10b981';
      $('stockDetBody').innerHTML = `
        <!-- Total + barra -->
        <div class="card-sm p-4">
          <div class="text-xs text-slate-500 uppercase mb-2">Total (WH + zonas)</div>
          <div class="grid grid-cols-2 gap-3 mb-3">
            <div>
              <div class="text-[10px] text-slate-500 uppercase">Stock total</div>
              <div class="text-2xl font-bold text-white">${total.cantidad}u</div>
            </div>
            <div>
              <div class="text-[10px] text-slate-500 uppercase">Rotación total</div>
              <div class="text-2xl font-bold ${total.rotacionDia > 0 ? 'text-emerald-400' : 'text-slate-600'}">${total.rotacionDia || 0}<span class="text-xs">/d</span></div>
            </div>
          </div>
          <div class="h-3 bg-slate-800 rounded overflow-hidden">
            <div class="h-full transition-all" style="width:${pct}%;background:${colorBar}"></div>
          </div>
          <div class="flex justify-between text-[10px] text-slate-500 mt-1">
            <span>mín ${minimo}u</span><span>máx ${maximo}u</span>
          </div>
          <div class="text-xs text-slate-400 mt-3 pt-2 border-t border-slate-800">
            ${(() => {
              if (total.cantidad < 0) {
                return '🚨 <span class="text-rose-500 font-semibold">Stock negativo (' + total.cantidad + 'u)</span> — discrepancia entre lo recibido y lo vendido. Auditar urgente.';
              }
              if (total.cantidad === 0) {
                return total.rotacionDia > 0
                  ? '🚨 <span class="text-rose-400">Stock total en 0 pero hay ventas activas</span> — reposición urgente'
                  : '⏸ <span class="text-slate-500">Stock total en 0 · Sin ventas en ' + (total.rangoDiasConsultado || 7) + 'd</span>';
              }
              if (total.diasParaAcabar !== null) {
                const cls = total.diasParaAcabar < 7 ? 'text-rose-400' : total.diasParaAcabar < 14 ? 'text-amber-400' : 'text-emerald-400';
                return `⏰ Al ritmo actual alcanza para <span class="${cls} font-semibold">${total.diasParaAcabar} días</span>`;
              }
              return '⏸ <span class="text-slate-500">Stock estable, sin ventas en ' + (total.rangoDiasConsultado || 7) + 'd</span>';
            })()}
          </div>
        </div>
        <!-- WH -->
        <div>
          <div class="text-xs text-slate-500 uppercase mb-2">🏭 Almacén central</div>
          <div class="card-sm p-3 ${(r.wh || {}).cantidad < 0 ? 'border-rose-500/40' : ''}">
            <div class="flex items-center justify-between">
              <div class="min-w-0 flex-1">
                <div class="text-sm text-slate-200">Stock disponible</div>
                <div class="text-xs text-slate-500 mt-0.5">
                  ${(r.wh || {}).cantidad < 0
                    ? '<span class="text-rose-400">⚠ Stock negativo: vendiste/saliste más de lo recibido</span>'
                    : (total.rotacionDia > 0
                      ? 'Despacha aprox. ' + total.rotacionDia + '/d (= venta total zonas)'
                      : 'Sin movimiento de salida en ' + (total.rangoDiasConsultado || 7) + 'd')}
                </div>
                ${((r.wh && r.wh.detalle) || []).length > 1 ? `<div class="text-[10px] text-slate-600 font-mono mt-1">${r.wh.detalle.length} entradas en WH STOCK</div>` : ''}
              </div>
              <div class="text-lg font-bold ${(r.wh || {}).cantidad > 0 ? 'text-blue-400' : (r.wh || {}).cantidad < 0 ? 'text-rose-500' : 'text-slate-500'} shrink-0">
                ${(r.wh || {}).cantidad > 0 ? ((r.wh || {}).cantidad + 'u') :
                  (r.wh || {}).cantidad < 0 ? ('⚠ ' + (r.wh || {}).cantidad + 'u') :
                  ((r.wh || {}).detalle && (r.wh || {}).detalle.length > 0 ? '0u' : '— sin registro')}
              </div>
            </div>
          </div>
        </div>
        <!-- Zonas -->
        ${zonasHtml ? `
        <div>
          <div class="text-xs text-slate-500 uppercase mb-1">🏪 Distribución por zona (rot ${total.rangoDiasConsultado || 7}d)</div>
          <div class="card-sm p-3">${zonasHtml}</div>
        </div>` : ''}
        <!-- Insights -->
        ${insightsHtml ? `
        <div>
          <div class="text-xs text-slate-500 uppercase mb-2">💡 Sugerencias</div>
          <div class="space-y-2">${insightsHtml}</div>
        </div>` : ''}
        <!-- Debug (colapsado por default) -->
        ${r._debug ? `
        <details class="text-[10px] text-slate-600 mt-2">
          <summary class="cursor-pointer hover:text-slate-400">🔍 Debug · ver qué leyó del backend</summary>
          <div class="mt-2 p-2 rounded font-mono whitespace-pre-wrap" style="background:#060d1f;border:1px solid #1e293b">
            <div class="text-slate-500 mb-1">Zonas leídas de tabla ZONAS:</div>
            ${(r._debug.zonasLeidasDeTablaZONAS || []).map(z =>
              `· idZona="${z.idZona}" · nombre="${z.nombre}" · estado=${z.estado} · canon→${z.canonResolved?.id}/${z.canonResolved?.nombre}`
            ).join('<br>') || '<span class="text-rose-400">⚠ Tabla ZONAS vacía o no leída</span>'}
            <div class="text-slate-500 mt-2 mb-1">IDs canónicos finales mostrados:</div>
            ${(r._debug.idsTodasFinales || []).join(', ')}
            <div class="text-slate-500 mt-2 mb-1">Nombres por canon:</div>
            ${Object.entries(r._debug.nombreCanonMap || {}).map(([k,v]) => `${k} → ${v}`).join('<br>')}
            <div class="text-slate-500 mt-2 mb-1">Stock encontrado por zona (canon):</div>
            ${(r._debug.zonaAcumKeys || []).join(', ') || '(ninguno)'}
            <div class="text-slate-500 mt-2 mb-1">Ventas por zona (canon):</div>
            ${(r._debug.ventasZonaKeys || []).join(', ') || '(ninguno)'}
          </div>
        </details>` : ''}
      `;
    } catch(e) {
      $('stockDetBody').innerHTML = `<div class="text-rose-400 text-sm">Error: ${e.message}</div>`;
    }
  }
  function cerrarStockDetalle() { closeModal('modalStockDetalle'); }

  async function almRefreshStockDetalle() {
    if (!S._stockDetCurrentId) return;
    toast('Refrescando datos…', 'info');
    await almAbrirStockDetalle(S._stockDetCurrentId, true);
  }

  // Cache local de detalles expandidos (skuBase → datos)
  S._stockDetCache = S._stockDetCache || {};
  S._stockExpanded = S._stockExpanded || {};

  function renderStockTable() {
    const list = $('almStockList');
    const stats = $('almStockStats');
    const warn = $('almStockGasVersionWarn');
    if (!list) return;
    if (warn) warn.classList.toggle('hidden', !S._catalogoGasOld);
    const items = S.catalogoStock || [];
    if (!items.length) {
      list.innerHTML = '<div class="text-xs text-slate-600 italic py-6 text-center">Sin productos activos en catálogo.</div>';
      if (stats) stats.textContent = '';
      return;
    }
    // Filtros
    const q = (S.almStockFilter || '').trim().toLowerCase();
    const filtroAlerta = $('almStockFiltroAlerta')?.value || '';
    let filtered = items;
    if (q) {
      filtered = filtered.filter(p =>
        (p.descripcion || '').toLowerCase().includes(q) ||
        (p.skuBase || '').toLowerCase().includes(q) ||
        (p.codigoBarra || '').toLowerCase().includes(q) ||
        (p.idProducto || '').toLowerCase().includes(q)
      );
    }
    if (filtroAlerta) filtered = filtered.filter(p => p.alerta === filtroAlerta);

    if (stats) stats.textContent = `${filtered.length} de ${items.length} productos`;

    if (!filtered.length) {
      list.innerHTML = '<div class="text-xs text-slate-600 italic py-6 text-center">Sin coincidencias' + (q ? ' para "' + q + '"' : '') + '</div>';
      return;
    }

    list.innerHTML = filtered.slice(0, 100).map(p => _renderStockCard(p)).join('') +
      (filtered.length > 100 ? `<div class="text-xs text-slate-600 italic text-center py-2">+ ${filtered.length - 100} productos más, refina la búsqueda</div>` : '');
  }

  function _renderStockCard(p) {
    const expanded = !!S._stockExpanded[p.skuBase];
    const total = p.totalCantidad;
    const minimo = p.stockMinimo || 0;
    const maximo = p.stockMaximo || (minimo * 2) || 100;
    const pct = Math.min(100, maximo > 0 ? Math.max(0, total) / maximo * 100 : 0);
    const colorBar = total < 0 ? '#f43f5e' :
                     total < minimo ? '#f43f5e' :
                     total < minimo * 1.2 ? '#f59e0b' :
                     '#10b981';
    // Mensaje de estado
    let alertMsg = '', alertColor = 'text-slate-400';
    if (p.alerta === 'NEGATIVO') {
      alertMsg = `🚨 Stock negativo (${total}u) — discrepancia entre lo recibido y lo vendido. Auditar urgente.`;
      alertColor = 'text-rose-500 font-semibold';
    } else if (p.alerta === 'BAJO_MINIMO') {
      alertMsg = `🚨 Stock total (${total}u) por debajo del mínimo (${minimo}u)`;
      alertColor = 'text-rose-400';
    } else if (p.alerta === 'AGOTAR_PRONTO' && p.diasParaAcabar !== null) {
      alertMsg = `⏰ Al ritmo actual alcanza para ${p.diasParaAcabar} días`;
      alertColor = 'text-amber-400';
    } else if (p.alerta === 'SIN_ROTACION') {
      alertMsg = `⏸ Stock sin movimiento en ${p.diasParaAcabar !== null ? p.diasParaAcabar + ' días' : 'el rango consultado'}`;
      alertColor = 'text-slate-500';
    } else if (p.alerta === 'CERCA_MINIMO') {
      alertMsg = `🟡 Cerca del mínimo (${total}u / mín ${minimo}u)`;
      alertColor = 'text-amber-400';
    } else if (p.diasParaAcabar !== null) {
      alertMsg = `✅ Alcanza para ${p.diasParaAcabar} días`;
      alertColor = 'text-emerald-400';
    } else if (total > 0) {
      alertMsg = '✅ Stock estable';
      alertColor = 'text-emerald-400';
    }
    const stockColor = total < 0 ? 'text-rose-500' : total === 0 ? 'text-slate-500' : 'text-slate-100';
    const stockDisplay = total < 0 ? `⚠ ${total}u` : `${total}u`;

    return `<div class="card-sm p-4">
      <!-- Header del card: nombre + código + total + rotación + barra + alerta -->
      <div class="flex items-start justify-between gap-3 mb-2">
        <div class="min-w-0 flex-1">
          <div class="text-sm font-semibold text-slate-100 truncate">📦 ${p.descripcion || p.skuBase}</div>
          <div class="text-[11px] text-slate-500 font-mono mt-0.5 truncate">SKU <span class="text-emerald-300/70">${p.skuBase}</span>${p.codigoBarra ? ' · ▌ ' + p.codigoBarra : ''}${p.countPresentaciones > 1 ? ' <span class="text-slate-600">+ ' + (p.countPresentaciones - 1) + ' pres.</span>' : ''}${p.countEquivalencias > 0 ? ' <span class="text-purple-400/70">+ ' + p.countEquivalencias + ' equiv.</span>' : ''}</div>
        </div>
        <div class="text-right shrink-0">
          <div class="text-lg font-bold ${stockColor}">${stockDisplay}</div>
          <div class="text-[10px] text-slate-500">${p.rotacionDia > 0 ? p.rotacionDia + '/d' : '0/d'}</div>
        </div>
      </div>
      <div class="h-2 bg-slate-800 rounded overflow-hidden mb-1">
        <div class="h-full transition-all" style="width:${pct}%;background:${colorBar}"></div>
      </div>
      <div class="flex justify-between text-[10px] text-slate-500 mb-2">
        <span>mín ${minimo}u</span>
        <span class="text-slate-600">WH ${p.whCantidad}u · zonas ${p.zonasCantidad}u</span>
        <span>máx ${maximo}u</span>
      </div>
      ${alertMsg ? `<div class="text-xs ${alertColor} mb-1">${alertMsg}</div>` : ''}
      <!-- Toggle expandir / colapsar -->
      <button onclick="MOS.almToggleStockExpand('${p.skuBase}', '${p.idProducto}')"
              class="text-[11px] text-slate-500 hover:text-slate-300 mt-1 w-full text-center py-1 rounded transition-colors"
              style="background:rgba(255,255,255,0.02)">
        ${expanded ? '▴ Ocultar detalle' : '▾ Ver detalle (WH + zonas + sugerencias)'}
      </button>
      <!-- Sección expandible -->
      <div id="stockExp_${p.skuBase}" class="${expanded ? '' : 'hidden'} mt-3 pt-3 border-t border-slate-800/50">
        ${expanded ? _renderStockExpandedContent(p.skuBase) : ''}
      </div>
    </div>`;
  }

  function _renderStockExpandedContent(skuBase) {
    const cached = S._stockDetCache[skuBase];
    if (!cached) {
      // Disparar fetch en background
      _fetchStockDetail(skuBase);
      return '<div class="text-xs text-slate-500 italic py-2">Cargando detalle…</div>';
    }
    if (cached.error) return `<div class="text-xs text-rose-400 italic py-2">Error: ${cached.error}</div>`;
    const r = cached;
    const wh = r.wh || {};
    const zonas = r.zonas || [];
    const insights = r.insights || [];
    const total = r.total || {};
    const codigosBarra = r.codigosBarra || [];
    // Matriz código × zona (solo si hay >1 código y al menos 1 zona con stock)
    let matrizHtml = '';
    if (codigosBarra.length > 1 && zonas.length) {
      const cabZonas = zonas.map(z => `<th class="text-right pl-2 pb-1 text-[10px] text-slate-500 font-normal">${z.nombre}</th>`).join('');
      const filasMatriz = codigosBarra.map(c => {
        const cells = zonas.map(z => {
          const q = (c.porZona && c.porZona[z.idZona]) || 0;
          const cls = q < 0 ? 'text-rose-500' : q === 0 ? 'text-slate-700' : 'text-slate-300';
          return `<td class="text-right pl-2 ${cls}">${q !== 0 ? q + 'u' : '·'}</td>`;
        }).join('');
        const tipoBadge = c.tipo === 'principal' ? '🟢' : '🟣';
        return `<tr><td class="text-[10px] font-mono text-slate-400 py-1 pr-2 truncate" style="max-width:120px">${tipoBadge} ${c.codigoBarra}</td>${cells}</tr>`;
      }).join('');
      matrizHtml = `
        <div class="text-xs">
          <div class="font-semibold text-slate-300 mb-1">📊 Matriz código × zona</div>
          <div class="card-sm p-2 overflow-x-auto">
            <table class="text-[11px] w-full" style="border-collapse:collapse">
              <thead><tr><th class="text-left pb-1 text-[10px] text-slate-500 font-normal">Código</th>${cabZonas}</tr></thead>
              <tbody>${filasMatriz}</tbody>
            </table>
          </div>
        </div>
      `;
    }
    // Códigos asociados (principal + equivalencias)
    const codigosHtml = codigosBarra.length > 1 ? `
      <div class="text-xs">
        <div class="font-semibold text-slate-300 mb-1">🏷️ Códigos asociados (${codigosBarra.length}: ${codigosBarra.filter(c => c.tipo === 'principal').length} principal + ${(r.countEquivalencias || 0)} equivalencia${(r.countEquivalencias || 0) === 1 ? '' : 's'})</div>
        <div class="card-sm p-2 space-y-1">
          ${codigosBarra.map(c => {
            const tipoBadge = c.tipo === 'principal'
              ? '<span class="text-[9px] text-emerald-400 bg-emerald-500/10 px-1 rounded">PRINCIPAL</span>'
              : '<span class="text-[9px] text-purple-400 bg-purple-500/10 px-1 rounded">EQUIV</span>';
            const totalCb = c.stockTotal || 0;
            const cls = totalCb < 0 ? 'text-rose-500' : totalCb === 0 ? 'text-slate-500' : 'text-slate-200';
            return `<div class="flex items-center justify-between gap-2 py-0.5">
              <div class="min-w-0 flex-1 flex items-center gap-2">
                ${tipoBadge}
                <span class="font-mono text-slate-300 truncate">▌ ${c.codigoBarra}</span>
              </div>
              <div class="text-[10px] text-slate-500 whitespace-nowrap">WH ${c.stockWh}u · zonas ${c.stockZonas}u · <span class="${cls} font-semibold">total ${totalCb}u</span></div>
            </div>`;
          }).join('')}
        </div>
      </div>
    ` : '';
    // WH detail
    const whHtml = `
      <div class="text-xs">
        <div class="font-semibold text-slate-300 mb-1">🏭 Almacén central</div>
        <div class="card-sm p-2 ${wh.cantidad < 0 ? 'border-rose-500/40' : ''}">
          <div class="flex items-center justify-between">
            <div class="min-w-0 flex-1">
              <div class="text-slate-300">Stock disponible</div>
              <div class="text-[10px] text-slate-500 mt-0.5">
                ${wh.cantidad < 0 ? '<span class="text-rose-400">⚠ Stock negativo: vendiste/saliste más de lo recibido</span>' :
                  total.rotacionDia > 0 ? 'Despacha aprox. ' + total.rotacionDia + '/d' : 'Sin movimiento'}
              </div>
            </div>
            <div class="font-bold ${wh.cantidad > 0 ? 'text-blue-400' : wh.cantidad < 0 ? 'text-rose-500' : 'text-slate-500'}">
              ${wh.cantidad > 0 ? wh.cantidad + 'u' : wh.cantidad < 0 ? '⚠ ' + wh.cantidad + 'u' : (wh.detalle && wh.detalle.length > 0 ? '0u' : '— sin registro')}
            </div>
          </div>
        </div>
      </div>
    `;
    // Zonas
    const zonasHtml = `
      <div class="text-xs">
        <div class="font-semibold text-slate-300 mb-1">🏪 Distribución por zona (rot ${total.rangoDiasConsultado || 7}d)</div>
        <div class="card-sm p-2 space-y-1">
          ${zonas.map(z => {
            const sinReg = !z.tieneRegistroStock;
            const isNeg = z.cantidad < 0;
            const isCero = z.cantidad === 0;
            let stockStr, stockCls;
            if (sinReg) { stockStr = '— sin registro'; stockCls = 'text-slate-600 italic'; }
            else if (isNeg) { stockStr = `⚠ ${z.cantidad}u`; stockCls = 'text-rose-500'; }
            else if (isCero) { stockStr = '0u'; stockCls = 'text-slate-500'; }
            else { stockStr = z.cantidad + 'u'; stockCls = 'text-slate-200'; }
            let detail;
            if (sinReg && z.sinVentas) detail = '<span class="text-slate-600 italic">Producto no registrado en zona</span>';
            else if (z.sinVentas) detail = '<span class="text-slate-600">Sin ventas en ' + (total.rangoDiasConsultado || 7) + 'd</span>';
            else {
              detail = 'Vende ' + z.rotacionDia + '/d';
              if (z.diasParaAcabar !== null) detail += ` · alcanza ${z.diasParaAcabar}d`;
              else if (sinReg) detail += ' · <span class="text-rose-400">⚠ vendiéndose sin registro</span>';
              else if (isCero) detail += ' · <span class="text-rose-400">⚠ stock agotado</span>';
            }
            return `<div class="flex items-center justify-between gap-2 py-1">
              <div class="min-w-0 flex-1">
                <div class="text-slate-300">🏪 ${z.nombre}</div>
                <div class="text-[10px] text-slate-500">${detail}</div>
              </div>
              <div class="font-bold ${stockCls} shrink-0">${stockStr}</div>
            </div>`;
          }).join('')}
        </div>
      </div>
    `;
    // Insights
    const insightsHtml = insights.length ? `
      <div class="text-xs">
        <div class="font-semibold text-slate-300 mb-1">💡 Sugerencias</div>
        <div class="space-y-1">
          ${insights.map(i => {
            const cls = i.severidad === 'CRITICA' ? 'border-rose-500/40' : i.severidad === 'ALTA' ? 'border-amber-500/40' : 'border-slate-700';
            return `<div class="card-sm p-2 border-l-2 ${cls}">
              <div class="text-slate-200">${i.mensaje}</div>
              ${i.accion ? `<div class="text-[10px] text-slate-500 mt-0.5">→ ${i.accion}</div>` : ''}
            </div>`;
          }).join('')}
        </div>
      </div>
    ` : '';
    return `<div class="space-y-3">${codigosHtml}${matrizHtml}${whHtml}${zonasHtml}${insightsHtml}</div>`;
  }

  async function _fetchStockDetail(skuBase) {
    if (!skuBase) return;
    if (S._stockDetCache[skuBase] && !S._stockDetCache[skuBase].error) return;
    try {
      const r = await API.get('getStockUnificado', { skuBase });
      S._stockDetCache[skuBase] = r;
      // Re-render solo si la sección sigue expandida
      if (S._stockExpanded[skuBase]) {
        const cont = $('stockExp_' + skuBase);
        if (cont) cont.innerHTML = _renderStockExpandedContent(skuBase);
      }
    } catch(e) {
      S._stockDetCache[skuBase] = { error: e.message };
      if (S._stockExpanded[skuBase]) {
        const cont = $('stockExp_' + skuBase);
        if (cont) cont.innerHTML = _renderStockExpandedContent(skuBase);
      }
    }
  }

  function almToggleStockExpand(skuBase, idProducto) {
    if (!skuBase) return;
    S._stockExpanded[skuBase] = !S._stockExpanded[skuBase];
    // Re-render solo esa card (más rápido que renderStockTable completo)
    renderStockTable();
    // Si abrió y aún no tiene cache, ya disparó el fetch dentro del render
  }

  function renderVencTable() {
    const listC = $('listVencCrit');
    const listA = $('listVencAlerta');
    if (listC) {
      listC.innerHTML = (S.vencimientos.criticos || []).length === 0
        ? '<p class="text-slate-600">Sin vencimientos críticos</p>'
        : (S.vencimientos.criticos || []).map(l =>
            `<div class="flex justify-between items-center p-2 rounded bg-red-950/30 border border-red-900/30">
              <span class="text-red-300 text-xs">${l.codigoProducto} — Lote ${l.idLote || '—'}</span>
              <span class="badge badge-red">${l.diasRestantes}d</span>
            </div>`
          ).join('');
    }
    if (listA) {
      listA.innerHTML = (S.vencimientos.alertas || []).length === 0
        ? '<p class="text-slate-600">Sin alertas de vencimiento</p>'
        : (S.vencimientos.alertas || []).map(l =>
            `<div class="flex justify-between items-center p-2 rounded" style="background:rgba(245,158,11,.05);border:1px solid rgba(245,158,11,.15)">
              <span class="text-yellow-300 text-xs">${l.codigoProducto} — Lote ${l.idLote || '—'}</span>
              <span class="badge badge-yellow">${l.diasRestantes}d</span>
            </div>`
          ).join('');
    }
  }

  function renderMermasTable() {
    const tbody = $('tbodyMermas');
    if (!tbody) return;
    if (!S.mermas.length) {
      tbody.innerHTML = '<tr><td colspan="5" class="text-center py-8 text-slate-500 text-sm">Sin mermas registradas</td></tr>';
      return;
    }
    tbody.innerHTML = S.mermas.map(m => {
      const badge = m.estado === 'PENDIENTE' ? '<span class="badge badge-yellow">Pendiente</span>'
                  : m.estado === 'PROCESADA'  ? '<span class="badge badge-green">Procesada</span>'
                  : '<span class="badge badge-gray">' + m.estado + '</span>';
      return `<tr>
        <td class="text-xs text-slate-400">${fmtDate(m.fechaIngreso)}</td>
        <td class="text-xs sm:text-sm text-slate-200">${m.codigoProducto}</td>
        <td class="text-xs text-slate-400">${m.origen || '—'}</td>
        <td class="hidden sm:table-cell text-xs">${parseFloat(m.cantidadPendiente || 0)}</td>
        <td>${badge}</td>
      </tr>`;
    }).join('');
  }

  function renderEnvTable() {
    const tbody = $('tbodyEnv');
    if (!tbody) return;
    if (!S.envasados.length) {
      tbody.innerHTML = '<tr><td colspan="5" class="text-center py-8 text-slate-500 text-sm">Sin envasados recientes</td></tr>';
      return;
    }
    tbody.innerHTML = S.envasados.slice(-20).reverse().map(e => {
      const ef = parseFloat(e.eficienciaPct || 0);
      const color = ef >= 98 ? 'text-green-400' : ef >= 90 ? 'text-yellow-400' : 'text-red-400';
      return `<tr>
        <td class="text-xs text-slate-400">${fmtDate(e.fecha)}</td>
        <td class="text-xs sm:text-sm text-slate-200">${e.codigoProductoBase} → ${e.codigoProductoEnvasado || '—'}</td>
        <td class="hidden sm:table-cell">${e.unidadesProducidas || 0}</td>
        <td class="${color} font-semibold">${ef.toFixed(1)}%</td>
        <td><span class="badge ${e.estado === 'COMPLETADO' ? 'badge-green' : 'badge-gray'}">${e.estado || '—'}</span></td>
      </tr>`;
    }).join('');
  }

  // ── PROVEEDORES ─────────────────────────────────────────────
  const PROV_CACHE_KEY = 'mos_prov_cache';
  function _provLoadCache() {
    try {
      const raw = localStorage.getItem(PROV_CACHE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (Date.now() - (parsed.ts || 0) > 86400000) return null; // 24h
      return parsed.data;
    } catch { return null; }
  }
  function _provSaveCache(data) {
    try { localStorage.setItem(PROV_CACHE_KEY, JSON.stringify({ ts: Date.now(), data })); } catch {}
  }

  async function loadProveedores() {
    if (!API.isConfigured()) {
      $('listProveedores').innerHTML = '<p class="text-slate-500 text-sm text-center py-8">Configura el GAS URL.</p>';
      return;
    }
    // Asegurar layout mobile correcto al entrar
    const isMobile = window.matchMedia('(max-width: 1023px)').matches;
    if (isMobile && !S.provSelId) {
      $('provListWrap')?.classList.remove('hidden');
      $('provHeaderBar')?.classList.remove('hidden');
      $('provDetailWrap')?.classList.add('hidden');
    }
    // Render desde cache (instantáneo)
    const cached = _provLoadCache();
    if (cached && (!S.proveedores || !S.proveedores.length)) {
      S.proveedores = cached;
      renderProveedores();
      const cnt = $('provCount'); if (cnt) cnt.textContent = _filtrarReales(S.proveedores).length;
    }
    // Fetch fresco
    try {
      const fresh = await API.get('getProveedores', {});
      const lista = Array.isArray(fresh) ? fresh : (fresh && fresh.data) || [];
      const changed = JSON.stringify(lista) !== JSON.stringify(S.proveedores);
      S.proveedores = lista;
      _provSaveCache(lista);
      if (changed || !cached) renderProveedores();
      const cnt = $('provCount'); if (cnt) cnt.textContent = _filtrarReales(S.proveedores).length;
    } catch(e) {
      if (!S.proveedores || !S.proveedores.length) {
        $('listProveedores').innerHTML = `<p class="text-red-400 text-sm text-center py-8">${e.message}</p>`;
      }
    }
  }

  // Filtra proveedores excluyendo cargadores (nombre prefijo CARGADOR)
  function _filtrarReales(lista) {
    return (lista || []).filter(p => !String(p.nombre || '').toUpperCase().startsWith('CARGADOR'));
  }
  function _filtrarCargadores(lista) {
    return (lista || []).filter(p => String(p.nombre || '').toUpperCase().startsWith('CARGADOR'));
  }

  // Refresh silencioso periódico (igual que catalogo)
  let _provRefreshTimer = null;
  function _startProvRefresh() {
    if (_provRefreshTimer) clearInterval(_provRefreshTimer);
    _provRefreshTimer = setInterval(() => {
      loadProveedores().catch(() => {});
    }, 120000); // cada 2 minutos
  }

  // ── Cargadores (proveedores con prefijo CARGADOR) ─────────
  function abrirVistaCargadores() {
    _renderCargadores();
    openModal('modalCargadores');
  }

  function _renderCargadores() {
    const cargadores = _filtrarCargadores(S.proveedores);
    const cnt = $('cargCount');
    if (cnt) cnt.textContent = cargadores.length;
    const list = $('listCargadores');
    if (!list) return;
    if (!cargadores.length) {
      list.innerHTML = '<p class="text-sm text-slate-500 text-center py-6">No hay cargadores registrados.</p>';
      return;
    }
    list.innerHTML = cargadores.map(c => `
      <div class="card-sm p-3 cursor-pointer hover:border-amber-500/30 transition-colors" onclick="MOS.editarCargador('${c.idProveedor}')">
        <div class="flex items-center justify-between">
          <div class="min-w-0 flex-1">
            <div class="text-sm font-semibold text-slate-100 truncate">${c.nombre}</div>
            <div class="text-xs text-slate-500 mt-0.5">${c.telefono || ''} ${c.dni ? '· DNI ' + c.dni : ''}</div>
          </div>
          <span class="text-xs text-slate-400">✏️</span>
        </div>
      </div>
    `).join('');
  }

  // Cierra el modal de cargadores y abre el modal de edición de proveedor
  function editarCargador(idProveedor) {
    closeModal('modalCargadores');
    setTimeout(() => abrirModalProveedor(idProveedor), 100);
  }

  function nuevoCargador() {
    closeModal('modalCargadores');
    abrirModalProveedor(null);
    // Pre-llenar el nombre con prefijo
    setTimeout(() => {
      const inp = $('provNombre');
      if (inp && !inp.value) inp.value = 'CARGADOR ';
    }, 50);
  }

  function renderProveedores() {
    const el = $('listProveedores');
    if (!el) return;
    const reales = _filtrarReales(S.proveedores);
    if (!reales.length) {
      el.innerHTML = '<p class="text-slate-500 text-sm text-center py-8">Sin proveedores</p>';
      return;
    }
    el.innerHTML = reales.map(p => `
      <div class="card mb-2 p-3 cursor-pointer hover:border-indigo-500/30 transition-colors ${S.provSelId === p.idProveedor ? 'border-indigo-500/50' : ''}"
           onclick="MOS.selectProveedor('${p.idProveedor}')">
        <div class="flex items-start justify-between gap-2">
          <div>
            <div class="font-medium text-sm text-slate-200">${p.nombre}</div>
            <div class="text-xs text-slate-500 mt-0.5">${p.ruc || '—'}</div>
          </div>
          <span class="badge ${p.estado == '1' ? 'badge-green' : 'badge-gray'} shrink-0">${p.estado == '1' ? 'Activo' : 'Inactivo'}</span>
        </div>
        <div class="flex items-center gap-3 mt-2 text-xs text-slate-500">
          ${p.telefono ? `<span>📞 ${p.telefono}</span>` : ''}
          ${p.formaPago ? `<span>${p.formaPago === 'CREDITO' ? `Crédito ${p.plazoCredito}d` : 'Contado'}</span>` : ''}
        </div>
      </div>
    `).join('');
  }

  async function selectProveedor(id) {
    // Reset filtros si se cambia de proveedor
    if (S.provSelId !== id) {
      S.provProdFilter = '';
      S.provHistFilter = '';
    }
    S.provSelId = id;
    S.provTab   = S.provTab || 'info';
    renderProveedores();

    // En mobile: ocultar lista + header, mostrar solo detalle
    const isMobile = window.matchMedia('(max-width: 1023px)').matches;
    if (isMobile) {
      $('provListWrap')?.classList.add('hidden');
      $('provHeaderBar')?.classList.add('hidden');
    }
    $('provDetailWrap')?.classList.remove('hidden');

    const prov = S.proveedores.find(p => p.idProveedor === id);
    if (!prov) return;

    // Pre-carga de todos los tabs en paralelo (no espera para mostrar la UI)
    _precargarProvData(id);

    const detailEl = $('proveedorDetail');
    if (!detailEl) return;
    const safeNombre = (prov.nombre || '').replace(/"/g, '&quot;');
    const meta = [prov.ruc, prov.email].filter(Boolean).join(' · ');
    detailEl.innerHTML = `
      <!-- Header sticky: back (mobile) + nombre + editar -->
      <div class="prov-detail-header">
        <div class="flex items-center gap-2 mb-2">
          <button onclick="MOS.cerrarDetalleProveedor()" class="lg:hidden btn-ghost px-2 py-1 text-base shrink-0" title="Volver">←</button>
          <div class="flex-1 min-w-0">
            <h3 class="font-bold text-white truncate text-base lg:text-lg">${safeNombre}</h3>
            <p class="text-xs text-slate-500 truncate">${meta || '—'}</p>
          </div>
          <button class="btn-ghost text-xs px-2 py-1 shrink-0" onclick="MOS.abrirModalProveedor('${id}')" title="Editar proveedor">✏️</button>
        </div>
        <div class="prov-tabs-wrap">
          <div class="prov-tabs">
            <button class="prov-tab" data-tab="info"      onclick="MOS.provSetTab('info')">📋 Info</button>
            <button class="prov-tab" data-tab="productos" onclick="MOS.provSetTab('productos')">📦 Productos</button>
            <button class="prov-tab" data-tab="historico" onclick="MOS.provSetTab('historico')">📊 Histórico</button>
            <button class="prov-tab" data-tab="pedidos"   onclick="MOS.provSetTab('pedidos')">🛒 Pedidos</button>
          </div>
        </div>
      </div>
      <!-- Contenido de cada tab -->
      <div id="provTabInfo" class="prov-tab-content"></div>
      <div id="provTabProductos" class="prov-tab-content hidden"></div>
      <div id="provTabHistorico" class="prov-tab-content hidden"></div>
      <div id="provTabPedidos" class="prov-tab-content hidden"></div>
    `;
    provSetTab(S.provTab);
  }

  // ── Pre-carga paralela de los 4 tabs del proveedor ─────────
  S.provPagos     = S.provPagos     || {};
  S.provProductos = S.provProductos || {};
  S.provHistorico = S.provHistorico || {};
  S.provPedidos   = S.provPedidos   || {};

  function _precargarProvData(id) {
    if (!id) return;
    // Pagos
    API.get('getPagos', { idProveedor: id })
      .then(r => {
        S.provPagos[id] = Array.isArray(r) ? r : (r && r.data) || [];
        if (S.provSelId === id && S.provTab === 'info') _renderProvInfo();
      }).catch(() => {});
    // Productos cotizados
    API.get('getProveedorProductos', { idProveedor: id })
      .then(r => {
        S.provProductos[id] = Array.isArray(r) ? r : (r && r.data) || [];
        if (S.provSelId === id && S.provTab === 'productos') _renderProvProductos();
      }).catch(() => {});
    // Histórico (60 días default)
    API.get('getHistoricoProveedor', { idProveedor: id, dias: 60 })
      .then(r => {
        S.provHistorico[id] = (r && r.data) ? r.data : r;
        if (S.provSelId === id && S.provTab === 'historico') _renderProvHistorico();
      }).catch(() => {});
    // Pedidos
    API.get('getPedidos', { idProveedor: id })
      .then(r => {
        S.provPedidos[id] = Array.isArray(r) ? r : (r && r.data) || [];
        if (S.provSelId === id && S.provTab === 'pedidos') _renderProvPedidos();
      }).catch(() => {});
  }

  function cerrarDetalleProveedor() {
    S.provSelId = null;
    $('provListWrap')?.classList.remove('hidden');
    $('provHeaderBar')?.classList.remove('hidden');
    const isMobile = window.matchMedia('(max-width: 1023px)').matches;
    if (isMobile) $('provDetailWrap')?.classList.add('hidden');
    renderProveedores();
  }

  function provSetTab(tab) {
    S.provTab = tab;
    document.querySelectorAll('.prov-tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
    document.querySelectorAll('.prov-tab-content').forEach(c => c.classList.add('hidden'));
    const targetMap = { info: 'provTabInfo', productos: 'provTabProductos', historico: 'provTabHistorico', pedidos: 'provTabPedidos' };
    const target = $(targetMap[tab]);
    if (target) target.classList.remove('hidden');
    if (tab === 'info')      _renderProvInfo();
    if (tab === 'productos') _renderProvProductos();
    if (tab === 'historico') _renderProvHistorico();
    if (tab === 'pedidos')   _renderProvPedidos();
  }

  function _renderProvInfo() {
    const id = S.provSelId;
    const prov = S.proveedores.find(p => p.idProveedor === id);
    const cont = $('provTabInfo');
    if (!cont || !prov) return;
    cont.innerHTML = `
      <div class="grid sm:grid-cols-2 gap-3 mb-4">
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Teléfono: </span><span class="text-slate-200">${prov.telefono || '—'}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Banco: </span><span class="text-slate-200">${prov.banco || '—'}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Cuenta: </span><span class="text-slate-200">${prov.numeroCuenta || '—'}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Día pago: </span><span class="text-slate-200">${prov.diaPago || '—'}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Forma pago: </span><span class="text-slate-200">${prov.formaPago || '—'}${prov.plazoCredito ? ' · ' + prov.plazoCredito + 'd' : ''}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Categoría: </span><span class="text-slate-200">${prov.categoriaProducto || '—'}</span></div>
      </div>
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm text-slate-300">💰 Pagos registrados</h4>
        <button class="btn-primary text-xs px-3 py-1.5" onclick="MOS.abrirModalPago('${id}')">+ Pago</button>
      </div>
      <div id="listPagos" class="text-sm text-slate-400"></div>
    `;
    // Render desde cache primero (instantáneo); sino fetch fresco
    if (S.provPagos[id]) {
      renderPagos(S.provPagos[id]);
    } else {
      $('listPagos').textContent = 'Cargando...';
      API.get('getPagos', { idProveedor: id }).then(r => {
        S.provPagos[id] = Array.isArray(r) ? r : (r && r.data) || [];
        renderPagos(S.provPagos[id]);
      }).catch(() => {});
    }
  }

  function _filtrarPP(items, q) {
    if (!q) return items;
    const qn = _norm(q);
    const palabras = qn.split(/\s+/).filter(Boolean);
    return items.filter(pp => {
      const hay = _norm((pp.descripcion || '') + ' ' + (pp.skuBase || '') + ' ' + (pp.codigoBarra || '') + ' ' + (pp.notas || ''));
      return palabras.every(w => hay.indexOf(w) >= 0);
    });
  }

  function _pintaProvProductos(items) {
    const list = $('provProductosList');
    if (!list) return;
    if (!items.length) {
      const filtro = S.provProdFilter || '';
      list.innerHTML = filtro
        ? `<p class="text-slate-500 text-sm py-6 text-center">Sin coincidencias para "${filtro}".</p>`
        : '<p class="text-slate-500 text-sm py-6 text-center">Sin productos registrados.<br>Agrega cotizaciones para planificar pedidos.</p>';
      return;
    }
    list.innerHTML = items.map(pp => `
      <div class="card-sm p-3 hover:border-indigo-500/30 transition-colors${pp._tmp ? ' opacity-60' : ''}">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1 cursor-pointer" onclick="MOS.abrirModalProvProducto('${pp.idPP}')">
            <div class="text-sm font-semibold text-slate-100 truncate">${pp.descripcion || pp.skuBase}</div>
            <div class="text-xs text-slate-500 mt-0.5 truncate" style="font-family:monospace">SKU ${pp.skuBase}${pp.codigoBarra ? ' · ▌' + pp.codigoBarra : ''}</div>
            ${pp.notas ? `<div class="text-xs text-slate-500 mt-1 italic truncate">${pp.notas}</div>` : ''}
          </div>
          <div class="text-right shrink-0 flex flex-col items-end gap-0.5">
            <div class="text-sm font-bold text-amber-400 whitespace-nowrap">${fmtMoney(pp.precioReferencia || 0)}</div>
            <div class="flex items-center gap-1 text-[10px] text-slate-500 whitespace-nowrap">
              ${pp.minimoCompra ? `<span>mín ${pp.minimoCompra}</span>` : ''}
              ${pp.diasEntrega ? `<span>${pp.diasEntrega}d</span>` : ''}
            </div>
            <button onclick="event.stopPropagation();MOS.eliminarProvProductoRapido('${pp.idPP}')" class="text-slate-500 hover:text-red-400 transition-colors text-base mt-0.5 p-1" title="Eliminar">🗑️</button>
          </div>
        </div>
      </div>
    `).join('');
  }

  function _filtrarProvProductos(q) {
    S.provProdFilter = q || '';
    const id = S.provSelId;
    if (!id) return;
    const items = _filtrarPP(S.provProductos[id] || [], S.provProdFilter);
    _pintaProvProductos(items);
  }

  async function _renderProvProductos() {
    const id = S.provSelId;
    const cont = $('provTabProductos');
    if (!cont) return;
    S.provProductos = S.provProductos || {};
    S.provProdFilter = S.provProdFilter || '';

    // Asegurar contenedor (con buscador + botón)
    if (!cont.querySelector('#provProductosList')) {
      cont.innerHTML = `
        <div class="flex items-center gap-2 mb-3 flex-wrap">
          <h4 class="font-semibold text-sm text-slate-300 shrink-0">📦 Catálogo</h4>
          <input id="provProdFilter" class="inp text-xs flex-1" style="min-width:120px;max-width:200px"
            placeholder="🔍 Filtrar..." oninput="MOS._filtrarProvProductos(this.value)" value="${S.provProdFilter}">
          <button class="btn-primary text-xs px-3 py-1.5 shrink-0" onclick="MOS.abrirModalProvProducto(null)">+ Producto</button>
        </div>
        <div id="provProductosList" class="space-y-2"></div>
      `;
    }
    const list = $('provProductosList');

    // Render cache si existe (instantáneo)
    if (S.provProductos[id]) {
      _pintaProvProductos(_filtrarPP(S.provProductos[id], S.provProdFilter));
    } else {
      list.innerHTML = '<div class="skel h-12 rounded-lg"></div>';
    }

    // Fetch fresco
    try {
      const lista = await API.get('getProveedorProductos', { idProveedor: id });
      const items = Array.isArray(lista) ? lista : (lista && lista.data) || [];
      S.provProductos[id] = items;
      _pintaProvProductos(_filtrarPP(items, S.provProdFilter));
    } catch(e) {
      if (!S.provProductos[id]) list.innerHTML = `<p class="text-red-400 text-sm">Error: ${e.message}</p>`;
    }
  }

  function _filtrarHist(productos, q) {
    if (!q) return productos;
    const qn = _norm(q);
    const palabras = qn.split(/\s+/).filter(Boolean);
    return productos.filter(it => {
      const hay = _norm((it.descripcion || '') + ' ' + (it.codigoBarra || ''));
      return palabras.every(w => hay.indexOf(w) >= 0);
    });
  }

  function _pintaProvHistorico(data) {
    const body = $('provHistoricoBody');
    if (!body) return;
    if (!data || (!data.productos || !data.productos.length)) {
      body.innerHTML = '<p class="text-slate-500 text-sm py-6 text-center">Sin compras registradas en el rango.</p>';
      return;
    }
    const filtro = S.provHistFilter || '';
    const productos = _filtrarHist(data.productos, filtro);
    body.innerHTML = `
      <div class="grid grid-cols-3 gap-2 mb-3">
        <div class="card-sm p-2 text-center"><div class="text-[10px] text-slate-500 uppercase tracking-wide">Guías</div><div class="text-base sm:text-lg font-bold text-slate-100">${data.totalGuias}</div></div>
        <div class="card-sm p-2 text-center"><div class="text-[10px] text-slate-500 uppercase tracking-wide">Gastado</div><div class="text-base sm:text-lg font-bold text-amber-400 truncate">${fmtMoney(data.totalGastado)}</div></div>
        <div class="card-sm p-2 text-center"><div class="text-[10px] text-slate-500 uppercase tracking-wide">Por pagar</div><div class="text-base sm:text-lg font-bold ${data.porPagar > 0 ? 'text-rose-400' : 'text-green-400'} truncate">${fmtMoney(data.porPagar)}</div></div>
      </div>
      <div class="text-xs text-slate-500 mb-2">${productos.length} de ${data.productos.length} productos${filtro ? ' · filtro: "' + filtro + '"' : ''}</div>
      <div class="space-y-1">
        ${productos.length ? productos.map(it => `
          <div class="card-sm p-2.5">
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0 flex-1">
                <div class="text-sm font-medium text-slate-200 truncate">${it.descripcion}</div>
                <div class="text-xs text-slate-500 truncate" style="font-family:monospace">▌${it.codigoBarra} · ${it.veces}× · ${it.cantidadTotal}u</div>
              </div>
              <div class="text-right shrink-0">
                <div class="text-sm font-bold text-slate-100">${fmtMoney(it.ultimoPrecio)}</div>
                <div class="text-xs ${it.variacionPct > 1 ? 'text-rose-400' : it.variacionPct < -1 ? 'text-green-400' : 'text-slate-500'}">${it.variacionPct > 0 ? '↑' : it.variacionPct < 0 ? '↓' : '='} ${Math.abs(it.variacionPct)}%</div>
              </div>
            </div>
          </div>
        `).join('') : '<p class="text-slate-500 text-sm py-4 text-center italic">Sin coincidencias.</p>'}
      </div>
    `;
  }

  function _filtrarProvHistorico(q) {
    S.provHistFilter = q || '';
    const id = S.provSelId;
    if (id && S.provHistorico[id]) _pintaProvHistorico(S.provHistorico[id]);
  }

  async function _renderProvHistorico() {
    const id = S.provSelId;
    const cont = $('provTabHistorico');
    if (!cont) return;
    S.provHistFilter = S.provHistFilter || '';
    // Asegurar contenedor base (con filtro)
    if (!cont.querySelector('#provHistoricoBody')) {
      cont.innerHTML = `
        <div class="flex items-center gap-2 mb-3 flex-wrap">
          <h4 class="font-semibold text-sm text-slate-300 shrink-0">📊 Histórico</h4>
          <input id="provHistFilter" class="inp text-xs flex-1" style="min-width:100px;max-width:180px"
            placeholder="🔍 Filtrar..." oninput="MOS._filtrarProvHistorico(this.value)" value="${S.provHistFilter}">
          <select id="provHistoricoDias" class="inp text-xs shrink-0" style="max-width:90px" onchange="MOS._refetchHistoricoProv()">
            <option value="30">30d</option>
            <option value="60" selected>60d</option>
            <option value="90">90d</option>
            <option value="180">180d</option>
          </select>
        </div>
        <div id="provHistoricoBody"></div>
      `;
    }

    // Render desde cache si existe (instantáneo)
    if (S.provHistorico[id]) {
      _pintaProvHistorico(S.provHistorico[id]);
    } else {
      $('provHistoricoBody').innerHTML = '<div class="skel h-32 rounded-lg"></div>';
    }

    // Fetch fresco
    try {
      const dias = parseInt($('provHistoricoDias')?.value) || 60;
      const r = await API.get('getHistoricoProveedor', { idProveedor: id, dias });
      const data = r && r.data ? r.data : r;
      S.provHistorico[id] = data;
      _pintaProvHistorico(data);
    } catch(e) {
      if (!S.provHistorico[id]) {
        $('provHistoricoBody').innerHTML = `<p class="text-red-400 text-sm">Error: ${e.message}</p>`;
      }
    }
  }

  // Forzar refetch al cambiar el rango de días
  function _refetchHistoricoProv() {
    const id = S.provSelId;
    if (id) S.provHistorico[id] = null;
    _renderProvHistorico();
  }

  async function _renderProvPedidos() {
    const id = S.provSelId;
    const cont = $('provTabPedidos');
    if (!cont) return;
    cont.innerHTML = `
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm text-slate-300">🛒 Pedidos de compra</h4>
        <button class="btn-primary text-xs px-3 py-1.5" onclick="MOS.abrirModalPedido('${id}')">+ Nuevo pedido</button>
      </div>
      <div id="listPedidos" class="text-sm text-slate-400"></div>
    `;
    // Render desde cache primero
    if (S.provPedidos[id]) {
      renderPedidos(S.provPedidos[id]);
    } else {
      $('listPedidos').textContent = 'Cargando...';
      try {
        const r = await API.get('getPedidos', { idProveedor: id });
        S.provPedidos[id] = Array.isArray(r) ? r : (r && r.data) || [];
        renderPedidos(S.provPedidos[id]);
      } catch(e) {
        $('listPedidos').innerHTML = `<p class="text-red-400">Error: ${e.message}</p>`;
      }
    }
  }

  function renderPagos(pagos) {
    const el = $('listPagos');
    if (!el) return;
    if (!pagos.length) { el.innerHTML = '<p class="text-slate-600">Sin pagos registrados</p>'; return; }
    const total = pagos.reduce((s, p) => s + parseFloat(p.monto || 0), 0);
    el.innerHTML = `<p class="text-xs text-slate-500 mb-2">Total: <span class="text-indigo-400 font-semibold">${fmtMoney(total)}</span></p>` +
      pagos.slice(-5).reverse().map(p => `
        <div class="flex justify-between items-center gap-2 py-1.5 border-b border-slate-800/50">
          <div class="min-w-0 flex-1">
            <span class="text-slate-300 text-xs">${fmtDate(p.fecha)}</span>
            ${p.numeroFactura ? `<span class="text-slate-500 ml-2 text-xs truncate">${p.numeroFactura}</span>` : ''}
          </div>
          <span class="font-semibold text-green-400 text-sm whitespace-nowrap shrink-0">${fmtMoney(p.monto)}</span>
        </div>
      `).join('');
  }

  function renderPedidos(pedidos) {
    const el = $('listPedidos');
    if (!el) return;
    if (!pedidos.length) { el.innerHTML = '<p class="text-slate-600">Sin pedidos registrados</p>'; return; }
    el.innerHTML = pedidos.slice(-5).reverse().map(p => {
      const badge = p.estado === 'BORRADOR' ? 'badge-gray' : p.estado === 'CONFIRMADO' ? 'badge-blue' : 'badge-green';
      return `<div class="flex justify-between items-center gap-2 py-1.5 border-b border-slate-800/50">
        <div class="min-w-0 flex-1">
          <div class="text-slate-300 text-xs truncate">${p.idPedido}</div>
          <div class="text-slate-500 text-[10px]">${fmtDate(p.fechaCreacion)}</div>
        </div>
        <div class="flex flex-col items-end gap-0.5 shrink-0">
          <span class="text-slate-300 text-sm whitespace-nowrap">${fmtMoney(p.montoEstimado)}</span>
          <span class="badge ${badge} text-[10px]">${p.estado}</span>
        </div>
      </div>`;
    }).join('');
  }

  // ── MODALS ──────────────────────────────────────────────────
  function openModal(id)  { const el = $(id); if (el) { el.classList.remove('hidden'); el.classList.add('open'); } }
  function closeModal(id) { const el = $(id); if (el) { el.classList.remove('open'); el.classList.add('hidden'); } }

  function openEcoModal(app) {
    const eco = S._ecoData;
    const titleEl = $('ecoModalTitle');
    const bodyEl  = $('ecoModalBody');
    if (!titleEl || !bodyEl) return;

    // Si aún no llegaron datos (primera carga), esperar y reintentar
    if (!eco) {
      titleEl.textContent = app === 'wh' ? 'warehouseMos' : 'MosExpress';
      bodyEl.innerHTML = `<div class="flex items-center gap-3 py-4 text-slate-400 text-sm">
        <span class="dot-loading" style="width:10px;height:10px"></span>Cargando datos...</div>`;
      openModal('modalEcosistema');
      // Reintentar en 2s por si la llamada GAS aún está en vuelo
      setTimeout(() => {
        if (S._ecoData && $('modalEcosistema')?.classList.contains('open')) {
          closeModal('modalEcosistema');
          openEcoModal(app);
        }
      }, 2000);
      return;
    }

    const _fmt = n => new Intl.NumberFormat('es-PE', { minimumFractionDigits: 2 }).format(n || 0);
    const _dot = c => `<span class="inline-block w-2.5 h-2.5 rounded-full ${c === 'green' ? 'bg-green-400' : c === 'yellow' ? 'bg-yellow-400' : c === 'red' ? 'bg-red-400' : 'bg-slate-500'}"></span>`;

    // Paleta de colores para zonas (se repite si hay muchas)
    const ZONA_PALETA = [
      { bg: 'bg-indigo-900/60',  border: 'border-indigo-500/40',  badge: 'bg-indigo-500/20 text-indigo-300',  dot: 'bg-indigo-400' },
      { bg: 'bg-emerald-900/50', border: 'border-emerald-500/40', badge: 'bg-emerald-500/20 text-emerald-300', dot: 'bg-emerald-400' },
      { bg: 'bg-amber-900/40',   border: 'border-amber-500/40',   badge: 'bg-amber-500/20 text-amber-300',    dot: 'bg-amber-400'  },
      { bg: 'bg-rose-900/40',    border: 'border-rose-500/40',    badge: 'bg-rose-500/20 text-rose-300',      dot: 'bg-rose-400'   },
      { bg: 'bg-cyan-900/40',    border: 'border-cyan-500/40',    badge: 'bg-cyan-500/20 text-cyan-300',      dot: 'bg-cyan-400'   },
    ];

    if (app === 'me') {
      const d = eco.me;
      titleEl.innerHTML = `🛒 MosExpress &nbsp;${_dot(d?.color)}`;
      if (!d || d.error) {
        bodyEl.innerHTML = `<p class="text-red-400 text-sm">${d?.error || 'Sin datos'}</p>`;
      } else {
        // ── KPIs globales ──
        let html = `
          <div class="grid grid-cols-2 gap-3 mb-5">
            <div class="bg-slate-800 rounded-xl p-3">
              <div class="text-2xl font-bold text-white">${d.ventasHoy}</div>
              <div class="text-xs text-slate-400 mt-0.5">Ventas hoy</div>
            </div>
            <div class="bg-slate-800 rounded-xl p-3">
              <div class="text-2xl font-bold text-white">S/ ${_fmt(d.totalHoy)}</div>
              <div class="text-xs text-slate-400 mt-0.5">Total hoy · ${d.ultimaVenta}</div>
            </div>
          </div>`;

        // ── Zonas ──
        const zonas = d.zonas || [];
        if (zonas.length) {
          html += `<div class="text-xs text-slate-400 uppercase tracking-widest font-semibold mb-2">Por zona</div>
          <div class="space-y-2 mb-5">`;
          zonas.forEach((z, idx) => {
            const pal = ZONA_PALETA[idx % ZONA_PALETA.length];
            html += `
            <div class="rounded-xl border ${pal.bg} ${pal.border} p-3">
              <div class="flex items-center justify-between mb-2">
                <div class="flex items-center gap-2">
                  <span class="w-2 h-2 rounded-full ${pal.dot} inline-block"></span>
                  <span class="text-sm font-semibold text-slate-100">${z.zona}</span>
                </div>
                <span class="text-xs px-2 py-0.5 rounded-full ${pal.badge}">${z.ventas} venta${z.ventas !== 1 ? 's' : ''}</span>
              </div>
              <div class="flex items-center justify-between">
                <span class="text-lg font-bold text-white">S/ ${_fmt(z.total)}</span>
                <span class="text-xs text-slate-400">${z.ultimaVenta}</span>
              </div>
            </div>`;
          });
          html += `</div>`;
        }

        // ── Personal del día ──
        const personal = d.personal || [];
        const activos  = personal.filter(p => p.estado === 'activo');
        const cerrados = personal.filter(p => p.estado === 'cerrado');

        html += `<div class="text-xs text-slate-400 uppercase tracking-widest font-semibold mb-2">
          Personal hoy <span class="ml-1 text-slate-500 normal-case">(${personal.length} turno${personal.length !== 1 ? 's' : ''})</span>
        </div>`;

        if (!personal.length) {
          html += `<p class="text-xs text-slate-500 py-2">Sin registros hoy</p>`;
        } else {
          html += `<div class="space-y-1.5">`;
          // Activos primero
          personal.forEach(p => {
            const zonaPal = ZONA_PALETA[zonas.findIndex(z => z.zona === p.zona) % ZONA_PALETA.length] || ZONA_PALETA[0];
            const esActivo = p.estado === 'activo';
            html += `
            <div class="flex items-center gap-2.5 rounded-lg px-3 py-2 ${esActivo ? 'bg-slate-700/60' : 'bg-slate-800/40'}">
              <span class="inline-block w-2 h-2 rounded-full flex-shrink-0 ${esActivo ? 'bg-green-400' : 'bg-slate-500'}"></span>
              <div class="flex-1 min-w-0">
                <div class="text-sm text-slate-100 font-medium truncate">${p.nombre}</div>
                <div class="text-xs text-slate-400">${p.estacion}${p.zona && p.zona !== '—' ? ' · <span class="' + zonaPal.badge.split(' ')[1] + '">' + p.zona + '</span>' : ''}</div>
              </div>
              <div class="text-right flex-shrink-0">
                ${esActivo
                  ? `<span class="text-xs text-green-400 font-medium">Activo</span><div class="text-xs text-slate-500">desde ${p.desde}</div>`
                  : `<span class="text-xs text-slate-500">Cerró ${p.hasta || '—'}</span><div class="text-xs text-slate-600">abrió ${p.desde}</div>`
                }
              </div>
            </div>`;
          });
          html += `</div>`;
        }

        bodyEl.innerHTML = html;
      }
    } else {
      const d = eco.wh;
      titleEl.innerHTML = `🏭 warehouseMos &nbsp;${_dot(d?.color)}`;
      if (!d || d.error) {
        bodyEl.innerHTML = `<p class="text-red-400 text-sm">${d?.error || 'Sin datos'}</p>`;
      } else {
        const sesion = d.sesionActiva
          ? `<span class="text-green-300">${d.sesionActiva.usuario} (${d.sesionActiva.rol}) · desde ${d.sesionActiva.desde}</span>`
          : '<span class="text-slate-500">Ninguna activa</span>';
        bodyEl.innerHTML = `
          <div class="grid grid-cols-3 gap-3 mb-4">
            <div class="bg-slate-800 rounded-xl p-3">
              <div class="text-2xl font-bold text-white">${d.entradasHoy}</div>
              <div class="text-xs text-slate-400 mt-0.5">Entradas hoy</div>
            </div>
            <div class="bg-slate-800 rounded-xl p-3">
              <div class="text-2xl font-bold text-white">${d.salidasHoy}</div>
              <div class="text-xs text-slate-400 mt-0.5">Salidas hoy</div>
            </div>
            <div class="bg-slate-800 rounded-xl p-3">
              <div class="text-2xl font-bold ${d.stockCritico > 0 ? 'text-red-400' : 'text-white'}">${d.stockCritico}</div>
              <div class="text-xs text-slate-400 mt-0.5">Stock crítico</div>
            </div>
          </div>
          <div class="mb-1 text-xs text-slate-400 uppercase tracking-widest font-semibold">Última guía</div>
          <p class="text-sm text-slate-200 mb-4">${d.ultimaGuia || '—'}</p>
          <div class="mb-1 text-xs text-slate-400 uppercase tracking-widest font-semibold">Sesión activa</div>
          <p class="text-sm mb-0">${sesion}</p>`;
      }
    }
    openModal('modalEcosistema');
  }

  function openConfig() {
    const inp = $('cfgGasUrl');
    if (inp) inp.value = API.getUrl();
    const tr = $('cfgTestResult');
    if (tr) { tr.classList.add('hidden'); tr.textContent = ''; }
    openModal('modalConfig');
  }

  function saveConfig() {
    const url = ($('cfgGasUrl')?.value || '').trim();
    API.setUrl(url);
    closeModal('modalConfig');
    setStatus(!!url);
    if (url) {
      toast('URL guardada. Actualizando datos...', 'ok');
      S.loaded = {};
      loadView(S.view);
    } else {
      const b = $('bannerNoUrl'); if (b) b.classList.remove('hidden');
    }
  }

  async function testConnection() {
    const url = ($('cfgGasUrl')?.value || '').trim();
    if (!url) { toast('Ingresa la URL primero', 'error'); return; }
    API.setUrl(url);
    const tr = $('cfgTestResult');
    if (tr) { tr.classList.remove('hidden'); tr.style.background = '#0f172a'; tr.textContent = 'Probando...'; }
    try {
      const d = await API.get('getConfig', {});
      if (tr) {
        tr.style.background = '#052e16'; tr.style.border = '1px solid #14532d'; tr.style.color = '#86efac';
        tr.textContent = '✓ Conexión exitosa — ' + (d?.EMPRESA_NOMBRE || 'MOS');
      }
    } catch (e) {
      if (tr) {
        tr.style.background = '#450a0a'; tr.style.border = '1px solid #7f1d1d'; tr.style.color = '#fca5a5';
        tr.textContent = '✗ Error: ' + e.message;
      }
    }
  }

  // ── Product modal — helpers ────────────────────────────────
  let _prodTipo = 'normal';

  function setProdTipo(tipo) {
    // tipo: 'normal' | 'envasable' | 'derivado' | 'presentacion'
    _prodTipo = tipo;
    // Sincronizar checkboxes
    const cbPres = $('cbEsPresentacion');
    const cbDer  = $('cbEsDerivado');
    const cbEnv  = $('cbEsEnvasable');
    if (cbPres) cbPres.checked = (tipo === 'presentacion');
    if (cbDer)  cbDer.checked  = (tipo === 'derivado');
    if (cbEnv)  cbEnv.checked  = (tipo === 'envasable');
    // Mostrar / ocultar secciones
    $('prodSecDerivado')?.classList.toggle('hidden', tipo !== 'derivado');
    $('prodSecPresentacion')?.classList.toggle('hidden', tipo !== 'presentacion');
    if (tipo === 'derivado')     _poblarEnvasablesSelect();
    if (tipo === 'presentacion') _poblarBasesSelect();
  }

  // Handler de los checkboxes mutex (presentación/derivado)
  function onTipoCheck(tipo, checked) {
    if (!checked) { setProdTipo('normal'); return; }
    // Mutex: si marca presentacion, desmarca derivado y viceversa
    setProdTipo(tipo);
  }
  // Handler del checkbox independiente "es envasable"
  function onEnvasableCheck(checked) {
    // envasable es independiente de presentacion/derivado
    if (checked) {
      // Si tenía presentación o derivado activo, lo desmarca (envasable es base)
      const cbPres = $('cbEsPresentacion');
      const cbDer  = $('cbEsDerivado');
      if (cbPres) cbPres.checked = false;
      if (cbDer)  cbDer.checked  = false;
      _prodTipo = 'envasable';
      $('prodSecDerivado')?.classList.add('hidden');
      $('prodSecPresentacion')?.classList.add('hidden');
    } else {
      _prodTipo = 'normal';
    }
  }

  function _esEnvasable(p) {
    const v = p.esEnvasable;
    return v === 1 || v === '1' || v === true || v === 'true' || v === 'Sí';
  }

  // Normaliza unidades legacy a códigos SUNAT (consistencia con prodUnidadMedida)
  // Aceptamos códigos SUNAT directos: NIU, KGM, LTR, BG, BX, PR, PK, ZZ
  // Mapeamos legacy: UNIDAD→NIU, KG→KGM, LITRO→LTR, BOLSA/SOBRE/SACO→BG, CAJA→BX
  const _UNIDAD_LEGACY_MAP = {
    'UNIDAD': 'NIU', 'UND': 'NIU', 'U': 'NIU', '': 'NIU',
    'KG': 'KGM', 'KILO': 'KGM', 'KILOGRAMO': 'KGM',
    'LITRO': 'LTR', 'LT': 'LTR', 'L': 'LTR',
    'BOLSA': 'BG', 'SOBRE': 'BG', 'SACO': 'BG',
    'CAJA': 'BX',
    'PAR': 'PR',
    'PAQUETE': 'PK', 'PACK': 'PK',
    'SERVICIO': 'ZZ'
  };
  function _normalizarUnidad(u) {
    if (!u) return 'NIU';
    const up = String(u).trim().toUpperCase();
    return _UNIDAD_LEGACY_MAP[up] || up;  // si ya es SUNAT, lo deja igual
  }
  // Display de unidad con ícono — ⚖️ para KGM (granel), × para el resto
  function _unidadDisplay(u) {
    const norm = _normalizarUnidad(u);
    return norm === 'KGM' ? `⚖️ ${norm}` : `× ${norm}`;
  }

  // Producto activo si estado NO es explícitamente 0/'0'/false.
  // Importante: Sheets convierte '0' en número 0; el check viejo usaba !p.estado,
  // que con estado=0 (número) daba true incorrectamente — producto se veía activo.
  function _isProdActivo(p) {
    if (!p) return false;
    const e = p.estado;
    if (e === 0 || e === '0' || e === false) return false;
    if (typeof e === 'string' && e.toLowerCase() === 'false') return false;
    return true;
  }

  function _poblarEnvasablesSelect() {
    const sel = $('prodCodigoProductoBase');
    if (!sel) return;
    const cur = sel.value;
    const items = S.productos.filter(p => _esEnvasable(p));
    if (!items.length) {
      sel.innerHTML = '<option value="">— sin productos envasables registrados —</option>';
      toast('No hay productos marcados como Envasable aún', 'error');
      return;
    }
    sel.innerHTML = '<option value="">— seleccionar envasable —</option>'
      + items.map(p => { const val = p.skuBase || p.idProducto; return `<option value="${val}"${cur===val?' selected':''}>${p.descripcion||p.idProducto}</option>`; }).join('');
    if (cur) sel.value = cur;
    sel.onchange = () => _heredarTributariosDeBase(sel.value);
  }

  function _poblarBasesSelect() {
    const sel = $('prodSkuBase');
    if (!sel) return;
    const cur = sel.value;
    const bases = S.productos.filter(p => !p.skuBase || p.skuBase === p.idProducto);
    sel.innerHTML = '<option value="">— seleccionar producto base —</option>'
      + bases.map(p => `<option value="${p.idProducto}"${cur===p.idProducto?' selected':''}>${p.descripcion||p.idProducto}</option>`).join('');
    if (cur) sel.value = cur;
    sel.onchange = () => _heredarTributariosDeBase(sel.value);
  }

  // Hereda Tipo_IGV, IGV%, Cod_Tributo, Cod_SUNAT, Unidad_Medida del producto padre seleccionado
  // (presentación o derivado). Editable después si se requiere.
  function _heredarTributariosDeBase(idBase) {
    if (!idBase) return;
    const padre = (S.productos || []).find(p =>
      p.idProducto === idBase || p.skuBase === idBase
    );
    if (!padre) return;
    // Migrar legacy gravado/exonerado/inafecto → 1/2/3
    const tipoLegacy = { 'gravado': '1', 'exonerado': '2', 'inafecto': '3' };
    const tipoVal = tipoLegacy[String(padre.Tipo_IGV || '').toLowerCase()] || (padre.Tipo_IGV ? String(padre.Tipo_IGV) : '1');
    if ($('prodTipoIGV'))     $('prodTipoIGV').value     = tipoVal;
    if ($('prodCodTributo'))  $('prodCodTributo').value  = padre.Cod_Tributo || (tipoVal === '1' ? '1000' : tipoVal === '2' ? '9997' : '9998');
    if ($('prodIGV'))         $('prodIGV').value         = (padre.IGV_Porcentaje !== undefined && padre.IGV_Porcentaje !== '') ? padre.IGV_Porcentaje : (tipoVal === '1' ? 18 : 0);
    if ($('prodCodSUNAT'))    $('prodCodSUNAT').value    = padre.Cod_SUNAT || '10000000';
    if ($('prodUnidadMedida')) $('prodUnidadMedida').value = padre.Unidad_Medida || 'NIU';
    // Solo herendar idCategoria si no se ha llenado
    if ($('prodCategoria') && !$('prodCategoria').value && padre.idCategoria) {
      $('prodCategoria').value = padre.idCategoria;
    }
    if ($('prodMarca') && !$('prodMarca').value && padre.marca) {
      $('prodMarca').value = padre.marca;
    }
    _actualizarResumenSunat();
    toast('🧬 Datos tributarios heredados de "' + (padre.descripcion || padre.idProducto) + '" — editables si requiere', 'info');
  }

  function prodAutogenBarcode() {
    const ts   = Date.now().toString().slice(-6);
    const rand = Math.floor(Math.random() * 900 + 100);
    const cb = $('prodCodigoBarra');
    if (cb) { cb.value = 'NMLEV' + ts + rand; prodValidarCodigoBarra(); }
  }

  function prodValidarCodigoBarra() {
    const inp = $('prodCodigoBarra');
    const fb  = $('prodCodigoBarraFeedback');
    if (!inp || !fb) return true;
    const val   = inp.value.trim();
    const curId = $('prodId')?.value || '';
    if (!val) {
      fb.className = 'hidden text-xs mt-1';
      inp.classList.remove('!border-red-500');
      return true;
    }
    const dup = (S.productos || []).find(p =>
      p.codigoBarra && p.codigoBarra === val && String(p.idProducto) !== curId
    );
    if (dup) {
      fb.textContent = `⚠ Ya existe en: ${dup.descripcion} (${dup.idProducto})`;
      fb.className   = 'text-xs mt-1 text-red-400';
      inp.classList.add('!border-red-500');
      return false;
    }
    fb.textContent = '✓ Disponible';
    fb.className   = 'text-xs mt-1 text-green-400';
    inp.classList.remove('!border-red-500');
    return true;
  }

  function prodToggleEstado() {
    const hidden = $('prodEstado');
    const btn    = $('prodEstadoToggle');
    if (!hidden || !btn) return;
    const activo = hidden.value !== '1';
    hidden.value = activo ? '1' : '0';
    btn.classList.toggle('on', activo);
    btn.querySelector('.prod-toggle-lbl').textContent = activo ? 'Activo' : 'Inactivo';
  }

  function prodToggleCosto() {
    const row = $('prodCostoRow');
    const ch  = $('costoChevron');
    if (!row) return;
    const wasHidden = row.classList.toggle('hidden');
    if (ch) ch.textContent = wasHidden ? '▶' : '▼';
  }

  function prodCalcMargen() {
    const v    = parseFloat($('prodPrecioVenta')?.value)  || 0;
    const c    = parseFloat($('prodPrecioCosto')?.value)  || 0;
    const bar  = $('prodMargenBar');
    const lbl  = $('prodMargenLabel');
    const fill = $('prodMargenFill');
    if (!bar) return;
    if (v > 0 && c > 0 && v >= c) {
      const m = (v - c) / v * 100;
      bar.classList.remove('hidden');
      if (lbl)  lbl.textContent  = m.toFixed(1) + '%';
      if (fill) { fill.style.width = Math.min(m, 100) + '%'; fill.style.background = m > 30 ? '#22c55e' : m > 15 ? '#f59e0b' : '#ef4444'; }
    } else {
      bar.classList.add('hidden');
    }
  }

  function prodOnRange() {
    const minEl = $('prodStockMinRange');
    const maxEl = $('prodStockMaxRange');
    if (!minEl || !maxEl) return;
    let min = parseInt(minEl.value), max = parseInt(maxEl.value);
    if (min > max) { if (document.activeElement === minEl) { minEl.value = max; min = max; } else { maxEl.value = min; max = min; } }
    if ($('prodStockMin')) $('prodStockMin').value = min;
    if ($('prodStockMax')) $('prodStockMax').value = max;
    if ($('stockMinLabel')) $('stockMinLabel').textContent = min;
    if ($('stockMaxLabel')) $('stockMaxLabel').textContent = max;
    const rMax = parseInt(minEl.max) || 500;
    const fill = $('prodRangeFill');
    if (fill) { fill.style.left = (min/rMax*100)+'%'; fill.style.width = ((max-min)/rMax*100)+'%'; }
  }

  function _setStockSlider(min, max) {
    const minEl = $('prodStockMinRange');
    const maxEl = $('prodStockMaxRange');
    if (minEl) minEl.value = min;
    if (maxEl) maxEl.value = max;
    if ($('prodStockMin')) $('prodStockMin').value = min;
    if ($('prodStockMax')) $('prodStockMax').value = max;
    if ($('stockMinLabel')) $('stockMinLabel').textContent = min;
    if ($('stockMaxLabel')) $('stockMaxLabel').textContent = max;
    const rMax = minEl ? parseInt(minEl.max) : 500;
    const fill = $('prodRangeFill');
    if (fill) { fill.style.left = (min/rMax*100)+'%'; fill.style.width = ((max-min)/rMax*100)+'%'; }
  }

  function prodToggleSunat() {
    const sec = $('prodSecSunat');
    const ch  = $('sunatChevron');
    if (!sec) return;
    const h = sec.classList.toggle('hidden');
    if (ch) ch.textContent = h ? '⚙️ ajustar' : '▴ ocultar';
  }

  // Cuando cambia Tipo IGV: autorrellenar los campos relacionados (Cod_Tributo, IGV%)
  function prodOnTipoIGVChange() {
    const tipo = $('prodTipoIGV')?.value || '1';
    if (tipo === '1') {
      $('prodCodTributo').value = '1000';
      $('prodIGV').value = '18';
    } else if (tipo === '2') {
      $('prodCodTributo').value = '9997';
      $('prodIGV').value = '0';
    } else if (tipo === '3') {
      $('prodCodTributo').value = '9998';
      $('prodIGV').value = '0';
    }
    _actualizarResumenSunat();
  }
  function _actualizarResumenSunat() {
    const tipo = $('prodTipoIGV')?.value;
    const igv = $('prodIGV')?.value || '0';
    const r = $('sunatResumen'); if (!r) return;
    let txt = '—';
    if (tipo === '1') txt = 'Gravado ' + igv + '%';
    else if (tipo === '2') txt = 'Exonerado';
    else if (tipo === '3') txt = 'Inafecto';
    r.textContent = txt;
    r.className = (tipo === '1') ? 'text-emerald-400 font-normal' : 'text-amber-400 font-normal';
  }

  function prodToggleEquiv() {
    const sec = $('equivContent');
    const ch  = $('equivChevron');
    if (!sec) return;
    const h = sec.classList.toggle('hidden');
    if (ch) ch.textContent = h ? '▶' : '▼';
  }

  // ── Product modal — abrir ─────────────────────────────────
  function abrirModalProducto(id) {
    // Reset
    ['prodDescripcion','prodCodigoBarra','prodMarca','prodPrecioVenta','prodPrecioCosto',
     'prodFactorConvBase','prodMerma','prodFactor','prodIGV','prodCodSUNAT'].forEach(i => { const el=$(i); if(el) el.value=''; });
    $('prodId').value = '';
    $('prodEstado').value = '1';
    const toggle = $('prodEstadoToggle');
    if (toggle) { toggle.classList.add('on'); toggle.querySelector('.prod-toggle-lbl').textContent = 'Activo'; }
    const fb = $('prodCodigoBarraFeedback');
    if (fb) { fb.className = 'hidden text-xs mt-1'; fb.textContent = ''; }
    $('prodCodigoBarra')?.classList.remove('!border-red-500');
    $('prodCostoRow')?.classList.add('hidden');
    const ch = $('costoChevron'); if (ch) ch.textContent = '▶';
    $('prodMargenBar')?.classList.add('hidden');
    _setStockSlider(0, 0);
    setProdTipo('normal');
    $('modalEquivSection')?.classList.add('hidden');
    $('equivContent')?.classList.add('hidden');
    const ech = $('equivChevron'); if (ech) ech.textContent = '▶';
    $('equivList') && ($('equivList').innerHTML = '');
    $('equivAddForm')?.classList.add('hidden');
    $('prodSecSunat')?.classList.add('hidden');
    const sch = $('sunatChevron'); if (sch) sch.textContent = '▶';

    if (id) {
      const p = S.productos.find(x => x.idProducto === id);
      if (!p) return;
      $('modalProdTitle').textContent = 'Editar Producto';
      $('prodId').value          = p.idProducto;
      $('prodDescripcion').value = p.descripcion   || '';
      $('prodCodigoBarra').value = p.codigoBarra   || '';
      $('prodMarca').value       = p.marca         || '';
      $('prodCategoria').value   = p.idCategoria   || '';
      // Migración: valores legacy (KG, LITRO, BOLSA, etc.) → códigos SUNAT
      $('prodUnidad').value      = _normalizarUnidad(p.unidad) || 'NIU';

      // Estado
      const activo = _isProdActivo(p);
      $('prodEstado').value = activo ? '1' : '0';
      if (toggle) { toggle.classList.toggle('on', activo); toggle.querySelector('.prod-toggle-lbl').textContent = activo ? 'Activo' : 'Inactivo'; }

      // Precios
      $('prodPrecioVenta').value = p.precioVenta || '';
      if (p.precioCosto) {
        $('prodPrecioCosto').value = p.precioCosto;
        $('prodCostoRow')?.classList.remove('hidden');
        if (ch) ch.textContent = '▼';
      }
      prodCalcMargen();

      // Stock
      _setStockSlider(parseFloat(p.stockMinimo)||0, parseFloat(p.stockMaximo)||0);

      // SUNAT con migración legacy gravado→1, exonerado→2, inafecto→3
      const tipoIgvLegacy = { 'gravado': '1', 'exonerado': '2', 'inafecto': '3' };
      const tipoIgvVal = String(p.Tipo_IGV || '1').toLowerCase();
      $('prodTipoIGV').value     = tipoIgvLegacy[tipoIgvVal] || (p.Tipo_IGV ? String(p.Tipo_IGV) : '1');
      $('prodCodTributo').value  = p.Cod_Tributo     || '1000';
      $('prodIGV').value         = (p.IGV_Porcentaje !== undefined && p.IGV_Porcentaje !== '') ? p.IGV_Porcentaje : 18;
      $('prodUnidadMedida').value= p.Unidad_Medida   || 'NIU';
      $('prodCodSUNAT').value    = p.Cod_SUNAT       || '10000000';
      _actualizarResumenSunat();

      // Determinar tipo correctamente según el modelo de datos:
      // - Envasable (granel): esEnvasable = 1
      // - Derivado (envasado del granel): tiene codigoProductoBase
      // - Presentación (variante del base, ej tripack): factorConversion > 1
      // - Normal/Base (canónico): factor = 1 o vacío, sin codigoProductoBase
      // OJO: skuBase y idProducto siempre son distintos en formato (IDPRO vs LEV),
      // por eso NO sirven como criterio para distinguir base de presentación.
      let tipo = 'normal';
      const factor = parseFloat(p.factorConversion);
      if (_esEnvasable(p)) {
        tipo = 'envasable';
      } else if (p.codigoProductoBase && String(p.codigoProductoBase).trim()) {
        tipo = 'derivado';
      } else if (factor && factor > 0 && factor !== 1) {
        tipo = 'presentacion';
      }
      // else: factor=1 o vacío + sin codigoProductoBase = base/normal/canónico
      setProdTipo(tipo);

      if (tipo === 'derivado') {
        $('prodCodigoProductoBase').value = p.codigoProductoBase || '';
        $('prodFactorConvBase').value     = p.factorConversionBase || '';
        $('prodMerma').value              = p.mermaEsperadaPct || '';
      }
      if (tipo === 'presentacion') {
        $('prodSkuBase').value = p.skuBase || '';
        $('prodFactor').value  = p.factorConversion || '';
      }

      // Equivalencias
      $('modalEquivSection')?.classList.remove('hidden');
      _loadEquivModal(p.skuBase || p.idProducto);

      // Política de precios (override del producto si tiene)
      const tieneOverride = !!(p.modoVenta && String(p.modoVenta).trim());
      $('prodPoliticaOverride').checked = tieneOverride;
      if (tieneOverride) {
        $('prodModoVenta').value = String(p.modoVenta).toUpperCase();
        $('prodMargenPct').value = (p.margenPct !== '' && p.margenPct !== undefined && p.margenPct !== null) ? p.margenPct : '';
        $('prodPrecioTope').value = (parseFloat(p.precioTope) > 0) ? p.precioTope : '';
      } else {
        $('prodModoVenta').value = 'MARGEN';
        $('prodMargenPct').value = '';
        $('prodPrecioTope').value = '';
      }
      _prodOnPoliticaOverride();
      _prodActualizarPoliticaEfectiva();
    } else {
      $('modalProdTitle').textContent = 'Nuevo Producto';
      // Defaults autorrelleno (típico abarrote: gravado 18%)
      $('prodUnidad').value       = 'NIU';
      $('prodUnidadMedida').value = 'NIU';
      $('prodTipoIGV').value      = '1';   // 1 = Gravado
      $('prodCodTributo').value   = '1000';
      $('prodIGV').value          = '18';
      $('prodCodSUNAT').value     = '10000000';
      _actualizarResumenSunat();
      // Política: por default heredar
      $('prodPoliticaOverride').checked = false;
      $('prodModoVenta').value = 'MARGEN';
      $('prodMargenPct').value = '';
      $('prodPrecioTope').value = '';
      _prodOnPoliticaOverride();
      _prodActualizarPoliticaEfectiva();
    }
    openModal('modalProducto');
  }

  // ── Modal producto: política de precios ───────────────────
  function prodTogglePolitica() {
    const sec = $('prodSecPolitica');
    const ch  = $('politicaChevron');
    if (!sec) return;
    const oculta = sec.classList.contains('hidden');
    sec.classList.toggle('hidden');
    if (ch) ch.textContent = oculta ? '▼' : '▶';
  }

  function _prodOnPoliticaOverride() {
    const on = $('prodPoliticaOverride')?.checked;
    $('prodPoliticaCampos')?.classList.toggle('hidden', !on);
    if (on) _prodOnModoChange();
  }

  function _prodOnModoChange() {
    const modo = $('prodModoVenta')?.value;
    $('prodMargenWrap')?.classList.toggle('hidden', modo === 'FIJO' || modo === 'LIBRE');
    $('prodTopeWrap')?.classList.toggle('hidden', modo !== 'COMPETITIVO');
  }

  function _prodActualizarPoliticaEfectiva() {
    const el = $('prodPoliticaEfectiva');
    if (!el) return;
    const idCat = $('prodCategoria')?.value;
    const cat = (cfgData.categorias || []).find(c => String(c.idCategoria).toUpperCase() === String(idCat || '').toUpperCase());
    const override = $('prodPoliticaOverride')?.checked;
    if (override) {
      const modo = $('prodModoVenta')?.value || 'MARGEN';
      const margen = parseFloat($('prodMargenPct')?.value);
      const detalle = (modo === 'MARGEN' || modo === 'COMPETITIVO') && !isNaN(margen)
        ? `${modo} ${margen}%` : modo;
      el.innerHTML = `Política efectiva: <span class="text-amber-400 font-semibold">${detalle}</span> <span class="text-slate-600">(override del producto)</span>`;
    } else if (cat) {
      const detalle = (cat.modoVenta === 'MARGEN' || cat.modoVenta === 'COMPETITIVO')
        ? `${cat.modoVenta} ${parseFloat(cat.margenPct).toFixed(1)}%` : cat.modoVenta;
      el.innerHTML = `Política efectiva: <span class="text-emerald-400 font-semibold">${detalle}</span> <span class="text-slate-600">(de categoría ${cat.nombre || cat.idCategoria})</span>`;
    } else {
      el.innerHTML = `Política efectiva: <span class="text-slate-400 italic">${idCat ? 'categoría sin política configurada' : 'selecciona una categoría primero'}</span>`;
    }
  }

  // Carga y renderiza equivalencias dentro del modal
  async function _loadEquivModal(skuBase) {
    const list = $('equivList');
    if (!list) return;
    list.innerHTML = '<div class="text-xs text-slate-600 italic py-1 px-1">Cargando...</div>';
    try {
      const rows = (await API.get('getEquivalencias', { skuBase })) || [];
      // Actualizar equivMap también
      S.equivMap[skuBase] = rows.filter(r => String(r.activo) === '1').map(r => r.codigoBarra).filter(Boolean);
      _renderEquivList(rows, skuBase);
    } catch(e) {
      list.innerHTML = `<div class="text-xs text-red-400 py-1 px-1">Error: ${e.message}</div>`;
    }
  }

  function _renderEquivList(rows, skuBase) {
    const list = $('equivList');
    if (!list) return;
    if (!rows.length) {
      list.innerHTML = '<div class="text-xs text-slate-600 italic py-1 px-1">Sin equivalencias registradas</div>';
      return;
    }
    list.innerHTML = rows.map(r => {
      const on = String(r.activo) === '1';
      return `<div class="equiv-row${on ? '' : ' inactive'}" data-id="${r.idEquiv}">
        <span class="equiv-code">▌${r.codigoBarra}</span>
        <span class="equiv-desc truncate">${r.descripcion || ''}</span>
        <button class="equiv-toggle ${on ? 'on' : 'off'}"
                onclick="MOS.toggleEquivActivo('${r.idEquiv}','${skuBase}','${on ? '0' : '1'}')"
                title="${on ? 'Desactivar' : 'Activar'}">
          ${on ? '✓ Activo' : '✗ Inactivo'}
        </button>
      </div>`;
    }).join('');
  }

  function toggleAddEquiv() {
    const form = $('equivAddForm');
    if (!form) return;
    const opening = form.classList.toggle('hidden');
    if (!opening) { // se acaba de mostrar
      const inp = $('equivCodigo');
      if (inp) { inp.value = ''; inp.focus(); }
      const d = $('equivDesc'); if (d) d.value = '';
    }
  }

  async function crearEquivalenciaModal() {
    const skuBase  = S.productos.find(p => p.idProducto === $('prodId')?.value);
    const sku      = skuBase ? (skuBase.skuBase || skuBase.idProducto) : '';
    const codigo   = ($('equivCodigo')?.value || '').trim();
    const desc     = ($('equivDesc')?.value   || '').trim();
    if (!sku)    { toast('Abre un producto primero', 'error'); return; }
    if (!codigo) { toast('Ingresa el código de barras', 'error'); return; }

    const btn = $('equivAddForm')?.querySelector('button');
    if (btn) btn.disabled = true;
    try {
      await API.post('crearEquivalencia', { _source: 'MOS_EQUIV_MODAL', skuBase: sku, codigoBarra: codigo, descripcion: desc });
      toast('Equivalencia guardada', 'ok');
      const f = $('equivAddForm'); if (f) f.classList.add('hidden');
      await _loadEquivModal(sku);
      renderCatalogo(); // actualiza badges en tarjetas
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  // ── Update visual surgical (sin re-renderizar) ────────────────
  function _actualizarVisualProducto(idProducto, activo) {
    // Toggle button
    const toggle = document.querySelector(`.toggle-sw[data-pid="${idProducto}"]`);
    if (toggle) {
      toggle.classList.toggle('on', activo);
      toggle.title = activo ? 'Apagar' : 'Prender';
    }
    // Si es presentación: pres-chip
    const presChip = document.querySelector(`.pres-chip[data-pres-id="${idProducto}"]`);
    if (presChip) {
      presChip.classList.toggle('pres-inactive', !activo);
    }
    // Si es base: cat-card
    const catCard = document.querySelector(`.cat-card[data-cat-id="${idProducto}"]`);
    if (catCard) {
      catCard.classList.toggle('cat-inactive', !activo);
    }
  }

  // ── Toggle estado activo/inactivo de producto ────────────────
  // esBase=true: si apagas → flip visual + confirmación. Si prendes → cascada directa.
  // esBase=false: solo toggle local (presentación independiente).
  async function toggleProductoActivo(idProducto, esBase) {
    const p = S.productos.find(x => x.idProducto === idProducto);
    if (!p) return;
    const activoActual = _isProdActivo(p);

    if (esBase && activoActual) {
      // Apagar base con confirmación: flip visual inmediato + abrir modal
      _actualizarVisualProducto(idProducto, false);
      _pedirApagarBase(idProducto);
      return;
    }

    const nuevoEstado = activoActual ? '0' : '1';

    // OPTIMISTIC: actualizar UI primero
    p.estado = nuevoEstado;
    _actualizarVisualProducto(idProducto, nuevoEstado === '1');
    toast(nuevoEstado === '1' ? 'Activado ✓' : 'Apagado ✓', 'ok');

    // Si es base prendiendo, cascadear visualmente a las presentaciones del grupo
    if (esBase && nuevoEstado === '1') {
      const skuBase = p.skuBase || idProducto;
      S.productos.forEach(pp => {
        if ((pp.skuBase || pp.idProducto) === skuBase && pp.idProducto !== idProducto) {
          if (!_isProdActivo(pp)) {
            pp.estado = '1';
            _actualizarVisualProducto(pp.idProducto, true);
          }
        }
      });
    }

    // POST en background sin bloquear UI
    try {
      await API.post('actualizarProducto', { _source: 'MOS_TOGGLE', idProducto, estado: nuevoEstado });
      if (esBase && nuevoEstado === '1') {
        // Prender hijos en backend (presentaciones + equivalencias)
        _prenderHijos(p).catch(() => {});
      }
    } catch(e) {
      // Revertir en caso de error
      p.estado = activoActual ? '1' : '0';
      _actualizarVisualProducto(idProducto, activoActual);
      toast('Error: ' + e.message, 'error');
    }
  }

  async function _prenderHijos(baseProd) {
    const skuBase = baseProd.skuBase || baseProd.idProducto;
    const presentaciones = S.productos.filter(p =>
      (p.skuBase || p.idProducto) === skuBase && p.idProducto !== baseProd.idProducto
    );
    await Promise.all(presentaciones.map(async pp => {
      if (_isProdActivo(pp)) return;
      await API.post('actualizarProducto', { _source: 'MOS_TOGGLE_CASCADA', idProducto: pp.idProducto, estado: '1' });
      pp.estado = '1';
    }));
    try {
      const equivs = await API.get('getEquivalencias', { skuBase });
      const inactivas = (equivs || []).filter(e => {
        const v = e.activo;
        return !(v === '1' || v === 1 || v === true || String(v).toLowerCase() === 'true');
      });
      await Promise.all(inactivas.map(e =>
        API.post('actualizarEquivalencia', { _source: 'MOS_TOGGLE_CASCADA', idEquiv: e.idEquiv, activo: '1' })
      ));
    } catch(_) {}
  }

  function _pedirApagarBase(idProducto) {
    const p = S.productos.find(x => x.idProducto === idProducto);
    if (!p) return;
    const skuBase = p.skuBase || idProducto;
    const presentaciones = S.productos.filter(pp =>
      (pp.skuBase || pp.idProducto) === skuBase && pp.idProducto !== idProducto
    );
    $('apagarBaseId').value = idProducto;
    $('apagarBaseSku').value = skuBase;
    $('apagarBaseTitle').textContent = p.descripcion || idProducto;
    $('apagarBasePresCount').textContent = presentaciones.length;
    $('apagarBasePresList').innerHTML = presentaciones.length > 0
      ? presentaciones.map(pp => `<li>— ${pp.descripcion || pp.idProducto}</li>`).join('')
      : '<li class="italic">— sin presentaciones —</li>';
    $('apagarBaseEqCount').textContent = '…';
    $('apagarBaseEqList').innerHTML = '<li class="italic">— cargando —</li>';
    const modal = $('modalApagarBase');
    modal.dataset.equivs = '[]';
    openModal('modalApagarBase');

    API.get('getEquivalencias', { skuBase }).then(equivs => {
      const activas = (equivs || []).filter(e => {
        const v = e.activo;
        return v === '1' || v === 1 || v === true || String(v).toLowerCase() === 'true';
      });
      $('apagarBaseEqCount').textContent = activas.length;
      $('apagarBaseEqList').innerHTML = activas.length > 0
        ? activas.map(e => `<li>— ▌${e.codigoBarra}${e.descripcion ? ' (' + e.descripcion + ')' : ''}</li>`).join('')
        : '<li class="italic">— sin equivalencias activas —</li>';
      modal.dataset.equivs = JSON.stringify(activas.map(e => e.idEquiv));
    }).catch(() => {
      $('apagarBaseEqCount').textContent = '?';
      $('apagarBaseEqList').innerHTML = '<li class="italic text-red-400">— error al cargar —</li>';
    });
  }

  async function confirmarApagarBase() {
    const idProducto = $('apagarBaseId').value;
    const skuBase    = $('apagarBaseSku').value;
    const equivIds   = JSON.parse($('modalApagarBase').dataset.equivs || '[]');
    if (!idProducto) return;

    const productos = S.productos.filter(pp =>
      (pp.skuBase || pp.idProducto) === skuBase || pp.idProducto === idProducto
    );

    // OPTIMISTIC: marcar todos como apagados visualmente y cerrar modal de inmediato
    productos.forEach(pp => {
      pp.estado = '0';
      _actualizarVisualProducto(pp.idProducto, false);
    });
    closeModal('modalApagarBase');
    toast('Apagado ' + productos.length + ' producto(s) ✓', 'ok');

    // Marcador de "no revertir" en el modal (la confirmación procedió)
    $('modalApagarBase').dataset.confirmado = '1';

    // POST en background
    try {
      await Promise.all(productos.map(pp =>
        API.post('actualizarProducto', { _source: 'MOS_TOGGLE_CASCADA', idProducto: pp.idProducto, estado: '0' })
      ));
      await Promise.all(equivIds.map(idEquiv =>
        API.post('actualizarEquivalencia', { _source: 'MOS_TOGGLE_CASCADA', idEquiv, activo: '0' })
      ));
    } catch(e) {
      toast('Error de sincronización: ' + e.message, 'error');
    }
  }

  // Cerrar modal apagar base SIN confirmar → revertir flip visual del toggle base
  function cerrarApagarBaseRevertir() {
    const modal = $('modalApagarBase');
    if (modal && modal.dataset.confirmado !== '1') {
      const idProducto = $('apagarBaseId').value;
      if (idProducto) _actualizarVisualProducto(idProducto, true);
    }
    if (modal) delete modal.dataset.confirmado;
    closeModal('modalApagarBase');
  }

  async function toggleEquivActivo(idEquiv, skuBase, nuevoActivo) {
    try {
      await API.post('actualizarEquivalencia', { _source: 'MOS_EQUIV_MODAL', idEquiv, activo: nuevoActivo });
      await _loadEquivModal(skuBase);
      renderCatalogo();
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  async function guardarProducto() {
    const desc = ($('prodDescripcion')?.value || '').trim();
    // Validaciones de campos OBLIGATORIOS
    if (!desc) {
      toast('⚠ La descripción es requerida', 'error');
      $('prodDescripcion')?.focus();
      return;
    }
    let codigoBarra = ($('prodCodigoBarra')?.value || '').trim();
    // Si no hay codigoBarra, autogenerar uno NMLEV en el momento (no permitir vacío)
    if (!codigoBarra) {
      prodAutogenBarcode();
      codigoBarra = ($('prodCodigoBarra')?.value || '').trim();
      if (!codigoBarra) {
        toast('⚠ El código de barras es requerido', 'error');
        $('prodCodigoBarra')?.focus();
        return;
      }
      toast('Código de barras autogenerado: ' + codigoBarra, 'info');
    }
    const precioVenta = parseFloat($('prodPrecioVenta')?.value);
    if (!precioVenta || precioVenta <= 0) {
      toast('⚠ El precio de venta es requerido (> 0)', 'error');
      $('prodPrecioVenta')?.focus();
      return;
    }

    const overridePolitica = !!$('prodPoliticaOverride')?.checked;
    const params = {
      idProducto:    $('prodId')?.value     || undefined,
      descripcion:   desc,
      codigoBarra:   $('prodCodigoBarra')?.value  || '',
      marca:         $('prodMarca')?.value        || '',
      idCategoria:   $('prodCategoria')?.value    || '',
      unidad:        $('prodUnidad')?.value       || 'NIU',
      precioVenta:   parseFloat($('prodPrecioVenta')?.value) || 0,
      precioCosto:   $('prodPrecioCosto')?.value  ? parseFloat($('prodPrecioCosto').value) : '',
      stockMinimo:   parseInt($('prodStockMin')?.value)  || 0,
      stockMaximo:   parseInt($('prodStockMax')?.value)  || 0,
      estado:        $('prodEstado')?.value       || '1',
      Tipo_IGV:      $('prodTipoIGV')?.value      || '',
      Cod_Tributo:   $('prodCodTributo')?.value   || '',
      IGV_Porcentaje:$('prodIGV')?.value          ? parseFloat($('prodIGV').value) : '',
      Unidad_Medida: $('prodUnidadMedida')?.value || 'NIU',
      Cod_SUNAT:     $('prodCodSUNAT')?.value     || '',
      // Política override (vacío = hereda de categoría)
      modoVenta:     overridePolitica ? ($('prodModoVenta')?.value || '') : '',
      margenPct:     overridePolitica && $('prodMargenPct')?.value ? parseFloat($('prodMargenPct').value) : '',
      precioTope:    overridePolitica && $('prodPrecioTope')?.value ? parseFloat($('prodPrecioTope').value) : ''
    };

    // Campos según tipo
    if (_prodTipo === 'envasable') {
      params.esEnvasable = '1'; params.codigoProductoBase = ''; params.factorConversion = ''; params.factorConversionBase = ''; params.mermaEsperadaPct = '';
    } else if (_prodTipo === 'derivado') {
      params.esEnvasable = '0';
      params.codigoProductoBase  = $('prodCodigoProductoBase')?.value || '';
      params.factorConversionBase= $('prodFactorConvBase')?.value ? parseFloat($('prodFactorConvBase').value) : '';
      params.mermaEsperadaPct    = $('prodMerma')?.value           ? parseFloat($('prodMerma').value)          : '';
      params.factorConversion = '';
    } else if (_prodTipo === 'presentacion') {
      params.esEnvasable = '0';
      // Solo mandar skuBase si el input tiene valor — evita borrar el SKU existente
      const skuVal = ($('prodSkuBase')?.value || '').trim();
      if (skuVal) params.skuBase = skuVal;
      params.factorConversion = $('prodFactor')?.value  ? parseFloat($('prodFactor').value) : '';
      params.codigoProductoBase = ''; params.factorConversionBase = ''; params.mermaEsperadaPct = '';
    } else { // normal (base): factorConversion = 1
      params.esEnvasable = '0'; params.codigoProductoBase = ''; params.factorConversionBase = ''; params.mermaEsperadaPct = '';
      // Solo asignar factorConversion=1 al CREAR (sin idProducto). En edición no se toca para no romper data.
      if (!params.idProducto) params.factorConversion = 1;
    }

    // BLOQUEO: si codigoBarra duplicado, no permitir guardar
    if (!prodValidarCodigoBarra()) {
      toast('El código de barras ya pertenece a otro producto. No se puede guardar.', 'error');
      $('prodCodigoBarra')?.focus();
      return;
    }

    // OPTIMISTIC FLOW: cerrar modal de inmediato + pulse visual al guardarse
    const isEdit = !!params.idProducto;
    params._source = 'MOS_MODAL_PRODUCTO';
    closeModal('modalProducto');
    toast(isEdit ? 'Actualizando…' : 'Creando producto…', 'info');

    try {
      const action = isEdit ? 'actualizarProducto' : 'crearProducto';
      const r = await API.post(action, params);
      toast(isEdit ? 'Producto actualizado ✓' : 'Producto creado ✓', 'ok');
      // Refresh catálogo
      S.loaded['catalogo'] = false;
      await loadCatalogo(true);
      // Pulse en la card del producto creado/editado
      const targetId = (r && r.idProducto) || params.idProducto || '';
      if (targetId) _pulseCatalogoCard(targetId);
    } catch(e) {
      toast('Error: ' + e.message, 'error');
      // Revertir abriendo el modal de nuevo con los datos para corregir
      // (no implementado por simplicidad — el usuario puede reintentar manualmente)
    }
  }

  // Hace scroll a la card del producto y le aplica un pulso visual breve
  function _pulseCatalogoCard(idProducto) {
    setTimeout(() => {
      const eid = CSS.escape(idProducto);
      const card = document.getElementById('fc-' + eid);
      if (!card) return;
      // Scroll suave
      card.scrollIntoView({ behavior: 'smooth', block: 'center' });
      // Aplicar clase de pulso
      card.classList.remove('cat-card-pulse');
      void card.offsetWidth;  // force reflow
      card.classList.add('cat-card-pulse');
      // Quitarla cuando termine
      setTimeout(() => card.classList.remove('cat-card-pulse'), 2200);
    }, 200);
  }

  // Price modal
  function abrirModalPrecio(id) {
    const p = S.productos.find(x => x.idProducto === id);
    if (!p) { toast('Producto no encontrado', 'error'); return; }
    $('precioIdProducto').value = id;
    $('precioInfoProd').textContent = p.descripcion + (p.codigoBarra ? ' — ' + p.codigoBarra : '');
    $('precioActual').textContent = fmtMoney(p.precioVenta);
    $('precioNuevo').value = p.precioVenta || '';
    $('precioMotivo').value = '';
    $('precioMembretes').checked = false;
    openModal('modalPrecio');
  }

  async function publicarPrecio() {
    const id     = $('precioIdProducto')?.value;
    const nuevo  = parseFloat($('precioNuevo')?.value || 0);
    const motivo = $('precioMotivo')?.value || '';
    const memb   = $('precioMembretes')?.checked;

    if (!nuevo || nuevo <= 0) { toast('Ingresa un precio válido', 'error'); return; }

    const p = S.productos.find(x => x.idProducto === id);
    const prevPrecio = p?.precioVenta;
    // Optimistic update
    if (p) { p.precioVenta = nuevo; _catSaveCache(S.productos); renderCatalogo(); }
    closeModal('modalPrecio');
    try {
      await API.post('publicarPrecio', {
        _source: 'MOS_MODAL_PRECIO',
        idProducto: id, skuBase: p?.skuBase, codigoBarra: p?.codigoBarra,
        descripcion: p?.descripcion, precioNuevo: nuevo,
        motivo, imprimirMembretes: memb
      });
      toast('Precio publicado: ' + fmtMoney(nuevo), 'ok');
      S.loaded['catalogo'] = false;
      loadCatalogo(true); // background refresh
    } catch (e) {
      if (p && prevPrecio !== undefined) { p.precioVenta = prevPrecio; renderCatalogo(); }
      toast('Error: ' + e.message, 'error');
    }
  }

  // Proveedor modal
  function abrirModalProveedor(id) {
    ['Id','Nombre','Ruc','Tel','Email','FormaPago','Plazo','Categoria','Banco','Cuenta'].forEach(c => {
      const el = $('prov' + c);
      if (el && el.tagName !== 'SELECT') el.value = '';
    });
    if (id) {
      const p = S.proveedores.find(x => x.idProveedor === id);
      if (!p) return;
      $('modalProvTitle').textContent = 'Editar Proveedor';
      $('provId').value        = p.idProveedor;
      $('provNombre').value    = p.nombre || '';
      $('provRuc').value       = p.ruc || '';
      $('provTel').value       = p.telefono || '';
      $('provEmail').value     = p.email || '';
      $('provFormaPago').value = p.formaPago || 'CONTADO';
      $('provPlazo').value     = p.plazoCredito || '';
      $('provCategoria').value = p.categoriaProducto || '';
      $('provBanco').value     = p.banco || '';
      $('provCuenta').value    = p.numeroCuenta || '';
    } else {
      $('modalProvTitle').textContent = 'Nuevo Proveedor';
      $('provId').value = '';
      $('provFormaPago').value = 'CONTADO';
    }
    openModal('modalProveedor');
  }

  async function guardarProveedor() {
    const params = {
      idProveedor:      $('provId')?.value || undefined,
      nombre:           $('provNombre')?.value || '',
      ruc:              $('provRuc')?.value || '',
      telefono:         $('provTel')?.value || '',
      email:            $('provEmail')?.value || '',
      formaPago:        $('provFormaPago')?.value || 'CONTADO',
      plazoCredito:     $('provPlazo')?.value || 0,
      categoriaProducto:$('provCategoria')?.value || '',
      banco:            $('provBanco')?.value || '',
      numeroCuenta:     $('provCuenta')?.value || ''
    };
    if (!params.nombre) { toast('El nombre es requerido', 'error'); return; }
    try {
      const action = params.idProveedor ? 'actualizarProveedor' : 'crearProveedor';
      await API.post(action, params);
      toast(params.idProveedor ? 'Proveedor actualizado' : 'Proveedor creado', 'ok');
      closeModal('modalProveedor');
      S.loaded['proveedores'] = false;
      await loadProveedores();
    } catch (e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  // Pago modal
  function abrirModalPago(idProveedor) {
    $('pagoIdProveedor').value = idProveedor;
    $('pagoMonto').value  = '';
    $('pagoFactura').value = '';
    $('pagoFecha').value  = today();
    $('pagoObs').value    = '';
    openModal('modalPago');
  }

  async function guardarPago() {
    const params = {
      idProveedor:    $('pagoIdProveedor')?.value,
      monto:          $('pagoMonto')?.value,
      numeroFactura:  $('pagoFactura')?.value || '',
      fecha:          $('pagoFecha')?.value || today(),
      observacion:    $('pagoObs')?.value || ''
    };
    if (!params.monto || parseFloat(params.monto) <= 0) { toast('Ingresa un monto válido', 'error'); return; }
    try {
      await API.post('registrarPago', params);
      toast('Pago registrado: ' + fmtMoney(params.monto), 'ok');
      closeModal('modalPago');
      if (S.provSelId) selectProveedor(S.provSelId);
    } catch (e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  // ── PEDIDO MODAL ────────────────────────────────────────────
  let _pedidoState = { items: [], idProveedor: null };

  async function abrirModalPedido(idProveedor) {
    if (!idProveedor) return;
    _pedidoState = { items: [], idProveedor: idProveedor };
    const prov = (S.proveedores || []).find(p => p.idProveedor === idProveedor);
    $('pedidoIdProveedor').value = idProveedor;
    $('pedidoProveedorNombre').textContent = prov ? prov.nombre : idProveedor;
    $('pedidoBuscar').value = '';
    $('pedidoBuscarRes').style.display = 'none';
    $('pedidoFechaEst').value = '';
    $('pedidoNotas').value = '';
    _renderPedidoItems();
    // Si vino con producto sugerido (desde insight), pre-cargar
    if (S._pedidoSugerido) {
      _pedidoState.items.push({
        skuBase:     S._pedidoSugerido.skuBase || S._pedidoSugerido.idProducto,
        codigoBarra: S._pedidoSugerido.codigoBarra || '',
        descripcion: S._pedidoSugerido.descripcion || '',
        cantidad:    1,
        precio:      S._pedidoSugerido.precioReferencia || 0
      });
      S._pedidoSugerido = null;
      _renderPedidoItems();
    }
    openModal('modalPedido');
  }

  function cerrarModalPedido() { closeModal('modalPedido'); }

  let _pedidoBuscarTimer = null;
  async function pedidoBuscarItem() {
    clearTimeout(_pedidoBuscarTimer);
    _pedidoBuscarTimer = setTimeout(async () => {
      const q = ($('pedidoBuscar').value || '').trim();
      const resBox = $('pedidoBuscarRes');
      if (!q) { resBox.style.display = 'none'; return; }
      try {
        const items = await API.get('getProveedorProductos', { idProveedor: _pedidoState.idProveedor });
        const lista = Array.isArray(items) ? items : (items && items.data) || [];
        const qn = _norm(q);
        const palabras = qn.split(/\s+/).filter(Boolean);
        const filtered = lista.filter(pp => {
          const hay = _norm((pp.descripcion || '') + ' ' + (pp.skuBase || '') + ' ' + (pp.codigoBarra || ''));
          return palabras.every(w => hay.indexOf(w) >= 0);
        }).slice(0, 8);
        if (!filtered.length) {
          resBox.innerHTML = '<div class="pn-result text-slate-500 italic">Sin coincidencias</div>';
          resBox.style.display = 'block';
          return;
        }
        resBox.innerHTML = filtered.map(pp => {
          const safeDesc = (pp.descripcion || pp.skuBase).replace(/'/g, "\\'");
          return `<div class="pn-result" onclick="MOS.pedidoAgregarItem('${pp.skuBase}', '${pp.codigoBarra || ''}', '${safeDesc}', ${pp.precioReferencia || 0})">
            <div class="text-slate-200 font-medium text-sm">${pp.descripcion || pp.skuBase}</div>
            <div class="text-slate-500 text-xs flex justify-between"><span style="font-family:monospace">${pp.skuBase}</span><span class="text-amber-400">${fmtMoney(pp.precioReferencia || 0)}</span></div>
          </div>`;
        }).join('');
        resBox.style.display = 'block';
      } catch(_){}
    }, 200);
  }

  function pedidoAgregarItem(sku, cb, desc, precio) {
    const existe = _pedidoState.items.find(it => it.skuBase === sku);
    if (existe) { existe.cantidad++; }
    else _pedidoState.items.push({ skuBase: sku, codigoBarra: cb, descripcion: desc, cantidad: 1, precio: parseFloat(precio) || 0 });
    $('pedidoBuscar').value = '';
    $('pedidoBuscarRes').style.display = 'none';
    _renderPedidoItems();
  }

  function pedidoQuitarItem(idx) {
    _pedidoState.items.splice(idx, 1);
    _renderPedidoItems();
  }

  function pedidoCambiarQty(idx, qty) {
    const q = Math.max(0, parseInt(qty) || 0);
    if (q === 0) { _pedidoState.items.splice(idx, 1); }
    else _pedidoState.items[idx].cantidad = q;
    _renderPedidoItems();
  }

  function _renderPedidoItems() {
    const list = $('pedidoItemsList');
    const cnt = $('pedidoItemsCount');
    if (!list) return;
    if (cnt) cnt.textContent = '(' + _pedidoState.items.length + ')';
    if (!_pedidoState.items.length) {
      list.innerHTML = '<div class="text-xs text-slate-600 italic text-center py-3">Sin items aún. Busca productos arriba.</div>';
      $('pedidoTotal').value = 'S/ 0.00';
      return;
    }
    let total = 0;
    list.innerHTML = _pedidoState.items.map((it, i) => {
      const sub = (it.cantidad || 0) * (it.precio || 0);
      total += sub;
      return `<div class="flex items-center gap-2 p-2 rounded" style="background:#0d1526">
        <div class="min-w-0 flex-1">
          <div class="text-sm text-slate-200 truncate">${it.descripcion}</div>
          <div class="text-[10px] text-slate-500 font-mono">${it.skuBase} · ${fmtMoney(it.precio)}</div>
        </div>
        <input type="number" min="0" step="1" class="inp text-xs" style="width:60px;text-align:center" value="${it.cantidad}" onchange="MOS.pedidoCambiarQty(${i}, this.value)">
        <div class="text-xs text-amber-400 font-semibold whitespace-nowrap" style="width:60px;text-align:right">${fmtMoney(sub)}</div>
        <button onclick="MOS.pedidoQuitarItem(${i})" class="text-rose-400 text-base p-1" title="Quitar">×</button>
      </div>`;
    }).join('');
    $('pedidoTotal').value = fmtMoney(total);
  }

  async function guardarPedido() {
    if (!_pedidoState.idProveedor) { toast('Falta proveedor', 'error'); return; }
    if (!_pedidoState.items.length) { toast('Agrega al menos 1 item', 'error'); return; }
    const total = _pedidoState.items.reduce((s, it) => s + (it.cantidad || 0) * (it.precio || 0), 0);
    try {
      await API.post('crearPedido', {
        idProveedor:    _pedidoState.idProveedor,
        items:          _pedidoState.items,
        montoEstimado:  total,
        fechaEstimada:  $('pedidoFechaEst').value || '',
        notas:          $('pedidoNotas').value || '',
        usuario:        S.session?.nombre || ''
      });
      toast('Pedido borrador creado ✓', 'ok');
      closeModal('modalPedido');
      // Refrescar pedidos del proveedor si la vista está abierta
      if (S.provSelId === _pedidoState.idProveedor && S.provTab === 'pedidos') {
        S.provPedidos[_pedidoState.idProveedor] = null;
        _renderProvPedidos();
      }
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  // ── Selector de proveedor desde insight de almacén ──
  async function _almGenerarPedidoFromInsight(idProducto, descripcion, skuBase, codigoBarra) {
    try {
      const r = await API.get('getProveedoresQueVenden', { skuBase: skuBase || idProducto, codigoBarra: codigoBarra || '' });
      const provs = (r && r.data) ? r.data : (r || []);
      if (!provs.length) {
        toast('Este producto no tiene proveedores registrados. Agrégalo en Proveedores → Productos.', 'error');
        return;
      }
      // Guardar producto sugerido para pre-cargar en el modal
      S._pedidoSugerido = {
        idProducto, descripcion, skuBase: skuBase || idProducto, codigoBarra: codigoBarra || '',
        precioReferencia: provs[0].precioReferencia
      };
      if (provs.length === 1) {
        // Directo al modal de pedido
        await abrirModalPedido(provs[0].idProveedor);
        return;
      }
      // Mostrar selector
      $('selProvProducto').textContent = descripcion || idProducto;
      $('selProvList').innerHTML = provs.map(p => `
        <div class="card-sm p-3 cursor-pointer hover:border-amber-500/40 transition-colors" onclick="MOS._almPickProveedor('${p.idProveedor}')">
          <div class="flex items-center justify-between gap-2">
            <div class="min-w-0 flex-1">
              <div class="text-sm font-semibold text-slate-200 truncate">${p.nombreProveedor}</div>
              <div class="text-xs text-slate-500">mín ${p.minimoCompra || 0} · ${p.diasEntrega || 0}d entrega</div>
            </div>
            <div class="text-amber-400 text-sm font-bold whitespace-nowrap shrink-0">${fmtMoney(p.precioReferencia)}</div>
          </div>
        </div>
      `).join('');
      openModal('modalSelProveedor');
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }
  async function _almPickProveedor(idProveedor) {
    closeModal('modalSelProveedor');
    await abrirModalPedido(idProveedor);
  }
  function cerrarSelProveedor() { closeModal('modalSelProveedor'); }

  // ── CONFIGURACIÓN ────────────────────────────────────────────
  let cfgData = { zonas: [], estaciones: [], impresoras: [], personal: [], personalMOS: [], series: [], dispositivos: [] };

  async function loadConfig() {
    S.cfgTab = S.cfgTab || 'zonas';
    const [zonRes, estRes, impRes, persRes, persMOSRes, serRes, dispRes, catRes] = await Promise.allSettled([
      API.get('getZonas', {}),
      API.get('getEstaciones', {}),
      API.get('getImpresoras', {}),
      API.get('getPersonalMaster', { appOrigen: 'warehouseMos' }),
      API.get('getPersonalMaster', { appOrigen: 'MOS' }),
      API.get('getSeries', {}),
      API.get('getDispositivos', {}),
      API.get('getCategorias', {})
    ]);
    cfgData.zonas        = zonRes.status      === 'fulfilled' ? (zonRes.value      || []) : [];
    cfgData.estaciones   = estRes.status      === 'fulfilled' ? (estRes.value      || []) : [];
    cfgData.impresoras   = impRes.status      === 'fulfilled' ? (impRes.value      || []) : [];
    cfgData.personal     = persRes.status     === 'fulfilled' ? (persRes.value     || []) : [];
    cfgData.personalMOS  = persMOSRes.status  === 'fulfilled' ? (persMOSRes.value  || []) : [];
    cfgData.series       = serRes.status      === 'fulfilled' ? (serRes.value      || []) : [];
    cfgData.dispositivos = dispRes.status     === 'fulfilled' ? (dispRes.value     || []) : [];
    cfgData.categorias   = catRes.status      === 'fulfilled' ? (catRes.value      || []) : [];
    renderCfgTab(S.cfgTab);
  }

  function setCfgTab(tab) {
    S.cfgTab = tab;
    const tabs = ['zonas','estaciones','impresoras','personal','series','seguridad','dispositivos','categorias','integridad'];
    tabs.forEach(t => {
      const btn = $('cfgTab' + t.charAt(0).toUpperCase() + t.slice(1));
      if (btn) btn.classList.toggle('active', t === tab);
      const panel = $('cfgPanel' + t.charAt(0).toUpperCase() + t.slice(1));
      if (panel) panel.classList.toggle('hidden', t !== tab);
    });
    renderCfgTab(tab);
  }

  function renderCfgTab(tab) {
    switch (tab) {
      case 'zonas':        renderZonas();        break;
      case 'estaciones':   renderEstaciones();   break;
      case 'impresoras':   renderImpresoras();   break;
      case 'personal':     renderPersonal();     break;
      case 'series':       renderSeries();       break;
      case 'seguridad':    renderSeguridad();    break;
      case 'dispositivos': renderDispositivos(); break;
      case 'categorias':   renderCategorias();   break;
      case 'integridad':   renderIntegridad();   break;
    }
  }

  // ── CATEGORÍAS / política de precios ─────────────────────
  async function renderCategorias(skipFetch) {
    const tbody = $('tbodyCategorias');
    if (!tbody) return;
    if (!skipFetch) {
      tbody.innerHTML = '<tr><td colspan="8" class="text-center py-8 text-slate-500 text-sm">Cargando...</td></tr>';
      try {
        const r = await API.get('getCategorias', {});
        cfgData.categorias = r || [];
      } catch(e) {
        tbody.innerHTML = `<tr><td colspan="8" class="text-center py-8 text-rose-400 text-sm">Error: ${e.message}</td></tr>`;
        return;
      }
    }
    const rows = cfgData.categorias || [];
    if (!rows.length) {
      tbody.innerHTML = '<tr><td colspan="8" class="text-center py-8 text-slate-500 text-sm">Sin categorías. Corre <code class="bg-slate-800 px-1 rounded">migrarPoliticaPrecios</code> en GAS para poblar las existentes.</td></tr>';
      return;
    }
    tbody.innerHTML = rows.map(c => {
      const activa = String(c.estado) === '1';
      const modoBadge = c.modoVenta === 'MARGEN' ? 'bg-emerald-500/15 text-emerald-400'
                      : c.modoVenta === 'FIJO' ? 'bg-blue-500/15 text-blue-400'
                      : c.modoVenta === 'COMPETITIVO' ? 'bg-amber-500/15 text-amber-400'
                      : 'bg-slate-700/40 text-slate-400';
      const topeStr = parseFloat(c.precioTope) > 0 ? 'S/ ' + parseFloat(c.precioTope).toFixed(2) : '—';
      return `<tr class="${activa ? '' : 'opacity-50'}">
        <td class="font-medium">${c.nombre || c.idCategoria}</td>
        <td class="text-[11px] text-slate-500 font-mono">${c.idCategoria}</td>
        <td><span class="px-2 py-0.5 rounded text-[10px] font-semibold ${modoBadge}">${c.modoVenta}</span></td>
        <td class="text-right font-mono">${c.modoVenta === 'MARGEN' || c.modoVenta === 'COMPETITIVO' ? (parseFloat(c.margenPct) || 0).toFixed(1) + '%' : '—'}</td>
        <td class="text-right hidden sm:table-cell font-mono text-slate-400">${topeStr}</td>
        <td class="hidden md:table-cell text-xs text-slate-500 truncate" style="max-width:200px">${c.descripcion || ''}</td>
        <td><span class="text-[10px] ${activa ? 'text-emerald-400' : 'text-slate-500'}">${activa ? 'Activa' : 'Inactiva'}</span></td>
        <td class="text-right">
          <button onclick="MOS.abrirModalCategoria('${c.idCategoria}')" class="text-xs text-amber-400 hover:text-amber-300">Editar</button>
        </td>
      </tr>`;
    }).join('');
  }

  function abrirModalCategoria(idCategoria) {
    const cat = idCategoria
      ? (cfgData.categorias || []).find(c => String(c.idCategoria) === String(idCategoria))
      : null;
    $('modalCategoriaTitle').textContent = cat ? 'Editar categoría' : 'Nueva categoría';
    $('catId').value = cat ? cat.idCategoria : '';
    $('catNombre').value = cat ? (cat.nombre || cat.idCategoria) : '';
    $('catModo').value = cat ? (cat.modoVenta || 'MARGEN') : 'MARGEN';
    $('catMargen').value = cat && cat.margenPct !== '' && cat.margenPct !== undefined ? cat.margenPct : 25;
    $('catTope').value = cat && parseFloat(cat.precioTope) > 0 ? cat.precioTope : '';
    $('catDesc').value = cat ? (cat.descripcion || '') : '';
    $('catEstado').value = cat ? String(cat.estado || '1') : '1';
    // Si es nueva, dejar nombre editable — si es edición, bloquear nombre/ID (lo identifica el sistema)
    $('catNombre').disabled = !!cat;
    _catOnModoChange();
    openModal('modalCategoria');
  }

  function _catOnModoChange() {
    const modo = $('catModo')?.value;
    const margenWrap = $('catMargenWrap');
    const topeWrap = $('catTopeWrap');
    if (margenWrap) margenWrap.classList.toggle('hidden', modo === 'FIJO' || modo === 'LIBRE');
    if (topeWrap)   topeWrap.classList.toggle('hidden', modo !== 'COMPETITIVO');
  }

  async function guardarCategoria() {
    const id = $('catId').value;
    const nombre = $('catNombre').value.trim();
    if (!nombre) { toast('Nombre requerido', 'error'); return; }
    const modo = $('catModo').value;
    const margen = parseFloat($('catMargen').value);
    const tope = parseFloat($('catTope').value);
    if ((modo === 'MARGEN' || modo === 'COMPETITIVO') && (isNaN(margen) || margen < 0 || margen >= 100)) {
      toast('Margen debe ser 0-99', 'error'); return;
    }
    if (modo === 'COMPETITIVO' && (!tope || tope <= 0)) {
      toast('Precio tope requerido para modo COMPETITIVO', 'error'); return;
    }
    const params = {
      nombre, modoVenta: modo,
      margenPct: isNaN(margen) ? '' : margen,
      precioTope: isNaN(tope) ? '' : tope,
      descripcion: $('catDesc').value.trim(),
      estado: $('catEstado').value
    };
    try {
      if (id) {
        await API.post('actualizarCategoria', { ...params, idCategoria: id });
        toast('Categoría actualizada ✓', 'ok');
      } else {
        await API.post('crearCategoria', params);
        toast('Categoría creada ✓', 'ok');
      }
      closeModal('modalCategoria');
      await renderCategorias(); // refetch
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  // ── Integridad / Auditoría de PRODUCTOS_MASTER + EQUIVALENCIAS ───
  async function renderIntegridad(skipFetch) {
    const cont = $('auditAlertas');
    const resumenEl = $('auditResumen');
    if (!cont || !resumenEl) return;
    if (!skipFetch) resumenEl.innerHTML = '<span class="text-slate-500">Cargando…</span>';
    try {
      const r = await API.get('getAuditoriaIntegridad', {});
      const data = (r && r.data) ? r.data : r;
      const alertas = (data && data.alertas) || [];
      const ultimaLimpia = data && data.ultimaAuditoriaLimpia;

      if (!alertas.length) {
        resumenEl.innerHTML = `
          <div class="flex items-start gap-3">
            <div class="text-2xl">✅</div>
            <div class="flex-1">
              <div class="text-sm font-semibold text-green-400">Catálogo íntegro</div>
              <div class="text-xs text-slate-500 mt-0.5">${ultimaLimpia ? 'Última auditoría limpia: ' + new Date(ultimaLimpia).toLocaleString() : 'Sin alertas activas. Corre una auditoría para verificar.'}</div>
            </div>
          </div>`;
        cont.innerHTML = '';
        return;
      }
      const criticas = alertas.filter(a => a.urgencia === 'CRITICA').length;
      const altas    = alertas.filter(a => a.urgencia === 'ALTA').length;
      resumenEl.innerHTML = `
        <div class="flex items-start gap-3">
          <div class="text-2xl">${criticas > 0 ? '🚨' : '⚠️'}</div>
          <div class="flex-1">
            <div class="text-sm font-semibold ${criticas > 0 ? 'text-rose-400' : 'text-amber-400'}">${alertas.length} alertas activas</div>
            <div class="text-xs text-slate-500 mt-0.5">${criticas} críticas · ${altas} altas · ${alertas.length - criticas - altas} medias/info</div>
          </div>
        </div>`;
      cont.innerHTML = alertas.map(a => {
        const colorBorder = a.urgencia === 'CRITICA' ? 'border-rose-500/40' : a.urgencia === 'ALTA' ? 'border-amber-500/40' : 'border-slate-700';
        const colorTipo   = a.urgencia === 'CRITICA' ? 'text-rose-400' : a.urgencia === 'ALTA' ? 'text-amber-400' : 'text-slate-400';
        let detalleExtra = '';
        // MOD_NO_AUTORIZADA → mostrar accion, tabla, source, params, contexto auditoría
        if (a.tipo === 'MOD_NO_AUTORIZADA' && a.datos) {
          const d = a.datos;
          let paramsObj = {};
          try { paramsObj = typeof d.params === 'string' ? JSON.parse(d.params) : (d.params || {}); } catch(_) { paramsObj = {}; }
          const idProd = paramsObj.idProducto || paramsObj.codigoBarra || paramsObj.idEquiv || '—';
          const camposEditados = Object.keys(paramsObj).filter(k => k !== '_source' && k !== '_audit' && k !== 'idProducto' && k !== 'idEquiv').join(', ') || '—';
          // Contexto auditoría
          const usuario = d.usuario ? `${d.usuario} (${d.rol || 'sin rol'})` : '— sin sesión —';
          const idSesion = d.idSesion || '—';
          const dispositivo = d.idDispositivo ? d.idDispositivo.slice(0, 16) + '…' : '— sin device ID —';
          const appOrigen = d.appOrigen || '—';
          // userAgent simplificado (extrae plataforma/browser)
          const ua = d.userAgent || '';
          const uaSimple = ua.match(/(iPhone|iPad|Android|Windows|Mac|Linux)[^;)]*/)?.[0]?.slice(0, 40) || (ua ? ua.slice(0, 40) : '—');
          const tsApp = d.timestampApp ? new Date(d.timestampApp).toLocaleString() : '—';
          detalleExtra = `
            <div class="mt-2 space-y-2">
              <!-- Qué intentó hacer -->
              <div class="text-[11px] font-mono space-y-0.5" style="background:rgba(244,63,94,.05);border-left:2px solid #f43f5e;padding:6px 8px;border-radius:4px">
                <div class="text-rose-300 font-semibold">⛔ Operación bloqueada</div>
                <div><span class="text-slate-500">Acción:</span> <span class="text-slate-300">${d.accion || '—'} en ${d.tabla || '—'}</span></div>
                <div><span class="text-slate-500">Origen reportado:</span> <span class="text-rose-300">${d.source || 'sin _source'}</span></div>
                <div><span class="text-slate-500">Producto/registro:</span> <span class="text-slate-300">${idProd}</span></div>
                <div><span class="text-slate-500">Campos:</span> <span class="text-slate-300">${camposEditados}</span></div>
              </div>
              <!-- Quién / Dónde / Cuándo -->
              <div class="text-[11px] font-mono space-y-0.5" style="background:rgba(99,102,241,.05);border-left:2px solid #6366f1;padding:6px 8px;border-radius:4px">
                <div class="text-indigo-300 font-semibold">🔎 Contexto del intento</div>
                <div><span class="text-slate-500">👤 Usuario:</span> <span class="text-slate-300">${usuario}</span></div>
                <div><span class="text-slate-500">🔑 idSesión:</span> <span class="text-slate-300">${idSesion}</span></div>
                <div><span class="text-slate-500">📱 Dispositivo:</span> <span class="text-slate-300">${dispositivo}</span></div>
                <div><span class="text-slate-500">🌐 App origen:</span> <span class="text-slate-300">${appOrigen}</span></div>
                <div><span class="text-slate-500">💻 Plataforma:</span> <span class="text-slate-300">${uaSimple}</span></div>
                <div><span class="text-slate-500">⏰ Hora cliente:</span> <span class="text-slate-300">${tsApp}</span></div>
              </div>
            </div>
            <div class="text-[10px] text-slate-600 mt-2 italic">💡 Si reconoces el usuario y la acción (cambió un precio, etc.) seguramente venga de una pestaña/dispositivo con la PWA antigua. Recárgala y marca la alerta como resuelta. Si NO reconoces nada, investigar.</div>
          `;
        } else if (a.datos && a.datos.primeras) {
          // AUDIT_INTEGRIDAD → primeras 5 anomalías
          detalleExtra = '<div class="text-[10px] text-slate-500 mt-2 font-mono whitespace-pre-wrap">'
            + (a.datos.primeras || []).slice(0, 5).map(p => '· ' + (p.detalle || JSON.stringify(p))).join('\n')
            + '</div>';
        }
        const fechaStr = a.fecha ? new Date(a.fecha).toLocaleString() : '';
        return `
          <div class="card-sm border ${colorBorder} p-3">
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span class="text-xs font-bold ${colorTipo}">${a.urgencia}</span>
                  <span class="text-xs text-slate-500 font-mono">${a.tipo}</span>
                </div>
                <div class="text-sm text-slate-200 mt-1">${a.mensaje}</div>
                <div class="text-[10px] text-slate-600 mt-1">${fechaStr}</div>
                ${detalleExtra}
              </div>
              <button onclick="MOS.auditResolver('${a.idAlerta}')" class="btn-ghost text-xs px-2 py-1 shrink-0" title="Marcar como resuelta">✓</button>
            </div>
          </div>`;
      }).join('');
    } catch(e) {
      resumenEl.innerHTML = `<div class="text-rose-400 text-sm">Error: ${e.message}</div>`;
      cont.innerHTML = '';
    }
  }

  async function auditCorrer() {
    const resumenEl = $('auditResumen');
    if (resumenEl) resumenEl.innerHTML = '<span class="text-slate-500">Auditando…</span>';
    try {
      const r = await API.get('getAuditoriaIntegridad', { run: 'true' });
      const data = (r && r.data) ? r.data : r;
      const totalAnomalias = (data && data.anomalias) ? data.anomalias.length : 0;
      toast(totalAnomalias === 0 ? 'Auditoría limpia ✓' : totalAnomalias + ' anomalías detectadas', totalAnomalias === 0 ? 'ok' : 'error');
      await renderIntegridad();
      _auditCheckBanner();
    } catch(e) {
      toast('Error: ' + e.message, 'error');
      if (resumenEl) resumenEl.innerHTML = `<div class="text-rose-400 text-sm">Error: ${e.message}</div>`;
    }
  }

  async function auditResolver(idAlerta) {
    if (!idAlerta) return;
    try {
      await API.post('resolverAlertaAuditoria', { idAlerta });
      await renderIntegridad();
      _auditCheckBanner();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  async function auditResolverTodas() {
    try {
      const r = await API.get('getAuditoriaIntegridad', {});
      const data = (r && r.data) ? r.data : r;
      const alertas = (data && data.alertas) || [];
      if (!alertas.length) { toast('No hay alertas activas', 'info'); return; }
      if (!confirm('¿Marcar las ' + alertas.length + ' alertas como resueltas?')) return;
      await Promise.all(alertas.map(a => API.post('resolverAlertaAuditoria', { idAlerta: a.idAlerta }).catch(() => {})));
      toast(alertas.length + ' alertas archivadas', 'ok');
      await renderIntegridad();
      _auditCheckBanner();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  // Banner de alertas en el catálogo
  async function _auditCheckBanner() {
    const banner = $('auditBannerCat');
    if (!banner) return;
    try {
      const r = await API.get('getAuditoriaIntegridad', {});
      const data = (r && r.data) ? r.data : r;
      const alertas = (data && data.alertas) || [];
      if (!alertas.length) { banner.classList.add('hidden'); banner.innerHTML = ''; return; }
      const criticas = alertas.filter(a => a.urgencia === 'CRITICA').length;
      const cls = criticas > 0 ? 'border-rose-500/40 bg-rose-500/5 text-rose-300' : 'border-amber-500/40 bg-amber-500/5 text-amber-300';
      const icon = criticas > 0 ? '🚨' : '⚠️';
      banner.classList.remove('hidden');
      banner.innerHTML = `
        <div class="card-sm border ${cls} p-3 flex items-center gap-3 cursor-pointer" onclick="MOS.nav('config');setTimeout(()=>MOS.setCfgTab('integridad'),50)">
          <span class="text-xl">${icon}</span>
          <div class="flex-1 min-w-0">
            <div class="text-sm font-semibold">${alertas.length} alerta${alertas.length === 1 ? '' : 's'} de integridad de catálogo</div>
            <div class="text-xs opacity-80">Click para ver detalle en Configuración → Integridad</div>
          </div>
          <span class="text-xl opacity-60">→</span>
        </div>`;
    } catch(_) { banner.classList.add('hidden'); }
  }

  function renderZonas() {
    const tbody = $('tbodyZonas');
    if (!tbody) return;
    if (!cfgData.zonas.length) {
      tbody.innerHTML = '<tr><td colspan="7" class="text-center py-8 text-slate-500 text-sm">Sin zonas registradas. Crea la primera.</td></tr>';
      return;
    }
    tbody.innerHTML = cfgData.zonas.map(z => {
      const estCount = cfgData.estaciones.filter(e => e.idZona === z.idZona).length;
      return `<tr>
        <td class="font-mono text-xs text-slate-400">${z.idZona}</td>
        <td class="font-medium text-white">${z.nombre}</td>
        <td class="hidden sm:table-cell text-slate-400 text-xs">${z.direccion || '—'}</td>
        <td class="hidden md:table-cell text-slate-400 text-xs">${z.responsable || '—'}</td>
        <td class="text-center"><span class="text-xs px-2 py-0.5 rounded-full bg-indigo-900 text-indigo-300">${estCount} est.</span></td>
        <td><span class="text-xs px-2 py-0.5 rounded-full ${z.estado === '1' || z.estado === 1 ? 'bg-emerald-900 text-emerald-300' : 'bg-slate-700 text-slate-400'}">${z.estado === '1' || z.estado === 1 ? 'Activa' : 'Inactiva'}</span></td>
        <td><button onclick="MOS.abrirModalZona('${z.idZona}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700">✏️</button></td>
      </tr>`;
    }).join('');
  }

  function abrirModalZona(id) {
    ['Id','Nombre','Direccion','Responsable','Desc'].forEach(f => {
      const el = $('zona' + f); if (el) el.value = '';
    });
    if (id) {
      const z = cfgData.zonas.find(x => x.idZona === id);
      if (!z) return;
      $('modalZonaTitle').textContent = 'Editar Zona';
      $('zonaId').value          = z.idZona;
      $('zonaNombre').value      = z.nombre || '';
      $('zonaDireccion').value   = z.direccion || '';
      $('zonaResponsable').value = z.responsable || '';
      $('zonaEstado').value      = String(z.estado ?? '1');
      $('zonaDesc').value        = z.descripcion || '';
    } else {
      $('modalZonaTitle').textContent = 'Nueva Zona';
      $('zonaId').value = '';
      $('zonaEstado').value = '1';
    }
    openModal('modalZona');
  }

  async function guardarZona() {
    const nombre = $('zonaNombre')?.value.trim();
    if (!nombre) { toast('Nombre requerido', 'error'); return; }
    const params = {
      idZona:      $('zonaId')?.value || undefined,
      nombre,
      descripcion: $('zonaDesc')?.value || '',
      direccion:   $('zonaDireccion')?.value || '',
      responsable: $('zonaResponsable')?.value || '',
      estado:      $('zonaEstado')?.value ?? '1'
    };
    if (!params.idZona) delete params.idZona;
    try {
      await API.post(params.idZona ? 'actualizarZona' : 'crearZona', params);
      toast('Zona guardada', 'ok');
      closeModal('modalZona');
      S.loaded['config'] = false;
      await loadConfig();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  function renderEstaciones() {
    const tbody = $('tbodyEstaciones');
    if (!tbody) return;
    if (!cfgData.estaciones.length) {
      tbody.innerHTML = '<tr><td colspan="7" class="text-center py-8 text-slate-500 text-sm">Sin estaciones. Configura el GAS URL.</td></tr>';
      return;
    }
    tbody.innerHTML = cfgData.estaciones.map(e => {
      const tipoBadge = e.tipo === 'CAJA' ? 'badge-blue' : 'badge-yellow';
      const appColor  = e.appOrigen === 'mosExpress' ? 'text-indigo-400' : 'text-orange-400';
      return `<tr>
        <td><div class="font-medium text-sm text-slate-200">${e.nombre}</div><div class="text-xs text-slate-500">${e.idEstacion}</div></td>
        <td class="text-slate-400 text-xs">${e.idZona || '—'}</td>
        <td><span class="badge ${tipoBadge}">${e.tipo}</span></td>
        <td class="${appColor} text-xs font-medium">${e.appOrigen}</td>
        <td class="hidden sm:table-cell text-slate-500 text-xs">${e.descripcion || '—'}</td>
        <td><span class="badge ${e.activo == '1' ? 'badge-green' : 'badge-gray'}">${e.activo == '1' ? 'Activa' : 'Inactiva'}</span></td>
        <td><button onclick="MOS.abrirModalEstacion('${e.idEstacion}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700">✏️</button></td>
      </tr>`;
    }).join('');
  }

  function renderImpresoras() {
    const tbody = $('tbodyImpresoras');
    if (!tbody) return;
    if (!cfgData.impresoras.length) {
      tbody.innerHTML = '<tr><td colspan="7" class="text-center py-8 text-slate-500 text-sm">Sin impresoras registradas.</td></tr>';
      return;
    }
    tbody.innerHTML = cfgData.impresoras.map(imp => {
      const tipoBadge = imp.tipo === 'TICKET' ? 'badge-blue' : imp.tipo === 'ADHESIVO' ? 'badge-yellow' : 'badge-gray';
      const hasPrintId = imp.printNodeId && imp.printNodeId !== '';
      return `<tr>
        <td><div class="font-medium text-sm text-slate-200">${imp.nombre}</div></td>
        <td>
          ${hasPrintId
            ? `<code class="text-indigo-400 text-xs bg-indigo-500/10 px-2 py-0.5 rounded">${imp.printNodeId}</code>`
            : `<span class="text-yellow-400 text-xs">⚠️ Sin configurar</span>`}
        </td>
        <td><span class="badge ${tipoBadge}">${imp.tipo}</span></td>
        <td class="text-slate-500 text-xs">${imp.idEstacion || '—'}</td>
        <td class="${imp.appOrigen === 'mosExpress' ? 'text-indigo-400' : 'text-orange-400'} text-xs">${imp.appOrigen}</td>
        <td><span class="badge ${imp.activo == '1' ? 'badge-green' : 'badge-gray'}">${imp.activo == '1' ? 'Activa' : 'Inactiva'}</span></td>
        <td><button onclick="MOS.abrirModalImpresora('${imp.idImpresora}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700">✏️</button></td>
      </tr>`;
    }).join('');
  }

  function renderPersonal() {
    // MOS users
    const elMOS = $('listUsuariosMOS');
    if (elMOS) {
      if (!cfgData.personalMOS.length) {
        elMOS.innerHTML = '<p class="text-slate-500 text-sm text-center py-4">Sin usuarios MOS</p>';
      } else {
        elMOS.innerHTML = cfgData.personalMOS.map(p => {
          const ini = ((p.nombre||'?')[0] + (p.apellido||'?')[0]).toUpperCase();
          const rolCls = p.rol === 'master' ? 'badge-yellow' : 'badge-blue';
          return `<div class="flex items-center gap-3 p-3 rounded-lg" style="background:#0d1526;border:1px solid #1e293b">
            <div class="w-9 h-9 rounded-full flex items-center justify-center text-white text-sm font-bold shrink-0"
                 style="background:${p.color||'#6366f1'}">${ini}</div>
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm text-slate-200">${p.nombre} ${p.apellido||''}</div>
              <span class="badge ${rolCls} text-xs">${p.rol}</span>
            </div>
            <div class="flex items-center gap-1">
              <span class="badge ${p.estado=='1'?'badge-green':'badge-gray'} text-xs">${p.estado=='1'?'Activo':'Inactivo'}</span>
              <button onclick="MOS.abrirModalPersonal('${p.idPersonal}','MOS')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700 ml-1">✏️</button>
            </div>
          </div>`;
        }).join('');
      }
    }
    // WH operadores
    const el = $('listOperadores');
    if (!el) return;
    if (!cfgData.personal.length) {
      el.innerHTML = '<p class="text-slate-500 text-sm text-center py-4">Sin operadores registrados</p>';
      return;
    }
    el.innerHTML = cfgData.personal.map(p => {
      const initials = (p.nombre || '?').charAt(0) + (p.apellido || '?').charAt(0);
      const rolBadge = p.rol === 'ENVASADOR' ? 'badge-yellow' : p.rol === 'SUPERVISOR' ? 'badge-blue' : 'badge-gray';
      return `<div class="flex items-center gap-3 p-3 rounded-lg" style="background:#0d1526;border:1px solid #1e293b">
        <div class="w-9 h-9 rounded-full flex items-center justify-center text-white text-sm font-bold shrink-0"
             style="background:${p.color || '#6366f1'}">${initials}</div>
        <div class="flex-1 min-w-0">
          <div class="font-medium text-sm text-slate-200">${p.nombre} ${p.apellido || ''}</div>
          <div class="flex items-center gap-2 mt-0.5">
            <span class="badge ${rolBadge} text-xs">${p.rol}</span>
            <span class="text-xs text-slate-500">${p.tarifaHora ? 'S/.' + parseFloat(p.tarifaHora).toFixed(2) + '/h' : ''}</span>
          </div>
        </div>
        <div class="flex items-center gap-1">
          <span class="badge ${p.estado == '1' ? 'badge-green' : 'badge-gray'} text-xs">${p.estado == '1' ? 'Activo' : 'Inactivo'}</span>
          <button onclick="MOS.abrirModalPersonal('${p.idPersonal}','warehouseMos')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700 ml-1">✏️</button>
        </div>
      </div>`;
    }).join('');
  }

  function renderSeries() {
    const tbody = $('tbodySeries');
    if (!tbody) return;
    if (!cfgData.series.length) {
      tbody.innerHTML = '<tr><td colspan="7" class="text-center py-8 text-slate-500 text-sm">Sin series configuradas.</td></tr>';
      return;
    }
    const tipoBadge = { NOTA_VENTA: 'badge-gray', BOLETA: 'badge-blue', FACTURA: 'badge-yellow' };
    tbody.innerHTML = cfgData.series.map(s => `<tr>
      <td class="text-slate-300 text-xs font-medium">${s.idEstacion}</td>
      <td class="text-slate-500 text-xs">${s.idZona || '—'}</td>
      <td><span class="badge ${tipoBadge[s.tipoDocumento] || 'badge-gray'}">${s.tipoDocumento}</span></td>
      <td><code class="text-indigo-400 text-xs bg-indigo-500/10 px-2 py-0.5 rounded">${s.serie}</code></td>
      <td class="font-semibold text-slate-200">${s.correlativo}</td>
      <td><span class="badge ${s.activo == '1' ? 'badge-green' : 'badge-gray'}">${s.activo == '1' ? 'Activa' : 'Inactiva'}</span></td>
      <td><button onclick="MOS.abrirModalSerie('${s.idSerie}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700">✏️</button></td>
    </tr>`).join('');
  }

  function renderSeguridad() {
    // PINs por estación (solo ME cajas)
    const listPins = $('listPinsEstaciones');
    if (!listPins) return;
    const cajasMe = cfgData.estaciones.filter(e => e.appOrigen === 'mosExpress' && e.tipo === 'CAJA');
    if (!cajasMe.length) {
      listPins.innerHTML = '<p class="text-slate-500 text-sm text-center py-4">Sin estaciones de tipo CAJA.</p>';
    } else {
      listPins.innerHTML = cajasMe.map(e => `
        <div class="flex items-center justify-between p-3 rounded-lg" style="background:#0d1526;border:1px solid #1e293b">
          <div>
            <div class="text-sm font-medium text-slate-200">${e.nombre}</div>
            <div class="text-xs text-slate-500">${e.idZona} · ${e.idEstacion}</div>
          </div>
          <div class="flex items-center gap-2">
            <input class="inp w-24 text-center" type="password" maxlength="6"
                   placeholder="••••" id="pin_${e.idEstacion}"
                   title="Nuevo PIN para ${e.nombre}">
            <button onclick="MOS.guardarPinEstacion('${e.idEstacion}')"
                    class="btn-primary text-xs px-2 py-1">Guardar</button>
          </div>
        </div>
      `).join('');
    }
  }

  function renderDispositivos() {
    const tbody = $('tbodyDispositivos');
    if (!tbody) return;
    if (!cfgData.dispositivos.length) {
      tbody.innerHTML = '<tr><td colspan="6" class="text-center py-8 text-slate-500 text-sm">Sin dispositivos registrados.</td></tr>';
      return;
    }
    tbody.innerHTML = cfgData.dispositivos.map(d => {
      const isActivo = d.Estado === 'ACTIVO';
      const appColor = d.App === 'mosExpress' ? 'text-indigo-400' : 'text-orange-400';
      const uc = d.Ultima_Conexion || '—';
      return `<tr>
        <td>
          <div class="font-medium text-sm text-slate-200">${d.Nombre_Equipo || '—'}</div>
          <div class="text-xs text-slate-600 font-mono truncate max-w-[180px]">${d.ID_Dispositivo}</div>
        </td>
        <td class="${appColor} text-xs font-medium">${d.App || '—'}</td>
        <td><span class="badge ${isActivo ? 'badge-green' : 'badge-gray'}">${isActivo ? 'Activo' : 'Inactivo'}</span></td>
        <td class="text-slate-500 text-xs">${uc}</td>
        <td>
          <button onclick="MOS.toggleEstadoDispositivo('${d.ID_Dispositivo}','${isActivo ? 'INACTIVO' : 'ACTIVO'}')"
                  class="text-xs px-2 py-1 rounded border ${isActivo ? 'border-red-700 text-red-400 hover:bg-red-900/30' : 'border-green-700 text-green-400 hover:bg-green-900/30'}">
            ${isActivo ? 'Desactivar' : 'Activar'}
          </button>
        </td>
        <td><button onclick="MOS.abrirModalDispositivo('${d.ID_Dispositivo}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700">✏️</button></td>
      </tr>`;
    }).join('');
  }

  // Config CRUD
  function abrirModalEstacion(id) {
    ['Id','Nombre','Tipo','App','Pin','Desc'].forEach(f => {
      const el = $('est' + f); if (el && el.tagName !== 'SELECT') el.value = '';
    });
    // Poblar select de zonas dinámicamente
    const zonaSelect = $('estZona');
    if (zonaSelect) {
      zonaSelect.innerHTML = '<option value="">— Sin zona —</option>' +
        cfgData.zonas.filter(z => z.estado === '1' || z.estado === 1).map(z =>
          `<option value="${z.idZona}">${z.nombre}</option>`
        ).join('');
    }
    if (id) {
      const e = cfgData.estaciones.find(x => x.idEstacion === id);
      if (!e) return;
      $('modalEstTitle').textContent = 'Editar Estación';
      $('estId').value     = e.idEstacion;
      $('estNombre').value = e.nombre || '';
      if (zonaSelect) zonaSelect.value = e.idZona || '';
      $('estTipo').value   = e.tipo || 'CAJA';
      $('estApp').value    = e.appOrigen || 'mosExpress';
      $('estDesc').value   = e.descripcion || '';
    } else {
      $('modalEstTitle').textContent = 'Nueva Estación';
      $('estId').value = '';
      $('estTipo').value = 'CAJA';
      $('estApp').value = 'mosExpress';
    }
    openModal('modalEstacion');
  }

  async function guardarEstacion() {
    const params = {
      idEstacion:  $('estId')?.value || undefined,
      nombre:      $('estNombre')?.value || '',
      idZona:      $('estZona')?.value || '',
      tipo:        $('estTipo')?.value || 'CAJA',
      appOrigen:   $('estApp')?.value || 'mosExpress',
      adminPin:    $('estPin')?.value || undefined,
      descripcion: $('estDesc')?.value || ''
    };
    if (!params.nombre) { toast('Nombre requerido', 'error'); return; }
    if (!params.adminPin) delete params.adminPin; // no sobreescribir PIN si está vacío
    try {
      await API.post(params.idEstacion ? 'actualizarEstacion' : 'crearEstacion', params);
      toast('Estación guardada', 'ok');
      closeModal('modalEstacion');
      S.loaded['config'] = false;
      await loadConfig();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  function abrirModalImpresora(id) {
    ['Id','Nombre','PrintNodeId','Estacion','Zona','Desc'].forEach(f => {
      const el = $('imp' + f); if (el && el.tagName !== 'SELECT') el.value = '';
    });
    if (id) {
      const imp = cfgData.impresoras.find(x => x.idImpresora === id);
      if (!imp) return;
      $('modalImpTitle').textContent = 'Editar Impresora';
      $('impId').value          = imp.idImpresora;
      $('impNombre').value      = imp.nombre || '';
      $('impPrintNodeId').value = imp.printNodeId || '';
      $('impTipo').value        = imp.tipo || 'TICKET';
      $('impEstacion').value    = imp.idEstacion || '';
      $('impZona').value        = imp.idZona || '';
      $('impApp').value         = imp.appOrigen || 'mosExpress';
      $('impDesc').value        = imp.descripcion || '';
    } else {
      $('modalImpTitle').textContent = 'Nueva Impresora';
      $('impId').value = '';
      $('impTipo').value = 'TICKET';
      $('impApp').value = 'mosExpress';
    }
    openModal('modalImpresora');
  }

  async function guardarImpresora() {
    const params = {
      idImpresora:  $('impId')?.value || undefined,
      nombre:       $('impNombre')?.value || '',
      printNodeId:  $('impPrintNodeId')?.value || '',
      tipo:         $('impTipo')?.value || 'TICKET',
      idEstacion:   $('impEstacion')?.value || '',
      idZona:       $('impZona')?.value || '',
      appOrigen:    $('impApp')?.value || 'mosExpress',
      descripcion:  $('impDesc')?.value || ''
    };
    if (!params.nombre) { toast('Nombre requerido', 'error'); return; }
    try {
      await API.post(params.idImpresora ? 'actualizarImpresora' : 'crearImpresora', params);
      toast('Impresora guardada', 'ok');
      closeModal('modalImpresora');
      S.loaded['config'] = false;
      await loadConfig();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  function abrirModalPersonal(id, appOrigen = 'warehouseMos') {
    ['Nombre','Apellido','Pin','Tarifa','Monto'].forEach(f => {
      const el = $('pers' + f); if (el && el.tagName !== 'SELECT') el.value = '';
    });
    $('persId').value = '';
    $('persAppOrigen').value = appOrigen;
    const isMOS = appOrigen === 'MOS';
    // Show/hide WH-only fields
    const tw = $('persTarifaWrap'); if (tw) tw.style.display = isMOS ? 'none' : '';
    const mw = $('persMontoWrap');  if (mw) mw.style.display = isMOS ? 'none' : '';
    // Set rol options based on app
    const rolSel = $('persRol');
    if (rolSel) {
      rolSel.innerHTML = isMOS
        ? '<option value="master">master (acceso total)</option><option value="admin">admin (sin configuración)</option>'
        : '<option value="ALMACENERO">ALMACENERO</option><option value="ENVASADOR">ENVASADOR</option><option value="SUPERVISOR">SUPERVISOR</option>';
    }
    $('persColor').value = '#6366f1';

    const source = isMOS ? cfgData.personalMOS : cfgData.personal;
    if (id) {
      const p = source.find(x => x.idPersonal === id);
      if (!p) return;
      $('modalPersTitle').textContent = isMOS ? 'Editar Usuario MOS' : 'Editar Operador';
      $('persId').value       = p.idPersonal;
      $('persNombre').value   = p.nombre || '';
      $('persApellido').value = p.apellido || '';
      if (rolSel) rolSel.value = p.rol || (isMOS ? 'admin' : 'ALMACENERO');
      $('persColor').value    = p.color || '#6366f1';
      if (!isMOS) {
        $('persTarifa').value = p.tarifaHora || '';
        $('persMonto').value  = p.montoBase  || '';
      }
    } else {
      $('modalPersTitle').textContent = isMOS ? 'Nuevo Usuario MOS' : 'Nuevo Operador';
      if (rolSel) rolSel.value = isMOS ? 'admin' : 'ALMACENERO';
    }
    openModal('modalPersonal');
  }

  async function guardarPersonal() {
    const appOrigen = $('persAppOrigen')?.value || 'warehouseMos';
    const isMOS = appOrigen === 'MOS';
    const params = {
      idPersonal:  $('persId')?.value || undefined,
      nombre:      $('persNombre')?.value || '',
      apellido:    $('persApellido')?.value || '',
      rol:         $('persRol')?.value || (isMOS ? 'admin' : 'ALMACENERO'),
      color:       $('persColor')?.value || '#6366f1',
      tipo:        'OPERADOR',
      appOrigen:   appOrigen
    };
    if (!isMOS) {
      params.tarifaHora = $('persTarifa')?.value || 0;
      params.montoBase  = $('persMonto')?.value  || 0;
    }
    const pin = $('persPin')?.value;
    if (pin) params.pin = pin;
    if (!params.nombre) { toast('Nombre requerido', 'error'); return; }
    if (!params.idPersonal && !pin) { toast('PIN requerido', 'error'); return; }
    try {
      await API.post(params.idPersonal ? 'actualizarPersonalMaster' : 'crearPersonalMaster', params);
      toast(params.idPersonal ? 'Actualizado' : 'Creado', 'ok');
      closeModal('modalPersonal');
      S.loaded['config'] = false;
      await loadConfig();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  function abrirModalSerie(id) {
    ['Id','Estacion','Zona','Serie','Correlativo'].forEach(f => {
      const el = $('serie' + f); if (el && el.tagName !== 'SELECT') el.value = '';
    });
    if (id) {
      const s = cfgData.series.find(x => x.idSerie === id);
      if (!s) return;
      $('modalSerieTitle').textContent = 'Editar Serie';
      $('serieId').value          = s.idSerie;
      $('serieEstacion').value    = s.idEstacion || '';
      $('serieZona').value        = s.idZona || '';
      $('serieTipo').value        = s.tipoDocumento || 'BOLETA';
      $('serieSerie').value       = s.serie || '';
      $('serieCorrelativo').value = s.correlativo || 1;
    } else {
      $('modalSerieTitle').textContent = 'Nueva Serie';
      $('serieId').value = '';
      $('serieCorrelativo').value = 1;
    }
    openModal('modalSerie');
  }

  async function guardarSerie() {
    const params = {
      idSerie:       $('serieId')?.value || undefined,
      idEstacion:    $('serieEstacion')?.value || '',
      idZona:        $('serieZona')?.value || '',
      tipoDocumento: $('serieTipo')?.value || 'BOLETA',
      serie:         $('serieSerie')?.value || '',
      correlativo:   parseInt($('serieCorrelativo')?.value || 1)
    };
    if (!params.idEstacion || !params.serie) { toast('Estación y Serie son requeridos', 'error'); return; }
    try {
      await API.post(params.idSerie ? 'actualizarSerie' : 'crearSerie', params);
      toast('Serie guardada', 'ok');
      closeModal('modalSerie');
      S.loaded['config'] = false;
      await loadConfig();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  async function guardarPinEstacion(idEstacion) {
    const inp = $('pin_' + idEstacion);
    const pin = inp?.value || '';
    if (!pin || pin.length < 4) { toast('PIN debe tener al menos 4 dígitos', 'error'); return; }
    try {
      await API.post('actualizarEstacion', { idEstacion, adminPin: pin });
      toast('PIN actualizado', 'ok');
      if (inp) inp.value = '';
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  async function guardarPinWH() {
    const pin  = $('pinWH')?.value || '';
    const conf = $('pinWHConfirm')?.value || '';
    if (!pin || pin.length < 4)  { toast('PIN debe tener al menos 4 dígitos', 'error'); return; }
    if (pin !== conf)             { toast('Los PINs no coinciden', 'error'); return; }
    try {
      await API.post('setConfig', { clave: 'PIN_ADMIN_WH', valor: pin, descripcion: 'PIN administrador warehouseMos' });
      toast('PIN admin warehouseMos actualizado', 'ok');
      const pw = $('pinWH'); if (pw) pw.value = '';
      const pc = $('pinWHConfirm'); if (pc) pc.value = '';
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  // Close modal on backdrop click
  document.addEventListener('click', e => {
    if (e.target.classList.contains('modal-backdrop')) {
      e.target.classList.remove('open');
    }
  });

  // Renderiza la vista de Cajas usando S._todasCajas / S._todosTickets ya cargados
  function _renderCajasDesdeEstado() {
    const abiertas  = (S._todasCajas||[]).filter(c=>c.estado==='ABIERTA');
    const cerradas  = (S._todasCajas||[]).filter(c=>c.estado!=='ABIERTA');
    const tkAll     = S._todosTickets||[];
    const todayStr  = today();

    // KPIs (recalcular localmente)
    const hoyKpis   = S._cajasHoy||[];
    const totalDia  = hoyKpis.reduce((s,c)=>s+c.totalVentas,0);
    const ticketsDia= hoyKpis.reduce((s,c)=>s+c.tickets,0);
    const setQ = (id,v)=>{ const el=$(id); if(el) el.textContent=v; };
    setQ('cajasKpiVentas', fmtMoney(totalDia));

    // Tickets KPIs desde S._todosTickets
    const hoy  = todayStr;
    let nvH=0,bH=0,fH=0,totH=0,nvM=0,bM=0,fM=0,totM=0;
    tkAll.forEach(t => {
      const an = t.estado==='ANULADO';
      if (!an) {
        totM++; if(t.tipo==='NV') nvM++; else if(t.tipo==='B') bM++; else if(t.tipo==='F') fM++;
        if(t.fecha===hoy){ totH++; if(t.tipo==='NV') nvH++; else if(t.tipo==='B') bH++; else if(t.tipo==='F') fH++; }
      }
    });
    setQ('cajasKpiTicketsHoy', totH); setQ('cajasKpiTicketsMes', totM);
    setQ('cajasKpiNV', nvH); setQ('cajasKpiBoleta', bH); setQ('cajasKpiFactura', fH);

    // Cajas abiertas
    const vivoWrap  = $('cajasVivoWrap');
    const vivoGrid  = $('cajasVivoGrid');
    const vivoCount = $('cajasVivoCount');
    if (abiertas.length>0 && vivoGrid) {
      vivoWrap?.classList.remove('hidden');
      if (vivoCount) vivoCount.textContent = abiertas.length;
      vivoGrid.innerHTML = abiertas.map(c=>_buildCajaCard(c)).join('');
    } else { vivoWrap?.classList.add('hidden'); }

    // Gráficos
    const chartsWrap = $('cajasChartsWrap');
    S._todasCajas = S._todasCajas||[];
    if (S._todasCajas.length>0 && chartsWrap) {
      chartsWrap.classList.remove('hidden');
      _renderChartCajasCompacto(7); _renderChartMetodosHoy();
    }

    // Historial
    const histWrap  = $('cajasHistorialWrap');
    const histTbody = $('cajasHistTbody');
    const histTitle = $('cajasHistTitle');
    if (cerradas.length>0 && histWrap && histTbody) {
      histWrap.classList.remove('hidden');
      if (histTitle) histTitle.textContent = 'Historial de Cierres ('+cerradas.length+')';
      const hora  = s=>(s||'').substring(11,16);
      const fecha = s=>(s||'').substring(0,16).replace('T',' ');
      histTbody.innerHTML = cerradas.map(c=>{
        const esHoy=(c.fechaCierre||'').startsWith(todayStr);
        return `<tr data-caja-row="${c.idCaja}">
          <td><div class="font-medium">${c.vendedor||'—'}</div><div class="text-xs text-slate-500">${esHoy?'Hoy '+hora(c.fechaCierre):fecha(c.fechaCierre)}</div></td>
          <td><span class="badge badge-blue">${c.zona||c.estacion||'—'}</span></td>
          <td class="text-slate-400 text-xs">${hora(c.fechaApertura)} → ${hora(c.fechaCierre)}</td>
          <td id="hr-total-${c.idCaja}" class="font-semibold">${fmtMoney(c.totalVentas)}</td>
          <td id="hr-tickets-${c.idCaja}" class="text-center">${c.tickets}</td>
          <td>
            <button onclick="window.open('./turno.html?idCaja=${c.idCaja}&api='+encodeURIComponent(API.getUrl()),'_blank')" class="btn-ghost text-xs px-3 py-1.5">📋 Turno</button>
          </td>
        </tr>`;
      }).join('');
    } else { histWrap?.classList.add('hidden'); }

    const empty = $('cajasEmpty');
    if (abiertas.length===0 && cerradas.length===0) empty?.classList.remove('hidden');
    else empty?.classList.add('hidden');

    const ts = $('cajasTimestamp');
    if (ts && S._cajasGenTs) ts.textContent = 'Actualizado: ' + S._cajasGenTs;
  }

  // ── CAJAS ────────────────────────────────────────────────────
  async function loadCajas(force) {
    if (!force && S.loaded['cajas']) return;
    S.loaded['cajas'] = true;

    const loading  = $('cajasLoading');
    const content  = $('cajasContent');
    const empty    = $('cajasEmpty');

    // Si ya tenemos datos precargados del timer, renderizar inmediatamente
    // y luego refrescar en background (sin bloquear ni mostrar spinner)
    if (S._cajasLoaded && S._todasCajas) {
      loading?.classList.add('hidden');
      content?.classList.remove('hidden');
      _renderCajasDesdeEstado();
      if (force) _cajasRefreshSilencioso(); // actualizar en bg sin spinner
      return;
    }

    loading?.classList.remove('hidden');
    content?.classList.add('hidden');

    try {
      const res = await API.get('getCierresCaja', {});

      loading?.classList.add('hidden');
      content?.classList.remove('hidden');

      const { kpis, abiertas = [], cerradas = [], generadoEn } = res || {};

      // Guardar cajas de hoy en estado para el panel de desglose
      const todayStr = today();
      S._cajasHoy = [
        ...abiertas,
        ...(cerradas || []).filter(c =>
          (c.fechaApertura || '').startsWith(todayStr) ||
          (c.fechaCierre   || '').startsWith(todayStr)
        )
      ];

      // Timestamp
      const ts = $('cajasTimestamp');
      if (ts) ts.textContent = 'Actualizado: ' + (generadoEn || '—');

      // ── KPIs ────────────────────────────────────────────────
      const set = (id, v) => { const el=$(id); if(el) el.textContent=v; };
      const { kpisTickets = {}, todosTickets: tkAll = [] } = res || {};
      S._todosTickets = tkAll;

      set('cajasKpiVentas',      fmtMoney(kpis?.totalDia || 0));
      set('cajasKpiTicketsHoy',  kpisTickets.hoy?.total    || 0);
      set('cajasKpiTicketsMes',  kpisTickets.mes?.total    || 0);
      set('cajasKpiNV',          kpisTickets.hoy?.NV       || 0);
      set('cajasKpiBoleta',      kpisTickets.hoy?.B        || 0);
      set('cajasKpiFactura',     kpisTickets.hoy?.F        || 0);

      const todosVacios = abiertas.length === 0 && cerradas.length === 0;
      if (todosVacios) { empty?.classList.remove('hidden'); return; }
      empty?.classList.add('hidden');

      // ── Cajas ABIERTAS en vivo ───────────────────────────────
      const vivoWrap  = $('cajasVivoWrap');
      const vivoGrid  = $('cajasVivoGrid');
      const vivoCount = $('cajasVivoCount');
      if (abiertas.length > 0 && vivoWrap && vivoGrid) {
        vivoWrap.classList.remove('hidden');
        if (vivoCount) vivoCount.textContent = abiertas.length;
        vivoGrid.innerHTML = abiertas.map(c => _buildCajaCard(c)).join('');
      } else if (vivoWrap) {
        vivoWrap.classList.add('hidden');
      }

      // ── Gráficos ─────────────────────────────────────────────
      const chartsWrap = $('cajasChartsWrap');
      S._todasCajas = [...abiertas, ...cerradas];
      if (S._todasCajas.length > 0 && chartsWrap) {
        chartsWrap.classList.remove('hidden');
        _renderChartCajasCompacto(7);
        _renderChartMetodosHoy();
      }

      // ── Historial cierres (últimos 30 días) ──────────────────
      const histWrap  = $('cajasHistorialWrap');
      const histTbody = $('cajasHistTbody');
      const histTitle = $('cajasHistTitle');
      if (cerradas.length > 0 && histWrap && histTbody) {
        histWrap.classList.remove('hidden');
        if (histTitle) histTitle.textContent = 'Historial de Cierres (' + cerradas.length + ')';
        histTbody.innerHTML = cerradas.map(c => {
          const fecha  = s => (s || '').substring(0, 16).replace('T', ' ');
          const hora   = s => (s || '').substring(11, 16);
          const esHoy  = (c.fechaCierre || '').startsWith(today());
          return `<tr data-caja-row="${c.idCaja}">
            <td>
              <div class="font-medium">${c.vendedor || '—'}</div>
              <div class="text-xs text-slate-500">${esHoy ? 'Hoy ' + hora(c.fechaCierre) : fecha(c.fechaCierre)}</div>
            </td>
            <td><span class="badge badge-blue">${c.zona || c.estacion || '—'}</span></td>
            <td class="text-slate-400 text-xs">${hora(c.fechaApertura)} → ${hora(c.fechaCierre)}</td>
            <td id="hr-total-${c.idCaja}" class="font-semibold">${fmtMoney(c.totalVentas)}</td>
            <td id="hr-tickets-${c.idCaja}" class="text-center">${c.tickets}</td>
            <td>
              <button onclick="window.open('./turno.html?idCaja=${c.idCaja}&api='+encodeURIComponent(API.getUrl()),'_blank')" class="btn-ghost text-xs px-3 py-1.5">📋 Turno</button>
            </td>
          </tr>`;
        }).join('');
      } else if (histWrap) {
        histWrap.classList.add('hidden');
      }

    } catch(e) {
      loading?.classList.add('hidden');
      content?.classList.remove('hidden');
      empty?.classList.remove('hidden');
      if (empty) empty.innerHTML = `<div class="text-4xl mb-3">⚠️</div><div class="text-red-400 font-medium mb-1">Error al cargar</div><div class="text-xs text-slate-500">${e.message}</div>`;
      S.loaded['cajas'] = false;
    }
  }

  // ── Auto-refresh silencioso de cajas cada 60s ───────────────
  let _cajasRefreshTimer = null;

  // ── Construye el HTML de una card de caja abierta ───────────
  function _buildCajaCard(c) {
    const elapsed   = _cajaElapsed(c.fechaApertura);
    const pctEfect  = c.totalVentas > 0 ? Math.round(c.efectivo / c.totalVentas * 100) : 0;
    const pctOtros  = 100 - pctEfect;
    const metodos   = Object.entries(c.byMetodo || {}).sort((a,b)=>b[1]-a[1])
      .map(([k,v])=>`<span class="text-xs text-slate-400">${k}: <span class="text-slate-200 font-medium">${fmtMoney(v)}</span></span>`).join('');
    const tkList    = c.ticketsList || [];
    const exList    = c.extrasList  || [];

    const estadoBadge = est => {
      if (est==='ANULADO')    return '<span class="badge badge-red" style="font-size:10px">ANULADO</span>';
      if (est==='POR_COBRAR') return '<span class="badge badge-yellow" style="font-size:10px">POR COBRAR</span>';
      if (est==='CREDITO')    return '<span class="badge badge-blue" style="font-size:10px">CRÉDITO</span>';
      return '';
    };
    const metodoBadge = m => {
      const cls = m==='EFECTIVO'?'badge-green':m==='POR_COBRAR'?'badge-yellow':m==='ANULADO'?'badge-red':'badge-blue';
      return `<span class="badge ${cls}" style="font-size:10px">${m}</span>`;
    };
    const ticketRows = tkList.map(t => {
      const an = t.estado==='ANULADO';
      return `<div class="flex items-center gap-2 py-1.5 border-b border-slate-800/60 ${an?'opacity-40':''}">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-1.5 flex-wrap">
            <span class="text-xs font-mono ${an?'line-through text-slate-500':'text-slate-200'}">${t.correlativo||t.idVenta}</span>
            ${estadoBadge(t.estado)}
          </div>
          <div class="text-xs text-slate-500 truncate mt-0.5">${t.clienteNom||t.clienteDoc||'Sin cliente'} · <span class="text-slate-600">${t.tipoDoc}</span>${t.hora?' · '+t.hora:''}</div>
        </div>
        <div class="text-right shrink-0">
          <div class="text-sm font-semibold ${an?'line-through text-slate-600':'text-white'}">${fmtMoney(t.total)}</div>
          <div class="mt-0.5">${metodoBadge(t.metodo)}</div>
        </div>
      </div>`;
    }).join('');
    const extraRows = exList.map(ex=>`
      <div class="flex items-center justify-between py-1 text-xs border-b border-slate-800/40 last:border-0">
        <div class="flex items-center gap-1.5">
          <span class="${ex.tipo==='INGRESO'?'text-emerald-400':'text-red-400'} font-bold">${ex.tipo==='INGRESO'?'▲':'▼'}</span>
          <span class="text-slate-300">${ex.concepto||ex.tipo}</span>
          ${ex.hora?`<span class="text-slate-600">${ex.hora}</span>`:''}
        </div>
        <span class="font-semibold ${ex.tipo==='INGRESO'?'text-emerald-400':'text-red-400'}">${ex.tipo==='INGRESO'?'+':'-'}${fmtMoney(ex.monto)}</span>
      </div>`).join('');

    return `
    <div class="card p-4" id="cajacard-${c.idCaja}" style="border-left:3px solid #22c55e">
      <div class="flex items-start justify-between mb-3">
        <div>
          <div class="font-semibold text-white text-base">${c.vendedor||'—'}</div>
          <div class="text-xs text-slate-400">${c.zona||c.estacion||'—'} · <span class="text-emerald-400">⏱ ${elapsed}</span></div>
        </div>
        <span class="badge badge-green">ABIERTA</span>
      </div>
      <div class="grid grid-cols-4 gap-2 mb-3">
        <div class="card-sm p-2 text-center"><div id="cv-total-${c.idCaja}" class="text-base font-bold text-white">${fmtMoney(c.totalVentas)}</div><div class="text-xs text-slate-500">Total</div></div>
        <div class="card-sm p-2 text-center"><div id="cv-tickets-${c.idCaja}" class="text-base font-bold text-emerald-400">${c.tickets}</div><div class="text-xs text-slate-500">Tickets</div></div>
        <div class="card-sm p-2 text-center"><div id="cv-anulados-${c.idCaja}" class="text-base font-bold ${c.anulados>0?'text-red-400':'text-slate-500'}">${c.anulados}</div><div class="text-xs text-slate-500">Anulados</div></div>
        <div class="card-sm p-2 text-center"><div id="cv-porcobrar-${c.idCaja}" class="text-base font-bold ${c.sinCobrar>0?'text-yellow-400':'text-slate-500'}">${c.sinCobrar}</div><div class="text-xs text-slate-500">Por cobrar</div></div>
      </div>
      <div class="mb-2">
        <div class="flex justify-between text-xs text-slate-500 mb-1">
          <span id="cv-barlbl-${c.idCaja}">Efectivo ${pctEfect}%</span><span>Otros ${pctOtros}%</span>
        </div>
        <div class="flex rounded-full overflow-hidden h-1.5" style="background:#1e293b">
          <div id="cv-barefect-${c.idCaja}" style="width:${pctEfect}%;background:#22c55e;transition:width .5s"></div>
          <div id="cv-barotros-${c.idCaja}" style="width:${pctOtros}%;background:#6366f1;transition:width .5s"></div>
        </div>
      </div>
      <div id="cv-metodos-${c.idCaja}" class="flex flex-wrap gap-x-3 gap-y-1 mb-3">${metodos}</div>
      <button id="cajabtn-${c.idCaja}" onclick="MOS.toggleCajaDetail('${c.idCaja}')"
        class="w-full text-xs text-slate-400 py-1.5 rounded-lg border border-slate-800 hover:border-indigo-600 hover:text-indigo-400 transition-all flex items-center justify-center gap-1.5">
        <span id="cajabtn-icon-${c.idCaja}">▼</span>
        <span id="cajabtn-label-${c.idCaja}">Ver ${tkList.length} ticket${tkList.length!==1?'s':''}</span>
      </button>
      <div id="cajadetail-${c.idCaja}" class="hidden mt-3 pt-3 border-t border-slate-800">
        <div class="flex items-center justify-between mb-2">
          <span id="cajatickets-label-${c.idCaja}" class="text-xs font-semibold text-slate-400 uppercase tracking-wide">Tickets (${tkList.length})</span>
        </div>
        ${tkList.length>0?`<div class="mb-4">${ticketRows}</div>`:`<div class="text-xs text-slate-600 mb-4">Sin tickets aún</div>`}
        ${exList.length>0?`<div class="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2">Movimientos extra (${exList.length})</div><div class="card-sm p-2 mb-4">${extraRows}</div>`:''}
        <div class="card-sm p-3 text-xs">
          <div class="text-xs font-semibold text-slate-400 uppercase tracking-wide mb-2">Arqueo estimado</div>
          <div class="text-xs text-slate-500 mb-1">💵 Físico (en caja)</div>
          <div class="flex justify-between py-0.5"><span class="text-slate-500">Apertura</span><span>${fmtMoney(c.montoInicial)}</span></div>
          <div class="flex justify-between py-0.5"><span class="text-slate-500">+ Ventas efectivo</span><span class="text-emerald-400">+${fmtMoney(c.efectivo)}</span></div>
          ${c.entradas>0?`<div class="flex justify-between py-0.5"><span class="text-slate-500">+ Ingresos extra</span><span class="text-emerald-400">+${fmtMoney(c.entradas)}</span></div>`:''}
          ${c.salidas>0?`<div class="flex justify-between py-0.5"><span class="text-slate-500">- Salidas extra</span><span class="text-red-400">-${fmtMoney(c.salidas)}</span></div>`:''}
          <div class="flex justify-between font-bold border-t border-slate-700 pt-1.5 mt-1 mb-3">
            <span class="text-slate-200">= Esperado físico</span><span class="text-emerald-400">${fmtMoney(c.efectivoEsperado)}</span>
          </div>
          ${c.otros>0?`<div class="text-xs text-slate-500 mb-1">📲 Virtual</div>
          ${Object.entries(c.byMetodo||{}).filter(([k])=>k!=='EFECTIVO').sort((a,b)=>b[1]-a[1]).map(([k,v])=>`<div class="flex justify-between py-0.5"><span class="text-slate-500">${k}</span><span class="text-indigo-400">${fmtMoney(v)}</span></div>`).join('')}
          <div class="flex justify-between font-bold border-t border-slate-700 pt-1.5 mt-1"><span class="text-slate-200">= Total virtual</span><span class="text-indigo-400">${fmtMoney(c.otros)}</span></div>`:''}
        </div>
      </div>
    </div>`;
  }

  // Helper: actualizar texto de un elemento solo si cambió, con flash opcional
  function _setVal(id, newVal, flash) {
    const el = $(id); if (!el) return;
    const str = String(newVal);
    if (el.textContent === str) return;
    el.textContent = str;
    if (flash) { el.classList.remove('val-flash'); el.offsetHeight; el.classList.add('val-flash'); }
  }

  // Smart update de una card de caja abierta (solo toca los valores que cambiaron)
  function _updateCajaCard(c) {
    const card = $('cajacard-' + c.idCaja);
    if (!card) return false; // no existe → hay que crearla
    const pct  = c.totalVentas > 0 ? Math.round(c.efectivo / c.totalVentas * 100) : 0;
    const metosHtml = Object.entries(c.byMetodo || {}).sort((a,b)=>b[1]-a[1])
      .map(([k,v])=>`<span class="text-xs text-slate-400">${k}: <span class="text-slate-200 font-medium">${fmtMoney(v)}</span></span>`).join('');

    _setVal('cv-total-'    + c.idCaja, fmtMoney(c.totalVentas), true);
    _setVal('cv-tickets-'  + c.idCaja, c.tickets, true);
    _setVal('cv-anulados-' + c.idCaja, c.anulados, c.anulados > 0);
    _setVal('cv-porcobrar-'+ c.idCaja, c.sinCobrar, c.sinCobrar > 0);

    const barEf = $('cv-barefect-' + c.idCaja);
    const barOt = $('cv-barotros-' + c.idCaja);
    if (barEf) barEf.style.width = pct + '%';
    if (barOt) barOt.style.width = (100-pct) + '%';
    _setVal('cv-barlbl-'   + c.idCaja, `Efectivo ${pct}%`);

    const metDiv = $('cv-metodos-' + c.idCaja);
    if (metDiv && metDiv.innerHTML !== metosHtml) metDiv.innerHTML = metosHtml;

    // Actualizar elapsed (siempre cambia)
    const cabeceraEl = card.querySelector('.text-xs.text-slate-400');
    if (cabeceraEl) {
      const el = cabeceraEl.querySelector('span.text-emerald-400');
      if (el) el.textContent = '⏱ ' + _cajaElapsed(c.fechaApertura);
    }
    return true;
  }

  // Smart update del historial (filas cerradas)
  function _updateHistorialRow(c) {
    const row = document.querySelector('[data-caja-row="' + c.idCaja + '"]');
    if (!row) return false;
    _setVal('hr-total-'   + c.idCaja, fmtMoney(c.totalVentas), true);
    _setVal('hr-tickets-' + c.idCaja, c.tickets, true);
    return true;
  }

  async function _cajasRefreshSilencioso() {
    if (!API.isConfigured()) return;
    try {
      const res = await API.get('getCierresCaja', {});
      const { kpis, abiertas = [], cerradas = [], kpisTickets = {}, todosTickets: tkAll = [], generadoEn } = res || {};

      // ── Detectar cambios en tickets ──────────────────────────
      const prevIds  = new Set((S._todosTickets || []).map(t => t.idVenta));
      const nuevos   = (tkAll || []).filter(t => !prevIds.has(t.idVenta));

      // ── Actualizar estado global ─────────────────────────────
      S._todosTickets = tkAll;
      const todayStr  = today();
      S._cajasHoy  = [...abiertas, ...(cerradas || []).filter(c =>
        (c.fechaApertura||'').startsWith(todayStr)||(c.fechaCierre||'').startsWith(todayStr))];
      S._todasCajas = [...abiertas, ...cerradas];
      S._cajasLoaded = true;
      S._cajasGenTs  = generadoEn || '';

      // ── KPIs ─────────────────────────────────────────────────
      _setVal('cajasKpiVentas',     fmtMoney(kpis?.totalDia||0), true);
      _setVal('cajasKpiTicketsHoy', kpisTickets.hoy?.total||0,   nuevos.length > 0);
      _setVal('cajasKpiTicketsMes', kpisTickets.mes?.total||0,   false);
      _setVal('cajasKpiNV',         kpisTickets.hoy?.NV||0,      false);
      _setVal('cajasKpiBoleta',     kpisTickets.hoy?.B||0,       false);
      _setVal('cajasKpiFactura',    kpisTickets.hoy?.F||0,       false);
      const ts = $('cajasTimestamp');
      if (ts) ts.textContent = 'Actualizado: ' + (generadoEn||'—');

      // ── Cards cajas abiertas ──────────────────────────────────
      const vivoGrid = $('cajasVivoGrid');
      if (vivoGrid) {
        const prevCardIds = new Set([...vivoGrid.querySelectorAll('[id^="cajacard-"]')].map(el=>el.id.replace('cajacard-','')));
        const newIds      = new Set(abiertas.map(c=>c.idCaja));

        // Actualizar o crear cards
        abiertas.forEach(c => {
          const existed = _updateCajaCard(c);
          if (!existed) {
            // Nueva caja abierta → crear card y prependla
            const tmp = document.createElement('div');
            tmp.innerHTML = _buildCajaCard(c);
            const newCard = tmp.firstElementChild;
            newCard.style.animation = 'cardSlideIn .4s ease';
            vivoGrid.prepend(newCard);
            if ($('cajasVivoWrap')) $('cajasVivoWrap').classList.remove('hidden');
          }
        });

        // Cards de cajas que ya cerraron → fade out y remover
        prevCardIds.forEach(id => {
          if (!newIds.has(id)) {
            const card = $('cajacard-' + id);
            if (card) { card.style.transition='opacity .4s'; card.style.opacity='0'; setTimeout(()=>card.remove(),400); }
          }
        });

        // Actualizar contador
        const vivoCount = $('cajasVivoCount');
        if (vivoCount) vivoCount.textContent = abiertas.length;
        if (vivoGrid.parentElement) vivoGrid.parentElement.classList.toggle('hidden', abiertas.length === 0);
      }

      // ── Historial (cajas cerradas) ────────────────────────────
      const histWrap  = $('cajasHistorialWrap');
      const histTbody = $('cajasHistTbody');
      if (histTbody && cerradas.length > 0) {
        histWrap?.classList.remove('hidden');
        const hora  = s => (s||'').substring(11,16);
        const fecha = s => (s||'').substring(0,16).replace('T',' ');
        cerradas.forEach(c => {
          const existed = _updateHistorialRow(c);
          if (!existed) {
            // Nueva fila → prepend con flash
            const esHoy  = (c.fechaCierre||'').startsWith(todayStr);
            const tr = document.createElement('tr');
            tr.setAttribute('data-caja-row', c.idCaja);
            tr.style.animation = 'ticketFadeIn .5s ease';
            tr.innerHTML = `
              <td><div class="font-medium">${c.vendedor||'—'}</div><div class="text-xs text-slate-500">${esHoy?'Hoy '+hora(c.fechaCierre):fecha(c.fechaCierre)}</div></td>
              <td><span class="badge badge-blue">${c.zona||c.estacion||'—'}</span></td>
              <td class="text-slate-400 text-xs">${hora(c.fechaApertura)} → ${hora(c.fechaCierre)}</td>
              <td id="hr-total-${c.idCaja}" class="font-semibold">${fmtMoney(c.totalVentas)}</td>
              <td id="hr-tickets-${c.idCaja}" class="text-center">${c.tickets}</td>
              <td>
                <button onclick="window.open('./turno.html?idCaja=${c.idCaja}&api='+encodeURIComponent(API.getUrl()),'_blank')" class="btn-ghost text-xs px-3 py-1.5">📋 Turno</button>
              </td>`;
            histTbody.prepend(tr);
            const histTitle = $('cajasHistTitle');
            if (histTitle) histTitle.textContent = 'Historial de Cierres (' + cerradas.length + ')';
          }
        });
      }

      // ── Panel tickets (si está abierto) ──────────────────────
      if (!$('cajasTicketsPanel')?.classList.contains('hidden')) {
        if (nuevos.length > 0) {
          _renderTicketList();
          nuevos.forEach(t => {
            const row = document.querySelector('[data-ticket-id="' + t.idVenta + '"]');
            if (row) { row.classList.remove('val-flash'); row.offsetHeight; row.classList.add('val-flash'); }
          });
          toast(`↑ ${nuevos.length} ticket${nuevos.length>1?'s':''} nuevo${nuevos.length>1?'s':''}`, 'ok');
        } else {
          _renderTicketList();
        }
      }

      // ── Panel desglose ventas (si está abierto) ───────────────
      if (!$('cajasKpiDetalle')?.classList.contains('hidden')) toggleKpiVentas(), toggleKpiVentas();

      // ── Gráficos ─────────────────────────────────────────────
      if ($('cajasChartsWrap') && !$('cajasChartsWrap').classList.contains('hidden')) {
        if (!$('modalHistorialCajas') || $('modalHistorialCajas').classList.contains('hidden')) {
          _renderChartCajasCompacto(_chartCajasPeriodo);
          _renderChartMetodosHoy();
        }
      }

    } catch(e) { console.warn('[CajasRefresh]', e.message); }
  }

  function _startCajasRefresh() {
    _stopCajasRefresh();
    _cajasRefreshSilencioso(); // fetch inmediato
    _cajasRefreshTimer = setInterval(_cajasRefreshSilencioso, 60000);
  }
  function _stopCajasRefresh() {
    if (_cajasRefreshTimer) { clearInterval(_cajasRefreshTimer); _cajasRefreshTimer = null; }
  }

  // ── Charts de cajas ─────────────────────────────────────────
  const _CHART_COLORES = ['#6366f1','#f59e0b','#0ea5e9','#a855f7','#ef4444','#14b8a6','#f97316'];
  let _chartCajasPeriodo      = 7;
  let _chartCajasModalPeriodo = 7;

  function _cajasFiltradas(dias) {
    const todas  = S._todasCajas || [];
    const desde  = _fechaOffset(today(), -dias);
    return todas.filter(c =>
      (c.fechaApertura || '').substring(0, 10) >= desde ||
      (c.fechaCierre   || '').substring(0, 10) >= desde
    );
  }

  // Chart compacto: barras verticales, eje X = cajeros, agrupado por vendedor
  function _renderChartCajasCompacto(dias) {
    const cajas    = _cajasFiltradas(dias);
    const hoy      = today();
    const byVend   = {};
    cajas.forEach(c => {
      const k = c.vendedor || c.idCaja;
      if (!byVend[k]) byVend[k] = { total: 0, active: false };
      byVend[k].total += c.totalVentas;
      if (c.estado === 'ABIERTA') byVend[k].active = true;
    });
    const labels = Object.keys(byVend);
    const data   = labels.map(k => Math.round(byVend[k].total * 100) / 100);
    const colors = labels.map(k => byVend[k].active ? '#22c55e' : '#6366f1');

    renderChart('chartCajasBars', {
      type: 'bar',
      data: { labels, datasets: [{ data, backgroundColor: colors, borderRadius: 5, barThickness: 32 }] },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              title: ctx => ctx[0].label,
              label: ctx => ` S/. ${ctx.raw.toFixed(2)}`,
              afterLabel: ctx => {
                const v    = labels[ctx.dataIndex];
                const cajs = _cajasFiltradas(dias).filter(c => (c.vendedor || c.idCaja) === v);
                const ef   = cajs.reduce((s,c) => s + c.efectivo, 0);
                const virt = cajs.reduce((s,c) => s + c.otros, 0);
                const tk   = cajs.reduce((s,c) => s + c.tickets, 0);
                return [` Efectivo: S/.${ef.toFixed(2)}`, ` Virtual:  S/.${virt.toFixed(2)}`, ` Tickets: ${tk}`];
              }
            }
          }
        },
        scales: {
          y: { ticks: { callback: v => 'S/' + v, font: { size: 10 }, color: '#64748b' }, grid: { color: '#1e293b' } },
          x: { ticks: { font: { size: 11 }, color: '#94a3b8' }, grid: { display: false } }
        }
      }
    });
  }

  // Chart modal: barras apiladas, eje X = fechas (días), por cajero
  function _renderChartCajasModal(dias) {
    const cajas  = _cajasFiltradas(dias);
    const hoy    = today();

    // Generar rango de fechas
    const dates = [];
    for (let d = dias - 1; d >= 0; d--) {
      dates.push(_fechaOffset(today(), -d));
    }

    // Cajas por fecha
    const cajasByDate = {};
    cajas.forEach(c => {
      const f = (c.fechaApertura || c.fechaCierre || '').substring(0, 10);
      if (!cajasByDate[f]) cajasByDate[f] = [];
      cajasByDate[f].push(c);
    });

    // Vendedores únicos
    const vendedores = [...new Set(cajas.map(c => c.vendedor || c.idCaja))];

    const datasets = vendedores.map((v, i) => ({
      label: v,
      data: dates.map(d => {
        const cs = (cajasByDate[d] || []).filter(c => (c.vendedor || c.idCaja) === v);
        return Math.round(cs.reduce((s,c) => s + c.totalVentas, 0) * 100) / 100;
      }),
      backgroundColor: dates.map(d => {
        if (d !== hoy) return _CHART_COLORES[i % _CHART_COLORES.length] + '99';
        const cs = (cajasByDate[d] || []).filter(c => (c.vendedor || c.idCaja) === v);
        return cs.some(c => c.estado === 'ABIERTA') ? '#22c55e' : _CHART_COLORES[i % _CHART_COLORES.length];
      }),
      borderRadius: 3,
      stack: 'cajas'
    }));

    renderChart('chartCajasModal', {
      type: 'bar',
      data: {
        labels: dates.map(d => {
          const day = parseInt(d.substring(8));
          return d === hoy ? day + '*' : String(day);
        }),
        datasets
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: {
          legend: { position: 'bottom', labels: { font:{ size:10 }, padding:8, boxWidth:10, color:'#94a3b8' } },
          tooltip: {
            mode: 'index', intersect: false,
            callbacks: {
              title: ctx => {
                const d = dates[ctx[0].dataIndex];
                return d === hoy ? `Hoy ${d}` : d;
              },
              label: ctx => ctx.raw > 0 ? ` ${ctx.dataset.label}: ${fmtMoney(ctx.raw)}` : null,
              footer: ctx => {
                const total = ctx.reduce((s,c) => s + c.raw, 0);
                return total > 0 ? `Total del día: ${fmtMoney(total)}` : '';
              }
            }
          }
        },
        scales: {
          y: { stacked: true, ticks: { callback: v => 'S/' + v, font:{ size:10 }, color:'#64748b' }, grid:{ color:'#1e293b' } },
          x: { stacked: true, ticks: { font:{ size:11 }, color:'#94a3b8' }, grid:{ display:false } }
        }
      }
    });
  }

  function _renderChartMetodosHoy() {
    const hoy      = today();
    const cajasHoy = (S._todasCajas || []).filter(c =>
      (c.fechaApertura || '').startsWith(hoy) || (c.fechaCierre || '').startsWith(hoy)
    );
    const metAcum  = {};
    cajasHoy.forEach(c => Object.entries(c.byMetodo || {}).forEach(([k,v]) => {
      metAcum[k] = (metAcum[k] || 0) + v;
    }));
    const metKeys  = Object.keys(metAcum).sort((a,b) => metAcum[b] - metAcum[a]);
    const totalMet = metKeys.reduce((s,k) => s + metAcum[k], 0);
    if (!metKeys.length) return;

    renderChart('chartCajasMetodo', {
      type: 'doughnut',
      data: {
        labels: metKeys,
        datasets: [{ data: metKeys.map(k => metAcum[k]),
          backgroundColor: _CHART_COLORES, borderWidth: 2, borderColor: '#0f172a', hoverOffset: 6 }]
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: { callbacks: {
            label: ctx => ` ${ctx.label}: ${fmtMoney(ctx.raw)} (${Math.round(ctx.raw / totalMet * 100)}%)`
          }}
        }
      }
    });

    const det = $('cajasMetodoDetalle');
    if (det) det.innerHTML = metKeys.map((k, i) => `
      <div class="flex items-center justify-between text-xs">
        <div class="flex items-center gap-1.5">
          <span class="inline-block w-2.5 h-2.5 rounded-sm shrink-0" style="background:${_CHART_COLORES[i] || '#64748b'}"></span>
          <span class="text-slate-400">${k}</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-slate-500">${Math.round(metAcum[k] / totalMet * 100)}%</span>
          <span class="font-semibold text-white">${fmtMoney(metAcum[k])}</span>
        </div>
      </div>`).join('');
  }

  function setChartCajasPeriodo(dias) {
    _chartCajasPeriodo = dias;
    [7, 30, 90].forEach(d => {
      const el = $('ccp' + d); if (el) el.classList.toggle('active', d === dias);
    });
    _renderChartCajasCompacto(dias);
  }

  function setChartCajasModalPeriodo(dias) {
    _chartCajasModalPeriodo = dias;
    [7, 30, 90].forEach(d => {
      const el = $('ccm' + d); if (el) el.classList.toggle('active', d === dias);
    });
    _renderChartCajasModal(dias);
  }

  function abrirModalHistorialCajas() {
    const modal = $('modalHistorialCajas'); if (!modal) return;
    modal.classList.remove('hidden');
    setTimeout(() => _renderChartCajasModal(_chartCajasModalPeriodo), 50);
  }

  function cerrarModalHistorialCajas() {
    const modal = $('modalHistorialCajas'); if (modal) modal.classList.add('hidden');
  }

  // ── Historial de tickets ────────────────────────────────────
  let _tkFiltroFecha  = 'hoy';
  let _tkFiltroEstado = '';
  let _tkFiltroTipo   = '';
  let _modalTicketId  = null;

  function toggleKpiTickets() {
    const panel = $('cajasTicketsPanel');
    const arrow = $('cajasKpiTicketsArrow');
    if (!panel) return;
    const opening = panel.classList.contains('hidden');
    panel.classList.toggle('hidden', !opening);
    if (arrow) arrow.textContent = opening ? '▲' : '▼';
    if (opening) _renderTicketList();
  }

  function setTicketFiltroFecha(v) {
    _tkFiltroFecha = v;
    ['hoy','semana','mes','todos'].forEach(k => {
      const el = $('tf' + k.charAt(0).toUpperCase() + k.slice(1));
      if (el) el.classList.toggle('active', k === v);
    });
    _renderTicketList();
  }

  function setTicketFiltroEstado(v) {
    _tkFiltroEstado = v;
    _tkFiltroTipo   = '';
    ['All','Com','Pend','Anu'].forEach(k => { const el=$('te'+k); if(el) el.classList.remove('active'); });
    ['NV','B','F'].forEach(k => { const el=$('tt'+k); if(el) el.classList.remove('active'); });
    const map = {'':'All','COMPLETADO':'Com','POR_COBRAR':'Pend','ANULADO':'Anu'};
    const el = $('te' + (map[v] || 'All')); if(el) el.classList.add('active');
    _renderTicketList();
  }

  function setTicketFiltroTipo(v) {
    _tkFiltroTipo   = v;
    _tkFiltroEstado = '';
    ['All','Com','Pend','Anu'].forEach(k => { const el=$('te'+k); if(el) el.classList.remove('active'); });
    ['NV','B','F'].forEach(k => { const el=$('tt'+k); if(el) el.classList.remove('active'); });
    const el = $('tt' + v); if(el) el.classList.add('active');
    _renderTicketList();
  }

  function _renderTicketList() {
    const container = $('cajasTicketsList');
    if (!container) return;
    const hoy    = today();
    const semana = _fechaOffset(today(), -7);
    const mes    = _fechaOffset(today(), -30);
    const desde  = _tkFiltroFecha === 'hoy' ? hoy : _tkFiltroFecha === 'semana' ? semana : _tkFiltroFecha === 'mes' ? mes : '0000-00-00';

    let lista = (S._todosTickets || []).filter(t => {
      if (t.fecha < desde) return false;
      if (_tkFiltroEstado && t.estado !== _tkFiltroEstado) return false;
      if (_tkFiltroTipo   && t.tipo   !== _tkFiltroTipo)   return false;
      return true;
    });

    if (!lista.length) {
      container.innerHTML = '<div class="text-xs text-slate-600 py-4 text-center">Sin tickets para los filtros seleccionados</div>';
      return;
    }

    const metodoBadge = m => {
      const cls = m === 'EFECTIVO' ? 'badge-green' : m === 'POR_COBRAR' ? 'badge-yellow' : m === 'ANULADO' ? 'badge-red' : 'badge-blue';
      return `<span class="badge ${cls}" style="font-size:10px">${m}</span>`;
    };
    const estadoIcon = s => s === 'ANULADO' ? '🚫' : s === 'POR_COBRAR' ? '⏳' : s === 'CREDITO' ? '💳' : '✅';
    const tipoIcon   = t => t === 'F' ? '📋' : t === 'B' ? '📄' : '🧾';

    container.innerHTML = lista.map(t => {
      const anulado = t.estado === 'ANULADO';
      const label   = t.correlativo || t.idVenta;
      const esHoy   = t.fecha === hoy;
      const fechaStr = esHoy ? `hoy ${t.hora}` : `${t.fecha} ${t.hora}`;
      return `
      <div data-ticket-id="${t.idVenta}" class="border-b border-slate-800/60 py-2.5 ${anulado ? 'opacity-50' : ''}">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class="text-sm">${tipoIcon(t.tipo)}</span>
              <span class="text-xs font-mono font-semibold ${anulado ? 'line-through text-slate-500' : 'text-slate-200'}">${label}</span>
              <span class="text-xs text-slate-600">${fechaStr}</span>
            </div>
            <div class="text-xs text-slate-500 mt-0.5 truncate">
              ${estadoIcon(t.estado)} ${t.vendedor || '—'} · ${t.zona || '—'}
              ${t.clienteNom ? ' · ' + t.clienteNom : t.clienteDoc ? ' · ' + t.clienteDoc : ''}
            </div>
          </div>
          <div class="text-right shrink-0">
            <div class="text-sm font-bold ${anulado ? 'line-through text-slate-600' : 'text-white'}">${fmtMoney(t.total)}</div>
            <div class="mt-0.5">${metodoBadge(t.metodo)}</div>
          </div>
        </div>
        <!-- Botones de acción -->
        ${!anulado ? `
        <div class="flex gap-1.5 mt-1.5">
          <button onclick="MOS.confirmarAnularTicket('${t.idVenta}','${label}')"
            class="text-xs px-2.5 py-1 rounded-md border border-red-900/50 text-red-400 hover:bg-red-900/20 transition-colors">
            🚫 Anular
          </button>
          <button onclick="MOS.abrirModalMetodo('${t.idVenta}','${label}','${t.metodo}',${t.total})"
            class="text-xs px-2.5 py-1 rounded-md border border-slate-700 text-slate-400 hover:border-indigo-600 hover:text-indigo-400 transition-colors">
            💳 Cambiar método
          </button>
        </div>` : ''}
      </div>`;
    }).join('');
  }

  async function confirmarAnularTicket(idVenta, label, desdeModal) {
    if (!idVenta) { toast('ID de ticket inválido', 'error'); return; }
    if (!confirm(`¿Anular el ticket ${label}?\nEsta acción no se puede deshacer.`)) return;
    if (desdeModal) cerrarModalMetodo();
    const id = String(idVenta).trim();
    try {
      await API.post('anularTicketME', { idVenta: id });
      toast('Ticket anulado', 'ok');
      // Actualizar local inmediatamente
      if (S._todosTickets) {
        S._todosTickets.forEach(t => {
          if (String(t.idVenta).trim() === id) { t.metodo = 'ANULADO'; t.estado = 'ANULADO'; }
        });
      }
      _renderTicketList();
      setTimeout(() => _cajasRefreshSilencioso(), 1000);
    } catch(e) { toast(e.message, 'error'); }
  }

  // ── Modal cambiar método (replica flujo ME) ─────────────────
  let _modalTicketTotal  = 0;
  let _modalMetodoSel    = 'EFECTIVO';
  let _modalLabel        = '';

  function abrirModalMetodo(idVenta, label, metodoActual, total) {
    if (!idVenta) { toast('ID de ticket inválido', 'error'); return; }
    _modalTicketId    = String(idVenta).trim();
    _modalLabel       = label || idVenta;
    _modalTicketTotal = parseFloat(total) || 0;
    // Si no viene total buscar en S._todosTickets
    if (!_modalTicketTotal) {
      const tk = (S._todosTickets || []).find(t => String(t.idVenta).trim() === _modalTicketId);
      if (tk) _modalTicketTotal = tk.total;
    }
    _modalMetodoSel = metodoActual === 'POR_COBRAR' ? 'EFECTIVO' : (metodoActual || 'EFECTIVO');
    _renderModalMetodo();
    const modal = $('modalCambiarMetodo');
    if (modal) modal.classList.remove('hidden');
  }

  function _renderModalMetodo() {
    const box = $('modalCambiarMetodoBox');
    if (!box) return;
    const total = _modalTicketTotal;
    const sel   = _modalMetodoSel;

    // Sección dinámica según método seleccionado
    let seccion = '';
    if (sel === 'MIXTO') {
      const virt = parseFloat($('mmVirtual')?.value) || 0;
      const efec = Math.max(0, total - virt);
      const valido = virt > 0 && virt < total;
      seccion = `
        <div class="mt-3 space-y-2">
          <div>
            <label class="lbl text-sky-400">📲 Monto virtual (S/.)</label>
            <input id="mmVirtual" type="number" step="0.10" min="0.01" max="${(total - 0.01).toFixed(2)}"
              placeholder="0.00" value="${virt || ''}"
              oninput="MOS._onMixtoInput()"
              class="inp text-center text-xl font-bold" style="border-color:#7c3aed">
            ${virt > 0 && virt >= total ? '<p class="text-xs text-amber-400 mt-1">El monto virtual cubre el total — usa VIRTUAL</p>' : ''}
          </div>
          <div class="flex justify-between items-center px-1 py-1.5 rounded-lg" style="background:#0d1526">
            <span class="text-sm text-slate-400">💵 Efectivo</span>
            <span class="text-lg font-bold ${efec > 0 ? 'text-emerald-400' : 'text-slate-600'}">S/. ${efec.toFixed(2)}</span>
          </div>
          <button onclick="MOS.aplicarCambioMetodo('MIXTO')" ${!valido ? 'disabled' : ''}
            class="w-full py-3.5 rounded-xl font-bold text-sm transition-all ${valido ? 'bg-purple-600 hover:bg-purple-500 text-white' : 'bg-slate-800 text-slate-600 cursor-not-allowed'}">
            Confirmar MIXTO · S/. ${total.toFixed(2)}
          </button>
        </div>`;
    } else if (sel === 'EFECTIVO') {
      seccion = `
        <div class="mt-3">
          <div class="flex justify-between items-center px-3 py-3 rounded-xl mb-3" style="background:#0d1526">
            <span class="text-slate-400">💵 Cobrar en efectivo</span>
            <span class="text-xl font-bold text-emerald-400">S/. ${total.toFixed(2)}</span>
          </div>
          <button onclick="MOS.aplicarCambioMetodo('EFECTIVO')"
            class="w-full py-3.5 rounded-xl font-bold text-sm bg-emerald-700 hover:bg-emerald-600 text-white transition-all">
            Confirmar EFECTIVO · S/. ${total.toFixed(2)}
          </button>
        </div>`;
    } else { // VIRTUAL
      seccion = `
        <div class="mt-3">
          <div class="flex justify-between items-center px-3 py-3 rounded-xl mb-3" style="background:#0d1526">
            <span class="text-slate-400">📲 Cobro virtual</span>
            <span class="text-xl font-bold text-sky-400">S/. ${total.toFixed(2)}</span>
          </div>
          <button onclick="MOS.aplicarCambioMetodo('VIRTUAL')"
            class="w-full py-3.5 rounded-xl font-bold text-sm bg-sky-700 hover:bg-sky-600 text-white transition-all">
            Confirmar VIRTUAL · S/. ${total.toFixed(2)}
          </button>
        </div>`;
    }

    const metodoBtns = ['EFECTIVO','VIRTUAL','MIXTO'].map(m => {
      const cfg = { EFECTIVO:{icon:'💵',active:'border-emerald-500 text-emerald-400 bg-emerald-900/20'},
                    VIRTUAL: {icon:'📲',active:'border-sky-500 text-sky-400 bg-sky-900/20'},
                    MIXTO:   {icon:'🔀',active:'border-purple-500 text-purple-400 bg-purple-900/20'} }[m];
      const cls = (m === sel) ? cfg.active : 'border-slate-700 text-slate-500 hover:border-slate-500 hover:text-slate-300';
      return `<button onclick="MOS._selMetodo('${m}')"
        class="flex flex-col items-center justify-center gap-1.5 py-4 rounded-xl border-2 transition-all ${cls}">
        <span class="text-xl">${cfg.icon}</span>
        <span class="text-xs font-bold tracking-wide">${m}</span>
      </button>`;
    }).join('');

    box.innerHTML = `
      <div class="flex items-center justify-between mb-3">
        <div>
          <div class="font-semibold text-slate-200">Cambiar método de pago</div>
          <div class="text-xs text-slate-500 mt-0.5 font-mono">${_modalLabel}</div>
        </div>
        <button onclick="MOS.cerrarModalMetodo()" class="text-slate-600 hover:text-slate-300 text-xl leading-none">✕</button>
      </div>

      <!-- Total prominente -->
      <div class="rounded-xl p-3 mb-4 text-center" style="background:#0d1526;border:1px solid #1e293b">
        <div class="text-xs text-slate-500 uppercase tracking-widest mb-1">Total a cobrar</div>
        <div class="text-3xl font-black text-white">S/. ${total.toFixed(2)}</div>
      </div>

      <!-- 3 botones método -->
      <div class="grid grid-cols-3 gap-2">${metodoBtns}</div>

      <!-- Sección dinámica -->
      ${seccion}

      <!-- Anular -->
      <div class="mt-3 pt-3 border-t border-slate-800">
        <button onclick="MOS.confirmarAnularTicket('${_modalTicketId}','${_modalLabel}',true)"
          class="w-full py-2.5 rounded-xl text-sm font-semibold border border-red-900/50 text-red-400 hover:bg-red-900/20 transition-all">
          🚫 Anular ticket
        </button>
      </div>`;
  }

  function _selMetodo(m) {
    _modalMetodoSel = m;
    _renderModalMetodo();
    // Focus en input virtual si es MIXTO
    if (m === 'MIXTO') setTimeout(() => $('mmVirtual')?.focus(), 50);
  }

  function _onMixtoInput() { _renderModalMetodo(); }

  function cerrarModalMetodo() {
    const modal = $('modalCambiarMetodo'); if (modal) modal.classList.add('hidden');
    _modalTicketId = null;
  }

  async function aplicarCambioMetodo(metodo) {
    if (!_modalTicketId) return;
    const id = _modalTicketId;
    cerrarModalMetodo();
    try {
      await API.post('cambiarMetodoME', { idVenta: id, metodo });
      toast('Método actualizado: ' + metodo, 'ok');
      if (S._todosTickets) {
        S._todosTickets.forEach(t => {
          if (String(t.idVenta).trim() === id) { t.metodo = metodo; t.estado = 'COMPLETADO'; }
        });
      }
      _renderTicketList();
      setTimeout(() => _cajasRefreshSilencioso(), 1200);
    } catch(e) { toast(e.message, 'error'); }
  }

  function toggleKpiVentas() {
    const panel = $('cajasKpiDetalle');
    const arrow = $('cajasKpiVentasArrow');
    if (!panel) return;
    const opening = panel.classList.contains('hidden');
    panel.classList.toggle('hidden', !opening);
    if (arrow) arrow.textContent = opening ? '▲' : '▼';
    if (!opening) return; // solo renderiza al abrir

    const cajas = S._cajasHoy || [];
    const body  = $('cajasKpiDetalleBody');
    if (!body) return;

    if (!cajas.length) {
      body.innerHTML = '<div class="text-xs text-slate-500">Sin cajas registradas hoy.</div>';
      return;
    }

    body.innerHTML = cajas.map(c => {
      const esAbierta  = c.estado === 'ABIERTA';
      const badgeCls   = esAbierta ? 'badge-green' : 'badge-gray';
      const badgeTxt   = esAbierta ? 'ABIERTA' : 'CERRADA';
      const horaApert  = (c.fechaApertura || '').substring(11, 16);
      const horaCierre = (c.fechaCierre   || '').substring(11, 16);
      const rango      = horaCierre ? `${horaApert} → ${horaCierre}` : `desde ${horaApert}`;

      // Métodos virtuales (no efectivo)
      const virtuales = Object.entries(c.byMetodo || {}).filter(([k]) => k !== 'EFECTIVO').sort((a,b) => b[1]-a[1]);

      return `
      <div class="border-b border-slate-800 py-3 last:border-0">
        <!-- Cabecera caja -->
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2">
            <span class="badge ${badgeCls} text-xs">${badgeTxt}</span>
            <span class="font-medium text-sm text-white">${c.vendedor || '—'}</span>
            <span class="text-xs text-slate-500">${c.zona || c.estacion || ''}</span>
          </div>
          <span class="text-xs text-slate-600">${rango}</span>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 text-xs">
          <!-- Físico -->
          <div class="card-sm p-2">
            <div class="text-slate-500 mb-1">💵 Físico</div>
            <div class="flex justify-between py-0.5"><span class="text-slate-500">Apertura</span><span>${fmtMoney(c.montoInicial)}</span></div>
            <div class="flex justify-between py-0.5"><span class="text-slate-500">+ Efectivo ventas</span><span class="text-emerald-400">+${fmtMoney(c.efectivo)}</span></div>
            ${c.entradas > 0 ? `<div class="flex justify-between py-0.5"><span class="text-slate-500">+ Ingresos extra</span><span class="text-emerald-400">+${fmtMoney(c.entradas)}</span></div>` : ''}
            ${c.salidas  > 0 ? `<div class="flex justify-between py-0.5"><span class="text-slate-500">- Salidas extra</span><span class="text-red-400">-${fmtMoney(c.salidas)}</span></div>` : ''}
            <div class="flex justify-between font-bold border-t border-slate-700 pt-1 mt-1">
              <span class="text-slate-300">Esperado físico</span>
              <span class="text-emerald-400">${fmtMoney(c.efectivoEsperado)}</span>
            </div>
          </div>

          <!-- Virtual -->
          <div class="card-sm p-2">
            <div class="text-slate-500 mb-1">📲 Virtual</div>
            ${virtuales.length > 0
              ? virtuales.map(([k,v]) => `<div class="flex justify-between py-0.5"><span class="text-slate-500">${k}</span><span class="text-indigo-400">${fmtMoney(v)}</span></div>`).join('')
              : '<div class="text-slate-600 py-0.5">Sin pagos virtuales</div>'
            }
            ${virtuales.length > 0 ? `
            <div class="flex justify-between font-bold border-t border-slate-700 pt-1 mt-1">
              <span class="text-slate-300">Total virtual</span>
              <span class="text-indigo-400">${fmtMoney(c.otros)}</span>
            </div>` : ''}
          </div>
        </div>

        <!-- Total caja -->
        <div class="flex justify-between items-center mt-2 pt-1">
          <span class="text-xs text-slate-500">Total vendido (efectivo + virtual)</span>
          <span class="font-bold text-white text-sm">${fmtMoney(c.totalVentas)}</span>
        </div>
      </div>`;
    }).join('');
  }

  async function toggleCajaDetail(idCaja) {
    const detail    = $('cajadetail-' + idCaja);
    const iconEl    = $('cajabtn-icon-'  + idCaja);
    const labelEl   = $('cajabtn-label-' + idCaja);
    const headerLbl = $('cajatickets-label-' + idCaja);
    if (!detail) return;

    const opening = detail.classList.contains('hidden');
    detail.classList.toggle('hidden', !opening);

    if (!opening) {
      // Cerrando
      if (iconEl)  iconEl.textContent  = '▼';
      if (labelEl) {
        const rows = detail.querySelectorAll('[data-ticket-row]').length;
        labelEl.textContent = `Ver ${rows || ''} ticket${rows !== 1 ? 's' : ''}`;
      }
      return;
    }

    // Abriendo → refresh silencioso de esta caja
    if (iconEl) { iconEl.innerHTML = '<span class="spin" style="display:inline-block;font-size:13px">↻</span>'; iconEl.style.animation = ''; }
    if (labelEl) labelEl.textContent = 'Actualizando…';

    try {
      const res = await API.get('getCierresCaja', {});
      const { abiertas = [], cerradas = [], todosTickets: tkAll = [],
              kpis, kpisTickets = {}, generadoEn } = res || {};

      // Actualizar estado global silencioso
      S._todosTickets = tkAll;
      const todayStr  = today();
      S._todasCajas   = [...abiertas, ...cerradas];
      S._cajasHoy     = [...abiertas, ...(cerradas || []).filter(c =>
        (c.fechaApertura || '').startsWith(todayStr) || (c.fechaCierre || '').startsWith(todayStr))];

      // KPIs
      const setQ = (id, v) => { const el=$(id); if(el) el.textContent = v; };
      setQ('cajasKpiVentas',     fmtMoney(kpis?.totalDia || 0));
      setQ('cajasKpiTicketsHoy', kpisTickets.hoy?.total || 0);
      setQ('cajasKpiTicketsMes', kpisTickets.mes?.total || 0);
      setQ('cajasKpiNV',         kpisTickets.hoy?.NV    || 0);
      setQ('cajasKpiBoleta',     kpisTickets.hoy?.B     || 0);
      setQ('cajasKpiFactura',    kpisTickets.hoy?.F     || 0);
      const ts = $('cajasTimestamp');
      if (ts) ts.textContent = 'Actualizado: ' + (generadoEn || '—');

      // Actualizar solo el contenido de ESTA caja
      const cajaDatos = [...abiertas, ...cerradas].find(c => c.idCaja === idCaja);
      if (cajaDatos) {
        const tkList = cajaDatos.ticketsList || [];
        const exList = cajaDatos.extrasList  || [];
        _renderCajaTicketRows(idCaja, tkList, exList, cajaDatos);
        const count = tkList.length;
        if (labelEl) labelEl.textContent = `${count} ticket${count !== 1 ? 's' : ''} ▲`;
        if (headerLbl) headerLbl.textContent = `Tickets (${count})`;
      } else {
        if (labelEl) labelEl.textContent = 'Sin datos ▲';
      }
    } catch(e) {
      if (labelEl) labelEl.textContent = 'Error · intentar de nuevo ▲';
      console.warn('[CajaDetail]', e.message);
    } finally {
      if (iconEl) { iconEl.innerHTML = ''; iconEl.style.animation = ''; }
    }
  }

  // Re-renderiza solo las filas de tickets de una caja abierta sin tocar el resto del DOM
  function _renderCajaTicketRows(idCaja, tkList, exList, cajaDatos) {
    const detail = $('cajadetail-' + idCaja);
    if (!detail) return;

    const estadoBadge = est => {
      if (est === 'ANULADO')    return '<span class="badge badge-red" style="font-size:10px">ANULADO</span>';
      if (est === 'POR_COBRAR') return '<span class="badge badge-yellow" style="font-size:10px">POR COBRAR</span>';
      if (est === 'CREDITO')    return '<span class="badge badge-blue" style="font-size:10px">CRÉDITO</span>';
      return '';
    };
    const metodoBadge = m => {
      const cls = m === 'EFECTIVO' ? 'badge-green' : m === 'ANULADO' ? 'badge-red' : m === 'POR_COBRAR' ? 'badge-yellow' : 'badge-blue';
      return `<span class="badge ${cls}" style="font-size:10px">${m}</span>`;
    };

    const ticketRowsHtml = tkList.map(t => {
      const anulado = t.estado === 'ANULADO';
      return `
      <div data-ticket-row="${t.idVenta}" class="flex items-center gap-2 py-1.5 border-b border-slate-800/60 ${anulado ? 'opacity-40' : ''}">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-1.5 flex-wrap">
            <span class="text-xs font-mono ${anulado ? 'line-through text-slate-500' : 'text-slate-200'}">${t.correlativo || t.idVenta}</span>
            ${estadoBadge(t.estado)}
          </div>
          <div class="text-xs text-slate-500 truncate mt-0.5">${t.clienteNom || t.clienteDoc || 'Sin cliente'} · <span class="text-slate-600">${t.tipoDoc}</span>${t.hora ? ' · ' + t.hora : ''}</div>
        </div>
        <div class="text-right shrink-0">
          <div class="text-sm font-semibold ${anulado ? 'line-through text-slate-600' : 'text-white'}">${fmtMoney(t.total)}</div>
          <div class="mt-0.5">${metodoBadge(t.metodo)}</div>
        </div>
      </div>`;
    }).join('');

    // Buscar o crear contenedor de rows
    let rowsDiv = detail.querySelector('.caja-ticket-rows');
    if (!rowsDiv) {
      rowsDiv = document.createElement('div');
      rowsDiv.className = 'caja-ticket-rows mb-4';
      detail.insertBefore(rowsDiv, detail.firstChild.nextSibling);
    }

    if (tkList.length > 0) {
      rowsDiv.innerHTML = ticketRowsHtml;
      // Fade-in en toda la lista como confirmación visual
      rowsDiv.style.animation = 'none'; rowsDiv.offsetHeight;
      rowsDiv.style.animation = 'fadeIn .3s ease';
    } else {
      rowsDiv.innerHTML = '<div class="text-xs text-slate-600 mb-4">Sin tickets registrados aún</div>';
    }
  }

  function _cajaElapsed(fechaApertura) {
    if (!fechaApertura) return '—';
    try {
      const inicio = new Date(fechaApertura.replace(' ', 'T'));
      const mins   = Math.floor((Date.now() - inicio.getTime()) / 60000);
      if (mins < 60)  return mins + ' min';
      const h = Math.floor(mins / 60), m = mins % 60;
      return h + 'h ' + (m < 10 ? '0' : '') + m + 'm';
    } catch { return '—'; }
  }


  // ── DISPOSITIVOS CRUD ────────────────────────────────────────
  function abrirModalDispositivo(id) {
    const modal = $('modalDispositivo');
    if (!modal) return;
    $('dispId').value = '';
    $('dispIdVisible').value = '';
    $('dispNombre').value = '';
    $('dispApp').value = 'mosExpress';
    $('dispEstado').value = 'ACTIVO';
    const lbl = $('dispIdLabel');
    if (id) {
      const d = cfgData.dispositivos.find(x => x.ID_Dispositivo === id);
      if (d) {
        $('dispId').value        = d.ID_Dispositivo;
        $('dispIdVisible').value = d.ID_Dispositivo;
        $('dispNombre').value    = d.Nombre_Equipo || '';
        $('dispApp').value       = d.App    || 'mosExpress';
        $('dispEstado').value    = d.Estado || 'ACTIVO';
      }
      if (lbl) lbl.innerHTML = 'ID del Dispositivo <span class="text-slate-500">(editable — el nuevo UUID reemplazará el anterior)</span>';
      $('dispIdVisible').readOnly = false;
    } else {
      if (lbl) lbl.innerHTML = 'ID del Dispositivo <span class="text-slate-500">(UUID del equipo)</span>';
      $('dispIdVisible').readOnly = false;
    }
    modal.classList.remove('hidden');
  }

  function cerrarModalDispositivo() {
    const modal = $('modalDispositivo');
    if (modal) modal.classList.add('hidden');
  }

  async function guardarDispositivo() {
    const idOriginal = $('dispId').value.trim();
    const idNuevo    = ($('dispIdVisible')?.value || '').trim();
    const nombre     = $('dispNombre').value.trim();
    const app        = $('dispApp').value;
    const estado     = $('dispEstado').value;
    if (!nombre) { toast('El nombre del equipo es obligatorio', 'warn'); return; }
    if (!idNuevo) { toast('Pega el ID del dispositivo (UUID)', 'warn'); return; }
    try {
      if (idOriginal) {
        // Edición: si cambió el ID, crear con nuevo ID y borrar el anterior (no hay rename en Sheets)
        if (idOriginal !== idNuevo) {
          await API.post('crearDispositivo', { ID_Dispositivo: idNuevo, Nombre_Equipo: nombre, App: app, Estado: estado });
          await API.post('actualizarDispositivo', { ID_Dispositivo: idOriginal, Estado: 'INACTIVO' });
        } else {
          await API.post('actualizarDispositivo', { ID_Dispositivo: idOriginal, Nombre_Equipo: nombre, App: app, Estado: estado });
        }
      } else {
        await API.post('crearDispositivo', { ID_Dispositivo: idNuevo, Nombre_Equipo: nombre, App: app, Estado: estado });
      }
      toast('Dispositivo guardado', 'ok');
      cerrarModalDispositivo();
      await loadConfig();
    } catch(e) {
      toast(e.message || 'Error al guardar dispositivo', 'error');
    }
  }

  async function toggleEstadoDispositivo(id, nuevoEstado) {
    const d = cfgData.dispositivos.find(x => x.ID_Dispositivo === id);
    if (d) d.Estado = nuevoEstado;
    renderDispositivos();
    try {
      await API.post('actualizarDispositivo', { ID_Dispositivo: id, Estado: nuevoEstado });
      toast(nuevoEstado === 'ACTIVO' ? 'Dispositivo activado' : 'Dispositivo desactivado', 'ok');
    } catch(e) {
      if (d) d.Estado = nuevoEstado === 'ACTIVO' ? 'INACTIVO' : 'ACTIVO';
      renderDispositivos();
      toast(e.message || 'Error al actualizar', 'error');
    }
  }

  // ── PWA Install ──────────────────────────────────────────────
  let _installPrompt = null;
  window.addEventListener('beforeinstallprompt', e => {
    e.preventDefault();
    _installPrompt = e;
    const btn = document.getElementById('installAppBtn');
    if (btn) btn.classList.remove('hidden');
  });
  window.addEventListener('appinstalled', () => {
    _installPrompt = null;
    const btn = document.getElementById('installAppBtn');
    if (btn) btn.classList.add('hidden');
  });

  function installPWA() {
    if (!_installPrompt) { toast('La app ya está instalada o el navegador no lo permite', 'info'); return; }
    _installPrompt.prompt();
    _installPrompt.userChoice.then(r => {
      if (r.outcome === 'accepted') toast('App instalada correctamente', 'ok');
      _installPrompt = null;
    });
    closeAvatarMenu();
  }

  // ── Avatar dropdown (fixed, fuera del sidebar) ───────────────
  // ── SVG traveling border + dot en sidebar avatar ─────────
  function _initAvatarTrigSvg() {
    const outer   = document.getElementById('avatarTrigOuter');
    const svg     = document.getElementById('avatarTrigSvg');
    const bRect   = document.getElementById('avatarTrigBorderRect');
    const bBase   = document.getElementById('avatarTrigBaseRect');
    const dotPath = document.getElementById('avatarTrigRectPath');
    if (!outer || !svg || !bRect || !dotPath) return;

    const W = outer.offsetWidth;
    const H = outer.offsetHeight;
    if (!W || !H) return;

    const pad = 3, rx = 11;
    const svgW = W + pad * 2, svgH = H + pad * 2;
    svg.setAttribute('viewBox', `0 0 ${svgW} ${svgH}`);

    // Rect coords (button area offset by pad)
    [bRect, bBase].forEach(el => {
      el.setAttribute('x',      pad);
      el.setAttribute('y',      pad);
      el.setAttribute('width',  W);
      el.setAttribute('height', H);
      el.setAttribute('rx',     rx);
      el.setAttribute('ry',     rx);
    });

    // Perimeter → dasharray para segmento viajero
    const perim = Math.round(2 * (W + H) - 8 * rx + 2 * Math.PI * rx);
    const seg   = 72;
    bRect.style.strokeDasharray  = `${seg} ${perim - seg}`;
    bRect.style.strokeDashoffset = '0';

    // Inyectar keyframe con perimeter correcto
    const kfId = 'mos-trig-kf';
    let kfEl = document.getElementById(kfId);
    if (!kfEl) { kfEl = document.createElement('style'); kfEl.id = kfId; document.head.appendChild(kfEl); }
    kfEl.textContent = `@keyframes travelBorder{from{stroke-dashoffset:0}to{stroke-dashoffset:${-perim}}}`;
    bRect.style.animation = 'travelBorder 3s linear infinite';

    // Path para el punto verde (sigue el mismo rectángulo)
    const x = pad, y = pad;
    const d = `M ${x+rx} ${y} L ${x+W-rx} ${y} Q ${x+W} ${y} ${x+W} ${y+rx} ` +
              `L ${x+W} ${y+H-rx} Q ${x+W} ${y+H} ${x+W-rx} ${y+H} ` +
              `L ${x+rx} ${y+H} Q ${x} ${y+H} ${x} ${y+H-rx} ` +
              `L ${x} ${y+rx} Q ${x} ${y} ${x+rx} ${y} Z`;
    dotPath.setAttribute('d', d);
  }

  // Re-calcula al cambiar ancho del sidebar (hover tablet)
  (function _watchSidebarResize() {
    const sidebar = document.getElementById('sidebar');
    if (!sidebar || typeof ResizeObserver === 'undefined') return;
    let _trig;
    new ResizeObserver(() => {
      clearTimeout(_trig);
      _trig = setTimeout(_initAvatarTrigSvg, 60);
    }).observe(sidebar);
  })();

  function toggleAvatarMenu() {
    const menu = $('avatarMenu');
    if (!menu) return;
    if (!menu.classList.contains('hidden')) {
      menu.classList.add('hidden');
      return;
    }
    // Buscar trigger visible: sidebar en desktop, botón mobile en móvil
    let trigger = document.querySelector('.avatar-trigger');
    if (!trigger || trigger.getBoundingClientRect().width === 0) {
      trigger = $('avatarMobBtn') || $('sessionAvatarMob');
    }
    if (trigger) {
      const rect   = trigger.getBoundingClientRect();
      const menuW  = 205;
      const midY   = window.innerHeight / 2;
      menu.style.top    = '0px'; // temporal para medir
      menu.style.left   = '0px';
      menu.style.right  = 'auto';
      menu.style.bottom = 'auto';
      menu.classList.remove('hidden');
      const menuH = menu.offsetHeight;
      if (rect.top < midY) {
        // trigger en mitad superior (header mobile) → abre DEBAJO alineado a la DERECHA del botón
        const rightOffset = window.innerWidth - rect.right;
        menu.style.right = Math.max(8, rightOffset) + 'px';
        menu.style.left  = 'auto';
        menu.style.top   = (rect.bottom + 8) + 'px';
      } else {
        // trigger en mitad inferior (sidebar) → abre ENCIMA alineado a la IZQUIERDA
        menu.style.left  = Math.max(8, rect.left) + 'px';
        menu.style.right = 'auto';
        menu.style.top   = Math.max(8, rect.top - menuH - 8) + 'px';
      }
    } else {
      menu.classList.remove('hidden');
    }
    setTimeout(() => document.addEventListener('click', _closeAvatarOnOutside, { once: true }), 0);
  }
  function closeAvatarMenu() {
    const menu = $('avatarMenu');
    if (menu) menu.classList.add('hidden');
  }
  function _closeAvatarOnOutside(e) {
    const menu = $('avatarMenu');
    const wrap = $('avatarWrap');
    const mobTrigger = $('sessionAvatarMob');
    if (menu && !menu.contains(e.target) &&
        (!wrap || !wrap.contains(e.target)) &&
        (!mobTrigger || !mobTrigger.contains(e.target))) {
      closeAvatarMenu();
    }
  }

  async function _loadFinanzas() {
    const inp = $('finFecha');
    if (inp && !inp.value) inp.value = today();
    // Si ya hay datos precargados, renderizar inmediatamente sin fetch extra
    if (_finPL) {
      const fecha = inp?.value || today();
      _finRender(_finPL, fecha);
      const hasta  = fecha;
      const desde7 = _fechaOffset(fecha, -6);
      try {
        const rango = await API.get('getFinanzasRango', { desde: desde7, hasta });
        _finRender7d(rango);
      } catch(_) {}
      return;
    }
    await finCargar();
  }

  // ── Sync / Update ────────────────────────────────────────────
  function syncApp()           { if (window._SWControl) window._SWControl.sync(); }
  function applyPendingUpdate(){ if (window._SWControl) window._SWControl.applyPending(); }

  // ════════════════════════════════════════════════════════════
  // MÓDULO FINANZAS
  // ════════════════════════════════════════════════════════════
  let _finPL = null;  // último P&L cargado
  let _finanzasRefreshTimer = null;

  function _startFinanzasRefresh() {
    _stopFinanzasRefresh();
    _finanzasRefreshSilencioso(); // fetch inmediato al autenticar
    _finanzasRefreshTimer = setInterval(_finanzasRefreshSilencioso, 60000);
  }
  function _stopFinanzasRefresh() {
    if (_finanzasRefreshTimer) { clearInterval(_finanzasRefreshTimer); _finanzasRefreshTimer = null; }
  }
  async function _finanzasRefreshSilencioso() {
    try {
      const fecha  = $('finFecha')?.value || today();
      const pl     = await API.get('getFinanzasDia', { fecha });
      _finPL = pl;
      if (S.view === 'finanzas') {
        _finRender(pl, fecha);
        const hasta  = fecha;
        const desde7 = _fechaOffset(fecha, -6);
        const rango  = await API.get('getFinanzasRango', { desde: desde7, hasta });
        _finRender7d(rango);
      }
    } catch(_) { /* silencioso */ }
  }

  async function finCargar() {
    const fecha = $('finFecha')?.value || today();
    try {
      _finPL = await API.get('getFinanzasDia', { fecha });
      _finRender(_finPL, fecha);
      // Cargar tendencia 7 días en paralelo
      const hasta  = fecha;
      const desde7 = _fechaOffset(fecha, -6);
      const rango  = await API.get('getFinanzasRango', { desde: desde7, hasta });
      _finRender7d(rango);
    } catch(e) {
      toast('Error Finanzas: ' + e.message, 'error');
    }
  }

  function finDia(delta) {
    const inp = $('finFecha');
    if (!inp) return;
    const d = new Date(inp.value + 'T00:00:00');
    d.setDate(d.getDate() + delta);
    inp.value = d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
    finCargar();
  }

  function _finRender(pl, fecha) {
    const fmt  = v => 'S/ ' + parseFloat(v || 0).toFixed(2);
    const pct  = v => parseFloat(v || 0).toFixed(1) + '%';

    // KPI cards
    _setText('finKpiVentas',  fmt(pl.ventasNetas));
    _setText('finKpiTickets', pl.tickets + ' ticket' + (pl.tickets !== 1 ? 's' : '') +
             (pl.anulados ? ' · ' + pl.anulados + ' anulado' + (pl.anulados > 1 ? 's' : '') : ''));
    _setText('finKpiCosto',   fmt(pl.costoVentas));
    _setText('finKpiMargenB', 'Margen bruto ' + pct(pl.margenBrutoPct));
    _setText('finKpiGastos',  fmt(pl.totalGastos));
    _setText('finKpiPersonas', pl.personas + ' persona' + (pl.personas !== 1 ? 's' : ''));
    _setText('finKpiUtil',    fmt(pl.utilidadNeta));
    _setText('finKpiMargenN', 'Margen neto ' + pct(pl.margenNetoPct));

    // Color de la card de utilidad
    const card = $('finKpiUtilCard');
    if (card) {
      card.className = 'fin-card ' + (pl.utilidadNeta >= 0 ? 'fin-card-indigo' : 'fin-card-red');
      const v = $('finKpiUtil');
      if (v) v.style.color = pl.utilidadNeta >= 0 ? '#a5b4fc' : '#f87171';
    }

    // KPI Productos vendidos
    _setText('finKpiUnidades',   pl.unidadesVendidas ?? '—');
    _setText('finKpiSkus',       pl.skusDistintos    ?? '—');
    _setText('finKpiTicketProm', pl.ticketPromedio   ? 'S/ ' + parseFloat(pl.ticketPromedio).toFixed(2) : '—');

    // ⚠ inline junto a "Productos Vendidos" si hay SKUs sin costo
    const sinCostoIcon = $('finSinCostoAlerta');
    if (sinCostoIcon) sinCostoIcon.classList.toggle('hidden', !(pl.productosSinCosto?.length));

    // Break-even
    _setText('finBEMeta',       pl.breakEvenVentas ? 'Meta: ' + fmt(pl.breakEvenVentas) : 'Sin datos');
    _setText('finBEVentas',     'Ventas: ' + fmt(pl.ventasNetas));
    _setText('finBECostosFijos', fmt(pl.costosFijos));
    _setText('finBEMargenC',    pct(pl.margenContribPct));
    const badge = $('finBEBadge');
    if (badge) {
      badge.textContent    = pl.superaBreakEven ? '✅ Alcanzado' : '⏳ Pendiente';
      badge.className      = 'text-xs font-bold px-2 py-0.5 rounded-full ' +
        (pl.superaBreakEven ? 'bg-emerald-900 text-emerald-300' : 'bg-slate-800 text-slate-400');
    }
    const barV = $('finBEBarVentas');
    const linBE = $('finBELinea');
    if (barV) barV.style.width = Math.min(pl.breakEvenPct || 0, 100) + '%';
    if (linBE && pl.breakEvenVentas && pl.ventasNetas) {
      const bePct = Math.min(pl.breakEvenVentas / Math.max(pl.ventasNetas, pl.breakEvenVentas) * 100, 100);
      linBE.style.left = bePct.toFixed(1) + '%';
    }

    // Waterfall chart
    _finRenderWaterfall(pl);

    // Personal list
    _finRenderPersonal(pl, fecha);

    // Gastos list
    _finRenderGastos(pl, fecha);
  }

  function _finRenderWaterfall(pl) {
    const labels = ['Ventas', 'Costo V.', 'Util. Bruta', 'Personal', 'Gastos', 'Util. Neta'];
    // Floating bars [min, max]
    const utilBruta = pl.utilidadBruta;
    const utilNeta  = pl.utilidadNeta;
    const gastosOtros = pl.gastoOtros;
    const gastoPer  = pl.gastoPersonal;

    const data = [
      [0, pl.ventasNetas],                               // Ventas
      [utilBruta, pl.ventasNetas],                        // Costo V. (baja desde ventas)
      [0, utilBruta],                                     // Util Bruta (resultado)
      [utilBruta - gastoPer, utilBruta],                  // Personal (baja)
      [utilBruta - gastoPer - gastosOtros, utilBruta - gastoPer], // Gastos (baja)
      [0, utilNeta]                                       // Util Neta (resultado final)
    ];
    const colors = [
      '#10b981','#f87171','#34d399','#f59e0b','#fb923c',
      utilNeta >= 0 ? '#818cf8' : '#f87171'
    ];

    renderChart('finChartWaterfall', {
      type: 'bar',
      data: {
        labels,
        datasets: [{ data, backgroundColor: colors, borderRadius: 5, borderSkipped: false }]
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: false },
          tooltip: {
            callbacks: {
              label: ctx => {
                const [min, max] = ctx.raw;
                return 'S/ ' + Math.abs(max - min).toFixed(2);
              }
            }
          }
        },
        scales: {
          x: { grid: { color: '#1e293b' }, ticks: { color: '#64748b', font: { size: 11 } } },
          y: { grid: { color: '#1e293b' }, ticks: { color: '#64748b',
               callback: v => 'S/' + v.toFixed(0) } }
        }
      }
    });
  }

  function _finRender7d(rango) {
    if (!rango || !rango.serie) return;
    const labels = rango.serie.map(d => {
      const dt = new Date(d.fecha + 'T00:00:00');
      return dt.toLocaleDateString('es-PE', { weekday:'short', day:'numeric' });
    });
    const ventas  = rango.serie.map(d => d.ventasNetas);
    const costos  = rango.serie.map(d => d.costoVentas);
    const gastos  = rango.serie.map(d => d.totalGastos);
    const util    = rango.serie.map(d => d.utilidadNeta);

    const totalUtil = rango.totales?.utilidadNeta || 0;
    _setText('fin7dTotal', (totalUtil >= 0 ? '+' : '') + 'S/ ' + totalUtil.toFixed(2) + ' neto');

    renderChart('finChart7d', {
      type: 'bar',
      data: {
        labels,
        datasets: [
          { label: 'Ventas',    data: ventas, backgroundColor: 'rgba(16,185,129,.5)',  borderRadius: 4 },
          { label: 'Costo V.',  data: costos, backgroundColor: 'rgba(248,113,113,.5)', borderRadius: 4 },
          { label: 'Gastos',    data: gastos, backgroundColor: 'rgba(245,158,11,.5)',  borderRadius: 4 },
          { label: 'Util.Neta', data: util,   backgroundColor: 'rgba(129,140,248,.85)',borderRadius: 4, type: 'line', tension: 0.35, pointRadius: 4, fill: false }
        ]
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { labels: { color: '#64748b', boxWidth: 10, font: { size: 11 } } } },
        scales: {
          x: { stacked: false, grid: { color: '#1e293b' }, ticks: { color: '#64748b', font: { size: 10 } } },
          y: { grid: { color: '#1e293b' }, ticks: { color: '#64748b', callback: v => 'S/'+v } }
        }
      }
    });
  }

  function _finRenderPersonal(pl, fecha) {
    const cont = $('finPersonalList');
    const tot  = $('finPersonalTotal');
    if (!cont) return;
    if (tot) tot.textContent = 'S/ ' + (pl.gastoPersonal || 0).toFixed(2);
    if (!pl.personalDetalle || !pl.personalDetalle.length) {
      cont.innerHTML = '<p class="text-slate-500 text-xs">Sin registros — usa "+ Jornada" o "⬇ Cajas"</p>';
      return;
    }
    cont.innerHTML = pl.personalDetalle.map(p => `
      <div class="fin-row">
        <div class="flex items-center gap-2">
          <div class="w-7 h-7 rounded-full bg-indigo-900 text-indigo-300 flex items-center justify-center text-xs font-bold">${(p.nombre||'?')[0].toUpperCase()}</div>
          <div>
            <div class="text-slate-200 font-medium text-sm">${p.nombre}</div>
            <div class="text-xs text-slate-500">${p.rol || '—'} ${p.zona ? '· ' + p.zona : ''} ${p.fuente === 'AUTO_CAJAS' ? '<span class="fin-tag fin-tag-green ml-1">auto</span>' : ''}</div>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-emerald-400 font-semibold text-sm">S/ ${parseFloat(p.monto||0).toFixed(2)}</span>
          <button class="fin-del" onclick="MOS.finEliminarJornada('${p.idJornada || ''}','${fecha}')" title="Eliminar">×</button>
        </div>
      </div>`).join('');
  }

  function _finRenderGastos(pl, fecha) {
    const listEl  = $('finGastosList');
    const categEl = $('finGastosCateg');
    const totEl   = $('finGastosTotal');
    if (!listEl) return;
    if (totEl) totEl.textContent = 'S/ ' + (pl.gastoOtros || 0).toFixed(2);

    // Por categoría
    if (categEl) {
      const cats = pl.gastosByCategoria || {};
      const keys = Object.keys(cats);
      categEl.innerHTML = keys.length ? keys.map(cat => `
        <div class="flex justify-between text-xs">
          <span class="text-slate-400">${cat}</span>
          <span class="text-slate-200 font-semibold">S/ ${cats[cat].toFixed(2)}</span>
        </div>`).join('') : '';
    }

    if (!pl.gastosDetalle || !pl.gastosDetalle.length) {
      listEl.innerHTML = '<p class="text-slate-500 text-xs">Sin gastos registrados</p>';
      return;
    }
    const tagColor = t => t === 'FIJO' ? 'fin-tag-amber' : 'fin-tag-green';
    listEl.innerHTML = '<div class="border-t border-slate-800 pt-2 mt-1">' +
      pl.gastosDetalle.map(g => `
        <div class="fin-row">
          <div>
            <div class="text-slate-200 text-sm">${g.descripcion || '—'}</div>
            <div class="text-xs text-slate-500">${g.categoria || ''} <span class="fin-tag ${tagColor(g.tipo)} ml-1">${g.tipo||'VAR'}</span> ${g.comprobante ? '· ' + g.comprobante : ''}</div>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <span class="text-amber-400 font-semibold text-sm">S/ ${parseFloat(g.monto||0).toFixed(2)}</span>
            <button class="fin-del" onclick="MOS.finEliminarGasto('${g.idGasto || ''}','${fecha}')" title="Eliminar">×</button>
          </div>
        </div>`).join('') +
      '</div>';
  }

  // ── Modales ──────────────────────────────────────────────────
  function finAbrirModalGasto() {
    const f = $('finFecha')?.value || today();
    const inp = $('finGastoFecha'); if (inp) inp.value = f;
    const m = $('modalFinGasto'); if (m) { m.classList.remove('hidden'); m.classList.add('open'); }
  }

  function finAbrirModalJornada() {
    const f = $('finFecha')?.value || today();
    const inp = $('finJorFecha'); if (inp) inp.value = f;
    const m = $('modalFinJornada'); if (m) { m.classList.remove('hidden'); m.classList.add('open'); }
  }

  function cerrarModalFin(id) {
    const m = $(id); if (m) { m.classList.add('hidden'); m.classList.remove('open'); }
  }

  async function finGuardarGasto() {
    const monto = parseFloat($('finGastoMonto')?.value);
    const desc  = $('finGastoDesc')?.value?.trim();
    const categ = $('finGastoCateg')?.value;
    const tipo  = $('finGastoTipo')?.value;
    const fecha = $('finGastoFecha')?.value;
    const comp  = $('finGastoComp')?.value?.trim();
    if (!monto || monto <= 0) { toast('Ingresa un monto válido', 'error'); return; }
    if (!desc)               { toast('Ingresa una descripción', 'error'); return; }
    try {
      await API.post('registrarGasto', {
        fecha, categoria: categ, tipo, descripcion: desc,
        monto, comprobante: comp, registradoPor: S.session?.nombre || ''
      });
      cerrarModalFin('modalFinGasto');
      toast('Gasto registrado', 'ok');
      finCargar();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  async function finGuardarJornada() {
    const nombre = $('finJorNombre')?.value?.trim();
    const monto  = parseFloat($('finJorMonto')?.value);
    const fecha  = $('finJorFecha')?.value;
    const rol    = $('finJorRol')?.value?.trim();
    const zona   = $('finJorZona')?.value?.trim();
    const obs    = $('finJorObs')?.value?.trim();
    if (!nombre)             { toast('Ingresa el nombre del trabajador', 'error'); return; }
    if (!monto || monto <= 0){ toast('Ingresa un jornal válido', 'error'); return; }
    try {
      await API.post('registrarJornada', {
        fecha, nombre, rol, zona, montoJornal: monto, observacion: obs,
        appOrigen: 'MOS', registradoPor: S.session?.nombre || ''
      });
      cerrarModalFin('modalFinJornada');
      toast('Jornada registrada', 'ok');
      finCargar();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  async function finEliminarGasto(idGasto, fecha) {
    if (!idGasto || !confirm('¿Eliminar este gasto?')) return;
    try {
      await API.post('eliminarGasto', { idGasto });
      toast('Gasto eliminado', 'ok');
      finCargar();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  async function finEliminarJornada(idJornada, fecha) {
    if (!idJornada || !confirm('¿Eliminar esta jornada?')) return;
    try {
      await API.post('eliminarJornada', { idJornada });
      toast('Jornada eliminada', 'ok');
      finCargar();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  async function finImportarCajas() {
    const fecha = $('finFecha')?.value || today();
    try {
      const res = await API.post('importarJornadasDesdeCajas', {
        fecha, montoDefault: 0, registradoPor: S.session?.nombre || ''
      });
      toast(res.importados > 0
        ? res.importados + ' jornada(s) importada(s) desde cajas'
        : 'Sin cajas nuevas para importar este día', 'ok');
      if (res.importados > 0) finCargar();
    } catch(e) { toast('Error importando cajas: ' + e.message, 'error'); }
  }

  // ── Editor de costo inline (desde alerta sin costo) ─────────
  let _finEditSku = null;

  function finEditarCostoSku(sku) {
    _finEditSku = sku;
    _setText('finCostoEditorSku', sku);
    const inp = $('finCostoEditorInput');
    if (inp) { inp.value = ''; }
    $('finCostoEditorWrap')?.classList.remove('hidden');
    inp?.focus();
  }

  function finCerrarCostoEditor() {
    _finEditSku = null;
    $('finCostoEditorWrap')?.classList.add('hidden');
  }

  async function finGuardarCostoSku() {
    if (!_finEditSku) return;
    const costo = parseFloat($('finCostoEditorInput')?.value);
    if (!costo || costo <= 0) { toast('Ingresa un costo válido', 'error'); return; }
    try {
      await API.post('actualizarCostoPorSku', { sku: _finEditSku, precioCosto: costo });
      finCerrarCostoEditor();
      toast('Costo actualizado', 'ok');
      finCargar();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  // ── Modal Productos Vendidos ─────────────────────────────────
  let _finProdFiltroSinCosto = false;
  let _finProdEditSku = null;

  function finAbrirModalProductos() {
    const m = $('finModalProductos');
    if (!m) return;
    m.classList.remove('hidden'); m.classList.add('open');
    _finProdFiltroSinCosto = false;
    _finRenderProductos();
  }

  function finToggleFiltroSinCosto() {
    _finProdFiltroSinCosto = !_finProdFiltroSinCosto;
    const btn = $('finProdBtnSinCosto');
    if (btn) {
      btn.classList.toggle('bg-amber-900/40', _finProdFiltroSinCosto);
      btn.classList.toggle('text-amber-200', _finProdFiltroSinCosto);
    }
    _finRenderProductos();
  }

  function _finRenderProductos() {
    const pl = _finPL;
    if (!pl) return;
    const fmtM = v => 'S/ ' + parseFloat(v || 0).toFixed(2);
    const todos = pl.detalleProductos || [];
    const haySinCosto = todos.some(p => p.sinCosto);
    const btn = $('finProdBtnSinCosto');
    if (btn) btn.classList.toggle('hidden', !haySinCosto);
    const lista = _finProdFiltroSinCosto ? todos.filter(p => p.sinCosto) : todos;
    const conteo = $('finProdConteo');
    if (conteo) conteo.textContent = lista.length + ' de ' + todos.length + ' SKUs';
    const tbody = $('finProdTableBody');
    if (!tbody) return;
    tbody.innerHTML = lista.map(p => {
      const alertBadge = p.sinCosto
        ? `<span class="text-amber-400 font-bold" title="Sin costo">⚠</span>` : '';
      const costoUnitStr = p.sinCosto
        ? `<span class="text-amber-400/60">—</span>` : fmtM(p.costoUnit);
      const costoTotalStr = p.sinCosto
        ? `<span class="text-amber-400/60">—</span>` : fmtM(p.costoTotal);
      const editBtn = p.sinCosto
        ? `<button onclick="MOS.finEditarCostoProd('${p.sku}')" class="text-amber-400 hover:text-amber-200 px-1" title="Asignar costo">✎</button>`
        : `<button onclick="MOS.finEditarCostoProd('${p.sku}')" class="text-slate-600 hover:text-slate-300 px-1" title="Editar costo">✎</button>`;
      return `<tr class="hover:bg-slate-800/30 transition-colors">
        <td class="px-3 py-2">
          <div class="flex items-start gap-1.5">
            ${alertBadge}
            <div>
              <div class="text-slate-200 text-xs leading-snug">${p.nombre || p.sku}</div>
              <div class="font-mono text-slate-500 text-xs">${p.sku}</div>
            </div>
          </div>
        </td>
        <td class="px-2 py-2 text-right font-bold text-slate-200 whitespace-nowrap">${p.cantidad}</td>
        <td class="px-2 py-2 text-right text-slate-400 whitespace-nowrap hidden sm:table-cell">${fmtM(p.precio)}</td>
        <td class="px-2 py-2 text-right whitespace-nowrap hidden sm:table-cell">${costoUnitStr}</td>
        <td class="px-2 py-2 text-right whitespace-nowrap">${costoTotalStr}</td>
        <td class="px-1 py-2">${editBtn}</td>
      </tr>`;
    }).join('') || '<tr><td colspan="6" class="px-4 py-8 text-center text-slate-500">Sin datos</td></tr>';
  }

  function finEditarCostoProd(sku) {
    _finProdEditSku = sku;
    _setText('finProdCostoSku', sku);
    const inp = $('finProdCostoInput');
    if (inp) { inp.value = ''; inp.focus(); }
    $('finProdCostoWrap')?.classList.remove('hidden');
  }
  function finCerrarCostoProd() {
    _finProdEditSku = null;
    $('finProdCostoWrap')?.classList.add('hidden');
  }
  async function finGuardarCostoProd() {
    if (!_finProdEditSku) return;
    const costo = parseFloat($('finProdCostoInput')?.value);
    if (!costo || costo <= 0) { toast('Ingresa un costo válido', 'error'); return; }
    try {
      await API.post('actualizarCostoPorSku', { sku: _finProdEditSku, precioCosto: costo });
      finCerrarCostoProd();
      toast('Costo actualizado', 'ok');
      await finCargar(); // refresca _finPL
      _finRenderProductos();
    } catch(e) { toast('Error: ' + e.message, 'error'); }
  }

  // ── Modal Tickets del Día ─────────────────────────────────────
  let _finTicketFiltro = 'todos';

  const _FIN_FILTROS = [
    { key: 'todos',   label: 'Todos' },
    { key: 'boleta',  label: 'Boleta' },
    { key: 'nota',    label: 'Nota' },
    { key: 'factura', label: 'Factura' },
    { key: 'credito', label: 'Crédito' },
    { key: 'efectivo',label: 'Efectivo' },
    { key: 'virtual', label: 'Virtual' },
    { key: 'anulado', label: 'Anulado' },
  ];

  function finAbrirModalTickets() {
    const m = $('finModalTickets');
    if (!m) return;
    m.classList.remove('hidden'); m.classList.add('open');
    _finTicketFiltro = 'todos';
    _finRenderFiltrosBtns();
    _finRenderTickets();
  }

  function finSetTicketFiltro(key) {
    _finTicketFiltro = key;
    _finRenderFiltrosBtns();
    _finRenderTickets();
  }

  function _finRenderFiltrosBtns() {
    const wrap = $('finTicketFiltros');
    if (!wrap) return;
    wrap.innerHTML = _FIN_FILTROS.map(f => {
      const active = f.key === _finTicketFiltro;
      const cls = active
        ? 'text-xs px-2.5 py-1 rounded-full bg-indigo-600 text-white font-semibold'
        : 'text-xs px-2.5 py-1 rounded-full bg-slate-800 text-slate-400 hover:text-slate-200 hover:bg-slate-700';
      return `<button onclick="MOS.finSetTicketFiltro('${f.key}')" class="${cls} transition-colors">${f.label}</button>`;
    }).join('');
  }

  function _finApplyTicketFiltro(tickets) {
    const f = _finTicketFiltro;
    if (f === 'todos')    return tickets;
    if (f === 'boleta')   return tickets.filter(t => t.tipoDoc === 'BOLETA');
    if (f === 'nota')     return tickets.filter(t => t.tipoDoc === 'NOTA_DE_VENTA');
    if (f === 'factura')  return tickets.filter(t => t.tipoDoc === 'FACTURA');
    if (f === 'credito')  return tickets.filter(t => t.formaPago === 'POR_COBRAR');
    if (f === 'efectivo') return tickets.filter(t => t.formaPago === 'EFECTIVO' && t.estado !== 'ANULADO');
    if (f === 'virtual')  return tickets.filter(t =>
      t.formaPago !== 'EFECTIVO' && !t.formaPago.startsWith('MIXTO') && t.formaPago !== 'POR_COBRAR' && t.estado !== 'ANULADO');
    if (f === 'anulado')  return tickets.filter(t => t.estado === 'ANULADO');
    return tickets;
  }

  function _finRenderTickets() {
    const pl = _finPL;
    if (!pl) return;
    const fmtM = v => 'S/ ' + parseFloat(v || 0).toFixed(2);
    const todos = pl.detalleTickets || [];
    const lista = _finApplyTicketFiltro(todos);
    const totalFiltrado = lista.reduce((s, t) => s + (t.estado === 'ANULADO' ? 0 : t.total), 0);
    const conteo = $('finTicketConteo');
    if (conteo) conteo.textContent = lista.length + ' ticket' + (lista.length !== 1 ? 's' : '') +
      (lista.length < todos.length ? ' · Total: ' + fmtM(totalFiltrado) : '');
    const list = $('finTicketList');
    if (!list) return;

    const docLabel = { 'BOLETA': 'Boleta', 'NOTA_DE_VENTA': 'Nota', 'FACTURA': 'Factura' };
    const metodoLabel = m => {
      if (m === 'EFECTIVO')    return { txt: 'Efectivo', cls: 'text-emerald-400' };
      if (m === 'POR_COBRAR')  return { txt: 'Crédito',  cls: 'text-amber-400' };
      if (m.startsWith('MIXTO')) return { txt: 'Mixto',  cls: 'text-blue-400' };
      return { txt: m, cls: 'text-purple-400' };
    };

    list.innerHTML = lista.map(t => {
      const anulado = t.estado === 'ANULADO';
      const met = metodoLabel(t.formaPago);
      const corrLabel = t.correlativo || t.idVenta.split('-').pop() || '—';
      return `<div class="flex items-center justify-between px-4 py-3 ${anulado ? 'opacity-50' : 'hover:bg-slate-800/30'} transition-colors">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <span class="text-slate-200 text-xs font-semibold">${corrLabel}</span>
            <span class="text-slate-500 text-xs">${docLabel[t.tipoDoc] || t.tipoDoc}</span>
            ${anulado ? '<span class="text-xs bg-red-900/40 text-red-400 px-1.5 py-0.5 rounded">ANULADO</span>' : ''}
          </div>
          <div class="flex items-center gap-2 mt-0.5 flex-wrap">
            <span class="text-slate-500">${t.hora || ''}</span>
            ${t.vendedor ? `<span class="text-slate-600">· ${t.vendedor}</span>` : ''}
            <span class="${met.cls}">${met.txt}</span>
          </div>
        </div>
        <div class="text-right pl-3">
          <div class="font-bold ${anulado ? 'line-through text-slate-600' : 'text-slate-200'}">${fmtM(t.total)}</div>
        </div>
      </div>`;
    }).join('') || '<div class="px-4 py-8 text-center text-slate-500">Sin tickets</div>';
  }

  // Helpers
  function _setText(id, val) { const el = $(id); if (el) el.textContent = val; }
  function _fechaOffset(fechaStr, dias) {
    const d = new Date(fechaStr + 'T00:00:00');
    d.setDate(d.getDate() + dias);
    return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
  }

  // ── Push Notifications (FCM) ─────────────────────────────────
  const _PUSH_VAPID = 'BB_Nhb8wPlFpObGxR93tzRfWw7VncQsJoyJYe6wv8r5yqcrhA53LEM9wPkvhtG19LmMEl30VaBFCPIClBBPKQgo';
  const _PUSH_CONFIG = {
    apiKey:            'AIzaSyA_gfynRxAmlbGgHWoioaj5aeaxnnywP88',
    projectId:         'proyectomos-push',
    messagingSenderId: '328735199478',
    appId:             '1:328735199478:web:947f338ae9716a7c049cd7'
  };

  let _pushMsgHandlerSet = false;

  async function _pushInit(nombre, rol, askPermission = false) {
    console.log('[Push] init — firebase:', !!window.firebase, '| Notification:', typeof Notification !== 'undefined' ? Notification.permission : 'N/A', '| ask:', askPermission);
    if (!window.firebase || !('Notification' in window) || !('serviceWorker' in navigator)) {
      console.warn('[Push] requisitos no cumplidos, saliendo');
      return;
    }

    if (!firebase.apps.length) firebase.initializeApp(_PUSH_CONFIG);
    const messaging = firebase.messaging();

    // Handler de primer plano — registrar UNA sola vez, independiente de si getToken falla
    if (!_pushMsgHandlerSet) {
      _pushMsgHandlerSet = true;
      messaging.onMessage(async payload => {
        const t = payload.notification?.title || '';
        const b = payload.notification?.body  || '';
        toast('🔔 ' + t + (b ? ': ' + b : ''), 'ok', 8000);
        // Mostrar también como notificación del sistema (visible aunque la app esté al frente)
        try {
          const reg = await navigator.serviceWorker.ready;
          reg.showNotification(t, {
            body: b,
            icon:  'https://levo19.github.io/MOS/icon-192.png',
            badge: 'https://levo19.github.io/MOS/icon-192.png',
            vibrate: [200, 100, 200],
            tag: 'mos-push'
          });
        } catch(_) {}
      });
    }

    try {
      const permission = askPermission
        ? await Notification.requestPermission()
        : Notification.permission;
      console.log('[Push] permission:', permission);
      if (permission !== 'granted') return;

      const swReg = await navigator.serviceWorker.ready;
      console.log('[Push] SW activo:', swReg.active?.scriptURL);
      const token = await messaging.getToken({ vapidKey: _PUSH_VAPID, serviceWorkerRegistration: swReg });
      console.log('[Push] token obtenido:', token ? token.substring(0,20)+'...' : 'null');
      if (!token) return;

      // Guardar token en GAS
      API.post('registrarPushToken', {
        token, usuario: nombre, appOrigen: 'MOS',
        dispositivo: navigator.userAgent.substring(0, 150)
      }).catch(() => {});

      // Notificar ingreso a todos los demás
      const hora = new Date().toLocaleTimeString('es-PE', { hour: '2-digit', minute: '2-digit' });
      API.post('enviarPushNotif', {
        titulo: '👤 ' + nombre + ' ingresó a MOS',
        cuerpo: (rol || '') + ' · ' + hora
      }).catch(() => {});

      console.log('[Push] token registrado en GAS ✅');
    } catch(e) {
      console.error('[Push] ERROR:', e.message);
      // No mostrar toast de error en session restore (solo en acción del usuario)
      if (askPermission) toast('Push error: ' + e.message, 'error');
    }
  }

  // ============================================================
  // ── EVALUACIÓN DE PERSONAL ────────────────────────────────────
  // ============================================================
  const _evalState = {
    appFilter: 'all',
    resumenes: [],
    fecha: today(),
    auditChecks: {},
    rolItems: {
      CAJERO: [
        'Atención al cliente cordial y rápida',
        'Sigue procedimiento de cobro',
        'Usa el sistema correctamente (sin manipular tickets)',
        'Maneja efectivo correctamente',
        'Cuadre de caja sin diferencias',
        'Estación limpia y ordenada',
        'Reporta incidencias y anomalías',
        'Uniforme y presentación adecuada',
        'Puntualidad de entrada/salida'
      ],
      VENDEDOR: [
        'Atención al cliente cordial y rápida',
        'Sigue procedimiento de cobro',
        'Usa el sistema correctamente (sin manipular tickets)',
        'Maneja efectivo correctamente',
        'Cuadre de caja sin diferencias',
        'Estación limpia y ordenada',
        'Reporta incidencias y anomalías',
        'Uniforme y presentación adecuada',
        'Puntualidad de entrada/salida'
      ],
      ALMACENERO: [
        'Productos con membretes correctos',
        'Stock organizado por zonas',
        'Productos en buen estado / sin deterioro',
        'Rotación FIFO respetada',
        'Equipos de seguridad usados',
        'Reporte de mermas / anomalías',
        'Estación limpia y ordenada',
        'Puntualidad de entrada/salida'
      ],
      ENVASADOR: [
        'Envasado uniforme (peso/volumen)',
        'Sellado correcto (sin fugas)',
        'Etiquetado completo (lote, fecha, código)',
        'Preservación e higiene de insumos',
        'Equipos de seguridad usados',
        'Limpieza tras cada envasado',
        'Reporte de mermas',
        'Puntualidad de entrada/salida'
      ]
    }
  };

  function _evalScoreClass(score) {
    if (score >= 85) return 'eval-score-high';
    if (score >= 60) return 'eval-score-mid';
    return 'eval-score-low';
  }

  function _evalRolBadgeClass(rol) {
    rol = String(rol || '').toUpperCase();
    if (rol === 'CAJERO' || rol === 'VENDEDOR') return 'badge-rol-cajero';
    if (rol === 'ALMACENERO')                    return 'badge-rol-almacen';
    if (rol === 'ENVASADOR')                     return 'badge-rol-envasador';
    return 'badge-rol-default';
  }

  async function loadEvaluacion() {
    const lbl = $('evalFechaLbl');
    if (lbl) lbl.textContent = 'Hoy ' + new Date(_evalState.fecha + 'T00:00:00').toLocaleDateString('es-PE', { day: '2-digit', month: 'long', year: 'numeric' });
    await refreshEvaluacion();
    _ensureLiqDefaults();
  }

  async function refreshEvaluacion() {
    const list = $('evalListPersonal');
    if (list) list.innerHTML = '<div class="skel h-24 rounded-xl"></div><div class="skel h-24 rounded-xl"></div><div class="skel h-24 rounded-xl"></div>';
    try {
      const res = await API.get('getResumenTodosDia', { fecha: _evalState.fecha });
      _evalState.resumenes = Array.isArray(res) ? res : [];
      _renderEvalLista();
      _renderLiqDropdown();
    } catch (e) {
      if (list) list.innerHTML = `<p class="text-sm text-red-400 text-center py-6">Error: ${e.message}</p>`;
    }
  }

  function evalSetApp(app) {
    _evalState.appFilter = app;
    document.querySelectorAll('#evalAppFilter .eval-pill').forEach(b => {
      b.classList.toggle('active', b.dataset.app === app);
    });
    _renderEvalLista();
  }

  function _renderEvalLista() {
    const list = $('evalListPersonal');
    if (!list) return;
    const filtered = _evalState.resumenes.filter(r =>
      _evalState.appFilter === 'all' || r.appOrigen === _evalState.appFilter
    );
    if (!filtered.length) {
      list.innerHTML = '<p class="text-sm text-slate-500 text-center py-8">No hay personal para mostrar.</p>';
      return;
    }
    // Ordenar por appOrigen y rol
    filtered.sort((a, b) => (a.appOrigen || '').localeCompare(b.appOrigen || '') || (a.rol || '').localeCompare(b.rol || ''));

    list.innerHTML = filtered.map(r => {
      const score = r.scoreFinal || 0;
      const scoreClass = _evalScoreClass(score);
      const rolClass = _evalRolBadgeClass(r.rol);
      const evalCount = r.evaluacionesCount || 0;
      const kpiTxt = _evalKpiSummary(r);
      const totalDia = (r.totalDia || r.montoBase || 0).toFixed(2);
      return `
        <div class="eval-card" data-id="${r.idPersonal}">
          <div class="flex items-center gap-3">
            <div class="eval-score-circle ${scoreClass}" style="--score:${score}">
              <span>${score}%</span>
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1 flex-wrap">
                <div class="font-semibold text-slate-100 text-sm truncate">${r.nombre}</div>
                <span class="badge-rol ${rolClass}">${r.rol || ''}</span>
                ${r.virtual ? '<span class="badge-rol badge-rol-default" title="Detectado de MosExpress (no en master)">⚡ del sistema</span>' : ''}
              </div>
              <div class="text-xs text-slate-500 mb-1">${kpiTxt}</div>
              <div class="flex items-center gap-2 flex-wrap">
                ${evalCount > 0
                  ? `<span class="audit-count-pill">${evalCount} auditoría${evalCount !== 1 ? 's' : ''} hoy</span>`
                  : `<span class="audit-count-pill" style="background:rgba(245,158,11,.12);color:#fbbf24;border-color:rgba(245,158,11,.3)">⚠ Sin auditar</span>`}
                <span class="text-xs text-slate-400">Pago día: <strong class="text-amber-400">S/${totalDia}</strong></span>
              </div>
            </div>
            <button onclick="MOS.abrirAuditar('${r.idPersonal}')" class="btn-primary text-xs whitespace-nowrap shrink-0">Auditar</button>
          </div>
        </div>`;
    }).join('');
  }

  function _evalKpiSummary(r) {
    const k = r.kpis || {};
    const rol = String(r.rol || '').toUpperCase();
    const auditTxt = `${k.auditoriasHechas || 0}/${k.metaAuditorias || 30} aud.`;
    if (rol === 'CAJERO' || rol === 'VENDEDOR') {
      return `Ventas S/${(k.ventasReales || 0).toFixed(2)} · ${auditTxt}`;
    }
    if (rol === 'ENVASADOR') {
      return `Envasados ${k.envasados || 0} uds · ${auditTxt}`;
    }
    if (rol === 'ALMACENERO') {
      return `${k.guias || 0} guías · ${auditTxt}`;
    }
    return auditTxt;
  }

  // ── Modal Auditar ────────────────────────────────────────────
  async function abrirAuditar(idPersonal) {
    const r = _evalState.resumenes.find(x => x.idPersonal === idPersonal);
    if (!r) { toast('Personal no encontrado', 'error'); return; }
    $('auditTitle').textContent = '🎯 Auditar · ' + r.nombre;
    const evalCount = r.evaluacionesCount || 0;
    $('auditSubtitle').textContent = evalCount > 0
      ? `${r.rol} · ${evalCount} auditoría${evalCount !== 1 ? 's' : ''} hoy · continuando...`
      : `${r.rol} · primera auditoría del día`;
    $('auditIdPersonal').value = r.idPersonal;
    $('auditRol').value = r.rol || '';
    $('auditComentario').value = '';

    // Pre-cargar acumulado del día (MAX/OR) para que el admin continúe, no empiece de cero
    const limpAcum = Math.round(((r.manual && r.manual.limpiezaPct) || 0) / 10) * 10;
    const limpProfAcum = Math.round(((r.manual && r.manual.limpiezaProfPct) || 0) / 10) * 10;
    $('auditLimpieza').value = String(limpAcum);
    $('auditLimpiezaProf').value = String(limpProfAcum);
    updateRateSlider('auditLimpieza', 'auditLimpiezaVal');
    updateRateSlider('auditLimpiezaProf', 'auditLimpiezaProfVal');

    // Pre-marcar checks ya cumplidos en evaluaciones previas
    _evalState.auditChecks = Object.assign({}, (r.manual && r.manual.checksAcum) || {});

    $('auditTogComision').classList.add('on');
    $('auditTogMeta').classList.add('on');
    _renderAuditKpis(r);
    _renderAuditChecklist(r.rol);
    openModal('modalAuditar');
  }

  // Actualiza visualmente el slider con el valor + track dorado proporcional
  function updateRateSlider(slId, valId) {
    const sl = $(slId);
    const lbl = $(valId);
    if (!sl) return;
    const v = parseFloat(sl.value) || 0;
    if (lbl) lbl.textContent = v + '%';
    // Track dorado proporcional (Webkit no soporta progress nativo)
    sl.style.background = `linear-gradient(90deg, #c9a227 0%, #ffd700 ${v}%, #1e293b ${v}%, #1e293b 100%)`;
  }

  function _renderAuditKpis(r) {
    const cont = $('auditKpis');
    if (!cont) return;
    const k = r.kpis || {};
    const rol = String(r.rol || '').toUpperCase();
    const auditMeta = k.metaAuditorias || 30;
    let rows = [];
    if (rol === 'CAJERO' || rol === 'VENDEDOR') {
      rows.push(_kpiRow('Ventas del día', `S/${(k.ventasReales || 0).toFixed(2)}`, k.ventasPct || 0));
    } else if (rol === 'ENVASADOR') {
      rows.push(_kpiRow('Unidades envasadas', `${k.envasados || 0}`, k.ventasPct || 0));
    } else if (rol === 'ALMACENERO') {
      rows.push(_kpiRow('Guías procesadas', `${k.guias || 0}`, k.ventasPct || 0));
    }
    rows.push(_kpiRow('Auditorías de productos', `${k.auditoriasHechas || 0}/${auditMeta}`, k.auditPct || 0));
    rows.push(_kpiRow('Score acumulado del día', `${r.scoreFinal || 0}%`, r.scoreFinal || 0));
    cont.innerHTML = rows.join('');
  }

  function _kpiRow(label, val, pct) {
    return `<div class="audit-kpi-row" style="flex-direction:column;align-items:stretch;gap:4px">
      <div class="flex items-center justify-between">
        <span class="audit-kpi-label">${label}</span>
        <span class="audit-kpi-val">${val}</span>
      </div>
      <div class="audit-kpi-bar"><div style="width:${Math.min(100, pct)}%"></div></div>
    </div>`;
  }

  function _renderAuditChecklist(rol) {
    const cont = $('auditControlList');
    if (!cont) return;
    const items = _evalState.rolItems[String(rol || '').toUpperCase()] || _evalState.rolItems.CAJERO;
    cont.innerHTML = items.map((txt, i) => {
      const key = 'c' + i;
      const checked = !!_evalState.auditChecks[key];
      return `
        <div class="audit-check-row${checked ? ' checked' : ''}" data-key="${key}" onclick="MOS.auditToggleCheck('${key}')">
          <div class="audit-check-box"></div>
          <span>${txt}</span>
        </div>`;
    }).join('');
  }

  function auditToggleCheck(key) {
    _evalState.auditChecks[key] = !_evalState.auditChecks[key];
    const row = document.querySelector(`#auditControlList .audit-check-row[data-key="${key}"]`);
    if (row) row.classList.toggle('checked', !!_evalState.auditChecks[key]);
  }

  function auditCheckAll() {
    document.querySelectorAll('#auditControlList .audit-check-row').forEach(row => {
      const k = row.dataset.key;
      _evalState.auditChecks[k] = true;
      row.classList.add('checked');
    });
  }

  function auditToggle(id) {
    const el = $(id);
    if (el) el.classList.toggle('on');
  }

  function cerrarAuditar() { closeModal('modalAuditar'); }

  async function guardarAuditoria() {
    const idPersonal = $('auditIdPersonal').value;
    const rol = $('auditRol').value;
    if (!idPersonal || !rol) { toast('Datos incompletos', 'error'); return; }

    // Construir checklist completo: incluye TRUE y FALSE para todos los items del rol
    const items = _evalState.rolItems[String(rol).toUpperCase()] || _evalState.rolItems.CAJERO;
    const checksFull = {};
    items.forEach((_, i) => {
      const k = 'c' + i;
      checksFull[k] = !!_evalState.auditChecks[k];
    });

    const params = {
      idPersonal,
      rol,
      fecha: _evalState.fecha,
      limpiezaPct: parseFloat($('auditLimpieza').value) || 0,
      limpiezaProfPct: parseFloat($('auditLimpiezaProf').value) || 0,
      controlChecks: JSON.stringify(checksFull),
      comentario: $('auditComentario').value || '',
      evaluadoPor: S.session?.nombre || '',
      aplicaComision: $('auditTogComision').classList.contains('on'),
      aplicaBonoMeta: $('auditTogMeta').classList.contains('on')
    };

    // PREDICTIVO: cerrar modal + toast inmediato; sync en background
    closeModal('modalAuditar');
    toast('Auditoría registrada ✓', 'ok');
    // Optimistic: update local state visualmente antes de confirmar servidor
    const r = _evalState.resumenes.find(x => x.idPersonal === idPersonal);
    if (r) {
      r.evaluacionesCount = (r.evaluacionesCount || 0) + 1;
      r.manual = r.manual || {};
      const newLimp = parseFloat(params.limpiezaPct) || 0;
      const newLimpProf = parseFloat(params.limpiezaProfPct) || 0;
      if (newLimp > (r.manual.limpiezaPct || 0))     r.manual.limpiezaPct = newLimp;
      if (newLimpProf > (r.manual.limpiezaProfPct || 0)) r.manual.limpiezaProfPct = newLimpProf;
      r.manual.checksAcum = Object.assign({}, r.manual.checksAcum || {});
      Object.keys(checksFull).forEach(k => { if (checksFull[k]) r.manual.checksAcum[k] = true; });
      _renderEvalLista();
    }

    try {
      await API.post('crearEvaluacion', params);
      // Pull fresh data del servidor (en bg) para reflejar score real con KPIs auto
      refreshEvaluacion().catch(() => {});
    } catch (e) {
      toast('Error al guardar: ' + e.message, 'error');
      refreshEvaluacion().catch(() => {});
    }
  }

  // ── Liquidación ──────────────────────────────────────────────
  function _renderLiqDropdown() {
    const sel = $('liqPersona');
    if (!sel) return;
    sel.innerHTML = '<option value="">— elegir persona —</option>'
      + _evalState.resumenes.map(r =>
          `<option value="${r.idPersonal}">${r.nombre} · ${r.rol}</option>`
        ).join('');
  }

  function _ensureLiqDefaults() {
    const inp = $('liqFechaInicio');
    if (inp && !inp.value) {
      // Default: lunes de la semana actual
      const d = new Date();
      const day = d.getDay() || 7; // domingo=7
      d.setDate(d.getDate() - day + 1);
      inp.value = d.toISOString().substring(0, 10);
    }
  }

  // ── Config de metas y bonos ──────────────────────────────────
  async function abrirConfigEval() {
    openModal('modalConfigEval');
    try {
      const res = await API.get('getConfig', {});
      const cfg = res || {};
      $('cfgMetaCajero').value     = cfg.evalMetaCajero     || 2000;
      $('cfgMetaEnvasador').value  = cfg.evalMetaEnvasador  || 500;
      $('cfgMetaAlmacenero').value = cfg.evalMetaAlmacenero || 15;
      $('cfgMetaAuditorias').value = cfg.evalMetaAuditorias || 30;
      $('cfgBonoMetaBase').value   = cfg.evalBonoMetaBase   || 8;
      $('cfgBonoMetaDoble').value  = cfg.evalBonoMetaDoble  || 15;
    } catch(e) {
      $('cfgMetaCajero').value = 2000;
      $('cfgMetaEnvasador').value = 500;
      $('cfgMetaAlmacenero').value = 15;
      $('cfgMetaAuditorias').value = 30;
      $('cfgBonoMetaBase').value = 8;
      $('cfgBonoMetaDoble').value = 15;
    }
  }

  async function guardarConfigEval() {
    const btn = $('cfgEvalSaveBtn');
    if (btn) { btn.disabled = true; btn.textContent = 'Guardando...'; }
    const pares = [
      ['evalMetaCajero',     $('cfgMetaCajero').value],
      ['evalMetaEnvasador',  $('cfgMetaEnvasador').value],
      ['evalMetaAlmacenero', $('cfgMetaAlmacenero').value],
      ['evalMetaAuditorias', $('cfgMetaAuditorias').value],
      ['evalBonoMetaBase',   $('cfgBonoMetaBase').value],
      ['evalBonoMetaDoble',  $('cfgBonoMetaDoble').value]
    ];
    try {
      await Promise.all(pares.map(([clave, valor]) =>
        API.post('setConfig', { clave, valor: String(valor || '') })
      ));
      toast('Configuración guardada ✓', 'ok');
      closeModal('modalConfigEval');
      refreshEvaluacion().catch(() => {});
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    } finally {
      if (btn) { btn.disabled = false; btn.textContent = 'Guardar'; }
    }
  }

  function abrirLiquidacion() {
    const id = $('liqPersona')?.value;
    const fechaInicio = $('liqFechaInicio')?.value;
    if (!id) { toast('Elige una persona', 'error'); return; }
    if (!fechaInicio) { toast('Elige fecha inicio (lunes)', 'error'); return; }
    const url = `liquidacion.html?id=${encodeURIComponent(id)}&inicio=${encodeURIComponent(fechaInicio)}`;
    window.open(url, '_blank');
  }

  // ============================================================
  // ── MODAL Producto-Proveedor (cotización) ─────────────────────
  // ============================================================
  const _ppState = { editando: null };

  async function abrirModalProvProducto(idPP) {
    console.log('[abrirModalProvProducto] idPP=', idPP, 'provSelId=', S.provSelId);
    const idProv = S.provSelId;
    if (!idProv) {
      toast('Selecciona primero un proveedor', 'error');
      console.warn('[abrirModalProvProducto] abortado: sin provSelId');
      return;
    }
    const elModal = $('modalProvProducto');
    if (!elModal) {
      toast('Modal no disponible — recarga la app', 'error');
      console.error('[abrirModalProvProducto] #modalProvProducto no existe en DOM');
      return;
    }
    _ppState.editando = idPP;
    const setVal = (id, v) => { const el = $(id); if (el) el.value = v; };
    const setTxt = (id, v) => { const el = $(id); if (el) el.textContent = v; };
    setTxt('ppModalTitle', idPP ? '📦 Editar cotización' : '📦 Nueva cotización');
    setVal('ppId', idPP || '');
    setVal('ppBuscar', '');
    setVal('ppSkuBase', '');
    setVal('ppCodigoBarra', '');
    if ($('ppBuscarRes')) $('ppBuscarRes').style.display = 'none';
    $('ppSeleccionado')?.classList.add('hidden');
    setVal('ppPrecio', '');
    setVal('ppMinimo', '');
    setVal('ppDiasEntrega', '');
    setVal('ppNotas', '');
    $('ppBtnEliminar')?.classList.toggle('hidden', !idPP);

    if (idPP) {
      try {
        const lista = await API.get('getProveedorProductos', { idProveedor: idProv });
        const items = Array.isArray(lista) ? lista : (lista && lista.data) || [];
        const pp = items.find(x => x.idPP === idPP);
        if (pp) {
          $('ppSkuBase').value     = pp.skuBase || '';
          $('ppCodigoBarra').value = pp.codigoBarra || '';
          $('ppPrecio').value      = pp.precioReferencia || '';
          $('ppMinimo').value      = pp.minimoCompra || '';
          $('ppDiasEntrega').value = pp.diasEntrega || '';
          $('ppNotas').value       = pp.notas || '';
          $('ppSeleccionado').textContent = `${pp.descripcion || pp.skuBase} (SKU ${pp.skuBase}${pp.codigoBarra ? ' · ▌' + pp.codigoBarra : ''})`;
          $('ppSeleccionado').classList.remove('hidden');
        }
      } catch(_){}
    }
    openModal('modalProvProducto');
  }

  function ppBuscar() {
    const raw = ($('ppBuscar').value || '').trim();
    const resBox = $('ppBuscarRes');
    if (!raw) { resBox.style.display = 'none'; resBox.innerHTML = ''; return; }
    const qn = _norm(raw);
    const palabras = qn.split(/\s+/).filter(Boolean);
    const canonicos = (S.productos || []).filter(p => {
      const f = parseFloat(p.factorConversion);
      return !p.factorConversion || f === 1;
    });
    const scored = canonicos.map(p => {
      const haystack = _norm((p.descripcion || '') + ' ' + (p.codigoBarra || '') + ' ' + (p.skuBase || p.idProducto || '') + ' ' + (p.marca || ''));
      let s = 0, ok = true;
      palabras.forEach(w => { if (haystack.indexOf(w) >= 0) s++; else ok = false; });
      return { p, score: s, ok };
    }).filter(x => x.ok).sort((a, b) => b.score - a.score).slice(0, 10);
    if (!scored.length) {
      resBox.innerHTML = '<div class="pn-result text-slate-500 italic">Sin resultados</div>';
      resBox.style.display = 'block';
      return;
    }
    resBox.innerHTML = scored.map(({ p }) => {
      const sku = p.skuBase || p.idProducto;
      const cb  = p.codigoBarra || '';
      const safeDesc = (p.descripcion || sku).replace(/'/g, "\\'");
      return `<div class="pn-result" onclick="MOS.ppSeleccionar('${sku}', '${cb}', '${safeDesc}')">
        <div class="text-slate-200 font-medium">${p.descripcion || sku}</div>
        <div class="text-slate-500 text-xs" style="font-family:monospace">SKU ${sku}${cb ? ' · ▌' + cb : ''}</div>
      </div>`;
    }).join('');
    resBox.style.display = 'block';
  }

  function ppSeleccionar(sku, cb, desc) {
    $('ppSkuBase').value     = sku;
    $('ppCodigoBarra').value = cb;
    $('ppSeleccionado').textContent = `${desc} (SKU ${sku}${cb ? ' · ▌' + cb : ''})`;
    $('ppSeleccionado').classList.remove('hidden');
    $('ppBuscarRes').style.display = 'none';
    $('ppBuscar').value = desc;
  }

  async function guardarProvProducto() {
    const idProveedor = S.provSelId;
    const idPP        = $('ppId').value;
    const skuBase     = $('ppSkuBase').value;
    const codigoBarra = $('ppCodigoBarra').value;
    if (!skuBase) { toast('Selecciona un producto', 'error'); return; }
    const params = {
      idProveedor,
      skuBase,
      codigoBarra,
      descripcion: ($('ppSeleccionado').textContent || '').split(' (')[0],
      precioReferencia: parseFloat($('ppPrecio').value) || 0,
      minimoCompra:     parseFloat($('ppMinimo').value) || 0,
      diasEntrega:      parseInt($('ppDiasEntrega').value) || 0,
      notas:            $('ppNotas').value
    };

    // OPTIMISTIC: actualizar cache local + cerrar modal de inmediato
    S.provProductos = S.provProductos || {};
    if (!S.provProductos[idProveedor]) S.provProductos[idProveedor] = [];
    if (idPP) {
      const idx = S.provProductos[idProveedor].findIndex(x => x.idPP === idPP);
      if (idx >= 0) Object.assign(S.provProductos[idProveedor][idx], params, { idPP });
    } else {
      const tmpId = 'PP_TMP_' + Date.now();
      S.provProductos[idProveedor].push(Object.assign({ idPP: tmpId, _tmp: true }, params));
    }
    closeModal('modalProvProducto');
    toast(idPP ? 'Cotización actualizada ✓' : 'Cotización agregada ✓', 'ok');
    _renderProvProductos();

    // Sync en background
    try {
      if (idPP) {
        await API.post('actualizarProductoProveedor', Object.assign({ idPP }, params));
      } else {
        await API.post('agregarProductoProveedor', params);
        // Refrescar para obtener idPP real del servidor
        const lista = await API.get('getProveedorProductos', { idProveedor });
        const items = Array.isArray(lista) ? lista : (lista && lista.data) || [];
        S.provProductos[idProveedor] = items;
        _renderProvProductos();
      }
    } catch(e) {
      toast('Error de sincronización: ' + e.message, 'error');
      // Revertir: re-fetch
      try {
        const lista = await API.get('getProveedorProductos', { idProveedor });
        const items = Array.isArray(lista) ? lista : (lista && lista.data) || [];
        S.provProductos[idProveedor] = items;
        _renderProvProductos();
      } catch(_){}
    }
  }

  // Eliminar desde el botón 🗑️ de cada card (sin abrir modal)
  async function eliminarProvProductoRapido(idPP) {
    if (!idPP) return;
    if (!confirm('¿Eliminar este producto del catálogo del proveedor?')) return;
    const idProveedor = S.provSelId;
    // OPTIMISTIC
    if (S.provProductos && S.provProductos[idProveedor]) {
      S.provProductos[idProveedor] = S.provProductos[idProveedor].filter(x => x.idPP !== idPP);
    }
    _renderProvProductos();
    toast('Eliminado', 'ok');
    try {
      await API.post('eliminarProductoProveedor', { idPP });
    } catch(e) { toast('Error de sincronización: ' + e.message, 'error'); }
  }

  async function eliminarProvProducto() {
    const idPP = $('ppId').value;
    if (!idPP) return;
    if (!confirm('¿Eliminar esta cotización?')) return;
    const idProveedor = S.provSelId;

    // OPTIMISTIC
    if (S.provProductos && S.provProductos[idProveedor]) {
      S.provProductos[idProveedor] = S.provProductos[idProveedor].filter(x => x.idPP !== idPP);
    }
    closeModal('modalProvProducto');
    toast('Eliminada', 'ok');
    _renderProvProductos();

    try {
      await API.post('eliminarProductoProveedor', { idPP });
    } catch(e) { toast('Error de sincronización: ' + e.message, 'error'); }
  }

  // ============================================================
  // ── PROMOCIONES (vista completa, no modal) ────────────────────
  // ============================================================
  const _promoState = { lista: [], editando: null, comboItems: [] };

  // Helper: stepper +/- para inputs numéricos
  function numStep(id, delta, step) {
    const el = $(id);
    if (!el) return;
    const stp = step || 1;
    const cur = parseFloat(el.value) || 0;
    let nuevo = cur + (delta * stp);
    if (nuevo < 0) nuevo = 0;
    // Redondear según el step para evitar errores de floating point
    if (stp < 1) nuevo = Math.round(nuevo * 100) / 100;
    el.value = nuevo;
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }

  const PROMO_CACHE_KEY = 'mos_promo_cache';
  function _promoLoadCache() {
    try {
      const raw = localStorage.getItem(PROMO_CACHE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (Date.now() - (parsed.ts || 0) > 86400000) return null; // 24h
      return parsed.data;
    } catch { return null; }
  }
  function _promoSaveCache(data) {
    try { localStorage.setItem(PROMO_CACHE_KEY, JSON.stringify({ ts: Date.now(), data })); } catch {}
  }

  async function loadPromociones() {
    $('promoListView').classList.remove('hidden');
    // Render cache primero (instantáneo) — usa cache si existe, sino lista actual del estado
    const cached = _promoLoadCache();
    if (cached) {
      _promoState.lista = cached;
    }
    // Render SIEMPRE al entrar a la vista (incluso si lista ya tenía data del init startup)
    if (_promoState.lista && _promoState.lista.length) {
      _renderPromoLista();
    } else {
      $('promoLista').innerHTML = '<div class="skel h-12 rounded-lg"></div><div class="skel h-12 rounded-lg mt-2"></div>';
    }
    // Fetch fresco
    _promoState.lastError = null;
    try {
      const lista = await API.get('getPromociones', {});
      const fresh = Array.isArray(lista) ? lista : (lista && lista.data) || [];
      console.log('[loadPromociones] respuesta GAS:', fresh.length, 'promociones', fresh);
      _promoState.lista = fresh;
      _promoState.lastFetch = Date.now();
      _promoSaveCache(fresh);
      _renderPromoLista();  // SIEMPRE re-renderizar después del fetch
    } catch(e) {
      console.error('[loadPromociones] error API:', e);
      _promoState.lastError = e && e.message ? e.message : String(e);
      toast('Error cargando promociones: ' + _promoState.lastError, 'error');
      if (!cached) _promoState.lista = [];
      _renderPromoLista();
    }
  }

  // Forzar refetch limpiando cache local
  function _promoForzarRefresh() {
    try { localStorage.removeItem(PROMO_CACHE_KEY); } catch {}
    _promoState.lista = [];
    toast('Cache limpiado, recargando…', 'info');
    loadPromociones();
  }

  // Refresh silencioso periódico
  let _promoRefreshTimer = null;
  function _startPromoRefresh() {
    if (_promoRefreshTimer) clearInterval(_promoRefreshTimer);
    _promoRefreshTimer = setInterval(() => {
      // Solo refresh si la vista está activa
      if (S.currentView === 'promociones') loadPromociones().catch(() => {});
    }, 120000);
  }

  // Compat: si alguien llama el viejo método, redirige a nav
  function abrirModalPromociones() { nav('promociones'); }

  function _renderPromoLista() {
    const cont = $('promoLista');
    const cnt  = $('promosCount');
    if (cnt) cnt.textContent = _promoState.lista.length;
    if (!_promoState.lista.length) {
      const hora = _promoState.lastFetch ? new Date(_promoState.lastFetch).toLocaleTimeString() : '—';
      const errMsg = _promoState.lastError
        ? `<div class="text-xs text-rose-400 mb-2">⚠ Error: ${_promoState.lastError}</div><div class="text-xs text-slate-500 mb-3">Revisa que el GAS esté desplegado como Nueva versión.</div>`
        : `<div class="text-xs text-slate-500 mb-3">El servidor respondió 0 promociones (verificado a las ${hora}).<br>Si tienes una registrada en la hoja PROMOCIONES de MosExpress, esto puede deberse a:<br>· GAS sin redesplegar con el último fix<br>· ME_SS_ID apunta a otro spreadsheet</div>`;
      cont.innerHTML = `
        <div class="text-center py-8">
          ${errMsg}
          <button class="btn-ghost text-xs" onclick="MOS._promoForzarRefresh()">🔄 Limpiar cache y reintentar</button>
        </div>
      `;
      return;
    }
    cont.innerHTML = _promoState.lista.map(p => {
      let nombre, tipoLabel, tipoIcon;
      if (p.tipo === 'COMBO') {
        nombre = `Combo de ${(p.items || []).length} producto${(p.items || []).length !== 1 ? 's' : ''}`;
        tipoLabel = `Precio combo: S/${p.valorPromo.toFixed(2)}`;
        tipoIcon = '🛒';
      } else {
        const prod = (S.productos || []).find(pr => (pr.skuBase || pr.idProducto) === p.skuBase);
        nombre = prod ? prod.descripcion : p.skuBase;
        if (p.tipo === 'GRUPO') {
          tipoLabel = `Lleva ${p.cantMin} por S/${(p.cantMin * p.valorPromo).toFixed(2)} (c/u S/${p.valorPromo.toFixed(2)})`;
          tipoIcon = '📦';
        } else {
          tipoLabel = `-${p.valorPromo}% desde ${p.cantMin} uds`;
          tipoIcon = '%';
        }
      }
      const activaCls = p.activa ? 'border-purple-500/40 bg-purple-500/5' : 'border-slate-700 bg-slate-900/40 opacity-60';
      const idRef = p.idPromo || p.skuBase || '';
      return `
        <div class="cursor-pointer p-3 rounded-lg border ${activaCls} hover:border-purple-400 transition-colors" onclick="MOS.promoEditar('${idRef}')">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex-1">
              <div class="text-sm font-semibold text-slate-100 truncate">${tipoIcon} ${nombre}</div>
              <div class="text-xs text-purple-300 mt-0.5">${tipoLabel}</div>
              ${p.descripcion ? `<div class="text-xs text-slate-500 mt-0.5">${p.descripcion}</div>` : ''}
            </div>
            <button type="button" class="toggle-sw shrink-0 ${p.activa ? 'on' : ''}"
                    onclick="event.stopPropagation();MOS.promoToggleActiva('${idRef}')"
                    title="${p.activa ? 'Desactivar' : 'Activar'}">
              <span class="toggle-sw-knob"></span>
            </button>
          </div>
        </div>`;
    }).join('');
  }

  // Toggle inline: activar/desactivar promoción sin abrir form (optimista)
  async function promoToggleActiva(idRef) {
    const p = _promoState.lista.find(x => (x.idPromo === idRef) || (x.skuBase === idRef));
    if (!p) return;
    const nuevoEstado = !p.activa;

    // OPTIMISTIC: cambiar en cache local + re-render
    p.activa = nuevoEstado;
    _promoSaveCache(_promoState.lista);
    _renderPromoLista();
    toast(nuevoEstado ? 'Promoción activada ✓' : 'Promoción desactivada', 'ok');

    // Sync en background
    try {
      await API.post('actualizarPromocion', {
        idPromo: p.idPromo,
        skuBase: p.skuBase,
        activa: nuevoEstado
      });
    } catch(e) {
      // Revertir
      p.activa = !nuevoEstado;
      _promoSaveCache(_promoState.lista);
      _renderPromoLista();
      toast('Error: ' + e.message, 'error');
    }
  }

  function _hoyISO() {
    const d = new Date();
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  function promoNuevoForm() {
    _promoState.editando = null;
    _promoState.comboItems = [];
    // Abrir modal flotante
    openModal('modalPromoEdit');
    $('promoBtnEliminar').classList.add('hidden');
    $('promoIdEdit').value = '';
    $('promoBuscar').value = '';
    $('promoSkuBase').value = '';
    $('promoBuscarRes').style.display = 'none';
    $('promoBuscarRes').innerHTML = '';
    $('promoSeleccionado').classList.add('hidden');
    $('promoComboBuscar').value = '';
    $('promoComboRes').style.display = 'none';
    $('promoComboItems').innerHTML = '';
    document.querySelector('input[name="promoTipo"][value="GRUPO"]').checked = true;
    promoSetTipo('GRUPO');
    $('promoCantMin').value = '';
    $('promoValor').value = '';
    const cp = $('promoComboPrecio'); if (cp) cp.value = '';
    $('promoDesc').value = '';
    // Vigencia por defecto: hoy
    $('promoFDesde').value = _hoyISO();
    $('promoFHasta').value = '';
    $('promoTogActiva').classList.add('on');
    $('promoError').style.display = 'none';
  }

  function promoEditar(idRef) {
    const p = _promoState.lista.find(x => (x.idPromo === idRef) || (x.skuBase === idRef));
    if (!p) return;
    _promoState.editando = p.idPromo || p.skuBase;
    promoNuevoForm();
    $('promoBtnEliminar').classList.remove('hidden');
    $('promoIdEdit').value = p.idPromo || p.skuBase;
    document.querySelector('input[name="promoTipo"][value="' + p.tipo + '"]').checked = true;
    promoSetTipo(p.tipo);

    if (p.tipo === 'COMBO') {
      _promoState.comboItems = (p.items || []).slice();
      _renderPromoComboItems();
      $('promoComboPrecio').value = p.valorPromo || 0;
    } else {
      $('promoSkuBase').value = p.skuBase;
      const prod = (S.productos || []).find(pr => (pr.skuBase || pr.idProducto) === p.skuBase);
      $('promoSeleccionadoNombre').textContent = prod ? `${prod.descripcion} (${p.skuBase})` : p.skuBase;
      $('promoSeleccionado').classList.remove('hidden');
      $('promoCantMin').value = p.cantMin;
      // Modo: si TOTAL, mostrar cantMin × valorPromo (lo que el usuario originalmente escribió)
      const modo = String(p.valorModo || 'UNITARIO').toUpperCase();
      if (p.tipo === 'GRUPO' && modo === 'TOTAL') {
        $('promoValor').value = (p.cantMin * p.valorPromo).toFixed(2);
        promoSetModo('TOTAL');
      } else {
        $('promoValor').value = p.valorPromo;
        if (p.tipo === 'GRUPO') promoSetModo('UNITARIO');
      }
    }
    $('promoDesc').value    = p.descripcion || '';
    $('promoFDesde').value  = p.vigenciaDesde ? String(p.vigenciaDesde).substring(0, 10) : '';
    $('promoFHasta').value  = p.vigenciaHasta ? String(p.vigenciaHasta).substring(0, 10) : '';
    $('promoTogActiva').classList.toggle('on', !!p.activa);
    promoActualizarEjemplo();
  }

  function promoVolverLista() {
    closeModal('modalPromoEdit');
  }

  function promoSetTipo(tipo) {
    const esCombo = tipo === 'COMBO';
    const esGrupo = tipo === 'GRUPO';
    $('promoSeccionUnico').classList.toggle('hidden', esCombo);
    $('promoSeccionCombo').classList.toggle('hidden', !esCombo);
    $('promoSeccionValor').classList.toggle('hidden', esCombo);
    $('promoSeccionPrecioCombo').classList.toggle('hidden', !esCombo);
    // Toggle modo solo visible en GRUPO
    const modoBox = $('promoModoBox');
    if (modoBox) modoBox.style.display = esGrupo ? '' : 'none';
    // Chips rápidos según tipo
    ['GRUPO','PORCENTAJE','COMBO'].forEach(t => {
      const row = $('promoQuick' + t);
      if (row) row.classList.toggle('hidden', t !== tipo);
    });
    if (tipo === 'GRUPO') {
      const modo = $('promoModoUnit')?.classList.contains('active') ? 'UNITARIO' : 'TOTAL';
      $('promoValorLbl').textContent = modo === 'TOTAL' ? 'Precio TOTAL del grupo *' : 'Precio UNITARIO en promo *';
    } else if (tipo === 'PORCENTAJE') {
      $('promoValorLbl').textContent = '% Descuento *';
    }
    promoActualizarEjemplo();
  }

  // Auto-llena descripción y opcionalmente cantidad mínima desde un chip
  function promoQuickFill(label, descripcion, cantMin) {
    const descEl = $('promoDesc');
    if (descEl) descEl.value = descripcion;
    if (typeof cantMin === 'number' && cantMin > 0) {
      const cm = $('promoCantMin');
      if (cm) {
        cm.value = cantMin;
        cm.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }
    promoActualizarEjemplo();
  }

  function promoSetModo(modo) {
    const esTotal = modo === 'TOTAL';
    $('promoModoUnit').classList.toggle('active', !esTotal);
    $('promoModoTotal').classList.toggle('active', esTotal);
    $('promoValorLbl').textContent = esTotal ? 'Precio TOTAL del grupo *' : 'Precio UNITARIO en promo *';
    promoActualizarEjemplo();
  }

  function promoActualizarEjemplo() {
    const tipo = document.querySelector('input[name="promoTipo"]:checked')?.value;
    const ej = $('promoEjemplo');
    if (!ej) return;
    if (tipo === 'COMBO') {
      const precio = parseFloat($('promoComboPrecio').value) || 0;
      const items = _promoState.comboItems || [];
      if (!items.length || !precio) { ej.textContent = ''; return; }
      ej.textContent = `Ejemplo: ${items.length} producto${items.length !== 1 ? 's' : ''} juntos = S/${precio.toFixed(2)}`;
      return;
    }
    const cant = parseFloat($('promoCantMin').value) || 0;
    const val  = parseFloat($('promoValor').value) || 0;
    if (!cant || !val) { ej.textContent = ''; return; }
    if (tipo === 'GRUPO') {
      const modoTotal = $('promoModoTotal')?.classList.contains('active');
      const total = modoTotal ? val : (cant * val);
      const unit  = modoTotal ? (cant > 0 ? val / cant : 0) : val;
      ej.textContent = `Ejemplo: lleva ${cant} y paga S/${total.toFixed(2)} en total (S/${unit.toFixed(2)} c/u)`;
    } else {
      ej.textContent = `Ejemplo: comprando ${cant}+ unidades, ${val}% de descuento sobre el subtotal`;
    }
  }

  // ── COMBO: agregar productos ─────────────────────────────────
  function promoComboBuscar() {
    const raw = ($('promoComboBuscar').value || '').trim();
    const resBox = $('promoComboRes');
    if (!raw) { resBox.style.display = 'none'; resBox.innerHTML = ''; return; }
    const qn = _norm(raw);
    const palabras = qn.split(/\s+/).filter(Boolean);
    const canonicos = (S.productos || []).filter(p => {
      const f = parseFloat(p.factorConversion);
      return !p.factorConversion || f === 1;
    });
    const scored = canonicos.map(p => {
      const haystack = _norm((p.descripcion || '') + ' ' + (p.codigoBarra || '') + ' ' + (p.skuBase || p.idProducto || '') + ' ' + (p.marca || ''));
      let s = 0, ok = true;
      palabras.forEach(w => { if (haystack.indexOf(w) >= 0) s++; else ok = false; });
      return { p, score: s, ok };
    }).filter(x => x.ok).sort((a, b) => b.score - a.score).slice(0, 8);
    if (!scored.length) {
      resBox.innerHTML = '<div class="pn-result text-slate-500 italic">Sin resultados</div>';
      resBox.style.display = 'block';
      return;
    }
    resBox.innerHTML = scored.map(({ p }) => {
      const sku = p.skuBase || p.idProducto;
      const safeDesc = (p.descripcion || sku).replace(/'/g, "\\'");
      return `<div class="pn-result" onclick="MOS.promoComboAgregar('${sku}', '${safeDesc}')">
        <div class="text-slate-200 font-medium">${p.descripcion || sku}</div>
        <div class="text-slate-500 text-xs" style="font-family:monospace">SKU ${sku}</div>
      </div>`;
    }).join('');
    resBox.style.display = 'block';
  }

  function promoComboAgregar(sku, descripcion) {
    const existing = _promoState.comboItems.find(x => x.skuBase === sku);
    if (existing) { existing.cantidad = (parseFloat(existing.cantidad) || 0) + 1; }
    else _promoState.comboItems.push({ skuBase: sku, descripcion, cantidad: 1 });
    _renderPromoComboItems();
    $('promoComboBuscar').value = '';
    $('promoComboRes').style.display = 'none';
    promoActualizarEjemplo();
  }

  function promoComboCerrarRes() {
    $('promoComboRes').style.display = 'none';
  }

  function _renderPromoComboItems() {
    const cont = $('promoComboItems');
    if (!cont) return;
    if (!_promoState.comboItems.length) {
      cont.innerHTML = '<p class="text-xs text-slate-500 italic py-2">Aún no hay productos. Búscalos arriba.</p>';
      return;
    }
    cont.innerHTML = _promoState.comboItems.map((it, i) => `
      <div class="promo-combo-item">
        <span class="desc">${it.descripcion}</span>
        <input class="qty" type="number" min="1" step="1" value="${it.cantidad}" onchange="MOS.promoComboCambiarQty(${i}, this.value)">
        <span class="rm" onclick="MOS.promoComboQuitar(${i})" title="Quitar">×</span>
      </div>
    `).join('');
  }

  function promoComboCambiarQty(idx, val) {
    if (!_promoState.comboItems[idx]) return;
    _promoState.comboItems[idx].cantidad = Math.max(1, parseInt(val) || 1);
  }

  function promoComboQuitar(idx) {
    _promoState.comboItems.splice(idx, 1);
    _renderPromoComboItems();
    promoActualizarEjemplo();
  }

  function promoBuscarBase() {
    const raw = ($('promoBuscar').value || '').trim();
    const resBox = $('promoBuscarRes');
    if (!raw) { resBox.style.display = 'none'; resBox.innerHTML = ''; return; }
    const qn = _norm(raw);
    const palabras = qn.split(/\s+/).filter(Boolean);
    const canonicos = (S.productos || []).filter(p => {
      const f = parseFloat(p.factorConversion);
      return !p.factorConversion || f === 1;
    });
    const scored = canonicos.map(p => {
      const haystack = _norm((p.descripcion || '') + ' ' + (p.codigoBarra || '') + ' ' + (p.skuBase || p.idProducto || '') + ' ' + (p.marca || ''));
      let s = 0, ok = true;
      palabras.forEach(w => { if (haystack.indexOf(w) >= 0) s++; else ok = false; });
      return { p, score: s, ok };
    }).filter(x => x.ok).sort((a, b) => b.score - a.score).slice(0, 10);
    if (!scored.length) {
      resBox.innerHTML = '<div class="pn-result text-slate-500 italic">Sin resultados</div>';
      resBox.style.display = 'block';
      return;
    }
    resBox.innerHTML = scored.map(({ p }) => {
      const sku = p.skuBase || p.idProducto;
      const safeDesc = (p.descripcion || p.idProducto).replace(/'/g, "\\'");
      return `<div class="pn-result" onclick="MOS.promoSeleccionarBase('${sku}', '${safeDesc}')">
        <div class="text-slate-200 font-medium">${p.descripcion || p.idProducto}</div>
        <div class="text-slate-500 text-xs" style="font-family:monospace">SKU ${sku}</div>
      </div>`;
    }).join('');
    resBox.style.display = 'block';
  }

  function promoSeleccionarBase(sku, descripcion) {
    $('promoSkuBase').value = sku;
    $('promoSeleccionadoNombre').textContent = `${descripcion} (${sku})`;
    $('promoSeleccionado').classList.remove('hidden');
    $('promoBuscarRes').style.display = 'none';
    $('promoBuscar').value = descripcion;
  }

  async function promoGuardar() {
    const errEl = $('promoError'); errEl.style.display = 'none';
    const tipo = document.querySelector('input[name="promoTipo"]:checked')?.value;
    let params;
    if (tipo === 'COMBO') {
      if (!_promoState.comboItems.length) { errEl.textContent = 'Agrega al menos 1 producto al combo'; errEl.style.display = 'block'; return; }
      const precio = parseFloat($('promoComboPrecio').value) || 0;
      if (precio <= 0) { errEl.textContent = 'Precio del combo inválido'; errEl.style.display = 'block'; return; }
      params = {
        tipo,
        items: _promoState.comboItems.map(it => ({ skuBase: it.skuBase, cantidad: parseInt(it.cantidad) || 1, descripcion: it.descripcion })),
        valorPromo: precio,
        cantMin: 1,
        descripcion:   $('promoDesc').value,
        vigenciaDesde: $('promoFDesde').value,
        vigenciaHasta: $('promoFHasta').value,
        activa:        $('promoTogActiva').classList.contains('on')
      };
    } else {
      const skuBase = $('promoSkuBase').value;
      if (!skuBase) { errEl.textContent = 'Selecciona un producto'; errEl.style.display = 'block'; return; }
      const cantMin = parseFloat($('promoCantMin').value) || 0;
      const valor   = parseFloat($('promoValor').value) || 0;
      if (!cantMin || cantMin < 1) { errEl.textContent = 'Cantidad mínima ≥ 1'; errEl.style.display = 'block'; return; }
      if (valor <= 0) { errEl.textContent = 'Valor inválido'; errEl.style.display = 'block'; return; }
      // Solo GRUPO usa el modo (UNITARIO/TOTAL); PORCENTAJE siempre es directo
      const valorModo = (tipo === 'GRUPO' && $('promoModoTotal')?.classList.contains('active')) ? 'TOTAL' : 'UNITARIO';
      params = {
        skuBase, tipo,
        cantMin, valorPromo: valor, valorModo,
        descripcion:   $('promoDesc').value,
        vigenciaDesde: $('promoFDesde').value,
        vigenciaHasta: $('promoFHasta').value,
        activa:        $('promoTogActiva').classList.contains('on')
      };
    }
    const isEdit = !!_promoState.editando;
    if (isEdit) params.idPromo = _promoState.editando;

    // OPTIMISTIC: actualizar lista local + cerrar modal de inmediato
    // Para GRUPO con modo TOTAL, convertir a unitario en local (igual que el server)
    let valorPromoLocal = params.valorPromo || 0;
    if (params.tipo === 'GRUPO' && params.valorModo === 'TOTAL' && params.cantMin > 0 && valorPromoLocal > 0) {
      valorPromoLocal = valorPromoLocal / params.cantMin;
    }
    const tmpId = isEdit ? params.idPromo : ('PROMO_TMP_' + Date.now());
    const localPromo = {
      idPromo:       tmpId,
      skuBase:       params.skuBase || '',
      tipo:          params.tipo,
      cantMin:       params.cantMin || 0,
      valorPromo:    valorPromoLocal,
      valorModo:     params.valorModo || 'UNITARIO',
      items:         params.items || [],
      descripcion:   params.descripcion || '',
      vigenciaDesde: params.vigenciaDesde || '',
      vigenciaHasta: params.vigenciaHasta || '',
      activa:        !!params.activa,
      notas:         '',
      _tmp:          !isEdit
    };
    if (isEdit) {
      const idx = _promoState.lista.findIndex(p => p.idPromo === params.idPromo);
      if (idx >= 0) _promoState.lista[idx] = Object.assign({}, _promoState.lista[idx], localPromo);
    } else {
      _promoState.lista.unshift(localPromo);
    }
    _promoSaveCache(_promoState.lista);
    _renderPromoLista();
    promoVolverLista();   // cierra modal
    toast(isEdit ? 'Promoción actualizada ✓' : 'Promoción creada ✓', 'ok');

    // Sync en background
    try {
      const action = isEdit ? 'actualizarPromocion' : 'crearPromocion';
      const res = await API.post(action, params);
      // Server devuelve idPromo real → actualizar el tmp en cache
      if (!isEdit && res && res.idPromo) {
        const item = _promoState.lista.find(p => p.idPromo === tmpId);
        if (item) { item.idPromo = res.idPromo; item._tmp = false; _promoSaveCache(_promoState.lista); }
      }
      // Refresh fresco en background (sin bloquear UI)
      loadPromociones().catch(() => {});
    } catch(e) {
      toast('Error de sincronización: ' + e.message, 'error');
      // Revertir
      if (!isEdit) {
        _promoState.lista = _promoState.lista.filter(p => p.idPromo !== tmpId);
      }
      _promoSaveCache(_promoState.lista);
      _renderPromoLista();
      // Reabrir el modal para que pueda corregir
      if (!isEdit) promoNuevoForm();
    }
  }

  async function promoEliminar() {
    if (!_promoState.editando) return;
    if (!confirm('¿Eliminar esta promoción?')) return;
    const idPromo = _promoState.editando;
    // OPTIMISTIC: cerrar modal + remover de lista local
    const backup = _promoState.lista.slice();
    _promoState.lista = _promoState.lista.filter(p => p.idPromo !== idPromo && p.skuBase !== idPromo);
    _promoSaveCache(_promoState.lista);
    _renderPromoLista();
    promoVolverLista();
    toast('Promoción eliminada', 'ok');
    try {
      await API.post('eliminarPromocion', { idPromo, skuBase: idPromo });
      loadPromociones().catch(() => {});
    } catch(e) {
      // Revertir
      _promoState.lista = backup;
      _promoSaveCache(_promoState.lista);
      _renderPromoLista();
      toast('Error de sincronización: ' + e.message, 'error');
    }
  }

  // ── PUBLIC API ───────────────────────────────────────────────
  return {
    init, nav, refresh, fabAction,
    openConfig, saveConfig, testConnection, closeModal, openEcoModal,
    filterCatalogo, setCatTab, toggleDerivs, togglePresentaciones, guardarPrecioRapido,
    abrirModalPN, cerrarModalPN, lanzarAProduccion, refreshPNManual,
    pnSetTipo, pnAutogenBarcode, pnBuscarBase, pnSeleccionarBase,
    abrirModalPromociones, loadPromociones, promoNuevoForm, promoEditar, promoVolverLista, promoToggleActiva, _promoForzarRefresh,
    promoSetTipo, promoSetModo, promoQuickFill, promoActualizarEjemplo, promoBuscarBase, promoSeleccionarBase,
    promoGuardar, promoEliminar,
    promoComboBuscar, promoComboAgregar, promoComboCerrarRes,
    promoComboCambiarQty, promoComboQuitar, numStep,
    abrirModalPrecioRapido, cerrarModalPrecioRapido, _qpSyncPresentaciones,
    abrirAnalitica, cerrarAnalitica, setAnPeriodo, guardarStockMinMax, _anCurrentId,
    guardarAjustePrecios, stepperInc, stepperDec,
    abrirModalProducto, guardarProducto,
    prodTogglePolitica, _prodOnPoliticaOverride, _prodOnModoChange, _prodActualizarPoliticaEfectiva,
    setProdTipo, onTipoCheck, onEnvasableCheck, prodAutogenBarcode, prodValidarCodigoBarra, prodToggleEstado, prodToggleCosto,
    prodCalcMargen, prodOnRange, prodToggleSunat, prodOnTipoIGVChange, prodToggleEquiv,
    toggleAddEquiv, crearEquivalenciaModal, toggleEquivActivo,
    toggleProductoActivo, confirmarApagarBase, cerrarApagarBaseRevertir,
    // Evaluación de personal
    loadEvaluacion, refreshEvaluacion, evalSetApp,
    abrirAuditar, cerrarAuditar, guardarAuditoria,
    auditToggleCheck, auditCheckAll, auditToggle,
    updateRateSlider, abrirConfigEval, guardarConfigEval,
    abrirLiquidacion,
    abrirModalPrecio, publicarPrecio,
    setAlmTab,
    almLoadResumen, almRefreshResumen, almFiltrarStock, almRefreshCatalogo, almToggleStockExpand,
    almLoadOps, almRefreshOps, almRenderOps, almToggleOpExpand,
    abrirCostosGuia, _costosGuiaUpdLinea, _costosGuiaSetMode, _costosGuiaSetIgv, cerrarCostosGuia, guardarCostosGuia,
    _impactoTogglesel, _impactoSetPrecio, cerrarImpactoCostos, aplicarSugerenciasSeleccionadas,
    almLoadZonas, almRefreshZonas, almAbrirStockDetalle, cerrarStockDetalle, almRefreshStockDetalle,
    _almGenerarPedidoFromInsight, _almPickProveedor, cerrarSelProveedor,
    cerrarModalPedido, pedidoBuscarItem, pedidoAgregarItem,
    pedidoQuitarItem, pedidoCambiarQty, guardarPedido,
    loadProveedores, selectProveedor, renderProveedores, cerrarDetalleProveedor,
    abrirModalProveedor, guardarProveedor,
    provSetTab, _renderProvHistorico, _refetchHistoricoProv,
    _filtrarProvProductos, _filtrarProvHistorico,
    abrirModalProvProducto, ppBuscar, ppSeleccionar,
    guardarProvProducto, eliminarProvProducto, eliminarProvProductoRapido,
    abrirVistaCargadores, nuevoCargador, editarCargador,
    abrirModalPago, guardarPago, abrirModalPedido,
    // Config
    setCfgTab,
    auditCorrer, auditResolver, auditResolverTodas, renderIntegridad,
    abrirModalZona, guardarZona,
    abrirModalCategoria, guardarCategoria, _catOnModoChange,
    abrirModalEstacion, guardarEstacion,
    abrirModalImpresora, guardarImpresora,
    abrirModalPersonal, guardarPersonal,
    abrirModalSerie, guardarSerie,
    guardarPinEstacion, guardarPinWH,
    abrirModalDispositivo, cerrarModalDispositivo, guardarDispositivo, toggleEstadoDispositivo,
    toggleAvatarMenu, closeAvatarMenu, installPWA,
    toggleFiltroCat, setFiltroCategoria, toggleFiltroTipo, limpiarFiltrosCat, toggleFiltroAlertas, toggleAlertPop,
    // Cajas
    loadCajas, toggleCajaDetail, toggleKpiVentas,
    toggleKpiTickets, setTicketFiltroFecha, setTicketFiltroEstado, setTicketFiltroTipo,
    confirmarAnularTicket, abrirModalMetodo, cerrarModalMetodo, aplicarCambioMetodo,
    _selMetodo, _onMixtoInput, _renderModalMetodo,
    // Login / sesión
    seleccionarUsuario, loginVolver, confirmarPin, logout, lockScreen, _np, _dismissWelcome,
    syncApp, applyPendingUpdate,
    // Finanzas
    finCargar, finDia, finAbrirModalGasto, finAbrirModalJornada, finGuardarGasto,
    finGuardarJornada, finEliminarGasto, finEliminarJornada, finImportarCajas,
    cerrarModalFin,
    finEditarCostoSku, finCerrarCostoEditor, finGuardarCostoSku,
    // Finanzas — modales detalle
    finAbrirModalProductos, finToggleFiltroSinCosto,
    finEditarCostoProd, finCerrarCostoProd, finGuardarCostoProd,
    finAbrirModalTickets, finSetTicketFiltro,
    activarPush: () => _pushInit(S.session?.nombre || '', S.session?.rol || '', true)
  };
})();
