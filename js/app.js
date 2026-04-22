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
    pnPendientes: []
  };

  function _getSession()      { try { return JSON.parse(localStorage.getItem(SESSION_KEY)); } catch { return null; } }
  function _saveSession(s)    { localStorage.setItem(SESSION_KEY, JSON.stringify(s)); }
  function _clearSession()    { localStorage.removeItem(SESSION_KEY); }

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
    el._t = setTimeout(() => el.classList.add('hide'), 3500);
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

    // Session check
    const saved = _getSession();
    if (saved && saved.idPersonal && saved.nombre) {
      S.session = saved;
      _applySession();
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
  const _PIN_MAX       = 6;

  // ── Numpad ───────────────────────────────────────────────────
  function _np(key) {
    if (key === 'del') {
      _pinValue = _pinValue.slice(0, -1);
      _updatePinDots();
    } else if (key === 'ok') {
      confirmarPin();
    } else {
      if (_pinValue.length >= _PIN_MAX) return;
      _pinValue += key;
      _updatePinDots();
      if (_pinValue.length === _PIN_MAX) setTimeout(confirmarPin, 130);
    }
  }

  function _updatePinDots() {
    const isLock = _pinMode === 'lock';
    const id = isLock ? 'lockPinDots' : 'loginPinDots';
    const el = $(id); if (!el) return;
    el.innerHTML = Array.from({ length: _PIN_MAX }, (_, i) =>
      `<div class="pin-dot${i < _pinValue.length ? (isLock ? ' filled lock' : ' filled') : ''}"></div>`
    ).join('');
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
      const eid = _pinMode === 'lock' ? 'lockPinError' : 'loginPinError';
      const e = $(eid); if (e) e.textContent = 'Mínimo 4 dígitos';
      return;
    }
    const pin    = _pinValue;
    const userId = _pinMode === 'lock' ? S.session?.idPersonal : _loginSelectedId;

    if (_pinMode === 'lock') {
      const err = $('lockPinError'); if (err) err.textContent = '';
      try {
        const res = await API.post('verificarPinPersonal', { idPersonal: userId, pin });
        if (!res?.autorizado) {
          _pinValue = ''; _updatePinDots();
          const e = $('lockPinError'); if (e) e.textContent = 'PIN incorrecto';
          return;
        }
        $('loginOverlay')?.classList.add('hidden');
      } catch(e) {
        _pinValue = ''; _updatePinDots();
        const err = $('lockPinError'); if (err) err.textContent = e.message;
      }
    } else {
      const err = $('loginPinError'); if (err) err.textContent = '';
      try {
        const res = await API.post('verificarPinPersonal', { idPersonal: userId, pin });
        if (!res?.autorizado) {
          _pinValue = ''; _updatePinDots();
          const e = $('loginPinError'); if (e) e.textContent = 'PIN incorrecto';
          return;
        }
        S.session = { idPersonal: userId, nombre: res.nombre, rol: res.rol };
        _saveSession(S.session);
        _applySession();
        $('loginOverlay')?.classList.add('hidden');
        nav('dashboard');
        loadView('dashboard');
        if (window._SWDailyCheck) window._SWDailyCheck();
        // Push: notificar login + registrar token (askPermission=true porque viene de gesto del usuario)
        _pushInit(res.nombre, res.rol, true);
      } catch(e) {
        _pinValue = ''; _updatePinDots();
        const err = $('loginPinError'); if (err) err.textContent = e.message;
      }
    }
  }

  function _applySession() {
    if (!S.session) return;
    const isMaster = (S.session.rol || '').toLowerCase() === 'master';
    // Iniciar pre-carga en background al autenticar
    _startCajasRefresh();
    _startCatRefresh();
    _startFinanzasRefresh();
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
    // Hide Config for admin role
    document.querySelectorAll('[data-view="config"]').forEach(b => {
      b.style.display = isMaster ? '' : 'none';
    });
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

  async function loadCatalogo() {
    // Si el timer ya precargó datos frescos, renderizar al instante sin fetch
    if (S.productos && S.productos.length > 0) {
      populateCatFiltro();
      renderCatalogo();
      return;
    }

    // Fallback: cache local → render inmediato, luego fetch fresco
    const cached = _catLoadCache();
    if (cached) {
      S.productos = cached.productos || cached;
      S.equivMap  = cached.equivMap  || {};
      populateCatFiltro();
      renderCatalogo();
    }

    // Fetch fresco (si no lo hizo el timer aún)
    try {
      const [freshProd, freshEquiv] = await Promise.all([
        API.get('getProductos', {}),
        API.get('getEquivalencias', { activo: '1' }).catch(() => [])
      ]);
      const productos = freshProd || [];
      const equivMap  = {};
      (freshEquiv || []).forEach(e => {
        const k = e.skuBase || e.idProducto;
        if (k) equivMap[k] = (equivMap[k] || 0) + 1;
      });
      const changed = JSON.stringify(productos) !== JSON.stringify(S.productos);
      S.productos = productos;
      S.equivMap  = equivMap;
      _catSaveCache({ productos, equivMap });
      if (changed || !cached) { populateCatFiltro(); renderCatalogo(); }
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
        if (k) equivMap[k] = (equivMap[k] || 0) + 1;
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
        const activos = productos.filter(p => !p.estado || String(p.estado) === '1').length;
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
            const activo = !p.estado || String(p.estado) === '1';
            cardEl.classList.toggle('cat-inactive', !activo);
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

  function populateCatFiltro() {
    const cats = [...new Set(S.productos.map(p => p.idCategoria).filter(Boolean))].sort();
    const opts = '<option value="">Todas las categorías</option>' + cats.map(c => `<option value="${c}">${c}</option>`).join('');
    const catOpts = '<option value="">— elegir —</option>' + cats.map(c => `<option value="${c}">${c}</option>`).join('');
    const sel = $('filtroCategoria'); if (sel) sel.innerHTML = opts;
    const prodCat = $('prodCategoria');
    if (prodCat) prodCat.innerHTML = '<option value="">— seleccionar —</option>' + cats.map(c => `<option value="${c}">${c}</option>`).join('');
    const pnCat = $('pnCategoria');
    if (pnCat) pnCat.innerHTML = catOpts;
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
    const cat  = $('filtroCategoria')?.value || '';
    const qn   = _norm(rawQ);
    const words = qn.split(/\s+/).filter(Boolean);

    // Build groups: agrupar por skuBase
    // Base = producto donde idProducto === skuBase (auto-referencia)
    // Presentación = producto donde skuBase apunta a otro idProducto
    const groups = {};
    S.productos.forEach(p => {
      const sku = String(p.skuBase || p.idProducto).trim();
      if (!groups[sku]) groups[sku] = { base: null, pres: [] };
      // Es base si: idProducto === skuBase (auto-ref) O factor = 1 o vacío (unidad mínima)
      const factor = parseFloat(p.factorConversion) || 1;
      const esBase = String(p.idProducto).trim() === sku ||
                     !p.skuBase ||
                     (factor === 1 && !groups[sku].base);
      if (esBase) groups[sku].base = p;
      else        groups[sku].pres.push(p);
    });
    // Ordenar presentaciones por factor ascendente
    Object.values(groups).forEach(g => {
      if (!g.base && g.pres.length) g.base = g.pres.shift();
      g.pres.sort((a, b) => (parseFloat(a.factorConversion)||1) - (parseFloat(b.factorConversion)||1));
    });
    _catGroups = groups; // guardar para acceso externo (ajuste de precios)

    // Score and filter
    let result = Object.values(groups).filter(g => g.base).map(g => {
      if (cat && g.base.idCategoria !== cat) return null;
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

    container.innerHTML = result.map(({ base, pres, score }) => {
      const eid   = CSS.escape(base.idProducto);
      const activo = !base.estado || String(base.estado) === '1';
      const hlDesc = _highlight(base.descripcion || '—', words);

      // Badges
      const badgeCat  = base.idCategoria ? `<span class="badge badge-gray text-xs">${base.idCategoria}</span>` : '';
      const badgeEnv  = base.esEnvasable == '1' ? `<span class="badge badge-yellow text-xs">⚗️ Envasable</span>` : '';
      const badgePres = pres.length ? `<span class="badge badge-blue text-xs cursor-pointer" onclick="event.stopPropagation();MOS.togglePresentaciones('${base.idProducto}')">📦 ${pres.length} presentacion${pres.length !== 1 ? 'es' : ''}</span>` : '';
      const badgeInac = activo ? '' : `<span class="badge badge-gray text-xs">Inactivo</span>`;

      // Equivalencias count para el skuBase
      const equivCount = S.equivMap[base.skuBase || base.idProducto] || 0;

      // Meta tags: barcode + equivalencias + brand
      const barcodeTag = base.codigoBarra
        ? `<span class="cat-barcode">▌${base.codigoBarra}</span>` : '';
      const equivTag   = equivCount > 0
        ? `<span class="cat-equiv">+${equivCount} equiv.</span>` : '';
      const brandTag   = base.marca
        ? `<span class="cat-brand">${base.marca}</span>` : '';

      // Pre-computar alertas de cada presentación
      const presInfo = pres.map(d => {
        const factor         = parseFloat(d.factorConversion) || 1;
        const precioActual   = parseFloat(d.precioVenta) || 0;
        const precioEsperado = parseFloat(base.precioVenta) * factor;
        const coherente      = precioEsperado <= 0 || factor >= 1 || precioActual >= precioEsperado * 0.95;
        const factorRep      = factor === 1 && (d.codigoBarra || '') !== (base.codigoBarra || '');
        return { d, factor, precioActual, precioEsperado, coherente, factorRep };
      });
      const hasAnyAlert = presInfo.some(a => !a.coherente || a.factorRep);

      // Presentaciones con expand animado
      const presHtml = pres.length ? `
        <div class="pres-wrap" id="pres-${eid}">
          <div class="pres-inner">
            <div class="px-4 pb-4 pt-3 border-t border-slate-800/80 space-y-2">
              <div class="text-xs text-slate-500 font-medium mb-2">📦 Presentaciones (${pres.length})</div>
              ${presInfo.map(({ d, factor, precioActual, precioEsperado, coherente, factorRep }) => {
                const hlD       = _highlight(d.descripcion || d.idProducto, words);
                const hasAlert  = !coherente || factorRep;
                const precioClass = coherente ? 'pres-price-ok' : 'pres-price-err';
                const alertHtml = [
                  !coherente ? `<span class="pres-alert-badge">⚠ precio bajo</span><span class="pres-suggest">esperado: ${fmtMoney(precioEsperado)}</span>` : '',
                  factorRep  ? `<span class="pres-alert-badge pres-alert-dup">⚠ factor repetido</span>` : ''
                ].filter(Boolean).join('');
                return `<div class="pres-chip${hasAlert ? ' border-amber-900/50' : ''}">
                  <div class="min-w-0 flex-1">
                    <div class="text-xs font-semibold text-slate-200 truncate">${hlD}</div>
                    <div class="flex items-center gap-2 mt-0.5">
                      ${d.codigoBarra ? `<span class="pres-code">▌${d.codigoBarra}</span>` : ''}
                      <span class="pres-factor">×${factor}</span>
                    </div>
                    ${alertHtml ? `<div class="flex flex-wrap items-center gap-1 mt-0.5">${alertHtml}</div>` : ''}
                  </div>
                  <div class="flex items-center gap-2 shrink-0">
                    <div class="${precioClass}">${fmtMoney(precioActual)}</div>
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
                ${barcodeTag}${equivTag}${brandTag}
              </div>
            </div>
            <div class="flex flex-col items-end gap-1.5 shrink-0 ml-2">
              <div class="flex items-center gap-1.5">
                ${hasAnyAlert ? `<span class="cat-alert-icon" title="Hay alertas en presentaciones">⚠</span>` : ''}
                <div class="cat-price" data-cat-precio="${base.idProducto}">${fmtMoney(base.precioVenta)}</div>
              </div>
              ${base.precioCosto > 0 ? `<div class="cat-cost" data-cat-costo="${base.idProducto}">Costo: ${fmtMoney(base.precioCosto)}</div>` : ''}
              <div class="flex gap-1.5 mt-1">
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

  async function _refreshPNPendientes() {
    try {
      const lista = await API.getProductosNuevosWH({ estado: 'PENDIENTE' });
      S.pnPendientes = lista || [];
    } catch(e) {
      S.pnPendientes = S.pnPendientes || [];
    }
    _updatePNBadge();
    renderPNBanner();
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
          <span style="font-size:13px;font-weight:600;color:#fcd34d">Productos nuevos pendientes de aprobación</span>
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

    $('pnId').value       = pn.idProductoNuevo;
    $('pnIdGuia').value   = pn.idGuia || '';
    $('pnUsuario').value  = pn.usuario || '';
    $('pnDesc').value     = pn.descripcion || '';
    $('pnMarca').value    = pn.marca || '';
    $('pnCodigoWH').textContent   = pn.codigoBarra || '—';
    $('pnCantidad').textContent   = pn.cantidad != null ? pn.cantidad : '—';
    $('pnFechaVenc').textContent  = pn.fechaVencimiento || '—';

    const guiaLabel = pn.guia ? `${pn.guia.tipo || 'Guía'} · ${pn.guia.fecha || ''} · ${pn.guia.estado || ''}` : `Guía ${pn.idGuia}`;
    $('pnGuiaInfo').textContent = guiaLabel;

    const obs = $('pnObservaciones');
    if (pn.observaciones) { obs.textContent = pn.observaciones; obs.style.display = 'block'; }
    else obs.style.display = 'none';

    const fotoBox = $('pnFotoPreview');
    if (pn.foto) {
      fotoBox.innerHTML = `<img src="${pn.foto}" style="width:100%;height:100%;object-fit:cover">`;
    } else {
      fotoBox.innerHTML = `<svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#475569" stroke-width="1.5"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21,15 16,10 5,21"/></svg>`;
    }

    $('pnPrecioVenta').value = '';
    $('pnPrecioCosto').value = '';
    $('pnStockMin').value    = '';

    const errEl = $('pnError'); if (errEl) errEl.style.display = 'none';
    const btn = $('btnLanzarPN'); if (btn) { btn.disabled = false; btn.textContent = 'Lanzar a producción'; }

    populateCatFiltro(); // repopulates pnCategoria from S.productos
    const catSel = $('pnCategoria');
    if (catSel && pn.idCategoria) catSel.value = pn.idCategoria;
    const unidSel = $('pnUnidad');
    if (unidSel && pn.unidad) unidSel.value = pn.unidad;

    const modal = $('modalPN');
    if (modal) { modal.classList.remove('hidden'); modal.classList.add('open'); }
  }

  function cerrarModalPN() {
    const modal = $('modalPN');
    if (modal) { modal.classList.add('hidden'); modal.classList.remove('open'); }
  }

  async function lanzarAProduccion() {
    const btn = $('btnLanzarPN');
    const errEl = $('pnError');
    if (errEl) errEl.style.display = 'none';

    const idProductoNuevo = $('pnId')?.value?.trim();
    const desc     = $('pnDesc')?.value?.trim();
    const marca    = $('pnMarca')?.value?.trim();
    const unidad   = $('pnUnidad')?.value;
    const catId    = $('pnCategoria')?.value;
    const pVenta   = parseFloat($('pnPrecioVenta')?.value || '0') || 0;
    const pCosto   = parseFloat($('pnPrecioCosto')?.value || '0') || 0;
    const stockMin = parseInt($('pnStockMin')?.value || '0') || 0;
    const usuario  = $('pnUsuario')?.value || (S.session?.nombre || 'MOS');
    const idGuia   = $('pnIdGuia')?.value || '';

    if (!desc)  { mostrarPNError('La descripción es obligatoria'); return; }
    if (!catId) { mostrarPNError('Selecciona una categoría'); return; }

    const pn = (S.pnPendientes || []).find(p => String(p.idProductoNuevo) === String(idProductoNuevo));
    const codigoBarra = pn?.codigoBarra || '';

    if (btn) { btn.disabled = true; btn.textContent = 'Procesando...'; }
    try {
      await API.lanzarProductoNuevo({
        idProductoNuevo,
        codigoBarra,
        descripcion: desc,
        marca,
        idCategoria: catId,
        unidad,
        precioVenta: pVenta,
        precioCosto: pCosto,
        stockMinimo: stockMin,
        stockMaximo: 0,
        esEnvasable: '0',
        usuario,
        aprobadoPor: S.session?.nombre || usuario,
        idGuia
      });

      S.pnPendientes = (S.pnPendientes || []).filter(p => String(p.idProductoNuevo) !== String(idProductoNuevo));
      _updatePNBadge();
      renderPNBanner();
      cerrarModalPN();
      toast('Producto lanzado a producción', 'ok');
      // Refrescar catálogo para mostrar el nuevo producto
      setTimeout(() => loadCatalogo(), 800);
    } catch(e) {
      mostrarPNError(e.message || 'Error al lanzar producto');
      if (btn) { btn.disabled = false; btn.textContent = 'Lanzar a producción'; }
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
        API.post('publicarPrecio', { idProducto: u.idProducto, precioNuevo: u.precio })
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
        API.post('publicarPrecio', { idProducto: u.idProducto, precioNuevo: u.precio })
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
      await API.post('actualizarProducto', { idProducto: id, stockMinimo: min, stockMaximo: max });
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
  async function loadAlmacen() {
    if (!API.isConfigured()) return;
    const [stockRes, alertasRes, mermasRes, envRes] = await Promise.allSettled([
      API.get('getStockWarehouse', {}),
      API.get('getAlertasWarehouse', {}),
      API.get('getMermasWarehouse', {}),
      API.get('getEnvasadosWarehouse', { limit: '50' })
    ]);
    if (stockRes.status === 'fulfilled') S.stock = stockRes.value || [];
    if (alertasRes.status === 'fulfilled') S.vencimientos = alertasRes.value || { criticos: [], alertas: [] };
    if (mermasRes.status === 'fulfilled') S.mermas = mermasRes.value || [];
    if (envRes.status === 'fulfilled')    S.envasados = envRes.value || [];
    renderAlmTab(S.almTab);
  }

  function setAlmTab(tab) {
    S.almTab = tab;
    ['stock','venc','merma','env'].forEach(t => {
      const b = $('almTab' + t.charAt(0).toUpperCase() + t.slice(1));
      if (b) b.classList.toggle('active', t === tab);
      const p = $('almPanel' + t.charAt(0).toUpperCase() + t.slice(1));
      if (p) p.classList.toggle('hidden', t !== tab);
    });
    if (!S.loaded['almacen']) { loadAlmacen(); return; }
    renderAlmTab(tab);
  }

  function renderAlmTab(tab) {
    if (tab === 'stock') renderStockTable();
    if (tab === 'venc')  renderVencTable();
    if (tab === 'merma') renderMermasTable();
    if (tab === 'env')   renderEnvTable();
  }

  function renderStockTable() {
    const tbody = $('tbodyStock');
    if (!tbody) return;
    if (!S.stock.length) {
      tbody.innerHTML = '<tr><td colspan="6" class="text-center py-8 text-slate-500 text-sm">Sin datos. Conecta warehouseMos.</td></tr>';
      return;
    }
    const sorted = [...S.stock].sort((a, b) => (a.alertaMinimo ? 0 : 1) - (b.alertaMinimo ? 0 : 1));
    tbody.innerHTML = sorted.map(s => {
      const badge = s.alertaMinimo
        ? '<span class="badge badge-red">Bajo</span>'
        : '<span class="badge badge-green">OK</span>';
      const dias = s.diasCobertura !== undefined && s.diasCobertura !== null
        ? `<span class="${s.diasCobertura <= 7 ? 'text-red-400' : s.diasCobertura <= 15 ? 'text-yellow-400' : 'text-slate-400'}">${s.diasCobertura}d</span>`
        : '<span class="text-slate-600">—</span>';
      return `<tr>
        <td><div class="font-medium text-slate-200 text-xs sm:text-sm">${s.descripcion || s.codigoProducto}</div></td>
        <td class="hidden sm:table-cell text-xs text-slate-500">${s.codigoProducto}</td>
        <td class="font-semibold">${parseFloat(s.cantidadDisponible || 0).toLocaleString()}</td>
        <td class="text-slate-500">${s.stockMinimo || 0}</td>
        <td>${dias}</td>
        <td>${badge}</td>
      </tr>`;
    }).join('');
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
  async function loadProveedores() {
    if (!API.isConfigured()) {
      $('listProveedores').innerHTML = '<p class="text-slate-500 text-sm text-center py-8">Configura el GAS URL.</p>';
      return;
    }
    S.proveedores = await API.get('getProveedores', {});
    const cnt = $('provCount'); if (cnt) cnt.textContent = S.proveedores.length;
    renderProveedores();
  }

  function renderProveedores() {
    const el = $('listProveedores');
    if (!el) return;
    if (!S.proveedores.length) {
      el.innerHTML = '<p class="text-slate-500 text-sm text-center py-8">Sin proveedores</p>';
      return;
    }
    el.innerHTML = S.proveedores.map(p => `
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
    S.provSelId = id;
    renderProveedores();

    const prov = S.proveedores.find(p => p.idProveedor === id);
    if (!prov) return;

    const detailEl = $('proveedorDetail');
    if (!detailEl) return;
    detailEl.innerHTML = `
      <div class="flex items-start justify-between mb-4">
        <div>
          <h3 class="font-bold text-white">${prov.nombre}</h3>
          <p class="text-sm text-slate-400">${prov.ruc || ''} — ${prov.email || ''}</p>
        </div>
        <div class="flex gap-2">
          <button class="btn-ghost text-xs" onclick="MOS.abrirModalProveedor('${id}')">✏️ Editar</button>
        </div>
      </div>
      <div class="grid sm:grid-cols-2 gap-3 mb-4">
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Banco: </span><span class="text-slate-200">${prov.banco || '—'}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Cuenta: </span><span class="text-slate-200">${prov.numeroCuenta || '—'}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Día pago: </span><span class="text-slate-200">${prov.diaPago || '—'}</span></div>
        <div class="card-sm p-3 text-sm"><span class="text-slate-500">Categoría: </span><span class="text-slate-200">${prov.categoriaProducto || '—'}</span></div>
      </div>
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm text-slate-300">Pagos registrados</h4>
        <button class="btn-primary text-xs px-3 py-1.5" onclick="MOS.abrirModalPago('${id}')">+ Pago</button>
      </div>
      <div id="listPagos" class="mb-4 text-sm text-slate-400">Cargando...</div>
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm text-slate-300">Pedidos de compra</h4>
        <button class="btn-ghost text-xs px-3 py-1.5" onclick="MOS.abrirModalPedido('${id}')">+ Pedido</button>
      </div>
      <div id="listPedidos" class="text-sm text-slate-400">Cargando...</div>
    `;

    // Load pagos + pedidos
    try {
      const [pagos, pedidos] = await Promise.all([
        API.get('getPagos', { idProveedor: id }),
        API.get('getPedidos', { idProveedor: id })
      ]);
      renderPagos(pagos || []);
      renderPedidos(pedidos || []);
    } catch (e) {
      const lp = $('listPagos'); if (lp) lp.textContent = 'Error: ' + e.message;
    }
  }

  function renderPagos(pagos) {
    const el = $('listPagos');
    if (!el) return;
    if (!pagos.length) { el.innerHTML = '<p class="text-slate-600">Sin pagos registrados</p>'; return; }
    const total = pagos.reduce((s, p) => s + parseFloat(p.monto || 0), 0);
    el.innerHTML = `<p class="text-xs text-slate-500 mb-2">Total: <span class="text-indigo-400 font-semibold">${fmtMoney(total)}</span></p>` +
      pagos.slice(-5).reverse().map(p => `
        <div class="flex justify-between items-center py-1.5 border-b border-slate-800/50">
          <div><span class="text-slate-300">${fmtDate(p.fecha)}</span><span class="text-slate-500 ml-2 text-xs">${p.numeroFactura || ''}</span></div>
          <span class="font-semibold text-green-400">${fmtMoney(p.monto)}</span>
        </div>
      `).join('');
  }

  function renderPedidos(pedidos) {
    const el = $('listPedidos');
    if (!el) return;
    if (!pedidos.length) { el.innerHTML = '<p class="text-slate-600">Sin pedidos registrados</p>'; return; }
    el.innerHTML = pedidos.slice(-5).reverse().map(p => {
      const badge = p.estado === 'BORRADOR' ? 'badge-gray' : p.estado === 'CONFIRMADO' ? 'badge-blue' : 'badge-green';
      return `<div class="flex justify-between items-center py-1.5 border-b border-slate-800/50">
        <div><span class="text-slate-300 text-xs">${p.idPedido}</span><span class="text-slate-500 ml-2 text-xs">${fmtDate(p.fechaCreacion)}</span></div>
        <div class="flex items-center gap-2">
          <span class="text-slate-300">${fmtMoney(p.montoEstimado)}</span>
          <span class="badge ${badge}">${p.estado}</span>
        </div>
      </div>`;
    }).join('');
  }

  // ── MODALS ──────────────────────────────────────────────────
  function openModal(id)  { const el = $(id); if (el) el.classList.add('open'); }
  function closeModal(id) { const el = $(id); if (el) el.classList.remove('open'); }

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

  // ── Product modal ──────────────────────────────────────────
  function abrirModalProducto(id) {
    const campos = ['Id','Descripcion','CodigoBarra','Marca','Categoria','Unidad',
                    'PrecioVenta','PrecioCosto','StockMin','StockMax','Zona',
                    'Base','Factor','Merma','EsEnvasable','CodTributo','IGV','CodSUNAT','TipoIGV'];
    campos.forEach(c => { const el = $('prod' + c); if (el && el.tagName !== 'SELECT') el.value = ''; });

    const equivSection = $('modalEquivSection');
    const equivList    = $('equivList');
    const equivForm    = $('equivAddForm');
    if (equivSection) equivSection.classList.add('hidden');
    if (equivList)    equivList.innerHTML = '';
    if (equivForm)    equivForm.classList.add('hidden');

    if (id) {
      const p = S.productos.find(x => x.idProducto === id);
      if (!p) return;
      $('modalProdTitle').textContent = 'Editar Producto';
      $('prodId').value              = p.idProducto;
      $('prodDescripcion').value     = p.descripcion || '';
      $('prodCodigoBarra').value     = p.codigoBarra || '';
      $('prodMarca').value           = p.marca || '';
      $('prodCategoria').value       = p.idCategoria || '';
      $('prodUnidad').value          = p.unidad || 'UNIDAD';
      $('prodPrecioVenta').value     = p.precioVenta || '';
      $('prodPrecioCosto').value     = p.precioCosto || '';
      $('prodStockMin').value        = p.stockMinimo || '';
      $('prodStockMax').value        = p.stockMaximo || '';
      $('prodZona').value            = p.zona || '';
      $('prodBase').value            = p.skuBase !== p.idProducto ? (p.skuBase || '') : '';
      $('prodFactor').value          = p.factorConversion || '';
      $('prodFactorConvBase').value  = p.factorConversionBase || '';
      const _fcbRow = $('prodFactorConvBaseRow');
      if (_fcbRow) _fcbRow.style.display = $('prodBase').value ? '' : 'none';
      $('prodMerma').value           = p.mermaEsperadaPct || '';
      $('prodEsEnvasable').value     = p.esEnvasable || '0';
      $('prodCodTributo').value      = p.Cod_Tributo || '';
      $('prodIGV').value             = p.IGV_Porcentaje || '';
      $('prodCodSUNAT').value        = p.Cod_SUNAT || '';
      $('prodTipoIGV').value         = p.Tipo_IGV || '';
      // Cargar equivalencias en background
      if (equivSection) equivSection.classList.remove('hidden');
      _loadEquivModal(p.skuBase || p.idProducto);
    } else {
      $('modalProdTitle').textContent = 'Nuevo Producto';
      $('prodId').value = '';
      $('prodUnidad').value = 'UNIDAD';
      $('prodEsEnvasable').value = '0';
    }
    openModal('modalProducto');
  }

  // Carga y renderiza equivalencias dentro del modal
  async function _loadEquivModal(skuBase) {
    const list = $('equivList');
    if (!list) return;
    list.innerHTML = '<div class="text-xs text-slate-600 italic py-1 px-1">Cargando...</div>';
    try {
      const rows = (await API.get('getEquivalencias', { skuBase })) || [];
      // Actualizar equivMap también
      S.equivMap[skuBase] = rows.filter(r => String(r.activo) === '1').length;
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
      await API.post('crearEquivalencia', { skuBase: sku, codigoBarra: codigo, descripcion: desc });
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

  async function toggleEquivActivo(idEquiv, skuBase, nuevoActivo) {
    try {
      await API.post('actualizarEquivalencia', { idEquiv, activo: nuevoActivo });
      await _loadEquivModal(skuBase);
      renderCatalogo();
    } catch(e) {
      toast('Error: ' + e.message, 'error');
    }
  }

  async function guardarProducto() {
    const params = {
      idProducto:          $('prodId')?.value || undefined,
      descripcion:         $('prodDescripcion')?.value || '',
      codigoBarra:         $('prodCodigoBarra')?.value || '',
      marca:               $('prodMarca')?.value || '',
      idCategoria:         $('prodCategoria')?.value || '',
      unidad:              $('prodUnidad')?.value || 'UNIDAD',
      precioVenta:         parseFloat($('prodPrecioVenta')?.value) || 0,
      precioCosto:         parseFloat($('prodPrecioCosto')?.value) || 0,
      stockMinimo:         parseFloat($('prodStockMin')?.value)    || 0,
      stockMaximo:         parseFloat($('prodStockMax')?.value)    || 0,
      zona:                $('prodZona')?.value || '',
      codigoProductoBase:    $('prodBase')?.value || '',
      factorConversion:      $('prodFactor')?.value         ? parseFloat($('prodFactor')?.value)         : '',
      factorConversionBase:  $('prodFactorConvBase')?.value ? parseFloat($('prodFactorConvBase')?.value) : '',
      mermaEsperadaPct:      $('prodMerma')?.value          ? parseFloat($('prodMerma')?.value)          : '',
      esEnvasable:         $('prodEsEnvasable')?.value || '0',
      Cod_Tributo:         $('prodCodTributo')?.value || '',
      IGV_Porcentaje:      $('prodIGV')?.value        ? parseFloat($('prodIGV')?.value)        : '',
      Cod_SUNAT:           $('prodCodSUNAT')?.value || '',
      Tipo_IGV:            $('prodTipoIGV')?.value || ''
    };

    if (!params.descripcion) { toast('La descripción es requerida', 'error'); return; }

    try {
      const action = params.idProducto ? 'actualizarProducto' : 'crearProducto';
      await API.post(action, params);
      toast(params.idProducto ? 'Producto actualizado' : 'Producto creado', 'ok');
      closeModal('modalProducto');
      S.loaded['catalogo'] = false;
      await loadCatalogo();
    } catch (e) {
      toast('Error: ' + e.message, 'error');
    }
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
        idProducto: id, skuBase: p?.skuBase, codigoBarra: p?.codigoBarra,
        descripcion: p?.descripcion, precioNuevo: nuevo,
        motivo, imprimirMembretes: memb
      });
      toast('Precio publicado: ' + fmtMoney(nuevo), 'ok');
      S.loaded['catalogo'] = false;
      loadCatalogo(); // background refresh
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

  function abrirModalPedido(idProveedor) {
    toast('Pedidos: próximamente desde esta vista', 'info');
  }

  // ── CONFIGURACIÓN ────────────────────────────────────────────
  let cfgData = { zonas: [], estaciones: [], impresoras: [], personal: [], personalMOS: [], series: [], dispositivos: [] };

  async function loadConfig() {
    S.cfgTab = S.cfgTab || 'zonas';
    const [zonRes, estRes, impRes, persRes, persMOSRes, serRes, dispRes] = await Promise.allSettled([
      API.get('getZonas', {}),
      API.get('getEstaciones', {}),
      API.get('getImpresoras', {}),
      API.get('getPersonalMaster', { appOrigen: 'warehouseMos' }),
      API.get('getPersonalMaster', { appOrigen: 'MOS' }),
      API.get('getSeries', {}),
      API.get('getDispositivos', {})
    ]);
    cfgData.zonas        = zonRes.status      === 'fulfilled' ? (zonRes.value      || []) : [];
    cfgData.estaciones   = estRes.status      === 'fulfilled' ? (estRes.value      || []) : [];
    cfgData.impresoras   = impRes.status      === 'fulfilled' ? (impRes.value      || []) : [];
    cfgData.personal     = persRes.status     === 'fulfilled' ? (persRes.value     || []) : [];
    cfgData.personalMOS  = persMOSRes.status  === 'fulfilled' ? (persMOSRes.value  || []) : [];
    cfgData.series       = serRes.status      === 'fulfilled' ? (serRes.value      || []) : [];
    cfgData.dispositivos = dispRes.status     === 'fulfilled' ? (dispRes.value     || []) : [];
    renderCfgTab(S.cfgTab);
  }

  function setCfgTab(tab) {
    S.cfgTab = tab;
    const tabs = ['zonas','estaciones','impresoras','personal','series','seguridad','dispositivos'];
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
    }
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
          <td class="flex gap-1.5 items-center flex-wrap">
            <a href="${c.urlReporte||'#'}" target="_blank" rel="noopener" class="btn-primary text-xs px-3 py-1.5 inline-block" style="text-decoration:none">📊 Reporte</a>
            <button onclick="MOS.abrirModalTicketZ('${c.idCaja}')" class="btn-ghost text-xs px-3 py-1.5">🖨 Z</button>
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
            <td class="flex gap-1.5 items-center flex-wrap">
              <a href="${c.urlReporte}" target="_blank" rel="noopener"
                 class="btn-primary text-xs px-3 py-1.5 inline-block" style="text-decoration:none">
                📊 Reporte
              </a>
              <button onclick="MOS.abrirModalTicketZ('${c.idCaja}')" class="btn-ghost text-xs px-3 py-1.5">🖨 Z</button>
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
              <td class="flex gap-1.5 items-center flex-wrap">
                <a href="${c.urlReporte||'#'}" target="_blank" rel="noopener" class="btn-primary text-xs px-3 py-1.5 inline-block" style="text-decoration:none">📊 Reporte</a>
                <button onclick="MOS.abrirModalTicketZ('${c.idCaja}')" class="btn-ghost text-xs px-3 py-1.5">🖨 Z</button>
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

  // ── TICKET Z — REIMPRESION ───────────────────────────────────
  let _ticketZCajaId = null;

  async function abrirModalTicketZ(idCaja) {
    if (!idCaja) { toast('Sin idCaja', 'error'); return; }
    _ticketZCajaId = idCaja;

    // Buscar la caja en los datos ya cargados
    const caja = (S._todasCajas || []).find(c => c.idCaja === idCaja);

    // Cargar impresoras/estaciones si aún no están disponibles
    if (!cfgData.impresoras.length || !cfgData.estaciones.length) {
      try {
        const [impRes, estRes] = await Promise.all([
          API.get('getImpresoras', {}),
          API.get('getEstaciones', {})
        ]);
        cfgData.impresoras = impRes || [];
        cfgData.estaciones = estRes || [];
      } catch(e) { /* se manejará luego como lista vacía */ }
    }

    // ── Previsualización: mostrar loading y abrir modal ya ──────
    const prev = $('tzPreview');
    if (prev) {
      prev.innerHTML = `<div class="tz-ticket" style="text-align:center;color:#999;padding:24px 0">
        <div style="font-size:1.2rem;margin-bottom:6px">⏳</div>
        <div style="font-size:11px">Cargando ticket...</div>
      </div>`;
    }
    openModal('modalTicketZ');

    // ── Cargar texto completo del ticket desde GAS ──────────────
    try {
      const res = await API.get('getTicketZTexto', { idCaja });
      if (prev) {
        if (res?.texto) {
          // Escapar HTML para mostrar en <pre>
          const escaped = res.texto
            .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
          prev.innerHTML = `<div class="tz-ticket tz-ticket-pre"><pre class="tz-pre">${escaped}</pre></div>`;
        } else {
          prev.innerHTML = `<div class="tz-ticket"><div class="tz-note">${res?.error || 'Sin datos'}</div></div>`;
        }
      }
    } catch(e) {
      if (prev) prev.innerHTML = `<div class="tz-ticket"><div class="tz-note">Error: ${e.message}</div></div>`;
    }

    // ── Botones de estaciones (impresoras TICKET activas) ────────
    const btns = $('tzEstacionBtns');
    if (btns) {
      const ticketPrinters = cfgData.impresoras.filter(
        i => i.tipo === 'TICKET' && i.printNodeId && String(i.activo) === '1'
      );
      if (ticketPrinters.length === 0) {
        btns.innerHTML = '<p class="text-slate-500 text-sm text-center py-3">Sin impresoras TICKET activas configuradas.</p>';
      } else {
        btns.innerHTML = ticketPrinters.map(imp => {
          const est   = cfgData.estaciones.find(e => e.idEstacion === imp.idEstacion);
          const label = est ? est.nombre : imp.nombre;
          const sub   = est ? imp.nombre : '';
          const zona  = imp.idZona || '';
          return `<button onclick="MOS.imprimirTicketZ('${imp.printNodeId}','${(est?.nombre||'').replace(/'/g,"\\'")}','${imp.idImpresora}')"
                    class="tz-imp-btn" data-pid="${imp.printNodeId}">
                    <span class="tz-imp-icon">🖨</span>
                    <span class="tz-imp-info">
                      <span class="tz-imp-name">${label}</span>
                      ${sub ? `<span class="tz-imp-sub">${sub}</span>` : ''}
                    </span>
                    ${zona ? `<span class="tz-imp-zona">${zona}</span>` : ''}
                  </button>`;
        }).join('');
      }
    }
  }

  async function imprimirTicketZ(printerId, estacionNombre, idImpresora) {
    if (!printerId) { toast('Sin impresora', 'error'); return; }
    if (!_ticketZCajaId) { toast('Sin caja seleccionada', 'error'); return; }

    // Deshabilitar todos los botones mientras imprime
    const allBtns = $('tzEstacionBtns')?.querySelectorAll('button') || [];
    allBtns.forEach(b => { b.disabled = true; });
    const activeBtn = $('tzEstacionBtns')?.querySelector(`[data-pid="${printerId}"]`);
    if (activeBtn) activeBtn.textContent = '⏳ Enviando...';

    try {
      await API.post('imprimirTicketZCierre', {
        idCaja: _ticketZCajaId,
        printerId,
        estacion: estacionNombre || ''
      });
      toast('Ticket Z enviado ✓', 'ok');
      closeModal('modalTicketZ');
    } catch(e) {
      toast('Error: ' + e.message, 'error');
      allBtns.forEach(b => { b.disabled = false; });
      if (activeBtn) {
        const est = cfgData.estaciones.find(en => {
          const imp = cfgData.impresoras.find(i => i.idImpresora === idImpresora);
          return imp && en.idEstacion === imp.idEstacion;
        });
        activeBtn.innerHTML = `<span class="tz-imp-icon">🖨</span><span class="tz-imp-info"><span class="tz-imp-name">${estacionNombre || printerId}</span></span>`;
      }
    }
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

  async function _pushInit(nombre, rol, askPermission = false) {
    console.log('[Push] init — firebase:', !!window.firebase, '| Notification:', typeof Notification !== 'undefined' ? Notification.permission : 'N/A', '| ask:', askPermission);
    if (!window.firebase || !('Notification' in window) || !('serviceWorker' in navigator)) {
      console.warn('[Push] requisitos no cumplidos, saliendo');
      return;
    }
    try {
      if (!firebase.apps.length) firebase.initializeApp(_PUSH_CONFIG);
      const messaging  = firebase.messaging();
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

      // Mostrar notificaciones en primer plano como toast
      messaging.onMessage(payload => {
        const t = payload.notification?.title || '';
        const b = payload.notification?.body  || '';
        toast('🔔 ' + t + (b ? ': ' + b : ''), 'ok');
      });
      console.log('[Push] token registrado en GAS ✅');
    } catch(e) {
      console.error('[Push] ERROR:', e.message);
    }
  }

  // ── PUBLIC API ───────────────────────────────────────────────
  return {
    init, nav, refresh, fabAction,
    openConfig, saveConfig, testConnection, closeModal, openEcoModal,
    filterCatalogo, setCatTab, toggleDerivs, togglePresentaciones, guardarPrecioRapido,
    abrirModalPN, cerrarModalPN, lanzarAProduccion,
    abrirModalPrecioRapido, cerrarModalPrecioRapido, _qpSyncPresentaciones,
    abrirAnalitica, cerrarAnalitica, setAnPeriodo, guardarStockMinMax, _anCurrentId,
    guardarAjustePrecios, stepperInc, stepperDec,
    abrirModalProducto, guardarProducto,
    toggleAddEquiv, crearEquivalenciaModal, toggleEquivActivo,
    abrirModalPrecio, publicarPrecio,
    setAlmTab,
    loadProveedores, selectProveedor, renderProveedores,
    abrirModalProveedor, guardarProveedor,
    abrirModalPago, guardarPago, abrirModalPedido,
    // Config
    setCfgTab,
    abrirModalZona, guardarZona,
    abrirModalEstacion, guardarEstacion,
    abrirModalImpresora, guardarImpresora,
    abrirModalPersonal, guardarPersonal,
    abrirModalSerie, guardarSerie,
    guardarPinEstacion, guardarPinWH,
    abrirModalDispositivo, cerrarModalDispositivo, guardarDispositivo, toggleEstadoDispositivo,
    toggleAvatarMenu, closeAvatarMenu, installPWA,
    // Cajas
    loadCajas, toggleCajaDetail, toggleKpiVentas,
    toggleKpiTickets, setTicketFiltroFecha, setTicketFiltroEstado, setTicketFiltroTipo,
    confirmarAnularTicket, abrirModalMetodo, cerrarModalMetodo, aplicarCambioMetodo,
    _selMetodo, _onMixtoInput, _renderModalMetodo,
    abrirModalTicketZ, imprimirTicketZ,
    // Login / sesión
    seleccionarUsuario, loginVolver, confirmarPin, logout, lockScreen, _np,
    syncApp, applyPendingUpdate,
    // Finanzas
    finCargar, finDia, finAbrirModalGasto, finAbrirModalJornada, finGuardarGasto,
    finGuardarJornada, finEliminarGasto, finEliminarJornada, finImportarCajas,
    cerrarModalFin,
    finEditarCostoSku, finCerrarCostoEditor, finGuardarCostoSku,
    // Finanzas — modales detalle
    finAbrirModalProductos, finToggleFiltroSinCosto,
    finEditarCostoProd, finCerrarCostoProd, finGuardarCostoProd,
    finAbrirModalTickets, finSetTicketFiltro
  };
})();
