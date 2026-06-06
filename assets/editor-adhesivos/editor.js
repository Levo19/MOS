// ════════════════════════════════════════════════════════════════════
// EditorAdhesivos — UI motor del editor de avisos
// v1.0.4 — 2026-06-05 — Audit profundo + fix printerId desde tabla:
//   • printerId leído desde IMPRESORAS tipo=ADHESIVO+ALMACEN (no Properties)
//   • Backend devuelve json YA parseado + flag jsonCorrupto
//   • UI marca plantillas corruptas con ⚠ rojo (no clickeable, solo borrar)
//   • Debounce impresión: _imprimiendo flag impide double-click x2 batches
//   • _undo/_redo cancela _dragState para evitar escritura a ref muerta
//   • CSS_VERSION constante (bumpear cuando cambie styles.css)
//   • Backend title PrintNode incluye nombre plantilla
//   • Backend defensa ancho_mm NaN/undefined en alineación
//   • Backend valida bytes.length > 0 antes de PrintNode
// v1.0.3 — 2026-06-05 — Pulido senior 9 items:
//   1) Auto-guardar antes de test si hay cambios sin guardar
//   2) Modal imprimir con preview SVG + advertencia + cantidad editable
//   3) Tooltips en todas las herramientas
//   4) Buscador de iconos (filtra por id o label, ignora tabs)
//   5) Indicador * + dot rojo en Guardar cuando hay cambios
//   6) Detectar cambios sin guardar al cargar otra plantilla / cerrar
//   7) Ctrl+S = abrir modal Guardar
//   8) Botón Duplicar plantilla (clona con sufijo "(copia)")
//   9) Botón Eliminar plantilla en lista (soft-delete)
//   + Helpers _hayCambiosSinGuardar() y _marcarGuardado() para tracking
//     limpio del estado dirty.
// v1.0.2 — 2026-06-05 — Wizard QR con 6 presets + tip educativo
// v1.0.1 — 2026-06-05 — Senior audit fixes (38 findings · 8 críticos):
//   #16 CRÍTICO  _apiPost enviaba `accion` pero backend lee `action`
//                → ABSOLUTAMENTE NADA llegaba al backend (bloqueante total)
//   #20 leak     canvas.onclick acumulaba listeners cada render
//                → 10 renders = 10 ejecuciones por click
//   #29 edge     clamp drag impedía poner capas en x=0/y=0 (borde)
//   #31 UX       errores sin .message mostraban "[object Object]"
//   #14 sync     consistencia line height con backend
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
  var _ultimoGuardado = null;    // [v1.0.3] JSON.stringify del estado guardado
  var _busquedaIconos = '';      // [v1.0.3] filtro buscador de iconos

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
  // [v1.0.4] CSS_VERSION constante — bumpear cuando cambie styles.css.
  // Antes era hardcoded inline '?v=1.0.0' → al actualizar estilos el cache
  // viejo se quedaba pegado en navegadores.
  var CSS_VERSION = '1.0.4';
  function _inyectarCss() {
    if (CSS_INYECTADO) return;
    var l = document.createElement('link');
    l.rel = 'stylesheet';
    var base = (typeof window.EDITOR_ADHESIVOS_BASE === 'string') ? window.EDITOR_ADHESIVOS_BASE : './assets/editor-adhesivos/';
    l.href = base + 'styles.css?v=' + CSS_VERSION;
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

  // [v1.0.3] Detector de cambios sin guardar. Si _ultimoGuardado == null
  // (plantilla nueva nunca guardada) → hay cambios solo si tiene capas.
  // Si != null → compara JSON. Ignora la metadata.nombre/desc para que
  // editar solo el título no marque como "modificado".
  function _hayCambiosSinGuardar() {
    if (_ultimoGuardado === null) {
      return _plantilla.capas.length > 0;
    }
    var snapActual = JSON.stringify({
      tamano: _plantilla.tamano,
      capas: _plantilla.capas
    });
    return snapActual !== _ultimoGuardado;
  }

  function _marcarGuardado() {
    _ultimoGuardado = JSON.stringify({
      tamano: _plantilla.tamano,
      capas: _plantilla.capas
    });
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
    // [v1.0.4 fix] Si hay drag en curso, _dragState.capa apunta a un
    // objeto que ya no estará en _plantilla.capas después del JSON.parse.
    // Cancelar el drag para evitar escrituras a referencia muerta.
    _dragState = null;
    _historialIdx--;
    _plantilla = JSON.parse(_historial[_historialIdx]);
    _seleccionadaId = null;
    _render();
  }
  function _redo() {
    if (_historialIdx >= _historial.length - 1) { _toast('Nada para rehacer', 'error'); return; }
    _dragState = null;  // [v1.0.4] mismo motivo que _undo
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

  // [v1.0.3] Toolbar con:
  //  - Asterisco visible si hay cambios sin guardar
  //  - Punto rojo palpitante en botón Guardar cuando hay cambios
  //  - Subtítulo dinámico (borrador / modificada / guardada)
  function _htmlToolbar() {
    var nombre = (_plantilla && _plantilla.metadata && _plantilla.metadata.nombre) || 'Sin nombre';
    var modif = _hayCambiosSinGuardar();
    var estado = !_idPlantillaActual ? ' <small style="color:#fbbf24">• borrador nuevo</small>'
              : modif                  ? ' <small style="color:#f87171">* con cambios sin guardar</small>'
              :                          ' <small style="color:#10b981">✓ guardada</small>';
    var asterisco = modif ? '<span style="color:#f87171;font-weight:900">*</span> ' : '';
    var dotGuardar = modif
      ? '<span style="display:inline-block;width:8px;height:8px;background:#f87171;border-radius:50%;margin-right:6px;animation:edaFadeIn 1s ease-in-out infinite alternate"></span>'
      : '';
    return ''
      + '<div class="eda-toolbar">'
      +   '<button class="eda-btn" onclick="EditorAdhesivos._cerrar()">◀ Volver</button>'
      +   '<div class="eda-toolbar-title">🎨 ' + asterisco + 'Plantilla: ' + _esc(nombre) + estado + '</div>'
      +   '<button class="eda-btn" onclick="EditorAdhesivos._undo()" title="Ctrl+Z">↶ Undo</button>'
      +   '<button class="eda-btn" onclick="EditorAdhesivos._redo()" title="Ctrl+Y">↷ Redo</button>'
      +   '<button class="eda-btn eda-btn-warn" onclick="EditorAdhesivos._testImpresion()" title="Imprime 1 etiqueta de prueba">👁 Test impresión</button>'
      +   '<button class="eda-btn eda-btn-primary" onclick="EditorAdhesivos._abrirModalGuardar()" title="Ctrl+S">' + dotGuardar + '💾 Guardar</button>'
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

  // [v1.0.3] Sidebar izq con:
  //  - Buscador de iconos (filtra por label o id)
  //  - Categoria tabs (si búsqueda activa, ignora tab — busca en TODOS)
  function _htmlSidebarIzq() {
    var iconos = (window.IconosAdhesivo ? IconosAdhesivo.listar() : []);
    var qLc = _busquedaIconos.toLowerCase().trim();
    var iconosFiltrados;
    if (qLc) {
      // Búsqueda activa: filtrar en TODAS las categorías
      iconosFiltrados = iconos.filter(function(i) {
        return i.id.toLowerCase().indexOf(qLc) >= 0
            || i.label.toLowerCase().indexOf(qLc) >= 0;
      });
    } else {
      iconosFiltrados = iconos.filter(function(i) { return i.categoria === _catActiva; });
    }
    var iconosHtml = iconosFiltrados.map(function(i) {
      var dataUri = IconosAdhesivo.dataUri(i.id);
      return '<div class="eda-icono-thumb" title="' + _esc(i.label) + '" onclick="EditorAdhesivos._agregarIcono(\'' + i.id + '\')">'
           +   '<img src="' + dataUri + '" alt="' + _esc(i.label) + '">'
           + '</div>';
    }).join('');
    if (iconosHtml === '' && qLc) {
      iconosHtml = '<div class="eda-prop-empty" style="grid-column:1/-1">Sin iconos para "' + _esc(_busquedaIconos) + '"</div>';
    }

    return ''
      + '<div class="eda-sidebar left">'
      +   '<h3>Herramientas</h3>'
      +   '<div class="eda-tools-grid">'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarTexto()" title="Capa de texto"><span class="eda-tool-icon">✏</span>Texto</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarLinea()" title="Línea horizontal o divisor"><span class="eda-tool-icon">─</span>Línea</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarRect()" title="Rectángulo con borde o relleno"><span class="eda-tool-icon">▢</span>Borde</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarBarcode()" title="Código de barras Code128"><span class="eda-tool-icon">▌</span>Barcode</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._agregarQR()" title="Wizard QR con presets"><span class="eda-tool-icon">▢</span>QR</button>'
      +     '<button class="eda-tool" onclick="EditorAdhesivos._nuevaPlantilla()" title="Empezar plantilla en blanco"><span class="eda-tool-icon">＋</span>Nueva</button>'
      +   '</div>'
      +   '<h3>Iconos</h3>'
      +   '<input type="text" class="eda-input" placeholder="🔍 Buscar icono..." value="' + _esc(_busquedaIconos) + '"'
      +     ' oninput="EditorAdhesivos._setBusquedaIconos(this.value)" style="width:100%;box-sizing:border-box;margin-bottom:8px">'
      +   (qLc ? '' : (''
      +   '<div class="eda-cat-tabs">'
      +     ['comercial', 'alerta', 'operativo', 'destaque'].map(function(c) {
              return '<div class="eda-cat-tab' + (c === _catActiva ? ' active' : '') + '" onclick="EditorAdhesivos._setCategoria(\'' + c + '\')" title="' + c + '">'
                   + (c === 'comercial' ? '💰' : c === 'alerta' ? '⚠' : c === 'operativo' ? '🏪' : '🎯')
                   + '</div>';
            }).join('')
      +   '</div>'))
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

  // [v1.0.3+v1.0.4] Lista de plantillas con:
  //  - Duplicar (⎘) y Eliminar (🗑) por plantilla
  //  - Indicador ⚠ + click-disabled para plantillas con JSON corrupto
  //    (detectado en backend `jsonCorrupto: true` en listarAdhesivosPlantillas)
  function _renderListaPlantillas() {
    var cont = document.getElementById('edaPlantillas');
    if (!cont) return;
    if (!_plantillasGuardadas.length) {
      cont.innerHTML = '<div class="eda-prop-empty">Sin plantillas guardadas</div>';
      return;
    }
    cont.innerHTML = _plantillasGuardadas.map(function(p) {
      var sel = (_idPlantillaActual === p.idPlantilla) ? ' active' : '';
      var idEsc = String(p.idPlantilla || '').replace(/'/g, "\\'");
      // [v1.0.4] Plantilla corrupta: no clickeable + indicador rojo
      if (p.jsonCorrupto) {
        return '<div class="eda-plantilla-item" style="opacity:.55;cursor:not-allowed" title="Plantilla con JSON corrupto — revisar en Sheets">'
             +   '<span class="eda-plantilla-icon" style="color:#f87171">⚠</span>'
             +   '<span class="eda-plantilla-name" style="color:#f87171">' + _esc(p.nombre) + ' (corrupta)</span>'
             +   '<div class="eda-capa-actions">'
             +     '<button onclick="event.stopPropagation();EditorAdhesivos._eliminarPlantilla(\'' + idEsc + '\')" title="Eliminar (soft-delete)">🗑</button>'
             +   '</div>'
             + '</div>';
      }
      return '<div class="eda-plantilla-item' + sel + '" onclick="EditorAdhesivos._cargarPlantilla(\'' + idEsc + '\')">'
           +   '<span class="eda-plantilla-icon">📋</span>'
           +   '<span class="eda-plantilla-name" title="' + _esc(p.descripcion || p.nombre) + '">' + _esc(p.nombre) + '</span>'
           +   '<div class="eda-capa-actions">'
           +     '<button onclick="event.stopPropagation();EditorAdhesivos._duplicarPlantilla(\'' + idEsc + '\')" title="Duplicar como nueva">⎘</button>'
           +     '<button onclick="event.stopPropagation();EditorAdhesivos._eliminarPlantilla(\'' + idEsc + '\')" title="Eliminar (soft-delete)">🗑</button>'
           +   '</div>'
           + '</div>';
    }).join('');
  }

  // ── Wiring de eventos ───────────────────────────────────────────
  function _wireToolbar() { /* botones inline en onclick */ }
  function _wireSidebars() { /* idem */ }

  // [v1.0.1 SENIOR AUDIT] Memory leak fix: el listener de click del canvas
  // se acumulaba en cada render (no había cleanup). Ahora se reemplaza el
  // contenedor canvas para limpiar todos sus listeners de un golpe.
  // Antes: 10 renders → 10 listeners → 10 ejecuciones por click.
  function _wireCanvas() {
    var canvas = document.getElementById('edaCanvas');
    if (!canvas) return;
    // Para el click de fondo: usar onclick directo (sobrescribe, no acumula)
    canvas.onclick = function(e) {
      var tg = e.target;
      if (tg === canvas || (tg.tagName && (tg.tagName === 'svg' || tg.tagName === 'SVG'))) {
        _seleccionar(null);
      }
    };
    var hits = canvas.querySelectorAll('.eda-capa-hit');
    hits.forEach(function(h) {
      // Listeners en el div hit son nuevos en cada render (el div es nuevo
      // tras innerHTML), así que no leak — son liberados al borrar el div.
      h.addEventListener('mousedown', _onDragStart);
      h.addEventListener('touchstart', _onDragStart, { passive: false });
      h.onclick = function(e) {
        e.stopPropagation();
        _seleccionar(h.getAttribute('data-id'));
      };
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
    // [v1.0.1 SENIOR AUDIT] Clamp: permitir capa en x=0 (borde izq) y hasta
    // anchoCanvas (no anchoCanvas-1). Antes restaba 1mm → no se podía
    // poner rectángulo borde que necesita x=0 con ancho=50mm.
    newX = Math.max(0, Math.min(_plantilla.tamano.ancho_mm, newX));
    newY = Math.max(0, Math.min(_plantilla.tamano.alto_mm, newY));
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
  // [v1.0.2] Wizard QR — antes inserte un QR vacío y obligaba al admin a
  // editar propiedades manualmente. Ahora abre modal con presets del
  // ecosistema + textarea + tamaño. UX guiado para casos comunes.
  function _agregarQR() {
    _abrirWizardQR();
  }

  function _abrirWizardQR() {
    if (document.getElementById('edaModalQR')) return;
    var presets = [
      { label: '🎯 MOS Admin',     url: 'https://levo19.github.io/MOS/' },
      { label: '📦 Warehouse',     url: 'https://levo19.github.io/warehouseMos-/' },
      { label: '⚡ MosExpress',    url: 'https://levo19.github.io/MosExpress/' },
      { label: '📧 Email',         url: 'mailto:luisvo.19@gmail.com' },
      { label: '📞 WhatsApp',      url: 'https://wa.me/51999999999' },
      { label: '🌐 URL libre',     url: 'https://' }
    ];
    var presetBtns = presets.map(function(p, i) {
      return '<button class="eda-btn" style="font-size:11px;padding:6px 10px"'
           + ' onclick="EditorAdhesivos._qrPreset(\'' + _esc(p.url) + '\')">'
           +   _esc(p.label)
           + '</button>';
    }).join('');
    var html = ''
      + '<div class="eda-modal-overlay" id="edaModalQR" onclick="if(event.target===this)EditorAdhesivos._cerrarModal()">'
      +   '<div class="eda-modal" style="max-width:560px">'
      +     '<h2>▢ Generar código QR</h2>'
      +     '<p style="color:#94a3b8;font-size:13px;margin-bottom:12px">'
      +       'El QR puede codificar una URL, texto, número de teléfono, email, o cualquier dato.'
      +     '</p>'
      +     '<div class="eda-prop-row">'
      +       '<label>Contenido del QR</label>'
      +       '<textarea id="edaQRTexto" placeholder="https://... o cualquier texto" rows="3" style="font-family:Consolas,monospace">https://</textarea>'
      +     '</div>'
      +     '<div style="margin:10px 0">'
      +       '<label style="font-size:11px;color:#94a3b8;font-weight:700;text-transform:uppercase;letter-spacing:1px">Atajos del ecosistema</label>'
      +       '<div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px">' + presetBtns + '</div>'
      +     '</div>'
      +     '<div class="eda-prop-row">'
      +       '<label>Tamaño del QR</label>'
      +       '<select id="edaQRTamano">'
      +         '<option value="40">40 dots · 5 mm — chico (test rápido)</option>'
      +         '<option value="56">56 dots · 7 mm — mediano</option>'
      +         '<option value="80" selected>80 dots · 10 mm — grande (recomendado)</option>'
      +         '<option value="96">96 dots · 12 mm — extra grande</option>'
      +       '</select>'
      +     '</div>'
      +     '<div style="background:rgba(99,102,241,.1);border-left:3px solid #6366f1;padding:8px 12px;border-radius:4px;margin-top:10px;font-size:12px;color:#a5b4fc">'
      +       '<strong>Tip:</strong> los QR más grandes son más fáciles de escanear desde lejos. '
      +       'Para distancias mayores a 30 cm, usá 80 dots o más.'
      +     '</div>'
      +     '<div class="eda-modal-actions">'
      +       '<button class="eda-btn" onclick="EditorAdhesivos._cerrarModal()">Cancelar</button>'
      +       '<button class="eda-btn eda-btn-primary" onclick="EditorAdhesivos._confirmarWizardQR()">▢ Insertar QR</button>'
      +     '</div>'
      +   '</div>'
      + '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
    // Focus textarea y seleccionar contenido al abrir
    setTimeout(function() {
      var ta = document.getElementById('edaQRTexto');
      if (ta) { ta.focus(); ta.select(); }
    }, 50);
  }

  function _qrPreset(url) {
    var ta = document.getElementById('edaQRTexto');
    if (!ta) return;
    ta.value = url;
    ta.focus();
    // Seleccionar todo para que el admin pueda editar rápido si quiere
    setTimeout(function() { ta.select(); }, 0);
  }

  function _confirmarWizardQR() {
    var ta = document.getElementById('edaQRTexto');
    var sel = document.getElementById('edaQRTamano');
    if (!ta || !sel) return;
    var contenido = String(ta.value || '').trim();
    var tamano = parseInt(sel.value) || 80;
    if (!contenido) {
      _toast('Pone algún contenido en el QR', 'error');
      ta.focus();
      return;
    }
    // QR Code 128 chars suele ser el límite práctico para legibilidad
    if (contenido.length > 200) {
      if (!confirm('El QR tiene ' + contenido.length + ' caracteres — puede ser difícil de escanear. ¿Insertar igual?')) return;
    }
    _plantilla.capas.push({
      id: _uuid(), tipo: 'qr',
      x_mm: 10, y_mm: 5,
      codigo: contenido,
      tamano_dots: tamano
    });
    _seleccionadaId = _plantilla.capas[_plantilla.capas.length - 1].id;
    _snapshot();
    _cerrarModal();
    _render();
    var resumen = contenido.length > 30 ? contenido.substring(0, 27) + '...' : contenido;
    _toast('QR insertado · ' + resumen, 'success');
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
    // [v1.0.3] _hayCambiosSinGuardar también detecta plantillas guardadas modificadas
    if (_hayCambiosSinGuardar()) {
      if (!confirm('Hay cambios sin guardar. ¿Crear plantilla nueva descartando?')) return;
    }
    _plantilla = _plantillaVacia();
    _idPlantillaActual = null;
    _ultimoGuardado = null;
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

  // [v1.0.3] Modal de imprimir con PREVIEW visual del adhesivo + advertencia
  // si hay cambios sin guardar. Antes era solo un confirm seco.
  function _abrirModalImprimir() {
    if (!_idPlantillaActual) {
      _toast('Guardá la plantilla antes de imprimir N copias', 'error');
      return;
    }
    var cant = (document.getElementById('edaCantidad') && parseInt(document.getElementById('edaCantidad').value)) || 10;
    var hayCambios = _hayCambiosSinGuardar();

    // Preview SVG escalado al 60% para mostrar en modal compacto
    var svgPreview = '';
    if (window.EditorAdhesivosConverter) {
      var svg = EditorAdhesivosConverter.json2svg(_plantilla, { grid: false });
      svgPreview = '<div style="transform:scale(.6);transform-origin:top center;width:600px;height:300px;margin:0 auto -120px">' + svg + '</div>';
    }

    var warnHtml = hayCambios
      ? '<div style="background:rgba(239,68,68,.15);border-left:3px solid #f87171;padding:10px 14px;border-radius:4px;margin:10px 0;font-size:13px;color:#fca5a5">'
      +   '⚠ <strong>Atención:</strong> hay cambios sin guardar. La impresión usa la versión GUARDADA en el backend, no lo que ves arriba. '
      +   '<button class="eda-btn" style="margin-left:6px;font-size:11px;padding:4px 8px" onclick="EditorAdhesivos._cerrarModal();EditorAdhesivos._abrirModalGuardar()">💾 Guardar primero</button>'
      + '</div>'
      : '';

    var html = ''
      + '<div class="eda-modal-overlay" id="edaModalImprimir" onclick="if(event.target===this)EditorAdhesivos._cerrarModal()">'
      +   '<div class="eda-modal" style="max-width:680px">'
      +     '<h2>🖨 Imprimir plantilla</h2>'
      +     '<p style="color:#94a3b8;font-size:13px;margin-bottom:14px"><strong>' + _esc(_plantilla.metadata.nombre || 'Sin nombre') + '</strong></p>'
      +     svgPreview
      +     warnHtml
      +     '<div class="eda-prop-row">'
      +       '<label>Cantidad de etiquetas</label>'
      +       '<input type="number" id="edaImprCant" min="1" max="100" value="' + cant + '" style="font-size:24px;font-weight:900;text-align:center">'
      +     '</div>'
      +     '<div style="font-size:12px;color:#94a3b8;margin-top:6px">Drift incremental compensado en BATCH. PrintNode procesa todo en 1 job.</div>'
      +     '<div class="eda-modal-actions">'
      +       '<button class="eda-btn" onclick="EditorAdhesivos._cerrarModal()">Cancelar</button>'
      +       '<button class="eda-btn eda-btn-info" onclick="EditorAdhesivos._confirmarImprimirDesdeModal()">🖨 Imprimir</button>'
      +     '</div>'
      +   '</div>'
      + '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
    // Dibujar barcodes del SVG preview
    setTimeout(function() {
      var modal = document.getElementById('edaModalImprimir');
      if (modal && window.EditorAdhesivosConverter) {
        EditorAdhesivosConverter.dibujarBarcodes(modal);
      }
    }, 30);
  }

  function _confirmarImprimirDesdeModal() {
    var inp = document.getElementById('edaImprCant');
    var cant = parseInt(inp && inp.value) || 1;
    if (cant < 1 || cant > 100) {
      _toast('Cantidad fuera de rango (1-100)', 'error');
      return;
    }
    _confirmarImprimir(cant);
  }

  function _cerrarModal() {
    // [v1.0.2] Incluye edaModalQR (wizard QR nuevo)
    ['edaModalGuardar', 'edaModalImprimir', 'edaModalQR'].forEach(function(id) {
      var m = document.getElementById(id);
      if (m) m.remove();
    });
  }

  // ── Acciones backend ────────────────────────────────────────────
  // [v1.0.1 SENIOR AUDIT FIX BLOQUEANTE] action vs accion: el backend MOS
  // (Code.gs _route) lee `params.action`, NO `params.accion`. La versión
  // previa enviaba `accion` y absolutamente NADA llegaba al backend.
  // También: mejor manejo de errores (no devolver objetos sin .message
  // que rompen el toast con "[object Object]").
  function _apiPost(action, params, cb) {
    function safeCb(err, res) {
      // Normalizar error para que siempre tenga .message
      if (err && typeof err === 'object' && !err.message) {
        err = new Error(String(err.error || err.toString() || 'error desconocido'));
      }
      cb(err, res);
    }
    var url = POST_URL_FALLBACK;
    if (typeof window.MOS_API !== 'undefined' && window.MOS_API.post) {
      return window.MOS_API.post(action, params)
        .then(function(r) { safeCb(null, r); })
        .catch(function(e) { safeCb(e); });
    }
    if (!url) { safeCb(new Error('Falta URL backend (MOS_API o EDITOR_BACKEND_URL)')); return; }
    // POST simple — la KEY correcta es "action", NO "accion"
    var body = Object.assign({}, params || {}, { action: action });
    fetch(url, {
      method: 'POST', mode: 'cors', redirect: 'follow',
      headers: { 'Content-Type': 'text/plain;charset=utf-8' },
      body: JSON.stringify(body)
    })
    .then(function(r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    })
    .then(function(j) { safeCb(null, j); })
    .catch(function(e) { safeCb(e); });
  }

  // [v1.0.3] _guardar acepta callback opcional (para chainear con
  // testImpresion → guardar y luego testear). También marca el estado
  // como "guardado" (limpia el flag de cambios sin guardar).
  function _guardar(cb) {
    var nombreInp = document.getElementById('edaGNombre');
    var nombre = nombreInp ? nombreInp.value.trim() : (_plantilla.metadata && _plantilla.metadata.nombre) || '';
    var descInp = document.getElementById('edaGDesc');
    var desc = descInp ? descInp.value.trim() : (_plantilla.metadata && _plantilla.metadata.descripcion) || '';
    if (!nombre) {
      _toast('Ponele un nombre', 'error');
      if (cb) cb(false);
      return;
    }

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
      if (cb) cb(false);
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
        if (cb) cb(false);
        return;
      }
      _idPlantillaActual = r.idPlantilla;
      _marcarGuardado();  // [v1.0.3] limpia flag de cambios sin guardar
      _toast(r.creado ? 'Plantilla creada' : 'Plantilla actualizada', 'success');
      _cerrarModal();
      _refrescarPlantillas();
      _render();
      if (cb) cb(true);
    });
  }

  // [v1.0.3] Duplicar plantilla — clona el JSON, agrega "(copia)" al
  // nombre, limpia _idPlantillaActual para que sea nueva, abre el modal
  // de guardar para que el admin confirme el nuevo nombre.
  function _duplicarPlantilla(id) {
    var p = _plantillasGuardadas.find(function(x) { return x.idPlantilla === id; });
    if (!p) { _toast('Plantilla no encontrada', 'error'); return; }
    if (_hayCambiosSinGuardar()) {
      if (!confirm('Hay cambios sin guardar en la plantilla actual. ¿Descartar y duplicar "' + p.nombre + '"?')) return;
    }
    var clon;
    try {
      clon = typeof p.json === 'string' ? JSON.parse(p.json) : JSON.parse(JSON.stringify(p.json));
    } catch(e) {
      _toast('Plantilla origen corrupta', 'error');
      return;
    }
    if (!clon.metadata) clon.metadata = {};
    clon.metadata.nombre = (p.nombre + ' (copia)').substring(0, 50);
    clon.metadata.descripcion = p.descripcion || '';
    _plantilla = clon;
    _idPlantillaActual = null;       // marca como NUEVA (no actualizar la original)
    _ultimoGuardado = null;          // sin guardar todavía
    _seleccionadaId = null;
    _historial = [];
    _historialIdx = -1;
    _snapshot();
    _render();
    _toast('Duplicada como "' + clon.metadata.nombre + '" — guardá para confirmar', 'success');
    setTimeout(_abrirModalGuardar, 200);
  }

  // [v1.0.3] Eliminar plantilla (soft-delete en backend).
  function _eliminarPlantilla(id) {
    var p = _plantillasGuardadas.find(function(x) { return x.idPlantilla === id; });
    if (!p) return;
    if (!confirm('¿Eliminar la plantilla "' + p.nombre + '"?\n\nEs soft-delete (recuperable desde Sheets cambiando activo=TRUE).')) return;
    _apiPost('eliminarAdhesivoPlantilla', { idPlantilla: id }, function(err, r) {
      if (err || !r || !r.ok) {
        _toast('Error: ' + (err && err.message || (r && r.error) || '?'), 'error');
        return;
      }
      _toast('Plantilla eliminada', 'success');
      // Si era la actualmente cargada, limpiar editor
      if (_idPlantillaActual === id) {
        _plantilla = _plantillaVacia();
        _idPlantillaActual = null;
        _ultimoGuardado = null;
        _historial = [];
        _historialIdx = -1;
        _snapshot();
      }
      _refrescarPlantillas();
      _render();
    });
  }

  // [v1.0.3] Setear búsqueda de iconos sin perder el foco del input.
  // _render() recrea todo el DOM, perdiendo cursor del search. Por eso
  // re-renderizamos solo el sidebar izq y restauramos el foco.
  function _setBusquedaIconos(val) {
    _busquedaIconos = String(val || '');
    var sidebar = document.querySelector('.eda-sidebar.left');
    if (sidebar) {
      sidebar.outerHTML = _htmlSidebarIzq();
      // Reasignar foco al input de búsqueda y poner cursor al final
      setTimeout(function() {
        var nuevoInp = document.querySelector('.eda-sidebar.left input.eda-input');
        if (nuevoInp) {
          nuevoInp.focus();
          nuevoInp.setSelectionRange(_busquedaIconos.length, _busquedaIconos.length);
        }
      }, 0);
      _renderListaPlantillas();
    }
  }

  // [v1.0.3 SENIOR FIX] Auto-guardar antes de test si hay cambios.
  // ANTES: test imprimía la plantilla del BACKEND (lo guardado), pero el
  // admin veía lo del EDITOR (lo modificado) → frustración "imprimió mal,
  // no lo que veo". AHORA: detecta cambios y ofrece auto-guardar.
  function _testImpresion() {
    if (!_idPlantillaActual) {
      if (!confirm('Plantilla nueva sin guardar. ¿Querés guardarla primero para hacer el test?')) return;
      _abrirModalGuardar();
      return;
    }
    if (_hayCambiosSinGuardar()) {
      if (!confirm('Hay cambios sin guardar.\n\nEl test imprimirá la versión GUARDADA en el backend, no lo que ves en pantalla.\n\n¿Guardar primero?')) {
        // Si dice "No" → testea la versión guardada igual
        _ejecutarTestImpresion();
        return;
      }
      // Auto-guardar y luego testear
      _guardar(function(ok) {
        if (ok) _ejecutarTestImpresion();
      });
      return;
    }
    _ejecutarTestImpresion();
  }

  function _ejecutarTestImpresion() {
    _apiPost('testImpresionAdhesivoPlantilla', { idPlantilla: _idPlantillaActual }, function(err, r) {
      if (err || !r || !r.ok) {
        _toast('Error: ' + (err && err.message || (r && r.error) || '?'), 'error');
        return;
      }
      _toast('1 etiqueta de test enviada', 'success');
    });
  }

  // [v1.0.4] Debounce contra double-click: bloquea reentradas mientras
  // hay impresión en curso. Antes 2 clicks rápidos = 2 batches (20 etiquetas
  // en lugar de 10).
  var _imprimiendo = false;
  function _confirmarImprimir(cant) {
    if (_imprimiendo) { _toast('Espera, ya hay una impresión en curso', 'error'); return; }
    _imprimiendo = true;
    // Deshabilitar visualmente el botón en el modal
    var modalImpr = document.getElementById('edaModalImprimir');
    if (modalImpr) {
      modalImpr.querySelectorAll('button').forEach(function(b) { b.disabled = true; b.style.opacity = '.5'; });
    }
    _apiPost('imprimirAdhesivoPlantilla', { idPlantilla: _idPlantillaActual, cantidad: cant }, function(err, r) {
      _imprimiendo = false;
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
    // [v1.0.3] Detectar cambios sin guardar tanto en plantilla nueva como
    // en plantilla cargada y modificada. Antes solo chequeaba si era nueva.
    if (_hayCambiosSinGuardar() && _idPlantillaActual !== id) {
      if (!confirm('Hay cambios sin guardar en la plantilla actual. ¿Descartar y cargar "' + p.nombre + '"?')) return;
    }
    try {
      _plantilla = typeof p.json === 'string' ? JSON.parse(p.json) : JSON.parse(JSON.stringify(p.json));
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
    _marcarGuardado();  // [v1.0.3] recién cargada = sin cambios pendientes
    _render();
    _toast('Plantilla cargada: ' + p.nombre, 'success');
  }

  // [v1.0.3] Cerrar editor con detección de cambios robusta.
  // ANTES: solo verificaba plantillas NUEVAS sin guardar (ignoraba
  // modificaciones sobre plantillas ya guardadas). AHORA: usa
  // _hayCambiosSinGuardar() que cubre ambos casos.
  function _cerrar() {
    if (_hayCambiosSinGuardar()) {
      var msg = _idPlantillaActual
        ? 'La plantilla tiene cambios sin guardar. ¿Salir descartando?'
        : 'Tenés una plantilla nueva sin guardar. ¿Salir descartando?';
      if (!confirm(msg)) return;
    }
    var ov = document.getElementById('edaOverlay');
    if (ov) ov.remove();
    document.removeEventListener('keydown', _keyHandler);
  }

  function _keyHandler(e) {
    // No interceptar atajos cuando el foco está en un input/textarea
    // (sino Ctrl+Z dentro del textarea no funciona).
    var tag = e.target && e.target.tagName;
    var enInput = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
    if ((e.ctrlKey || e.metaKey) && e.key === 's') {
      // [v1.0.3] Ctrl+S → guardar
      e.preventDefault();
      _abrirModalGuardar();
      return;
    }
    if (enInput) return;
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
    _ultimoGuardado = null;  // [v1.0.3] al abrir, no hay nada "guardado" aún
    _busquedaIconos = '';
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
    // [v1.0.2] Wizard QR
    _abrirWizardQR: _abrirWizardQR,
    _qrPreset: _qrPreset,
    _confirmarWizardQR: _confirmarWizardQR,
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
    _confirmarImprimirDesdeModal: _confirmarImprimirDesdeModal,
    _cargarPlantilla: _cargarPlantilla,
    // [v1.0.3] Pulido senior — 9 mejoras UX
    _duplicarPlantilla: _duplicarPlantilla,
    _eliminarPlantilla: _eliminarPlantilla,
    _setBusquedaIconos: _setBusquedaIconos
  };
})();
