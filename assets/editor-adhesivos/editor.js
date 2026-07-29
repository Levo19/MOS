// ════════════════════════════════════════════════════════════════════
// EditorAdhesivos v2.0.0 — "Estudio de Avisos" (reescritura total, 2026-07-28)
//
// NUEVA LÓGICA (decisión del dueño):
//   • CATÁLOGO (inicio): las plantillas son archivos FIJOS — se imprimen, no se
//     editan ni se borran. Tocar un card = imprimir (modal con imagen PNG + cantidad).
//   • ESTUDIO (crear): mini-paint — lienzo protagonista, dock de herramientas,
//     selección con barra flotante contextual, bandeja de propiedades.
//     "Guardar al catálogo" congela la creación como plantilla fija.
//   • MEMBRETE OBLIGATORIO: toda creación nace con la franja "INVERSIONES MOS ──"
//     (capas texto+linea con flag fija:true — el TSPL las imprime como capas
//     normales; el editor las bloquea: ni mover, ni borrar, ni seleccionar).
//
// Compatibilidad: mismo JSON de plantilla {tamano, metadata, capas[]} — la
// impresión (Edge print-adhesivo-plantilla/tspl.mjs) y las RPCs no cambian.
// Depende de: EditorAdhesivosConverter (json2svg/dibujarBarcodes/validar),
// IconosAdhesivo, window.MOS_API.post (adaptador Supabase), JsBarcode (CDN).
// Reglas del sistema: español neutral, sin confirm()/prompt() nativos,
// full responsive (PC/tablet/móvil · Android/iOS/Windows).
// ════════════════════════════════════════════════════════════════════
(function() {
  'use strict';

  var CSS_VERSION = '2.0.0';
  var STORAGE_BORRADOR = 'eda2_borrador';
  var CSS_INYECTADO = false;
  var POST_URL_FALLBACK = null;

  // ── Estado ──────────────────────────────────────────────────────
  var _vista = 'catalogo';            // 'catalogo' | 'estudio'
  var _plantillas = [];               // catálogo (RAW del backend)
  var _catCargando = false;
  var _busqueda = '';
  var _plantilla = null;              // la creación viva del Estudio
  var _selId = null;
  var _historial = [], _histIdx = -1;
  var _zoom = 1, _zoomAuto = true;
  var _autosaveTimer = null;
  var _ultimoGuardado = null;
  var _imprimiendo = false;
  var _printCtx = null;               // { idPlantilla, nombre, cantidad }
  var _iconCat = 'comercial';
  var _iconBusca = '';
  var _dragState = null;
  var _thumbCache = {};               // idPlantilla → dataURL (miniaturas PNG)

  // ── Utilidades ──────────────────────────────────────────────────
  function _esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function _uuid() { return 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }
  function _conv() { return window.EditorAdhesivosConverter || null; }
  function _movil() { return window.matchMedia && window.matchMedia('(max-width: 860px)').matches; }

  function _toast(msg, tipo) {
    var t = document.createElement('div');
    t.className = 'ed2-toast' + (tipo === 'error' ? ' err' : tipo === 'ok' ? ' ok' : '');
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(function() { t.classList.add('out'); setTimeout(function() { t.remove(); }, 350); }, 2600);
  }

  // Diálogo propio (sin confirm/prompt nativos). botones=[{txt,cls,val}]
  function _dlg(opts, cb) {
    _cerrarDlg();
    var html = ''
      + '<div class="ed2-dlg-back" id="ed2Dlg">'
      +   '<div class="ed2-dlg">'
      +     (opts.titulo ? '<h3>' + _esc(opts.titulo) + '</h3>' : '')
      +     (opts.cuerpo ? '<p>' + opts.cuerpo + '</p>' : '')
      +     (opts.input != null ? '<input type="text" id="ed2DlgInput" maxlength="' + (opts.maxlength || 50) + '" value="' + _esc(opts.input) + '" placeholder="' + _esc(opts.placeholder || '') + '">' : '')
      +     '<div class="ed2-dlg-acts">'
      +       opts.botones.map(function(b, i) {
                return '<button class="ed2-btn ' + (b.cls || '') + '" data-val="' + i + '">' + b.txt + '</button>';
              }).join('')
      +     '</div>'
      +   '</div>'
      + '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
    var back = document.getElementById('ed2Dlg');
    back.addEventListener('click', function(e) { if (e.target === back && opts.cerrable !== false) { _cerrarDlg(); cb(null); } });
    back.querySelectorAll('button[data-val]').forEach(function(btn) {
      btn.onclick = function() {
        var inp = document.getElementById('ed2DlgInput');
        var val = opts.botones[parseInt(btn.getAttribute('data-val'), 10)].val;
        var txt = inp ? inp.value : null;
        _cerrarDlg();
        cb(val, txt);
      };
    });
    var inp0 = document.getElementById('ed2DlgInput');
    if (inp0) { inp0.focus(); inp0.select(); }
  }
  function _cerrarDlg() { var d = document.getElementById('ed2Dlg'); if (d) d.remove(); }

  // ── Backend (mismo adaptador de siempre) ────────────────────────
  function _apiPost(action, params, cb) {
    var done = false;
    function safeCb(err, r) { if (done) return; done = true; if (cb) cb(err, r); }
    if (typeof window.MOS_API !== 'undefined' && window.MOS_API.post) {
      return window.MOS_API.post(action, params)
        .then(function(r) { safeCb(null, r); })
        .catch(function(e) { safeCb(e); });
    }
    safeCb(new Error('Backend no disponible (MOS_API)'));
  }

  // ── MEMBRETE obligatorio ────────────────────────────────────────
  // Capas normales para el TSPL (texto + linea) con flag fija:true para el editor.
  function _capasMembrete(anchoMm) {
    return [
      { id: 'memb-txt', tipo: 'texto', fija: true, x_mm: 1.5, y_mm: 0.8,
        texto: 'INVERSIONES MOS', font: 1, alineacion: 'left', negrita: true, rotacion: 0 },
      { id: 'memb-lin', tipo: 'linea', fija: true, x_mm: 33, y_mm: 2.4,
        ancho_mm: Math.max(4, (anchoMm || 50) - 34.5), alto_mm: 0.4 }
    ];
  }
  function _esFija(c) { return !!(c && c.fija); }
  function _tieneMembrete(p) {
    return (p.capas || []).some(function(c) { return c.id === 'memb-txt' && _esFija(c); });
  }
  function _asegurarMembrete(p) {
    if (_tieneMembrete(p)) return p;
    p.capas = _capasMembrete(p.tamano && p.tamano.ancho_mm).concat(p.capas || []);
    return p;
  }
  function _plantillaNueva() {
    var p = {
      version: 2,
      tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
      metadata: { nombre: 'Nueva creación', membrete: true },
      capas: []
    };
    return _asegurarMembrete(p);
  }

  // ── CSS ─────────────────────────────────────────────────────────
  function _inyectarCss() {
    if (CSS_INYECTADO) return;
    var l = document.createElement('link');
    l.rel = 'stylesheet';
    var base = (typeof window.EDITOR_ADHESIVOS_BASE === 'string') ? window.EDITOR_ADHESIVOS_BASE : './assets/editor-adhesivos/';
    l.href = base + 'styles.css?v=' + CSS_VERSION;
    document.head.appendChild(l);
    CSS_INYECTADO = true;
  }

  // ════════════════════════════════════════════════════════════════
  // ABRIR / CERRAR
  // ════════════════════════════════════════════════════════════════
  function abrir(opts) {
    opts = opts || {};
    _inyectarCss();
    POST_URL_FALLBACK = opts.backendUrl || window.EDITOR_BACKEND_URL || null;
    _vista = 'catalogo';
    _selId = null;
    var ov = document.getElementById('ed2Overlay');
    if (!ov) {
      ov = document.createElement('div');
      ov.id = 'ed2Overlay';
      ov.className = 'ed2-overlay';
      document.body.appendChild(ov);
    }
    document.addEventListener('keydown', _keyHandler);
    _render();
    _refrescarCatalogo();
    // ¿Hay un borrador del Estudio? (solo si tiene contenido más allá del membrete)
    var b = _cargarBorrador();
    if (b && b.plantilla && (b.plantilla.capas || []).some(function(c) { return !_esFija(c); })) {
      var mins = Math.max(1, Math.round((Date.now() - b.ts) / 60000));
      _dlg({
        titulo: 'Borrador sin guardar',
        cuerpo: 'Hay una creación de hace <b>' + mins + ' min</b> que no se guardó al catálogo. ¿Quieres continuarla?',
        botones: [
          { txt: 'Descartar', cls: 'ed2-btn-ghost', val: 'no' },
          { txt: '✨ Continuar creación', cls: 'ed2-btn-primary', val: 'si' }
        ]
      }, function(val) {
        if (val === 'si') { _plantilla = _asegurarMembrete(b.plantilla); _irEstudio(false); }
        else if (val === 'no') _limpiarBorrador();
      });
    }
  }

  function _cerrar() {
    if (_vista === 'estudio' && _hayCambios()) { _confirmarSalidaEstudio(function() { _cerrarYa(); }); return; }
    _cerrarYa();
  }
  function _cerrarYa() {
    document.removeEventListener('keydown', _keyHandler);
    var ov = document.getElementById('ed2Overlay');
    if (ov) ov.remove();
    _cerrarDlg();
  }

  // ════════════════════════════════════════════════════════════════
  // RENDER RAÍZ
  // ════════════════════════════════════════════════════════════════
  function _render() {
    var ov = document.getElementById('ed2Overlay');
    if (!ov) return;
    ov.innerHTML = (_vista === 'catalogo') ? _htmlCatalogo() : _htmlEstudio();
    if (_vista === 'catalogo') _pintarGrid();
    else _montarEstudio();
  }

  // ════════════════════════════════════════════════════════════════
  // CATÁLOGO
  // ════════════════════════════════════════════════════════════════
  function _htmlCatalogo() {
    return ''
      + '<div class="ed2-cat">'
      +   '<div class="ed2-cat-top">'
      +     '<button class="ed2-btn ed2-btn-ghost" onclick="EditorAdhesivos._cerrar()">✕ Salir</button>'
      +     '<div class="ed2-cat-title">🗂 Catálogo de Avisos</div>'
      +     '<div class="ed2-search"><span>🔍</span><input type="text" placeholder="Buscar plantilla…" value="' + _esc(_busqueda) + '" oninput="EditorAdhesivos._setBusqueda(this.value)"></div>'
      +     '<button class="ed2-btn ed2-btn-primary ed2-crear" onclick="EditorAdhesivos._crearNuevo()">✨ Crear nuevo</button>'
      +   '</div>'
      +   '<div class="ed2-cat-nota">🔒 Las plantillas del catálogo son fijas: se imprimen, no se editan ni se borran. Toca una para imprimirla.</div>'
      +   '<div class="ed2-grid" id="ed2Grid"><div class="ed2-vacio">Cargando catálogo…</div></div>'
      + '</div>';
  }

  function _setBusqueda(v) {
    _busqueda = String(v || '');
    _pintarGrid();
    // devolver el foco al input (re-render lo pierde) — solo repintamos el grid, el input queda
  }

  function _refrescarCatalogo() {
    if (_catCargando) return;
    _catCargando = true;
    _apiPost('listarAdhesivosPlantillas', {}, function(err, r) {
      _catCargando = false;
      if (err || !r || !r.ok) {
        var g = document.getElementById('ed2Grid');
        if (g) g.innerHTML = '<div class="ed2-vacio">⚠ No se pudo cargar el catálogo' + (err ? ': ' + _esc(err.message || '') : '') + '<br><button class="ed2-btn ed2-btn-ghost" style="margin-top:10px" onclick="EditorAdhesivos._reintentarCat()">Reintentar</button></div>';
        return;
      }
      _plantillas = r.plantillas || [];
      _pintarGrid();
    });
  }
  function _reintentarCat() {
    var g = document.getElementById('ed2Grid');
    if (g) g.innerHTML = '<div class="ed2-vacio">Cargando catálogo…</div>';
    _refrescarCatalogo();
  }

  function _pintarGrid() {
    var g = document.getElementById('ed2Grid');
    if (!g) return;
    var q = _busqueda.trim().toLowerCase();
    var lista = _plantillas.filter(function(p) {
      if (p.jsonCorrupto) return false;
      if (!q) return true;
      return String(p.nombre || '').toLowerCase().indexOf(q) >= 0
          || String(p.descripcion || '').toLowerCase().indexOf(q) >= 0;
    });
    if (!lista.length) {
      g.innerHTML = '<div class="ed2-vacio">' + (q ? 'Sin resultados para "' + _esc(_busqueda) + '"' : 'El catálogo está vacío.<br>Crea el primer aviso con <b>✨ Crear nuevo</b>.') + '</div>';
      return;
    }
    g.innerHTML = lista.map(function(p, i) {
      var idEsc = _esc(String(p.idPlantilla || ''));
      var tam = _esc(p.tamanoCanvas || '50x25');
      return '<div class="ed2-card" style="animation-delay:' + Math.min(i * 55, 500) + 'ms">'
        +   '<div class="ed2-card-th" data-print="' + idEsc + '" title="Imprimir este aviso"><div class="ed2-th-holder" id="ed2Th_' + idEsc + '"><span class="ed2-th-spin"></span></div></div>'
        +   '<div class="ed2-card-body">'
        +     '<div class="ed2-card-name" title="' + _esc(p.descripcion || p.nombre) + '">' + _esc(p.nombre) + '</div>'
        +     '<div class="ed2-card-meta"><span>' + tam + ' mm</span><span class="ed2-chip-fija">🔒 FIJA</span></div>'
        +     '<div class="ed2-card-acts">'
        +       '<button class="ed2-btn-print" data-print="' + idEsc + '">🖨 Imprimir</button>'
        +       '<button class="ed2-btn-base" data-base="' + idEsc + '" title="Partir de esta: crea una copia editable en el Estudio (el original no se toca)">⧉</button>'
        +     '</div>'
        +   '</div>'
        + '</div>';
    }).join('');
    // wiring (sin onclicks inline con ids — más robusto con ids raros)
    g.querySelectorAll('[data-print]').forEach(function(el) {
      el.onclick = function() { _abrirImprimir(el.getAttribute('data-print')); };
    });
    g.querySelectorAll('[data-base]').forEach(function(el) {
      el.onclick = function(e) { e.stopPropagation(); _partirDe(el.getAttribute('data-base')); };
    });
    // miniaturas fieles (SVG con QR real + barcodes)
    lista.forEach(function(p) { _pintarThumb(p); });
  }

  function _jsonDe(p) {
    try { return (typeof p.json === 'string') ? JSON.parse(p.json) : JSON.parse(JSON.stringify(p.json)); }
    catch (_) { return null; }
  }

  function _pintarThumb(p) {
    var holder = document.getElementById('ed2Th_' + String(p.idPlantilla || ''));
    if (!holder) return;
    var pj = _jsonDe(p);
    var conv = _conv();
    if (!pj || !conv) { holder.innerHTML = '<span class="ed2-th-err">sin preview</span>'; return; }
    holder.innerHTML = conv.json2svg(pj, { grid: false });
    var svg = holder.querySelector('svg');
    if (svg) { svg.removeAttribute('width'); svg.removeAttribute('height'); }
    try { conv.dibujarBarcodes(holder); } catch (_) {}
  }

  // ── acciones catálogo ──
  function _crearNuevo() {
    _plantilla = _plantillaNueva();
    _irEstudio(true);
  }
  function _partirDe(id) {
    var p = _plantillas.find(function(x) { return String(x.idPlantilla) === String(id); });
    if (!p) return;
    var pj = _jsonDe(p);
    if (!pj) { _toast('No se pudo leer la plantilla', 'error'); return; }
    pj.metadata = pj.metadata || {};
    pj.metadata.nombre = 'Copia de ' + (p.nombre || 'aviso');
    _plantilla = _asegurarMembrete(pj);
    // ids nuevos para las capas no fijas (evita colisiones raras)
    _plantilla.capas.forEach(function(c) { if (!_esFija(c)) c.id = _uuid(); });
    _irEstudio(true);
    _toast('Copia creada — el original del catálogo no se toca', 'ok');
  }
  function _irEstudio(resetHist) {
    _vista = 'estudio';
    _selId = null;
    _zoomAuto = true;
    if (resetHist !== false) { _historial = []; _histIdx = -1; _ultimoGuardado = null; _snapshot(); }
    _render();
  }

  // ════════════════════════════════════════════════════════════════
  // IMPRIMIR (modal con imagen PNG + cantidad)
  // ════════════════════════════════════════════════════════════════
  function _abrirImprimir(id) {
    var p = _plantillas.find(function(x) { return String(x.idPlantilla) === String(id); });
    if (!p) return;
    _printCtx = { idPlantilla: p.idPlantilla, nombre: p.nombre, cantidad: 10 };
    var imp = _impresoraAdhesivo();
    var html = ''
      + '<div class="ed2-dlg-back" id="ed2Print">'
      +   '<div class="ed2-print">'
      +     '<div class="ed2-print-h">🖨 <b>Imprimir · ' + _esc(p.nombre) + '</b><button class="ed2-x" onclick="EditorAdhesivos._cerrarImprimir()">✕</button></div>'
      +     '<div class="ed2-print-sub">Así saldrá la etiqueta (' + _esc(p.tamanoCanvas || '50x25') + ' mm)</div>'
      +     '<div class="ed2-paper"><div class="ed2-shot" id="ed2Shot"><span class="ed2-th-spin"></span></div></div>'
      +     '<div class="ed2-print-cap">Imagen generada — fiel a la impresión térmica (B/N, QR real)</div>'
      +     '<div class="ed2-qty">'
      +       '<button onclick="EditorAdhesivos._qty(-1)" aria-label="Menos">−</button>'
      +       '<div class="ed2-qty-val" id="ed2QtyVal">10</div>'
      +       '<button onclick="EditorAdhesivos._qty(1)" aria-label="Más">＋</button>'
      +     '</div>'
      +     '<div class="ed2-qty-l">cantidad de etiquetas</div>'
      +     (imp ? '<div class="ed2-prn"><span class="ed2-dot ' + (imp.ok ? 'ok' : 'bad') + '"></span>' + _esc(imp.nombre) + ' · ' + (imp.ok ? 'en línea' : 'sin señal') + '</div>' : '')
      +     '<div class="ed2-print-acts">'
      +       '<button class="ed2-btn ed2-btn-ghost" onclick="EditorAdhesivos._imprimir(1)">Imprimir 1 de prueba</button>'
      +       '<button class="ed2-btn ed2-btn-go" id="ed2GoBtn" onclick="EditorAdhesivos._imprimir(0)">🖨 Imprimir 10</button>'
      +     '</div>'
      +   '</div>'
      + '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
    var back = document.getElementById('ed2Print');
    back.addEventListener('click', function(e) { if (e.target === back) _cerrarImprimir(); });
    // PNG (con caché por id)
    var pj = _jsonDe(p);
    if (_thumbCache[p.idPlantilla]) _ponShot(_thumbCache[p.idPlantilla]);
    else if (pj) _plantillaAPng(pj, 2, function(url) {
      if (url) { _thumbCache[p.idPlantilla] = url; _ponShot(url); }
      else _ponShotSvg(pj);
    });
  }
  function _ponShot(url) {
    var s = document.getElementById('ed2Shot');
    if (s) s.innerHTML = '<img src="' + url + '" alt="Preview de la etiqueta">';
  }
  function _ponShotSvg(pj) {
    // Respaldo si el PNG falla: SVG directo (igual de fiel, solo que no es "foto")
    var s = document.getElementById('ed2Shot');
    var conv = _conv();
    if (!s || !conv) return;
    s.innerHTML = conv.json2svg(pj, { grid: false });
    var svg = s.querySelector('svg');
    if (svg) { svg.removeAttribute('width'); svg.removeAttribute('height'); }
    try { conv.dibujarBarcodes(s); } catch (_) {}
  }
  function _cerrarImprimir() { var d = document.getElementById('ed2Print'); if (d) d.remove(); _printCtx = null; }

  function _qty(delta) {
    if (!_printCtx) return;
    _printCtx.cantidad = Math.max(1, Math.min(100, _printCtx.cantidad + delta));
    var v = document.getElementById('ed2QtyVal');
    if (v) v.textContent = _printCtx.cantidad;
    var go = document.getElementById('ed2GoBtn');
    if (go) go.innerHTML = '🖨 Imprimir ' + _printCtx.cantidad;
  }

  function _imprimir(cantFija) {
    if (!_printCtx || _imprimiendo) { if (_imprimiendo) _toast('Espera — ya hay una impresión en curso', 'error'); return; }
    var cant = cantFija > 0 ? cantFija : _printCtx.cantidad;
    _imprimiendo = true;
    var modal = document.getElementById('ed2Print');
    if (modal) modal.querySelectorAll('button').forEach(function(b) { b.disabled = true; b.style.opacity = '.55'; });
    _apiPost('imprimirAdhesivoPlantilla', { idPlantilla: _printCtx.idPlantilla, cantidad: cant }, function(err, r) {
      _imprimiendo = false;
      if (modal) modal.querySelectorAll('button').forEach(function(b) { b.disabled = false; b.style.opacity = ''; });
      if (err || !r || !r.ok) {
        _toast('Error al imprimir: ' + ((err && err.message) || (r && r.error) || 'desconocido'), 'error');
        return;
      }
      _toast(cant + (cant === 1 ? ' etiqueta enviada' : ' etiquetas enviadas') + ' a la impresora ✓', 'ok');
      if (cantFija === 0) _cerrarImprimir();
    });
  }

  // Estado de la impresora de adhesivos (best-effort desde el caché que MOS ya llena)
  function _impresoraAdhesivo() {
    try {
      var raw = localStorage.getItem('mos_printers_cache');
      if (!raw) return null;
      var arr = (JSON.parse(raw) || {}).data || [];
      var p = arr.find(function(x) { return String(x.tipo || x.uso || '').toUpperCase().indexOf('ADHESIVO') >= 0; });
      if (!p) return null;
      var ok = (p.state === 'ONLINE') || (p.online === true);
      return { nombre: p.nombre || p.printerName || 'Impresora de etiquetas', ok: ok };
    } catch (_) { return null; }
  }

  // ── SVG → PNG (imagen fiel; barcodes dibujados primero) ─────────
  function _plantillaAPng(pj, escala, cb) {
    var conv = _conv();
    if (!conv) { cb(null); return; }
    var host = document.createElement('div');
    host.style.cssText = 'position:fixed;left:-9999px;top:0;background:#fff';
    try { host.innerHTML = conv.json2svg(pj, { grid: false }); } catch (_) { cb(null); return; }
    document.body.appendChild(host);
    try { conv.dibujarBarcodes(host); } catch (_) {}
    setTimeout(function() {
      try {
        var svg = host.querySelector('svg');
        var w = parseInt(svg.getAttribute('width'), 10), h = parseInt(svg.getAttribute('height'), 10);
        var xml = new XMLSerializer().serializeToString(svg);
        var img = new Image();
        img.onload = function() {
          try {
            var cv = document.createElement('canvas');
            cv.width = w * escala; cv.height = h * escala;
            var ctx = cv.getContext('2d');
            ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, cv.width, cv.height);
            ctx.imageSmoothingEnabled = false;
            ctx.drawImage(img, 0, 0, cv.width, cv.height);
            host.remove();
            cb(cv.toDataURL('image/png'));
          } catch (e) { host.remove(); cb(null); }
        };
        img.onerror = function() { host.remove(); cb(null); };
        img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml);
      } catch (e) { host.remove(); cb(null); }
    }, 80);
  }

  // ════════════════════════════════════════════════════════════════
  // ESTUDIO (mini-paint)
  // ════════════════════════════════════════════════════════════════
  function _htmlEstudio() {
    var nombre = (_plantilla && _plantilla.metadata && _plantilla.metadata.nombre) || 'Nueva creación';
    var modif = _hayCambios();
    return ''
      + '<div class="ed2-est">'
      +   '<div class="ed2-est-top">'
      +     '<button class="ed2-btn ed2-btn-ghost" onclick="EditorAdhesivos._volverCatalogo()">◀ Catálogo</button>'
      +     '<div class="ed2-est-name">✨ <input type="text" id="ed2Nombre" maxlength="50" value="' + _esc(nombre) + '" onchange="EditorAdhesivos._setNombre(this.value)">'
      +       '<span class="ed2-estado ' + (modif ? 'mod' : '') + '" id="ed2Estado">' + (modif ? '● borrador' : '· listo') + '</span></div>'
      +     '<button class="ed2-btn ed2-btn-ghost ed2-undo" onclick="EditorAdhesivos._undo()" title="Deshacer (Ctrl+Z)">↶</button>'
      +     '<button class="ed2-btn ed2-btn-ghost ed2-undo" onclick="EditorAdhesivos._redo()" title="Rehacer (Ctrl+Y)">↷</button>'
      +     '<button class="ed2-btn ed2-btn-go" onclick="EditorAdhesivos._guardarAlCatalogo()">📌 Guardar al catálogo</button>'
      +   '</div>'
      +   '<div class="ed2-studio" id="ed2Studio">'
      +     '<div class="ed2-stage" id="ed2Stage">'
      +       '<div class="ed2-membtag">🔒 membrete fijo</div>'
      +       '<div class="ed2-canvas" id="ed2Canvas"></div>'
      +     '</div>'
      +     '<div class="ed2-zoom">'
      +       '<button onclick="EditorAdhesivos._zoomDelta(-0.25)" aria-label="Alejar">−</button>'
      +       '<span id="ed2ZoomLbl">auto</span>'
      +       '<button onclick="EditorAdhesivos._zoomDelta(0.25)" aria-label="Acercar">＋</button>'
      +       '<button onclick="EditorAdhesivos._zoomFit()" title="Ajustar a la vista">⤢</button>'
      +       '<span class="ed2-zoom-info">' + _plantilla.tamano.ancho_mm + '×' + _plantilla.tamano.alto_mm + ' mm</span>'
      +     '</div>'
      +     '<div class="ed2-tray" id="ed2Tray"></div>'
      +     '<div class="ed2-dock" id="ed2Dock">'
      +       '<button class="ed2-dtool" onclick="EditorAdhesivos._addTexto()"><span class="dg gT">T</span>Texto</button>'
      +       '<button class="ed2-dtool" onclick="EditorAdhesivos._abrirIconos()"><span class="dg">💰</span>Icono</button>'
      +       '<button class="ed2-dtool" onclick="EditorAdhesivos._addQR()"><span class="dg"><span class="gQ"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i></span></span>QR</button>'
      +       '<button class="ed2-dtool" onclick="EditorAdhesivos._addBarcode()"><span class="dg"><span class="gB"></span></span>Barras</button>'
      +       '<button class="ed2-dtool" onclick="EditorAdhesivos._addLinea()"><span class="dg"><span class="gL"></span></span>Línea</button>'
      +       '<button class="ed2-dtool" onclick="EditorAdhesivos._addRect()"><span class="dg"><span class="gR"></span></span>Recuadro</button>'
      +     '</div>'
      +   '</div>'
      + '</div>';
  }

  function _montarEstudio() {
    _renderCanvas();
    _zoomFit();
  }

  function _setNombre(v) {
    if (!_plantilla) return;
    _plantilla.metadata = _plantilla.metadata || {};
    _plantilla.metadata.nombre = String(v || '').trim() || 'Nueva creación';
    _autosave();
  }

  function _volverCatalogo() {
    if (_hayCambios()) { _confirmarSalidaEstudio(function() { _vista = 'catalogo'; _render(); _refrescarCatalogo(); }); return; }
    _vista = 'catalogo';
    _render();
    _refrescarCatalogo();
  }
  function _confirmarSalidaEstudio(continuar) {
    _dlg({
      titulo: '¿Salir sin guardar?',
      cuerpo: 'Tu creación no está guardada en el catálogo. Si sales, queda como borrador (24 h).',
      botones: [
        { txt: 'Seguir editando', cls: 'ed2-btn-ghost', val: 'no' },
        { txt: 'Salir', cls: 'ed2-btn-primary', val: 'si' }
      ]
    }, function(val) { if (val === 'si') continuar(); });
  }

  // ── lienzo ──────────────────────────────────────────────────────
  function _renderCanvas() {
    var cv = document.getElementById('ed2Canvas');
    var conv = _conv();
    if (!cv || !conv || !_plantilla) return;
    cv.innerHTML = conv.json2svg(_plantilla, { grid: true, gridMm: 5 }) + _htmlHits();
    try { conv.dibujarBarcodes(cv); } catch (_) {}
    _wireHits();
    _aplicarZoom();
    _renderSel();
    _renderTray();
    _refrescarEstado();
  }

  function _refrescarEstado() {
    var e = document.getElementById('ed2Estado');
    if (!e) return;
    var m = _hayCambios();
    e.textContent = m ? '● borrador' : '· listo';
    e.className = 'ed2-estado' + (m ? ' mod' : '');
  }

  function _boundsCapa(c) {
    var conv = _conv();
    var x = conv.mm2px(c.x_mm), y = conv.mm2px(c.y_mm);
    var w = 40, h = 24;
    if (c.tipo === 'icono' || c.tipo === 'qr') { w = conv.dots2px(c.tamano_dots || (c.tipo === 'qr' ? 64 : 48)); h = w; }
    else if (c.tipo === 'rectangulo') { w = conv.mm2px(c.ancho_mm || 5); h = conv.mm2px(c.alto_mm || 5); }
    else if (c.tipo === 'linea') { w = conv.mm2px(c.ancho_mm || 0); h = Math.max(10, conv.mm2px(c.alto_mm || 0.5)); }
    else if (c.tipo === 'texto') {
      var fpx = conv.fontPx(c.font || 3) * (c.negrita ? 1.15 : 1);
      var lineas = String(c.texto || '').split('\n');
      var maxLen = lineas.reduce(function(m, l) { return Math.max(m, l.length); }, 1);
      w = maxLen * fpx * 0.58; h = fpx * 1.08 * lineas.length;
    }
    else if (c.tipo === 'barcode') {
      var modules = 11 * String(c.codigo || '').length + 35;
      w = conv.dots2px(modules * (c.narrow || 2)); h = conv.dots2px(c.alto_dots || 48) + 16;
    }
    return { x: x, y: y, w: w, h: h };
  }

  function _htmlHits() {
    return (_plantilla.capas || []).map(function(c) {
      if (_esFija(c)) return '';
      var b = _boundsCapa(c);
      return '<div class="ed2-hit" data-id="' + c.id + '" style="left:' + b.x + 'px;top:' + b.y + 'px;width:' + b.w + 'px;height:' + b.h + 'px"></div>';
    }).join('');
  }

  function _wireHits() {
    var cv = document.getElementById('ed2Canvas');
    if (!cv) return;
    cv.onpointerdown = function(e) {
      var hit = e.target.closest ? e.target.closest('.ed2-hit') : null;
      if (!hit) { _seleccionar(null); return; }
      var id = hit.getAttribute('data-id');
      _seleccionar(id);
      _dragStart(e, id, hit);
    };
  }

  // ── drag (Pointer Events → mouse + touch + pen) ─────────────────
  function _dragStart(e, id, el) {
    var capa = _plantilla.capas.find(function(c) { return c.id === id; });
    if (!capa || _esFija(capa)) return;
    e.preventDefault();
    try { el.setPointerCapture(e.pointerId); } catch (_) {}
    _dragState = { id: id, capa: capa, x0: e.clientX, y0: e.clientY, mm: { x: capa.x_mm, y: capa.y_mm }, moved: false };
    el.onpointermove = _dragMove;
    el.onpointerup = el.onpointercancel = _dragEnd;
  }
  function _dragMove(e) {
    if (!_dragState) return;
    e.preventDefault();
    var PX_POR_MM = 12 * _zoom;
    var nx = _dragState.mm.x + (e.clientX - _dragState.x0) / PX_POR_MM;
    var ny = _dragState.mm.y + (e.clientY - _dragState.y0) / PX_POR_MM;
    nx = Math.round(nx * 2) / 2; ny = Math.round(ny * 2) / 2;
    nx = Math.max(0, Math.min(_plantilla.tamano.ancho_mm, nx));
    ny = Math.max(0, Math.min(_plantilla.tamano.alto_mm, ny));
    if (nx !== _dragState.capa.x_mm || ny !== _dragState.capa.y_mm) {
      _dragState.capa.x_mm = nx; _dragState.capa.y_mm = ny; _dragState.moved = true;
      _renderCanvasLigero();
    }
  }
  function _dragEnd() {
    if (!_dragState) return;
    var movio = _dragState.moved;
    _dragState = null;
    if (movio) { _snapshot(); _renderCanvas(); }
  }
  function _renderCanvasLigero() {
    // re-render SVG + hits sin tocar bandeja (fluidez del drag)
    var cv = document.getElementById('ed2Canvas');
    var conv = _conv();
    if (!cv || !conv) return;
    cv.innerHTML = conv.json2svg(_plantilla, { grid: true, gridMm: 5 }) + _htmlHits();
    try { conv.dibujarBarcodes(cv); } catch (_) {}
    _wireHits();
    _renderSel();
  }

  // ── selección (hormigas marchando + barra flotante) ─────────────
  function _seleccionar(id) {
    _selId = id;
    _renderSel();
    _renderTray();
  }
  function _capaSel() { return _selId ? _plantilla.capas.find(function(c) { return c.id === _selId; }) : null; }

  function _renderSel() {
    var stage = document.getElementById('ed2Stage');
    if (!stage) return;
    var old = stage.querySelector('.ed2-selbox'); if (old) old.remove();
    var c = _capaSel();
    if (!c) return;
    var b = _boundsCapa(c);
    var cv = document.getElementById('ed2Canvas');
    var box = document.createElement('div');
    box.className = 'ed2-selbox';
    // coordenadas en el sistema del canvas escalado
    box.style.left = (cv.offsetLeft + b.x * _zoom) + 'px';
    box.style.top = (cv.offsetTop + b.y * _zoom) + 'px';
    box.style.width = (b.w * _zoom) + 'px';
    box.style.height = (b.h * _zoom) + 'px';
    box.innerHTML = '<div class="ed2-flt">' + _botonesFlt(c) + '</div>';
    stage.appendChild(box);
    box.querySelectorAll('button[data-act]').forEach(function(btn) {
      btn.onclick = function(e) { e.stopPropagation(); _accionFlt(btn.getAttribute('data-act')); };
    });
  }
  function _botonesFlt(c) {
    var extra = '';
    if (c.tipo === 'texto') extra = '<button data-act="fmenos">A−</button><button data-act="fmas">A＋</button><button data-act="bold"' + (c.negrita ? ' class="on"' : '') + '><b>B</b></button>';
    if (c.tipo === 'qr' || c.tipo === 'icono') extra = '<button data-act="smenos">−</button><button data-act="smas">＋</button>';
    if (c.tipo === 'barcode') extra = '<button data-act="hmenos">▁−</button><button data-act="hmas">▁＋</button>';
    return extra + '<button data-act="dup">⧉</button><button data-act="del" class="del">🗑</button>';
  }
  function _accionFlt(act) {
    var c = _capaSel();
    if (!c) return;
    var FONTS = [1, 2, 3, 4, 5];
    var QRS = [40, 56, 72, 96, 120, 168];
    var ICS = [32, 48, 64, 96];
    if (act === 'del') { _eliminarSel(); return; }
    if (act === 'dup') {
      var copia = JSON.parse(JSON.stringify(c));
      copia.id = _uuid(); copia.x_mm = Math.min(_plantilla.tamano.ancho_mm - 2, copia.x_mm + 2); copia.y_mm = Math.min(_plantilla.tamano.alto_mm - 2, copia.y_mm + 2);
      _plantilla.capas.push(copia);
      _selId = copia.id;
    }
    else if (act === 'bold') c.negrita = !c.negrita;
    else if (act === 'fmas' || act === 'fmenos') {
      var fi = FONTS.indexOf(c.font || 3);
      c.font = FONTS[Math.max(0, Math.min(FONTS.length - 1, fi + (act === 'fmas' ? 1 : -1)))];
    }
    else if (act === 'smas' || act === 'smenos') {
      var arr = c.tipo === 'qr' ? QRS : ICS;
      var cur = c.tamano_dots || (c.tipo === 'qr' ? 64 : 48);
      var si = 0, best = 1e9;
      arr.forEach(function(v, i) { if (Math.abs(v - cur) < best) { best = Math.abs(v - cur); si = i; } });
      c.tamano_dots = arr[Math.max(0, Math.min(arr.length - 1, si + (act === 'smas' ? 1 : -1)))];
    }
    else if (act === 'hmas' || act === 'hmenos') {
      c.alto_dots = Math.max(24, Math.min(96, (c.alto_dots || 48) + (act === 'hmas' ? 8 : -8)));
    }
    _snapshot();
    _renderCanvas();
  }
  function _eliminarSel() {
    var c = _capaSel();
    if (!c || _esFija(c)) return;
    _plantilla.capas = _plantilla.capas.filter(function(x) { return x.id !== c.id; });
    _selId = null;
    _snapshot();
    _renderCanvas();
  }

  // ── bandeja contextual ──────────────────────────────────────────
  function _renderTray() {
    var tray = document.getElementById('ed2Tray');
    if (!tray) return;
    var c = _capaSel();
    if (!c) { tray.className = 'ed2-tray'; tray.innerHTML = ''; return; }
    tray.className = 'ed2-tray abierta';
    var h = '<div class="ed2-tray-h">' + _iconoTipo(c.tipo) + ' ' + _labelTipo(c.tipo) + '<button class="ed2-x" onclick="EditorAdhesivos._seleccionar(null)">✕</button></div>';
    if (c.tipo === 'texto') {
      h += '<textarea class="ed2-in" id="ed2TxTexto" rows="2" placeholder="Escribe el texto…">' + _esc(c.texto || '') + '</textarea>';
      h += '<div class="ed2-sizes">' + [1, 2, 3, 4, 5].map(function(f) {
        return '<button class="ed2-size s' + f + (c.font === f ? ' on' : '') + '" data-font="' + f + '">Aa</button>';
      }).join('') + '</div>';
      h += '<div class="ed2-row3">'
        + '<button class="ed2-mini' + (c.negrita ? ' on' : '') + '" data-p="negrita"><b>B</b> Negrita</button>'
        + '<button class="ed2-mini' + (c.alineacion === 'left' || !c.alineacion ? ' on' : '') + '" data-al="left">⯇ Izq.</button>'
        + '<button class="ed2-mini' + (c.alineacion === 'center' ? ' on' : '') + '" data-al="center">▣ Centro</button>'
        + '</div>';
    } else if (c.tipo === 'qr') {
      h += '<input class="ed2-in" id="ed2QrCod" type="text" placeholder="Contenido del QR (link, texto, WIFI:…)" value="' + _esc(c.codigo || '') + '">';
      h += '<div class="ed2-hintline">Al escanear: un link abre la página; un WIFI: conecta a la red.</div>';
    } else if (c.tipo === 'barcode') {
      h += '<input class="ed2-in" id="ed2BcCod" type="text" maxlength="14" placeholder="Código (máx 14)" value="' + _esc(c.codigo || '') + '">';
    } else if (c.tipo === 'linea') {
      h += _sliderRow('Largo', 'ancho_mm', c.ancho_mm || 10, 2, _plantilla.tamano.ancho_mm, 0.5, 'mm');
      h += _sliderRow('Grosor', 'alto_mm', c.alto_mm || 0.5, 0.2, 3, 0.1, 'mm');
    } else if (c.tipo === 'rectangulo') {
      h += _sliderRow('Ancho', 'ancho_mm', c.ancho_mm || 10, 2, _plantilla.tamano.ancho_mm, 0.5, 'mm');
      h += _sliderRow('Alto', 'alto_mm', c.alto_mm || 6, 2, _plantilla.tamano.alto_mm, 0.5, 'mm');
      h += '<div class="ed2-row3"><button class="ed2-mini' + (c.relleno ? ' on' : '') + '" data-p="relleno">◼ Relleno</button></div>';
    } else if (c.tipo === 'icono') {
      h += '<button class="ed2-mini" onclick="EditorAdhesivos._abrirIconos(true)">🔁 Cambiar icono</button>';
    }
    tray.innerHTML = h;
    // wiring
    var tx = document.getElementById('ed2TxTexto');
    if (tx) {
      tx.oninput = function() { c.texto = tx.value; _renderCanvasLigero(); };
      tx.onchange = function() { _snapshot(); _refrescarEstado(); };
    }
    var qr = document.getElementById('ed2QrCod');
    if (qr) { qr.onchange = function() { c.codigo = qr.value.trim(); _snapshot(); _renderCanvas(); }; }
    var bc = document.getElementById('ed2BcCod');
    if (bc) { bc.onchange = function() { c.codigo = bc.value.trim(); _snapshot(); _renderCanvas(); }; }
    tray.querySelectorAll('[data-font]').forEach(function(b) {
      b.onclick = function() { c.font = parseInt(b.getAttribute('data-font'), 10); _snapshot(); _renderCanvas(); };
    });
    tray.querySelectorAll('[data-al]').forEach(function(b) {
      b.onclick = function() { c.alineacion = b.getAttribute('data-al'); _snapshot(); _renderCanvas(); };
    });
    tray.querySelectorAll('[data-p]').forEach(function(b) {
      b.onclick = function() { var k = b.getAttribute('data-p'); c[k] = !c[k]; _snapshot(); _renderCanvas(); };
    });
    tray.querySelectorAll('input[type="range"][data-k]').forEach(function(r) {
      r.oninput = function() {
        c[r.getAttribute('data-k')] = parseFloat(r.value);
        var lbl = tray.querySelector('[data-lbl="' + r.getAttribute('data-k') + '"]');
        if (lbl) lbl.textContent = r.value + ' mm';
        _renderCanvasLigero();
      };
      r.onchange = function() { _snapshot(); _refrescarEstado(); };
    });
  }
  function _sliderRow(label, key, val, min, max, step, unidad) {
    return '<div class="ed2-slider"><label>' + label + ' <span data-lbl="' + key + '">' + val + ' ' + unidad + '</span></label>'
      + '<input type="range" data-k="' + key + '" min="' + min + '" max="' + max + '" step="' + step + '" value="' + val + '"></div>';
  }
  function _iconoTipo(t) { return { texto: '✏️', icono: '💰', qr: '⬚', barcode: '▮▯▮', linea: '━', rectangulo: '▭' }[t] || '◆'; }
  function _labelTipo(t) { return { texto: 'Texto', icono: 'Icono', qr: 'Código QR', barcode: 'Código de barras', linea: 'Línea', rectangulo: 'Recuadro' }[t] || t; }

  // ── dock: agregar elementos ─────────────────────────────────────
  function _zonaLibreY() {
    // coloca el elemento nuevo debajo del membrete, en zona con menos capas
    return Math.min(_plantilla.tamano.alto_mm - 6, 6 + (_plantilla.capas.filter(function(c) { return !_esFija(c); }).length % 4) * 4);
  }
  function _addCapa(c) {
    c.id = _uuid();
    _plantilla.capas.push(c);
    _selId = c.id;
    _snapshot();
    _renderCanvas();
  }
  function _addTexto() {
    _addCapa({ tipo: 'texto', x_mm: 20, y_mm: _zonaLibreY(), texto: 'TEXTO', font: 3, alineacion: 'left', negrita: false, rotacion: 0 });
  }
  function _addLinea() { _addCapa({ tipo: 'linea', x_mm: 4, y_mm: _zonaLibreY() + 2, ancho_mm: Math.min(40, _plantilla.tamano.ancho_mm - 8), alto_mm: 0.5 }); }
  function _addRect() { _addCapa({ tipo: 'rectangulo', x_mm: 6, y_mm: _zonaLibreY(), ancho_mm: 18, alto_mm: 8, grosor: 2, relleno: false }); }
  function _addBarcode() { _addCapa({ tipo: 'barcode', x_mm: 4, y_mm: Math.max(8, _zonaLibreY()), codigo: 'MOS001', formato: '128', alto_dots: 48, narrow: 2 }); }
  function _addQR() {
    _addCapa({ tipo: 'qr', x_mm: 2, y_mm: 4.5, codigo: 'https://levo19.github.io/MOS/', tamano_dots: 120 });
    _toast('QR agregado — edita el contenido en la bandeja', 'ok');
  }

  // picker de iconos (bandeja)
  function _abrirIconos(cambiar) {
    var tray = document.getElementById('ed2Tray');
    if (!tray || !window.IconosAdhesivo) return;
    _iconMode = cambiar === true ? 'cambiar' : 'agregar';
    tray.className = 'ed2-tray abierta';
    _pintarIconos();
  }
  var _iconMode = 'agregar';
  function _pintarIconos() {
    var tray = document.getElementById('ed2Tray');
    if (!tray) return;
    var todos = IconosAdhesivo.listar();
    var q = _iconBusca.trim().toLowerCase();
    var lista = q
      ? todos.filter(function(i) { return i.id.toLowerCase().indexOf(q) >= 0 || i.label.toLowerCase().indexOf(q) >= 0; })
      : todos.filter(function(i) { return i.categoria === _iconCat; });
    var cats = [['comercial', '💰'], ['alerta', '⚠'], ['operativo', '🏪'], ['destaque', '🎯']];
    tray.innerHTML = ''
      + '<div class="ed2-tray-h">💰 Iconos<button class="ed2-x" onclick="EditorAdhesivos._seleccionar(null)">✕</button></div>'
      + '<input class="ed2-in" type="text" id="ed2IconQ" placeholder="🔍 Buscar icono…" value="' + _esc(_iconBusca) + '">'
      + (q ? '' : '<div class="ed2-cats">' + cats.map(function(cc) {
          return '<button class="ed2-catb' + (cc[0] === _iconCat ? ' on' : '') + '" data-cat="' + cc[0] + '">' + cc[1] + '</button>';
        }).join('') + '</div>')
      + '<div class="ed2-icongrid">' + (lista.length ? lista.map(function(i) {
          return '<button class="ed2-icb" data-ic="' + i.id + '" title="' + _esc(i.label) + '"><img src="' + IconosAdhesivo.dataUri(i.id) + '" alt=""></button>';
        }).join('') : '<div class="ed2-hintline">Sin iconos para esa búsqueda</div>') + '</div>';
    var qEl = document.getElementById('ed2IconQ');
    if (qEl) { qEl.oninput = function() { _iconBusca = qEl.value; _pintarIconos(); var el2 = document.getElementById('ed2IconQ'); if (el2) { el2.focus(); el2.setSelectionRange(el2.value.length, el2.value.length); } }; }
    tray.querySelectorAll('[data-cat]').forEach(function(b) { b.onclick = function() { _iconCat = b.getAttribute('data-cat'); _pintarIconos(); }; });
    tray.querySelectorAll('[data-ic]').forEach(function(b) {
      b.onclick = function() {
        var idIc = b.getAttribute('data-ic');
        if (_iconMode === 'cambiar') {
          var c = _capaSel();
          if (c && c.tipo === 'icono') { c.idIcono = idIc; _snapshot(); _renderCanvas(); return; }
        }
        _addCapa({ tipo: 'icono', x_mm: 4, y_mm: _zonaLibreY(), idIcono: idIc, tamano_dots: 48 });
      };
    });
  }

  // ── zoom ────────────────────────────────────────────────────────
  function _zoomFit() {
    var st = document.getElementById('ed2Studio');
    var cv = document.getElementById('ed2Canvas');
    var svg = cv && cv.querySelector('svg');
    if (!st || !svg) return;
    var w = parseInt(svg.getAttribute('width') || svg.viewBox.baseVal.width, 10) || 600;
    var availW = st.clientWidth - (_movil() ? 28 : 90);
    var availH = st.clientHeight - (_movil() ? 210 : 200);
    _zoom = Math.max(0.4, Math.min(availW / w, availH / Math.max(1, parseInt(svg.getAttribute('height'), 10) || 300), 1.8));
    _zoom = Math.round(_zoom * 100) / 100;
    _zoomAuto = true;
    _aplicarZoom();
    _renderSel();
  }
  function _zoomDelta(d) {
    _zoom = Math.max(0.4, Math.min(2.5, Math.round((_zoom + d) * 100) / 100));
    _zoomAuto = false;
    _aplicarZoom();
    _renderSel();
  }
  function _aplicarZoom() {
    var cv = document.getElementById('ed2Canvas');
    if (cv) { cv.style.transform = 'scale(' + _zoom + ')'; cv.style.transformOrigin = 'top left'; }
    var svg = cv && cv.querySelector('svg');
    if (cv && svg) {
      // reservar el espacio real (transform no afecta layout)
      var w = parseInt(svg.getAttribute('width'), 10) || 600, h = parseInt(svg.getAttribute('height'), 10) || 300;
      cv.style.width = w + 'px'; cv.style.height = h + 'px';
      var stage = document.getElementById('ed2Stage');
      if (stage) { stage.style.width = (w * _zoom) + 'px'; stage.style.height = (h * _zoom) + 'px'; }
    }
    var lbl = document.getElementById('ed2ZoomLbl');
    if (lbl) lbl.textContent = (_zoomAuto ? 'auto ' : '') + Math.round(_zoom * 100) + '%';
  }

  // ── historial / borrador ────────────────────────────────────────
  function _snapshot() {
    var snap = JSON.stringify(_plantilla);
    _historial = _historial.slice(0, _histIdx + 1);
    _historial.push(snap);
    if (_historial.length > 50) _historial.shift();
    _histIdx = _historial.length - 1;
    _autosave();
  }
  function _hayCambios() {
    if (_vista !== 'estudio' || !_plantilla) return false;
    return (_plantilla.capas || []).some(function(c) { return !_esFija(c); });
  }
  function _undo() {
    if (_histIdx <= 0) { _toast('Nada para deshacer'); return; }
    _dragState = null;
    _histIdx--;
    _plantilla = JSON.parse(_historial[_histIdx]);
    _selId = null;
    _renderCanvas();
  }
  function _redo() {
    if (_histIdx >= _historial.length - 1) { _toast('Nada para rehacer'); return; }
    _dragState = null;
    _histIdx++;
    _plantilla = JSON.parse(_historial[_histIdx]);
    _selId = null;
    _renderCanvas();
  }
  function _autosave() {
    clearTimeout(_autosaveTimer);
    _autosaveTimer = setTimeout(function() {
      try { localStorage.setItem(STORAGE_BORRADOR, JSON.stringify({ plantilla: _plantilla, ts: Date.now() })); } catch (_) {}
    }, 700);
  }
  function _cargarBorrador() {
    try {
      var raw = localStorage.getItem(STORAGE_BORRADOR);
      if (!raw) return null;
      var obj = JSON.parse(raw);
      if (Date.now() - obj.ts > 24 * 3600 * 1000) { localStorage.removeItem(STORAGE_BORRADOR); return null; }
      return obj;
    } catch (_) { return null; }
  }
  function _limpiarBorrador() { try { localStorage.removeItem(STORAGE_BORRADOR); } catch (_) {} }

  // ── teclado (desktop) ───────────────────────────────────────────
  function _keyHandler(e) {
    if (document.getElementById('ed2Dlg') || document.getElementById('ed2Print')) return;
    var enInput = /INPUT|TEXTAREA|SELECT/.test((e.target && e.target.tagName) || '');
    if ((e.ctrlKey || e.metaKey) && e.key === 'z') { e.preventDefault(); if (_vista === 'estudio') _undo(); return; }
    if ((e.ctrlKey || e.metaKey) && (e.key === 'y' || (e.shiftKey && e.key === 'Z'))) { e.preventDefault(); if (_vista === 'estudio') _redo(); return; }
    if (e.key === 'Escape') { if (_selId) { _seleccionar(null); } return; }
    if (_vista !== 'estudio' || enInput) return;
    var c = _capaSel();
    if (!c || _esFija(c)) return;
    var paso = e.shiftKey ? 2 : 0.5;
    var mapa = { ArrowLeft: [-paso, 0], ArrowRight: [paso, 0], ArrowUp: [0, -paso], ArrowDown: [0, paso] };
    if (mapa[e.key]) {
      e.preventDefault();
      c.x_mm = Math.max(0, Math.min(_plantilla.tamano.ancho_mm, c.x_mm + mapa[e.key][0]));
      c.y_mm = Math.max(0, Math.min(_plantilla.tamano.alto_mm, c.y_mm + mapa[e.key][1]));
      _snapshot();
      _renderCanvas();
    } else if (e.key === 'Delete' || e.key === 'Backspace') {
      e.preventDefault();
      _eliminarSel();
    }
  }

  // ── guardar al catálogo ─────────────────────────────────────────
  function _guardarAlCatalogo() {
    if (!_plantilla) return;
    _asegurarMembrete(_plantilla);
    var conv = _conv();
    var errores = conv ? conv.validar(_plantilla) : [];
    if (!(_plantilla.capas || []).some(function(c) { return !_esFija(c); })) {
      _toast('El aviso está vacío — agrega texto, un QR o un icono', 'error');
      return;
    }
    if (errores.length) { _toast('Revisa el diseño: ' + errores[0], 'error'); return; }
    var nombreActual = (_plantilla.metadata && _plantilla.metadata.nombre) || '';
    _dlg({
      titulo: '📌 Guardar al catálogo',
      cuerpo: 'La creación se guardará como <b>plantilla fija</b>: quedará en el catálogo lista para imprimir (con el membrete de la empresa).',
      input: nombreActual === 'Nueva creación' ? '' : nombreActual,
      placeholder: 'Nombre del aviso (ej. Oferta 2x1 sábados)',
      maxlength: 50,
      botones: [
        { txt: 'Cancelar', cls: 'ed2-btn-ghost', val: 'no' },
        { txt: '📌 Guardar', cls: 'ed2-btn-go', val: 'si' }
      ]
    }, function(val, txt) {
      if (val !== 'si') return;
      var nombre = String(txt || '').trim();
      if (!nombre) { _toast('Ponle un nombre al aviso', 'error'); return; }
      _plantilla.metadata = _plantilla.metadata || {};
      _plantilla.metadata.nombre = nombre;
      _plantilla.metadata.membrete = true;
      _apiPost('guardarAdhesivoPlantilla', {
        nombre: nombre,
        descripcion: 'Creado en el Estudio de Avisos',
        json: _plantilla
      }, function(err, r) {
        if (err || !r || !r.ok) {
          _toast('No se pudo guardar: ' + ((err && err.message) || (r && r.error) || 'desconocido'), 'error');
          return;
        }
        _limpiarBorrador();
        _historial = []; _histIdx = -1; _plantilla = null;
        _toast('📌 "' + nombre + '" guardado al catálogo ✓', 'ok');
        _vista = 'catalogo';
        _render();
        _refrescarCatalogo();
      });
    });
  }

  // ── API pública ─────────────────────────────────────────────────
  window.EditorAdhesivos = {
    abrir: abrir,
    _cerrar: _cerrar,
    _setBusqueda: _setBusqueda,
    _reintentarCat: _reintentarCat,
    _crearNuevo: _crearNuevo,
    _volverCatalogo: _volverCatalogo,
    _cerrarImprimir: _cerrarImprimir,
    _qty: _qty,
    _imprimir: _imprimir,
    _undo: _undo,
    _redo: _redo,
    _setNombre: _setNombre,
    _seleccionar: _seleccionar,
    _addTexto: _addTexto,
    _addQR: _addQR,
    _addBarcode: _addBarcode,
    _addLinea: _addLinea,
    _addRect: _addRect,
    _abrirIconos: _abrirIconos,
    _zoomDelta: _zoomDelta,
    _zoomFit: _zoomFit,
    _guardarAlCatalogo: _guardarAlCatalogo
  };
})();
