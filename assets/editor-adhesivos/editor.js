// ════════════════════════════════════════════════════════════════════
// EditorAdhesivos — UI motor del editor de avisos
// v1.0.0 — 2026-06-05
//
// Overlay fullscreen vanilla JS (sin Vue). Expone window.EditorAdhesivos.abrir().
// Depende de: IconosAdhesivo, EditorAdhesivosConverter, JsBarcode, MOS_API.
//
// Estado en memoria mientras está abierto:
//   _plantilla       JSON estructura activa
//   _idPlantillaActual  null = borrador / ID = guardada
//   _seleccionadaId  capa con outline
//   _historial[]     stack snapshots para undo
//   _historialIdx    posición actual en el stack
// ════════════════════════════════════════════════════════════════════
(function() {
  'use strict';
  if (window.EditorAdhesivos) return;

  var CSS_INYECTADO = false;
  var _plantilla = null;
  var _idPlantillaActual = null;
  var _seleccionadaId = null;
  var _historial = [];
  var _historialIdx = -1;
  var _plantillasGuardadas = [];
  var _autosaveTimer = null;
  var _catActiva = 'comercial';
  var _zoom = 1;

  var STORAGE_BORRADOR = 'eda_borrador_v1';
  var POST_URL_FALLBACK = null;  // se setea desde abrir()

  // ── Helpers utilitarios ──────────────────────────────────────────
  function _esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
    });
  }
  function _uuid() {
    return 'c-' + Math.random().toString(36).substring(2, 6) + Math.random().toString(36).substring(2, 4);
  }
  function _toast(msg, tipo) {
    var t = document.createElement('div');
    t.className = 'eda-toast' + (tipo ? ' ' + tipo : '');
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(function() {
      t.style.animation = 'edaFadeIn .2s reverse';
      setTimeout(function() { t.remove(); }, 220);
    }, 2400);
  }
  function _inyectarCss() {
    if (CSS_INYECTADO) return;
    var l = document.createElement('link');
    l.rel = 'stylesheet';
    // Path relativo al HTML que carga el editor
    var base = (typeof window.EDITOR_ADHESIVOS_BASE === 'string') ? window.EDITOR_ADHESIVOS_BASE : './assets/editor-adhesivos/';
    l.href = base + 'styles.css?v=1.0.0';
    document.head.appendChild(l);
    CSS_INYECTADO = true;
  }

  // ── Plantilla en blanco ─────────────────────────────────────────
  function _plantillaVacia() {
    return {
      version: 1,
      tamano: { ancho_mm: 50, alto_mm: 25, tipo: 'adhesivo' },
      metadata: { nombre: 'Nueva plantilla', fechaCreado: new Date().toISOString().slice(0, 10) },
      capas: []
    };
  }

  // ── Snapshot/historial ──────────────────────────────────────────
  function _snapshot() {
    var snap = JSON.stringify(_plantilla);
    // Truncar historial si estoy en el medio (rama nueva)
    _historial = _historial.slice(0, _historialIdx + 1);
    _historial.push(snap);
    if (_historial.length > 50) _historial.shift();
    _historialIdx = _historial.length - 1;
    _autosaveBorrador();
  }
  function _undo() {
    if (_historialIdx <= 0) { _toast('Nada para deshacer', 'error'); return; }
    _historialIdx--;
    _plantilla = JSON.parse(_historial[_historialIdx]);
    _seleccionadaId = null;
    _render();
  }
  function _redo() {
    if (_historialIdx >= _historial.length - 1) { _toast('Nada para rehacer', 'error'); return; }
    _historialIdx++;
    _plantilla = JSON.parse(_historial[_historialIdx]);
    _seleccionadaId = null;
    _render();
  }

  function _autosaveBorrador() {
    clearTimeout(_autosaveTimer);
    _autosaveTimer = setTimeout(function() {
      try { localStorage.setItem(STORAGE_BORRADOR, JSON.stringify({
        plantilla: _plantilla,
        idPlantillaActual: _idPlantillaActual,
        ts: Date.now()
      })); } catch(_) {}
    }, 800);
  }
  function _cargarBorrador() {
    try {
      var raw = localStorage.getItem(STORAGE_BORRADOR);
      if (!raw) return null;
      var obj = JSON.parse(raw);
      // Borrador vence a las 24h
      if (Date.now() - obj.ts > 24 * 3600 * 1000) {
        localStorage.removeItem(STORAGE_BORRADOR);
        return null;
      }
      return obj;
    } catch(_) { return null; }
  }
  function _limpiarBorrador() {
    try { localStorage.removeItem(STORAGE_BORRADOR); } catch(_) {}
  }

  // ── Render principal del editor ─────────────────────────────────
  function _render() {
    var ov = document.getElementById('edaOverlay');
    if (!ov) return;
    ov.innerHTML = _htmlToolbar() + _htmlBody();
    _wireToolbar();
    _wireSidebars();
    _wireCanvas();
    _renderListaCapas();
    _renderListaPlantillas();
    _renderPropiedades();
    setTimeout(function() {
      if (window.EditorAdhesivosConverter) {
        EditorAdhesivosConverter.dibujarBarcodes(document.getElementById('edaCanvas') || ov);
      }
    }, 30);
  }

  function _htmlToolbar() {
    var nombre = (_plantilla && _plantilla.metadata && _plantilla.metadata.nombre) || 'Sin nombre';
    var dirty = _idPlantillaActual ? '' : ' <small>• borrador</small>';
    return ''
      + '<div class="eda-toolbar">'
      +   '<button class="eda-btn" onclick="EditorAdhesivos._cerrar()">◀ Volver</button>'
      +   '<div class="eda-toolbar-title">🎨 Plantilla: ' + _esc(nombre) + dirty + '</div>'
      +   '<button class="eda-btn" onclick="EditorAdhesivos._undo()" title="Ctrl+Z">↶ Undo</button>'
      +   '<button class="eda-btn" onclick="EditorAdhesivos._redo()" title="Ctrl+Y">↷ Redo</button>'
      +   '<button class="eda-btn eda-btn-warn" onclick="EditorAdhesivos._testImpresion()">👁 Test impresión</button>'
      +   '<button class="eda-btn eda-btn-primary" onclick="EditorAdhesivos._abrirModalGuardar()">💾 Guardar</button>'
      +   '<button class="eda-btn eda-btn-info" onclick="EditorAdhesivos._abrirModalImprimir()">🖨 Imprimir</button>'
      + '</div>';
  }

  function _htmlBody() {
    return ''
      + '<div class="eda-body">'
      +   _htmlSidebarIzq()
      +   _htmlCanvasArea()
      +   _htmlSidebarDer()
      + '</div>';
  }

  function _htmlSidebarIzq() {
    var iconos = (window.IconosAdhesivo ? IconosAdhesivo.listar() : []);
    var iconosCat = iconos.filter(function(i) { return i.categoria === _catActiva; });
    var iconosHtml = iconosCat.map(function(i) {
      var dataUri = IconosAdhesivo.dataUri(i.id);
      return '<div class="eda-icono-thumb" title="' + _esc(i.label) + '" onclick="EditorAdhesivos._agregarIcono(\'' + i.id + '\')">'
           +   '<img src="' + dataUri + '" alt="' + _esc(i.label) + '">'
           + '</div>';
    }).join('');

    return ''
      + '<div class="eda-sidebar left">'
      +   '<h3>Herramientas</h3>'
      +   '<div class="eda-tools-grid">'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarTexto()"><span class="eda-tool-icon">✏</span>Texto</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarLinea()"><span class="eda-tool-icon">─</span>Línea</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarRect()"><span class="eda-tool-icon">▢</span>Borde</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarBarcode()"><span class="eda-tool-icon">▌</span>Barcode</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarQR()"><span class="eda-tool-icon">▢</span>QR</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._nuevaPlantilla()"><span class="eda-tool-icon">＋</span>Nueva</button>'
      +   '</div>'
      +   '<h3>Iconos</h3>'
      +   '<div class="eda-cat-tabs">'
      +     ['comercial', 'alerta', 'operativo', 'destaque'].map(function(c) {
              return '<div class="eda-cat-tab' + (c === _catActiva ? ' active' : '') + '" onclick="EditorAdhesivos._setCategoria(\'' + c + '\')">'
                   + (c === 'comercial' ? '💰' : c === 'alerta' ? '⚠' : c === 'operativo' ? '🏪' : '🎯')
                   + '</div>';
            }).join('')
      +   '</div>'
      +   '<div class="eda-iconos-grid">' + iconosHtml + '</div>'
      +   '<h3>Plantillas</h3>'
      +   '<div class="eda-plantillas" id="edaPlantillas"></div>'
      + '</div>';
  }

  function _htmlCanvasArea() {
    var anchoMm = _plantilla.tamano.ancho_mm;
    var altoMm  = _plantilla.tamano.alto_mm;
    var svg = window.EditorAdhesivosConverter
      ? EditorAdhesivosConverter.json2svg(_plantilla, { grid: true, gridMm: 5 })
      : '<div>Falta EditorAdhesivosConverter</div>';
    return ''
      + '<div class="eda-canvas-wrap">'
      +   '<div class="eda-canvas-info">Lienzo ' + anchoMm + ' × ' + altoMm + ' mm · TSC adhesivo · zoom ' + Math.round(_zoom * 100) + '%</div>'
      +   '<div class="eda-canvas" id="edaCanvas" style="transform:scale(' + _zoom + ');transform-origin:center">' + svg + _htmlOverlayCapas() + '</div>'
      +   '<div class="eda-canvas-controls">'
      +     '<label style="font-size:12px">Cantidad: </label>'
      +     '<input type="number" id="edaCantidad" class="eda-input" min="1" max="100" value="10" style="width:70px">'
      +     '<label style="font-size:12px;margin-left:12px">Zoom: </label>'
      +     '<select class="eda-select" onchange="EditorAdhesivos._setZoom(parseFloat(this.value))">'
      +       ['0.5', '0.75', '1', '1.25', '1.5', '2'].map(function(z) {
              return '<option value="' + z + '"' + (parseFloat(z) === _zoom ? ' selected' : '') + '>' + Math.round(z * 100) + '%</option>';
            }).join('')
      +     '</select>'
      +   '</div>'
      +   '<div style="font-size:11px;color:#94a3b8">⚠ Vista aproximada — usá "Test impresión" antes de imprimir N copias.</div>'
      + '</div>';
  }

  // Overlay con divs invisibles para capturar click/drag por capa
  function _htmlOverlayCapas() {
    if (!_plantilla) return '';
    var conv = window.EditorAdhesivosConverter;
    if (!conv) return '';
    return _plantilla.capas.map(function(c) {
      var x = conv.mm2px(c.x_mm), y = conv.mm2px(c.y_mm);
      var w = 40, h = 30;  // tamaño bounding mínimo
      if (c.tipo === 'icono') {
        w = conv.dots2px(c.tamano_dots || 48);
        h = w;
      } else if (c.tipo === 'rectangulo') {
        w = conv.mm2px(c.ancho_mm || 5);
        h = conv.mm2px(c.alto_mm || 5);
      } else if (c.tipo === 'linea') {
        w = conv.mm2px(c.ancho_mm || 0);
        h = Math.max(8, conv.mm2px(c.alto_mm || 0.5));
      } else if (c.tipo === 'texto') {
        var fpx = conv.fontPx(c.font || 3);
        w = String(c.texto || '').length * fpx * 0.55;
        h = fpx;
      } else if (c.tipo === 'barcode') {
        var bcLen = String(c.codigo || '').length;
        var modules = 11 * bcLen + 35;
        w = conv.dots2px(modules * (c.narrow || 2));
        h = conv.dots2px(c.alto_dots || 48);
      } else if (c.tipo === 'qr') {
        w = conv.dots2px(c.tamano_dots || 64);
        h = w;
      }
      var sel = (_seleccionadaId === c.id) ? ' selected' : '';
      return '<div class="eda-capa-hit' + sel + '" data-id="' + c.id + '" style="position:absolute;left:' + x + 'px;top:' + y + 'px;width:' + w + 'px;height:' + h + 'px;cursor:move;outline:' + (sel ? '2px dashed #6366f1' : 'none') + ';outline-offset:2px"></div>';
    }).join('');
  }

  function _htmlSidebarDer() {
    return ''
      + '<div class="eda-sidebar right">'
      +   '<h3>Propiedades</h3>'
      +   '<div id="edaPropiedades"></div>'
      +   '<h3 style="margin-top:14px">Capas</h3>'
      +   '<div class="eda-capas" id="edaCapas"></div>'
      + '</div>';
  }

  // ── Render dinámico de propiedades de la capa seleccionada ──────
  function _renderPropiedades() {
    var cont = document.getElementById('edaPropiedades');
    if (!cont) return;
    if (!_seleccionadaId) {
      cont.innerHTML = '<div class="eda-prop-empty">Seleccioná una capa<br>(clickeá en el lienzo o en la lista)</div>';
      return;
    }
    var capa = _plantilla.capas.find(function(c) { return c.id === _seleccionadaId; });
    if (!capa) {
      cont.innerHTML = '<div class="eda-prop-empty">Capa no encontrada</div>';
      _seleccionadaId = null;
      return;
    }
    var html = ''
      + _propRow('X (mm)',  '<input type="number" step="0.5" value="' + capa.x_mm + '" onchange="EditorAdhesivos._setProp(\'x_mm\', parseFloat(this.value))">')
      + _propRow('Y (mm)',  '<input type="number" step="0.5" value="' + capa.y_mm + '" onchange="EditorAdhesivos._setProp(\'y_mm\', parseFloat(this.value))">');

    if (capa.tipo === 'texto') {
      var textoEsc = _esc(capa.texto || '');
      html += _propRow('Texto', '<textarea onchange="EditorAdhesivos._setProp(\'texto\', this.value)">' + textoEsc + '</textarea>');
      html += _propRow('Font',  '<select onchange="EditorAdhesivos._setProp(\'font\', parseInt(this.value))">'
                              + [1,2,3,4,5].map(function(f) { return '<option value="' + f + '"' + (capa.font === f ? ' selected' : '') + '>Font ' + f + ' ' + ['chico','pequeño','medio','grande','MEGA'][f-1] + '</option>'; }).join('')
                              + '</select>');
      html += _propRow('Alineación', '<select onchange="EditorAdhesivos._setProp(\'alineacion\', this.value)">'
                              + ['left', 'center', 'right'].map(function(a) { return '<option value="' + a + '"' + (capa.alineacion === a ? ' selected' : '') + '>' + a + '</option>'; }).join('')
                              + '</select>');
      html += _propRow('Negrita', '<label><input type="checkbox"' + (capa.negrita ? ' checked' : '') + ' onchange="EditorAdhesivos._setProp(\'negrita\', this.checked)"> Bold</label>');
    }
    else if (capa.tipo === 'icono') {
      html += _propRow('Ícono', '<select onchange="EditorAdhesivos._setProp(\'idIcono\', this.value)">'
                              + (window.IconosAdhesivo ? IconosAdhesivo.listar().map(function(i) {
                                  return '<option value="' + i.id + '"' + (capa.idIcono === i.id ? ' selected' : '') + '>' + i.label + '</option>';
                                }).join('') : '')
                              + '</select>');
      html += _propRow('Tamaño (dots)', '<select onchange="EditorAdhesivos._setProp(\'tamano_dots\', parseInt(this.value))">'
                              + [32, 48, 64, 96].map(function(t) { return '<option value="' + t + '"' + (capa.tamano_dots === t ? ' selected' : '') + '>' + t + ' dots (' + (t/8).toFixed(1) + ' mm)</option>'; }).join('')
                              + '</select>');
    }
    else if (capa.tipo === 'linea') {
      html += _propRow('Ancho (mm)', '<input type="number" step="0.5" value="' + (capa.ancho_mm || 10) + '" onchange="EditorAdhesivos._setProp(\'ancho_mm\', parseFloat(this.value))">');
      html += _propRow('Grosor (mm)', '<input type="number" step="0.1" value="' + (capa.alto_mm || 0.5) + '" onchange="EditorAdhesivos._setProp(\'alto_mm\', parseFloat(this.value))">');
    }
    else if (capa.tipo === 'rectangulo') {
      html += _propRow('Ancho (mm)', '<input type="number" step="0.5" value="' + (capa.ancho_mm || 5) + '" onchange="EditorAdhesivos._setProp(\'ancho_mm\', parseFloat(this.value))">');
      html += _propRow('Alto (mm)',  '<input type="number" step="0.5" value="' + (capa.alto_mm || 5) + '" onchange="EditorAdhesivos._setProp(\'alto_mm\', parseFloat(this.value))">');
      html += _propRow('Grosor borde (px)', '<input type="number" min="1" max="5" value="' + (capa.grosor || 1) + '" onchange="EditorAdhesivos._setProp(\'grosor\', parseInt(this.value))">');
      html += _propRow('Relleno', '<label><input type="checkbox"' + (capa.relleno ? ' checked' : '') + ' onchange="EditorAdhesivos._setProp(\'relleno\', this.checked)"> Sólido</label>');
    }
    else if (capa.tipo === 'barcode') {
      html += _propRow('Código', '<input type="text" value="' + _esc(capa.codigo || '') + '" maxlength="14" onchange="EditorAdhesivos._setProp(\'codigo\', this.value)">');
      html += _propRow('Alto (dots)', '<input type="number" min="24" max="96" value="' + (capa.alto_dots || 48) + '" onchange="EditorAdhesivos._setProp(\'alto_dots\', parseInt(this.value))">');
    }
    else if (capa.tipo === 'qr') {
      html += _propRow('Contenido', '<input type="text" value="' + _esc(capa.codigo || '') + '" onchange="EditorAdhesivos._setProp(\'codigo\', this.value)">');
      html += _propRow('Tamaño (dots)', '<select onchange="EditorAdhesivos._setProp(\'tamano_dots\', parseInt(this.value))">'
                              + [40, 56, 72, 96].map(function(t) { return '<option value="' + t + '"' + (capa.tamano_dots === t ? ' selected' : '') + '>' + t + ' dots</option>'; }).join('')
                              + '</select>');
    }

    html += '<button class="eda-btn eda-btn-danger" style="width:100%;margin-top:8px" onclick="EditorAdhesivos._eliminarCapa()">🗑 Eliminar capa</button>';
    cont.innerHTML = html;
  }

  function _propRow(label, control) {
    return '<div class="eda-prop-row"><label>' + label + '</label>' + control + '</div>';
  }

  // ── Render lista de capas ───────────────────────────────────────
  function _renderListaCapas() {
    var cont = document.getElementById('edaCapas');
    if (!cont) return;
    if (!_plantilla.capas.length) {
      cont.innerHTML = '<div class="eda-prop-empty">Sin capas — agregá una desde herramientas</div>';
      return;
    }
    var TIPOS_ICON = { texto: '✏', icono: '◆', linea: '─', rectangulo: '▢', barcode: '▌', qr: '▢' };
    cont.innerHTML = _plantilla.capas.map(function(c, idx) {
      var sel = (_seleccionadaId === c.id) ? ' selected' : '';
      var label = c.tipo === 'texto' ? (c.texto || '(vacío)').substring(0, 18)
                : c.tipo === 'icono' ? (c.idIcono || '?')
                : c.tipo + ' ' + (c.ancho_mm || '')
                ;
      return '<div class="eda-capa-item' + sel + '" onclick="EditorAdhesivos._seleccionar(\'' + c.id + '\')">'
           +   '<span class="eda-capa-tipo">' + (TIPOS_ICON[c.tipo] || '?') + '</span>'
           +   '<span class="eda-capa-label">' + _esc(label) + '</span>'
           +   '<div class="eda-capa-actions">'
           +     '<button onclick="event.stopPropagation();EditorAdhesivos._subirCapa(\'' + c.id + '\')" title="Subir">↑</button>'
           +     '<button onclick="event.stopPropagation();EditorAdhesivos._bajarCapa(\'' + c.id + '\')" title="Bajar">↓</button>'
           +   '</div>'
           + '</div>';
    }).join('');
  }

  // ── Render lista de plantillas guardadas ────────────────────────
  function _renderListaPlantillas() {
    var cont = document.getElementById('edaPlantillas');
    if (!cont) return;
    if (!_plantillasGuardadas.length) {
      cont.innerHTML = '<div class="eda-prop-empty">Sin plantillas guardadas</div>';
      return;
    }
    cont.innerHTML = _plantillasGuardadas.map(function(p) {
      var sel = (_idPlantillaActual === p.idPlantilla) ? ' active' : '';
      return '<div class="eda-plantilla-item' + sel + '" onclick="EditorAdhesivos._cargarPlantilla(\'' + p.idPlantilla + '\')">'
           +   '<span class="eda-plantilla-icon">📋</span>'
           +   '<span class="eda-plantilla-name">' + _esc(p.nombre) + '</span>'
           + '</div>';
    }).join('');
  }

  // ── Wiring de eventos ───────────────────────────────────────────
  function _wireToolbar() { /* botones inline en onclick */ }
  function _wireSidebars() { /* idem */ }

  function _wireCanvas() {
    var canvas = document.getElementById('edaCanvas');
    if (!canvas) return;
    var hits = canvas.querySelectorAll('.eda-capa-hit');
    hits.forEach(function(h) {
      h.addEventListener('mousedown', _onDragStart);
      h.addEventListener('touchstart', _onDragStart, { passive: false });
      h.addEventListener('click', function(e) {
        e.stopPropagation();
        _seleccionar(h.getAttribute('data-id'));
      });
    });
    // Click en zona vacía = deseleccionar
    canvas.addEventListener('click', function(e) {
      if (e.target === canvas || e.target.tagName === 'svg' || e.target.tagName === 'SVG') {
        _seleccionar(null);
      }
    });
  }

  // ── Drag para mover capas ───────────────────────────────────────
  var _dragState = null;
  function _onDragStart(e) {
    e.preventDefault();
    var id = this.getAttribute('data-id');
    _seleccionar(id);
    var capa = _plantilla.capas.find(function(c) { return c.id === id; });
    if (!capa) return;
    var touch = e.touches ? e.touches[0] : e;
    _dragState = {
      id: id,
      capa: capa,
      startMouseX: touch.clientX,
      startMouseY: touch.clientY,
      startMm: { x: capa.x_mm, y: capa.y_mm }
    };
    document.addEventListener('mousemove', _onDragMove);
    document.addEventListener('mouseup', _onDragEnd);
    document.addEventListener('touchmove', _onDragMove, { passive: false });
    document.addEventListener('touchend', _onDragEnd);
  }
  function _onDragMove(e) {
    if (!_dragState) return;
    e.preventDefault();
    var touch = e.touches ? e.touches[0] : e;
    var dx = touch.clientX - _dragState.startMouseX;
    var dy = touch.clientY - _dragState.startMouseY;
    // px → mm. 1 dot = 1.5 px; 1 mm = 8 dots = 12 px (sin zoom)
    var PX_POR_MM = 12 * _zoom;
    var newX = _dragState.startMm.x + dx / PX_POR_MM;
    var newY = _dragState.startMm.y + dy / PX_POR_MM;
    // Snap a 0.5mm
    newX = Math.round(newX * 2) / 2;
    newY = Math.round(newY * 2) / 2;
    // Clamp dentro del lienzo
    newX = Math.max(0, Math.min(_plantilla.tamano.ancho_mm - 1, newX));
    newY = Math.max(0, Math.min(_plantilla.tamano.alto_mm - 1, newY));
    _dragState.capa.x_mm = newX;
    _dragState.capa.y_mm = newY;
    _renderSoloPosicionCapa(_dragState.id);
  }
  function _onDragEnd() {
    if (!_dragState) return;
    _dragState = null;
    document.removeEventListener('mousemove', _onDragMove);
    document.removeEventListener('mouseup', _onDragEnd);
    document.removeEventListener('touchmove', _onDragMove);
    document.removeEventListener('touchend', _onDragEnd);
    _snapshot();
    _render();
  }

  function _renderSoloPosicionCapa(id) {
    // Solo actualiza el div de hit + re-render del SVG completo (más simple)
    var canvas = document.getElementById('edaCanvas');
    if (!canvas) return;
    var conv = window.EditorAdhesivosConverter;
    if (!conv) return;
    var svgHtml = conv.json2svg(_plantilla, { grid: true, gridMm: 5 });
    canvas.innerHTML = svgHtml + _htmlOverlayCapas();
    _wireCanvas();
    if (conv.dibujarBarcodes) conv.dibujarBarcodes(canvas);
    _renderPropiedades();
  }

  // ── Acciones públicas ───────────────────────────────────────────
  function _agregarTexto() {
    _plantilla.capas.push({
      id: _uuid(), tipo: 'texto', x_mm: 10, y_mm: 10,
      texto: 'TEXTO', font: 3, alineacion: 'left', negrita: false, rotacion: 0
    });
    _seleccionadaId = _plantilla.capas[_plantilla.capas.length - 1].id;
    _snapshot();
    _render();
  }
  function _agregarIcono(idIcono) {
    _plantilla.capas.push({
      id: _uuid(), tipo: 'icono', x_mm: 5, y_mm: 5, idIcono: idIcono, tamano_dots: 48
    });
    _seleccionadaId = _plantilla.capas[_plantilla.capas.length - 1].id;
    _snapshot();
    _render();
  }
  function _agregarLinea() {
    _plantilla.capas.push({
      id: _uuid(), tipo: 'linea', x_mm: 5, y_mm: 12, ancho_mm: 40, alto_mm: 0.5
    });
    _seleccionadaId = _plantilla.capas[_plantilla.capas.length - 1].id;
    _snapshot();
    _render();
  }
  function _agregarRect() {
    _plantilla.capas.push({
      id: _uuid(), tipo: 'rectangulo', x_mm: 5, y_mm: 5, ancho_mm: 20, alto_mm: 10,
      grosor: 2, relleno: false
    });
    _seleccionadaId = _plantilla.capas[_plantilla.capas.length - 1].id;
    _snapshot();
    _render();
  }
  function _agregarBarcode() {
    _plantilla.capas.push({
      id: _uuid(), tipo: 'barcode', x_mm: 5, y_mm: 15, codigo: 'AVISO001',
      formato: '128', alto_dots: 48, narrow: 2
    });
    _seleccionadaId = _plantilla.capas[_plantilla.capas.length - 1].id;
    _snapshot();
    _render();
  }
  function _agregarQR() {
    _plantilla.capas.push({
      id: _uuid(), tipo: 'qr', x_mm: 30, y_mm: 5, codigo: 'https://', tamano_dots: 56
    });
    _seleccionadaId = _plantilla.capas[_plantilla.capas.length - 1].id;
    _snapshot();
    _render();
  }

  function _setCategoria(cat) {
    _catActiva = cat;
    _render();
  }

  function _setZoom(z) {
    _zoom = z;
    _render();
  }

  function _seleccionar(id) {
    _seleccionadaId = id;
    _renderPropiedades();
    _renderListaCapas();
    // Actualizar outline en overlay sin re-render completo
    var canvas = document.getElementById('edaCanvas');
    if (canvas) {
      canvas.querySelectorAll('.eda-capa-hit').forEach(function(h) {
        if (h.getAttribute('data-id') === id) h.style.outline = '2px dashed #6366f1';
        else h.style.outline = 'none';
      });
    }
  }

  function _setProp(prop, val) {
    var capa = _plantilla.capas.find(function(c) { return c.id === _seleccionadaId; });
    if (!capa) return;
    capa[prop] = val;
    _snapshot();
    _render();
  }

  function _eliminarCapa() {
    if (!_seleccionadaId) return;
    if (!confirm('¿Eliminar la capa seleccionada?')) return;
    _plantilla.capas = _plantilla.capas.filter(function(c) { return c.id !== _seleccionadaId; });
    _seleccionadaId = null;
    _snapshot();
    _render();
  }

  function _subirCapa(id) {
    var idx = _plantilla.capas.findIndex(function(c) { return c.id === id; });
    if (idx < 0 || idx >= _plantilla.capas.length - 1) return;
    var temp = _plantilla.capas[idx + 1];
    _plantilla.capas[idx + 1] = _plantilla.capas[idx];
    _plantilla.capas[idx] = temp;
    _snapshot();
    _render();
  }
  function _bajarCapa(id) {
    var idx = _plantilla.capas.findIndex(function(c) { return c.id === id; });
    if (idx <= 0) return;
    var temp = _plantilla.capas[idx - 1];
    _plantilla.capas[idx - 1] = _plantilla.capas[idx];
    _plantilla.capas[idx] = temp;
    _snapshot();
    _render();
  }

  function _nuevaPlantilla() {
    if (_plantilla.capas.length > 0) {
      if (!confirm('Hay capas sin guardar. ¿Crear plantilla nueva descartando?')) return;
    }
    _plantilla = _plantillaVacia();
    _idPlantillaActual = null;
    _seleccionadaId = null;
    _historial = [];
    _historialIdx = -1;
    _snapshot();
    _limpiarBorrador();
    _render();
    _toast('Plantilla nueva creada', 'success');
  }

  // ── Modales internos ────────────────────────────────────────────
  function _abrirModalGuardar() {
    var nombreActual = _plantilla.metadata && _plantilla.metadata.nombre || 'Sin nombre';
    var descActual = _plantilla.metadata && _plantilla.metadata.descripcion || '';
    var html = ''
      + '<div class="eda-modal-overlay" id="edaModalGuardar" onclick="if(event.target===this)EditorAdhesivos._cerrarModal()">'
      +   '<div class="eda-modal">'
      +     '<h2>💾 Guardar plantilla</h2>'
      +     '<div class="eda-prop-row">'
      +       '<label>Nombre (único)</label>'
      +       '<input type="text" id="edaGNombre" value="' + _esc(nombreActual) + '" maxlength="50">'
      +     '</div>'
      +     '<div class="eda-prop-row">'
      +       '<label>Descripción</label>'
      +       '<textarea id="edaGDesc">' + _esc(descActual) + '</textarea>'
      +     '</div>'
      +     '<div class="eda-modal-actions">'
      +       '<button class="eda-btn" onclick="EditorAdhesivos._cerrarModal()">Cancelar</button>'
      +       '<button class="eda-btn eda-btn-primary" onclick="EditorAdhesivos._guardar()">💾 Guardar</button>'
      +     '</div>'
      +   '</div>'
      + '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
  }

  function _abrirModalImprimir() {
    if (!_idPlantillaActual) {
      _toast('Guardá la plantilla antes de imprimir N copias', 'error');
      return;
    }
    var cant = (document.getElementById('edaCantidad') && parseInt(document.getElementById('edaCantidad').value)) || 10;
    var html = ''
      + '<div class="eda-modal-overlay" id="edaModalImprimir" onclick="if(event.target===this)EditorAdhesivos._cerrarModal()">'
      +   '<div class="eda-modal">'
      +     '<h2>🖨 Imprimir plantilla</h2>'
      +     '<p style="color:#94a3b8;font-size:13px">Se imprimirán <strong>' + cant + '</strong> etiquetas con drift incremental.</p>'
      +     '<div class="eda-modal-actions">'
      +       '<button class="eda-btn" onclick="EditorAdhesivos._cerrarModal()">Cancelar</button>'
      +       '<button class="eda-btn eda-btn-info" onclick="EditorAdhesivos._confirmarImprimir(' + cant + ')">🖨 Imprimir ' + cant + '</button>'
      +     '</div>'
      +   '</div>'
      + '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
  }

  function _cerrarModal() {
    ['edaModalGuardar', 'edaModalImprimir'].forEach(function(id) {
      var m = document.getElementById(id);
      if (m) m.remove();
    });
  }

  // ── Acciones backend ────────────────────────────────────────────
  function _apiPost(action, params, cb) {
    var url = POST_URL_FALLBACK;
    if (typeof window.MOS_API !== 'undefined' && window.MOS_API.post) {
      return window.MOS_API.post(action, params).then(function(r) { cb(null, r); }).catch(function(e) { cb(e); });
    }
    if (!url) { cb(new Error('Falta URL backend (MOS_API o EDITOR_BACKEND_URL)')); return; }
    // POST simple
    var body = Object.assign({}, params || {}, { accion: action });
    fetch(url, {
      method: 'POST', mode: 'cors', redirect: 'follow',
      headers: { 'Content-Type': 'text/plain;charset=utf-8' },
      body: JSON.stringify(body)
    }).then(function(r) { return r.json(); }).then(function(j) { cb(null, j); }).catch(cb);
  }

  function _guardar() {
    var nombre = document.getElementById('edaGNombre').value.trim();
    var desc   = document.getElementById('edaGDesc').value.trim();
    if (!nombre) { _toast('Ponele un nombre', 'error'); return; }

    if (!_plantilla.metadata) _plantilla.metadata = {};
    _plantilla.metadata.nombre = nombre;
    _plantilla.metadata.descripcion = desc;

    // Validar antes de mandar
    var errores = window.EditorAdhesivosConverter
      ? EditorAdhesivosConverter.validar(_plantilla)
      : [];
    if (errores.length > 0) {
      _toast('Plantilla inválida: ' + errores[0], 'error');
      console.warn('[EditorAdhesivos] errores:', errores);
      return;
    }

    _apiPost('guardarAdhesivoPlantilla', {
      nombre: nombre,
      descripcion: desc,
      json: _plantilla,
      idPlantilla: _idPlantillaActual || null
    }, function(err, r) {
      if (err || !r || !r.ok) {
        _toast('Error guardando: ' + (err && err.message || (r && r.error) || 'desconocido'), 'error');
        return;
      }
      _idPlantillaActual = r.idPlantilla;
      _toast(r.creado ? 'Plantilla creada' : 'Plantilla actualizada', 'success');
      _cerrarModal();
      _refrescarPlantillas();
      _render();
    });
  }

  function _testImpresion() {
    if (!_idPlantillaActual) {
      _toast('Guardá primero para hacer test', 'error');
      return;
    }
    _apiPost('testImpresionAdhesivoPlantilla', { idPlantilla: _idPlantillaActual }, function(err, r) {
      if (err || !r || !r.ok) {
        _toast('Error: ' + (err && err.message || (r && r.error) || '?'), 'error');
        return;
      }
      _toast('1 etiqueta de test enviada', 'success');
    });
  }

  function _confirmarImprimir(cant) {
    _apiPost('imprimirAdhesivoPlantilla', { idPlantilla: _idPlantillaActual, cantidad: cant }, function(err, r) {
      _cerrarModal();
      if (err || !r || !r.ok) {
        _toast('Error: ' + (err && err.message || (r && r.error) || '?'), 'error');
        return;
      }
      _toast(cant + ' etiquetas enviadas a la impresora', 'success');
    });
  }

  function _refrescarPlantillas() {
    _apiPost('listarAdhesivosPlantillas', {}, function(err, r) {
      if (err || !r || !r.ok) return;
      _plantillasGuardadas = r.plantillas || [];
      _renderListaPlantillas();
    });
  }

  function _cargarPlantilla(id) {
    var p = _plantillasGuardadas.find(function(x) { return x.idPlantilla === id; });
    if (!p) return;
    if (_plantilla.capas.length > 0 && _idPlantillaActual !== id) {
      if (!confirm('Descartar cambios y cargar "' + p.nombre + '"?')) return;
    }
    try {
      _plantilla = typeof p.json === 'string' ? JSON.parse(p.json) : p.json;
    } catch(e) {
      _toast('Plantilla corrupta', 'error');
      return;
    }
    if (!_plantilla.metadata) _plantilla.metadata = {};
    _plantilla.metadata.nombre = p.nombre;
    _plantilla.metadata.descripcion = p.descripcion;
    _idPlantillaActual = id;
    _seleccionadaId = null;
    _historial = [];
    _historialIdx = -1;
    _snapshot();
    _render();
    _toast('Plantilla cargada: ' + p.nombre, 'success');
  }

  function _cerrar() {
    if (_plantilla.capas.length > 0 && !_idPlantillaActual) {
      if (!confirm('Tenés capas sin guardar. ¿Salir igual?')) return;
    }
    var ov = document.getElementById('edaOverlay');
    if (ov) ov.remove();
    document.removeEventListener('keydown', _keyHandler);
  }

  function _keyHandler(e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'z') { e.preventDefault(); _undo(); }
    else if ((e.ctrlKey || e.metaKey) && (e.key === 'y' || (e.shiftKey && e.key === 'Z'))) { e.preventDefault(); _redo(); }
    else if (e.key === 'Escape' && _seleccionadaId) { _seleccionar(null); }
    else if (e.key === 'Delete' && _seleccionadaId) { _eliminarCapa(); }
  }

  // ── Entry point público ─────────────────────────────────────────
  function abrir(opts) {
    opts = opts || {};
    _inyectarCss();
    POST_URL_FALLBACK = opts.backendUrl || window.EDITOR_BACKEND_URL || null;

    // Cargar borrador si existe
    var borrador = _cargarBorrador();
    if (borrador && borrador.plantilla && borrador.plantilla.capas && borrador.plantilla.capas.length > 0) {
      if (confirm('Hay un borrador guardado de hace ' + Math.round((Date.now() - borrador.ts) / 60000) + ' min. ¿Recuperarlo?')) {
        _plantilla = borrador.plantilla;
        _idPlantillaActual = borrador.idPlantillaActual;
      } else {
        _plantilla = _plantillaVacia();
        _idPlantillaActual = null;
        _limpiarBorrador();
      }
    } else {
      _plantilla = _plantillaVacia();
      _idPlantillaActual = null;
    }
    _seleccionadaId = null;
    _historial = [];
    _historialIdx = -1;
    _snapshot();

    // Crear overlay
    var ov = document.createElement('div');
    ov.className = 'eda-overlay';
    ov.id = 'edaOverlay';
    document.body.appendChild(ov);

    document.addEventListener('keydown', _keyHandler);

    _render();
    _refrescarPlantillas();
  }

  window.EditorAdhesivos = {
    abrir: abrir,
    _cerrar: _cerrar,
    _undo: _undo,
    _redo: _redo,
    _agregarTexto: _agregarTexto,
    _agregarIcono: _agregarIcono,
    _agregarLinea: _agregarLinea,
    _agregarRect: _agregarRect,
    _agregarBarcode: _agregarBarcode,
    _agregarQR: _agregarQR,
    _setCategoria: _setCategoria,
    _setZoom: _setZoom,
    _seleccionar: _seleccionar,
    _setProp: _setProp,
    _eliminarCapa: _eliminarCapa,
    _subirCapa: _subirCapa,
    _bajarCapa: _bajarCapa,
    _nuevaPlantilla: _nuevaPlantilla,
    _abrirModalGuardar: _abrirModalGuardar,
    _abrirModalImprimir: _abrirModalImprimir,
    _cerrarModal: _cerrarModal,
    _guardar: _guardar,
    _testImpresion: _testImpresion,
    _confirmarImprimir: _confirmarImprimir,
    _cargarPlantilla: _cargarPlantilla
  };
})();
