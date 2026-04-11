// MOS Admin — app.js
// Full app logic: navigation, views, charts, CRUD

const MOS = (() => {
  // ── STATE ────────────────────────────────────────────────────
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
    loaded: {}
  };

  // ── HELPERS ─────────────────────────────────────────────────
  const $  = id => document.getElementById(id);
  const fmtMoney = v => 'S/. ' + parseFloat(v || 0).toFixed(2);
  const fmtDate  = v => v ? String(v).substring(0, 10) : '—';
  const today    = () => new Date().toISOString().substring(0, 10);

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

    const titles = { dashboard:'Dashboard', catalogo:'Catálogo', almacen:'Almacén', proveedores:'Proveedores', cajas:'Cajas', config:'Configuración' };
    const t = titles[viewName] || viewName;
    const pt = $('pageTitle'); if (pt) pt.textContent = t;
    const ptd = $('pageTitleDesktop'); if (ptd) ptd.textContent = t;

    // FAB visibility
    const fab = $('fab');
    if (fab) fab.classList.toggle('visible', ['catalogo','proveedores'].includes(viewName));

    // Config: show first panel
    if (viewName === 'config') {
      setCfgTab(S.cfgTab || 'estaciones');
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

    if (!API.isConfigured()) {
      const b = $('bannerNoUrl'); if (b) b.classList.remove('hidden');
      setStatus(false);
    } else {
      setStatus(true);
    }

    // Set today on date inputs
    const pf = $('pagoFecha'); if (pf) pf.value = today();

    // Initial view
    nav('dashboard');
    loadView('dashboard');
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
        case 'cajas':        await loadCajas();        break;
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

  // ── DASHBOARD ───────────────────────────────────────────────
  async function loadDashboard() {
    if (!API.isConfigured()) return;

    // Load in parallel
    const [rotRes, alertasRes, mermasRes, prodRes] = await Promise.allSettled([
      API.get('getRotacion', {}),
      API.get('getAlertasWarehouse', {}),
      API.get('getMermasWarehouse', { estado: 'PENDIENTE' }),
      API.get('getProductos', { estado: '1' })
    ]);

    // Ecosystem status
    const ecoWhDot   = $('ecoWhDot');
    const ecoWhLabel = $('ecoWhLabel');

    // KPI — stock bajo
    const rot = rotRes.status === 'fulfilled' ? rotRes.value : [];
    const stockBajo = Array.isArray(rot) ? rot.filter(r => r.alertaMinimo).length : 0;
    const kpiSV = $('kpiStockVal');
    if (kpiSV) { kpiSV.textContent = stockBajo; }
    if (stockBajo > 0) {
      const b = $('kpiStockBadge'); if (b) b.classList.remove('hidden');
    }

    // Update ecosystem WH status
    if (ecoWhDot && ecoWhLabel) {
      if (rotRes.status === 'fulfilled') {
        ecoWhDot.className = 'dot-green'; ecoWhLabel.textContent = 'Conectado';
        setStatus(true);
      } else {
        ecoWhDot.className = 'dot-red';
        ecoWhLabel.textContent = rotRes.reason?.message?.includes('WH_SS_ID') ? 'Sin configurar' : 'Error';
      }
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

  // ── CATÁLOGO ────────────────────────────────────────────────
  async function loadCatalogo() {
    if (!API.isConfigured()) {
      $('listCatalogo').innerHTML = '<p class="text-slate-500 text-sm text-center py-8">Configura el GAS URL para ver el catálogo.</p>';
      return;
    }
    try {
      const [prods] = await Promise.all([API.get('getProductos', {})]);
      S.productos = prods || [];
      // Load categories
      try {
        const cats = await API.get('getProductos', { soloCategoria: '1' });
      } catch(e) {}
      populateCatFiltro();
      renderCatalogo();
    } catch (e) {
      $('listCatalogo').innerHTML = `<p class="text-red-400 text-sm text-center py-8">${e.message}</p>`;
      throw e;
    }
  }

  function populateCatFiltro() {
    const sel = $('filtroCategoria');
    if (!sel) return;
    const cats = [...new Set(S.productos.map(p => p.idCategoria).filter(Boolean))].sort();
    sel.innerHTML = '<option value="">Todas las categorías</option>' +
      cats.map(c => `<option value="${c}">${c}</option>`).join('');

    // Also fill product category select in modal
    const prodCat = $('prodCategoria');
    if (prodCat) {
      prodCat.innerHTML = '<option value="">— seleccionar —</option>' +
        cats.map(c => `<option value="${c}">${c}</option>`).join('');
    }
  }

  function filterCatalogo() { renderCatalogo(); }

  function setCatTab(tab) {
    S.catTab = tab;
    ['base','deriv','todos'].forEach(t => {
      const b = $('tab' + (t === 'base' ? 'Base' : t === 'deriv' ? 'Deriv' : 'Todos') + 'Btn');
      if (b) b.classList.toggle('active', t === tab);
    });
    renderCatalogo();
  }

  function renderCatalogo() {
    const container = $('listCatalogo');
    if (!container) return;

    const q    = ($('searchCatalogo')?.value || '').toLowerCase();
    const cat  = $('filtroCategoria')?.value || '';

    let prods = S.productos.filter(p => {
      if (cat && p.idCategoria !== cat) return false;
      if (q) {
        const hay = ((p.descripcion || '') + (p.codigoBarra || '') + (p.skuBase || '') + (p.marca || '')).toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });

    if (S.catTab === 'base')  prods = prods.filter(p => !p.codigoProductoBase || p.codigoProductoBase === '');
    if (S.catTab === 'deriv') prods = prods.filter(p => p.codigoProductoBase && p.codigoProductoBase !== '');

    if (!prods.length) {
      container.innerHTML = '<p class="text-slate-500 text-sm text-center py-12">Sin resultados</p>';
      return;
    }

    // Group: base products + their presentaciones
    if (S.catTab === 'base' || S.catTab === 'todos') {
      const bases      = prods.filter(p => !p.codigoProductoBase || p.codigoProductoBase === '');
      const derivados  = S.productos.filter(p => p.codigoProductoBase && p.codigoProductoBase !== '');

      container.innerHTML = bases.map(base => {
        const derivs = derivados.filter(d => d.codigoProductoBase === base.idProducto);
        return `
          <div class="card mb-2 overflow-hidden">
            <div class="flex items-center gap-3 p-3 cursor-pointer hover:bg-slate-800/30" onclick="MOS.toggleDerivs('${base.idProducto}')">
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="font-medium text-slate-200 text-sm">${base.descripcion || '—'}</span>
                  ${base.marca ? `<span class="text-xs text-slate-500">${base.marca}</span>` : ''}
                  <span class="badge badge-blue text-xs">${base.unidad || ''}</span>
                  ${!base.estado || base.estado == '1' ? '' : '<span class="badge badge-gray">inactivo</span>'}
                </div>
                <div class="flex items-center gap-3 mt-1">
                  <span class="text-xs text-slate-500">${base.idProducto}</span>
                  ${base.codigoBarra ? `<span class="text-xs text-slate-600">☰ ${base.codigoBarra}</span>` : ''}
                </div>
              </div>
              <div class="flex items-center gap-3 shrink-0">
                <div class="text-right hidden sm:block">
                  <div class="text-sm font-semibold text-indigo-400">${fmtMoney(base.precioVenta)}</div>
                  <div class="text-xs text-slate-500">Costo: ${fmtMoney(base.precioCosto)}</div>
                </div>
                <button onclick="event.stopPropagation();MOS.abrirModalPrecio('${base.idProducto}')" class="text-xs text-slate-400 hover:text-indigo-400 px-2 py-1 rounded border border-slate-700 hover:border-indigo-500 transition-colors">💰</button>
                <button onclick="event.stopPropagation();MOS.abrirModalProducto('${base.idProducto}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700 hover:border-slate-500 transition-colors">✏️</button>
              </div>
            </div>
            ${derivs.length ? `
              <div id="derivs-${base.idProducto}" class="hidden border-t border-slate-800 px-3 py-2">
                <div class="text-xs text-slate-500 mb-2">Presentaciones (${derivs.length})</div>
                <div class="flex flex-wrap gap-2">
                  ${derivs.map(d => `
                    <div class="presentacion-chip cursor-pointer hover:bg-indigo-500/20" onclick="MOS.abrirModalProducto('${d.idProducto}')">
                      ${d.descripcion || d.idProducto}
                      <span class="text-indigo-300 ml-1">${fmtMoney(d.precioVenta)}</span>
                    </div>
                  `).join('')}
                </div>
              </div>
            ` : ''}
          </div>
        `;
      }).join('');
    } else {
      container.innerHTML = prods.map(p => `
        <div class="card mb-2 p-3 flex items-center gap-3 hover:bg-slate-800/20">
          <div class="flex-1 min-w-0">
            <div class="font-medium text-slate-200 text-sm">${p.descripcion || '—'}</div>
            <div class="flex items-center gap-2 mt-0.5">
              <span class="text-xs text-slate-500">${p.idProducto}</span>
              ${p.codigoProductoBase ? `<span class="text-xs text-slate-600">Base: ${p.codigoProductoBase}</span>` : ''}
            </div>
          </div>
          <div class="text-sm font-semibold text-indigo-400 shrink-0">${fmtMoney(p.precioVenta)}</div>
          <button onclick="MOS.abrirModalPrecio('${p.idProducto}')" class="text-xs text-slate-400 hover:text-indigo-400 px-2 py-1 rounded border border-slate-700">💰</button>
          <button onclick="MOS.abrirModalProducto('${p.idProducto}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700">✏️</button>
        </div>
      `).join('');
    }
  }

  function toggleDerivs(baseId) {
    const el = $('derivs-' + baseId);
    if (el) el.classList.toggle('hidden');
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

  // Product modal
  function abrirModalProducto(id) {
    const campos = ['Id','Descripcion','CodigoBarra','Marca','Categoria','Unidad',
                    'PrecioVenta','PrecioCosto','StockMin','StockMax','Zona',
                    'Base','Factor','Merma','EsEnvasable','CodTributo','IGV','CodSUNAT','TipoIGV'];
    campos.forEach(c => { const el = $('prod' + c); if (el && el.tagName !== 'SELECT') el.value = ''; });

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
      $('prodBase').value            = p.codigoProductoBase || '';
      $('prodFactor').value          = p.factorConversion || '';
      $('prodMerma').value           = p.mermaEsperadaPct || '';
      $('prodEsEnvasable').value     = p.esEnvasable || '0';
      $('prodCodTributo').value      = p.Cod_Tributo || '';
      $('prodIGV').value             = p.IGV_Porcentaje || '';
      $('prodCodSUNAT').value        = p.Cod_SUNAT || '';
      $('prodTipoIGV').value         = p.Tipo_IGV || '';
    } else {
      $('modalProdTitle').textContent = 'Nuevo Producto';
      $('prodId').value = '';
      $('prodUnidad').value = 'UNIDAD';
      $('prodEsEnvasable').value = '0';
    }
    openModal('modalProducto');
  }

  async function guardarProducto() {
    const params = {
      idProducto:          $('prodId')?.value || undefined,
      descripcion:         $('prodDescripcion')?.value || '',
      codigoBarra:         $('prodCodigoBarra')?.value || '',
      marca:               $('prodMarca')?.value || '',
      idCategoria:         $('prodCategoria')?.value || '',
      unidad:              $('prodUnidad')?.value || 'UNIDAD',
      precioVenta:         $('prodPrecioVenta')?.value || 0,
      precioCosto:         $('prodPrecioCosto')?.value || 0,
      stockMinimo:         $('prodStockMin')?.value || 0,
      stockMaximo:         $('prodStockMax')?.value || 0,
      zona:                $('prodZona')?.value || '',
      codigoProductoBase:  $('prodBase')?.value || '',
      factorConversion:    $('prodFactor')?.value || '',
      mermaEsperadaPct:    $('prodMerma')?.value || '',
      esEnvasable:         $('prodEsEnvasable')?.value || '0',
      Cod_Tributo:         $('prodCodTributo')?.value || '',
      IGV_Porcentaje:      $('prodIGV')?.value || '',
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
    try {
      await API.post('publicarPrecio', {
        idProducto: id, skuBase: p?.skuBase, codigoBarra: p?.codigoBarra,
        descripcion: p?.descripcion, precioNuevo: nuevo,
        motivo, imprimirMembretes: memb
      });
      toast('Precio publicado: ' + fmtMoney(nuevo), 'ok');
      closeModal('modalPrecio');
      S.loaded['catalogo'] = false;
      await loadCatalogo();
    } catch (e) {
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
  let cfgData = { estaciones: [], impresoras: [], personal: [], series: [] };

  async function loadConfig() {
    if (!API.isConfigured()) return;
    S.cfgTab = S.cfgTab || 'estaciones';
    const [estRes, impRes, persRes, serRes] = await Promise.allSettled([
      API.get('getEstaciones', {}),
      API.get('getImpresoras', {}),
      API.get('getPersonalMaster', { tipo: 'OPERADOR' }),
      API.get('getSeries', {})
    ]);
    cfgData.estaciones = estRes.status === 'fulfilled' ? (estRes.value || []) : [];
    cfgData.impresoras = impRes.status === 'fulfilled' ? (impRes.value || []) : [];
    cfgData.personal   = persRes.status === 'fulfilled' ? (persRes.value || []) : [];
    cfgData.series     = serRes.status === 'fulfilled' ? (serRes.value || []) : [];
    renderCfgTab(S.cfgTab);
  }

  function setCfgTab(tab) {
    S.cfgTab = tab;
    const tabs = ['estaciones','impresoras','personal','series','seguridad'];
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
      case 'estaciones': renderEstaciones();  break;
      case 'impresoras': renderImpresoras();  break;
      case 'personal':   renderPersonal();    break;
      case 'series':     renderSeries();      break;
      case 'seguridad':  renderSeguridad();   break;
    }
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
          <button onclick="MOS.abrirModalPersonal('${p.idPersonal}')" class="text-xs text-slate-400 hover:text-white px-2 py-1 rounded border border-slate-700 ml-1">✏️</button>
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

  // Config CRUD
  function abrirModalEstacion(id) {
    ['Id','Nombre','Zona','Tipo','App','Pin','Desc'].forEach(f => {
      const el = $('est' + f); if (el && el.tagName !== 'SELECT') el.value = '';
    });
    if (id) {
      const e = cfgData.estaciones.find(x => x.idEstacion === id);
      if (!e) return;
      $('modalEstTitle').textContent = 'Editar Estación';
      $('estId').value     = e.idEstacion;
      $('estNombre').value = e.nombre || '';
      $('estZona').value   = e.idZona || '';
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

  function abrirModalPersonal(id) {
    ['Id','Nombre','Apellido','Pin','Tarifa','Monto'].forEach(f => {
      const el = $('pers' + f); if (el && el.tagName !== 'SELECT') el.value = '';
    });
    if (id) {
      const p = cfgData.personal.find(x => x.idPersonal === id);
      if (!p) return;
      $('modalPersTitle').textContent = 'Editar Operador';
      $('persId').value       = p.idPersonal;
      $('persNombre').value   = p.nombre || '';
      $('persApellido').value = p.apellido || '';
      $('persRol').value      = p.rol || 'ALMACENERO';
      $('persColor').value    = p.color || '#6366f1';
      $('persTarifa').value   = p.tarifaHora || '';
      $('persMonto').value    = p.montoBase || '';
    } else {
      $('modalPersTitle').textContent = 'Nuevo Operador';
      $('persId').value = '';
      $('persRol').value = 'ALMACENERO';
      $('persColor').value = '#6366f1';
    }
    openModal('modalPersonal');
  }

  async function guardarPersonal() {
    const params = {
      idPersonal:  $('persId')?.value || undefined,
      nombre:      $('persNombre')?.value || '',
      apellido:    $('persApellido')?.value || '',
      rol:         $('persRol')?.value || 'ALMACENERO',
      color:       $('persColor')?.value || '#6366f1',
      tarifaHora:  $('persTarifa')?.value || 0,
      montoBase:   $('persMonto')?.value || 0,
      tipo:        'OPERADOR',
      appOrigen:   'warehouseMos'
    };
    const pin = $('persPin')?.value;
    if (pin) params.pin = pin;
    if (!params.nombre) { toast('Nombre requerido', 'error'); return; }
    if (!params.idPersonal && !pin) { toast('PIN requerido para nuevos operadores', 'error'); return; }
    try {
      await API.post(params.idPersonal ? 'actualizarPersonalMaster' : 'crearPersonalMaster', params);
      toast(params.idPersonal ? 'Operador actualizado' : 'Operador creado', 'ok');
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

  // ── CAJAS ────────────────────────────────────────────────────
  async function loadCajas(force) {
    if (!force && S.loaded['cajas']) return;
    S.loaded['cajas'] = true;

    const loading  = $('cajasLoading');
    const content  = $('cajasContent');
    const empty    = $('cajasEmpty');

    loading?.classList.remove('hidden');
    content?.classList.add('hidden');

    try {
      const res = await API.get('getCierresCaja', {});
      // API.get ya desenvuelve d.data, así que res = { kpis, abiertas, cerradas, generadoEn }

      loading?.classList.add('hidden');
      content?.classList.remove('hidden');

      const { kpis, abiertas = [], cerradas = [], generadoEn } = res || {};

      // Timestamp
      const ts = $('cajasTimestamp');
      if (ts) ts.textContent = 'Actualizado: ' + (generadoEn || '—');

      // ── KPIs ────────────────────────────────────────────────
      const set = (id, v) => { const el=$(id); if(el) el.textContent=v; };
      set('cajasKpiVentas',   fmtMoney(kpis?.totalDia || 0));
      set('cajasKpiTickets',  kpis?.ticketsDia || 0);
      set('cajasKpiAbiertas', kpis?.cajasAbiertas || 0);
      set('cajasKpiCerradas', kpis?.cajasCerradas || 0);
      set('cajasKpiAnulados', kpis?.anuladosDia   || 0);

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
        vivoGrid.innerHTML = abiertas.map(c => {
          const elapsed  = _cajaElapsed(c.fechaApertura);
          const pctEfect = c.totalVentas > 0 ? Math.round(c.efectivo / c.totalVentas * 100) : 0;
          const pctOtros = 100 - pctEfect;
          const metodos  = Object.entries(c.byMetodo || {})
            .sort((a,b) => b[1]-a[1])
            .map(([k,v]) => `<span class="text-xs text-slate-400">${k}: <span class="text-slate-200 font-medium">${fmtMoney(v)}</span></span>`)
            .join('');
          return `
          <div class="card p-4" style="border-left:3px solid #22c55e">
            <div class="flex items-start justify-between mb-3">
              <div>
                <div class="font-semibold text-white text-base">${c.vendedor || '—'}</div>
                <div class="text-xs text-slate-400">${c.zona || c.estacion || '—'} · <span class="text-emerald-400">⏱ ${elapsed}</span></div>
              </div>
              <span class="badge badge-green">ABIERTA</span>
            </div>
            <div class="grid grid-cols-3 gap-2 mb-3">
              <div class="card-sm p-2 text-center">
                <div class="text-lg font-bold text-white">${fmtMoney(c.totalVentas)}</div>
                <div class="text-xs text-slate-500">Total</div>
              </div>
              <div class="card-sm p-2 text-center">
                <div class="text-lg font-bold text-emerald-400">${c.tickets}</div>
                <div class="text-xs text-slate-500">Tickets</div>
              </div>
              <div class="card-sm p-2 text-center">
                <div class="text-lg font-bold ${c.anulados > 0 ? 'text-red-400' : 'text-slate-400'}">${c.anulados}</div>
                <div class="text-xs text-slate-500">Anulados</div>
              </div>
            </div>
            <!-- Mini barra efectivo vs otros -->
            <div class="mb-2">
              <div class="flex justify-between text-xs text-slate-500 mb-1">
                <span>Efectivo ${pctEfect}%</span><span>Otros ${pctOtros}%</span>
              </div>
              <div class="flex rounded-full overflow-hidden h-2" style="background:#1e293b">
                <div style="width:${pctEfect}%;background:#22c55e"></div>
                <div style="width:${pctOtros}%;background:#6366f1"></div>
              </div>
            </div>
            <div class="flex flex-wrap gap-x-3 gap-y-1 mt-2">${metodos}</div>
            ${c.sinCobrar > 0 ? `<div class="mt-2 text-xs text-yellow-400">⏳ ${c.sinCobrar} sin cobrar</div>` : ''}
          </div>`;
        }).join('');
      } else if (vivoWrap) {
        vivoWrap.classList.add('hidden');
      }

      // ── Gráficos ─────────────────────────────────────────────
      const chartsWrap = $('cajasChartsWrap');
      const todos      = [...abiertas, ...cerradas];
      if (todos.length > 0 && chartsWrap) {
        chartsWrap.classList.remove('hidden');

        // Bar: ventas por cajero
        renderChart('chartCajasBars', {
          type: 'bar',
          data: {
            labels:   todos.map(c => c.vendedor || c.idCaja),
            datasets: [{
              label: 'Vendido',
              data:  todos.map(c => c.totalVentas),
              backgroundColor: todos.map(c => c.estado === 'ABIERTA' ? '#22c55e' : '#6366f1'),
              borderRadius: 5
            }]
          },
          options: {
            responsive: true, maintainAspectRatio: false,
            plugins: { legend: { display: false } },
            scales: { y: { ticks: { callback: v => 'S/'+v, font: { size: 11 } } },
                      x: { ticks: { font: { size: 11 } } } }
          }
        });

        // Donut: métodos de pago acumulados del día
        const metAcum = {};
        todos.forEach(c => Object.entries(c.byMetodo || {}).forEach(([k,v]) => {
          metAcum[k] = (metAcum[k] || 0) + v;
        }));
        const metKeys = Object.keys(metAcum);
        if (metKeys.length > 0) {
          renderChart('chartCajasMetodo', {
            type: 'doughnut',
            data: {
              labels: metKeys,
              datasets: [{ data: metKeys.map(k => metAcum[k]),
                backgroundColor: ['#22c55e','#6366f1','#f59e0b','#ef4444','#0ea5e9'],
                borderWidth: 2, borderColor: '#0f172a' }]
            },
            options: {
              responsive: true, maintainAspectRatio: false,
              plugins: { legend: { position: 'bottom', labels: { font:{ size:11 }, padding:8, boxWidth:12 } } }
            }
          });
        }
      }

      // ── Historial cierres del día ─────────────────────────────
      const histWrap  = $('cajasHistorialWrap');
      const histTbody = $('cajasHistTbody');
      if (cerradas.length > 0 && histWrap && histTbody) {
        histWrap.classList.remove('hidden');
        histTbody.innerHTML = cerradas.map(c => {
          const dif    = c.diferencia;
          const difCls = dif === null ? 'badge-gray' : dif > 0.05 ? 'badge-green' : dif < -0.05 ? 'badge-red' : 'badge-green';
          const difStr = dif === null ? '—' : (dif >= 0 ? '+' : '') + fmtMoney(dif);
          const hora   = s => (s || '').substring(11, 16);
          return `<tr>
            <td class="font-medium">${c.vendedor || '—'}</td>
            <td><span class="badge badge-blue">${c.zona || c.estacion || '—'}</span></td>
            <td class="text-slate-400 text-xs">${hora(c.fechaApertura)} → ${hora(c.fechaCierre)}</td>
            <td class="font-semibold">${fmtMoney(c.totalVentas)}</td>
            <td class="text-center">${c.tickets}</td>
            <td><span class="badge ${difCls}">${difStr}</span></td>
            <td>
              <a href="${c.urlReporte}" target="_blank" rel="noopener"
                 class="btn-primary text-xs px-3 py-1.5 inline-block" style="text-decoration:none">
                📊 Reporte
              </a>
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

  // ── PUBLIC API ───────────────────────────────────────────────
  return {
    init, nav, refresh, fabAction,
    openConfig, saveConfig, testConnection, closeModal,
    filterCatalogo, setCatTab, toggleDerivs,
    abrirModalProducto, guardarProducto,
    abrirModalPrecio, publicarPrecio,
    setAlmTab,
    loadProveedores, selectProveedor, renderProveedores,
    abrirModalProveedor, guardarProveedor,
    abrirModalPago, guardarPago, abrirModalPedido,
    // Config
    setCfgTab,
    abrirModalEstacion, guardarEstacion,
    abrirModalImpresora, guardarImpresora,
    abrirModalPersonal, guardarPersonal,
    abrirModalSerie, guardarSerie,
    guardarPinEstacion, guardarPinWH,
    // Cajas
    loadCajas
  };
})();
