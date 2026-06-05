// ════════════════════════════════════════════════════════════════════
// EditorAdhesivosConverter — JSON ↔ SVG (preview) ↔ TSPL (info)
// v1.0.0 — 2026-06-05
//
// El backend (gas/AdhesivosPersonalizados.gs) tiene su propio json2tspl
// que es la fuente autoritativa de impresión. Este converter es solo:
//   • json2svg(plantilla) → HTML SVG para preview pixel-perfect
//   • validar(plantilla)  → errores de capas fuera de canvas/etc
//   • mm2dots(mm)         → conversor 8 dots/mm (TSC 203 DPI)
//
// La regla 1 dot TSPL = 1.5 px CSS se mantiene (consistente con
// AdhesivoPreview). Para canvas 50×25mm: 400×200 dots = 600×300 px.
// ════════════════════════════════════════════════════════════════════
(function() {
  'use strict';
  if (window.EditorAdhesivosConverter) return;

  var DOTS_POR_MM = 8;   // TSC 203 DPI = 8 dots/mm
  var PX_POR_DOT  = 1.5; // misma regla que AdhesivoPreview

  function _mm2dots(mm) { return Math.round(mm * DOTS_POR_MM); }
  function _dots2px(d)  { return Math.round(d * PX_POR_DOT); }
  function _mm2px(mm)   { return _dots2px(_mm2dots(mm)); }

  function _esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
    });
  }

  // Mapeo Font TSPL → px CSS aproximado (los TSPL bitmap fonts no tienen
  // equivalente vector exacto; aproximamos para preview).
  // Font 1 = 8×12 dots → 12 px tall · Font 2 = 12×20 → 20 px
  // Font 3 = 16×24 → 24 px · Font 4 = 24×32 → 32 px · Font 5 = 32×48 → 48 px
  function _fontPx(font) {
    return { 1: 12, 2: 20, 3: 24, 4: 32, 5: 48 }[font] || 24;
  }
  function _fontDots(font) {
    return { 1: 12, 2: 20, 3: 24, 4: 32, 5: 48 }[font] || 24;
  }

  // ── Validación de plantilla ─────────────────────────────────────
  function _validar(plantilla) {
    var errores = [];
    if (!plantilla || typeof plantilla !== 'object') {
      errores.push('Plantilla inválida (no es objeto)');
      return errores;
    }
    if (!plantilla.tamano || !plantilla.tamano.ancho_mm || !plantilla.tamano.alto_mm) {
      errores.push('Falta tamano.ancho_mm / alto_mm');
    }
    if (!Array.isArray(plantilla.capas)) {
      errores.push('Falta array de capas');
      return errores;
    }
    if (plantilla.capas.length === 0) {
      errores.push('La plantilla no tiene capas (canvas vacío)');
    }
    if (plantilla.capas.length > 20) {
      errores.push('Demasiadas capas (máx 20, hay ' + plantilla.capas.length + ')');
    }
    var anchoMm = plantilla.tamano.ancho_mm, altoMm = plantilla.tamano.alto_mm;
    plantilla.capas.forEach(function(c, i) {
      var prefix = '[Capa ' + (i + 1) + ' · ' + (c.tipo || '?') + ']';
      if (typeof c.x_mm !== 'number' || typeof c.y_mm !== 'number') {
        errores.push(prefix + ' falta x_mm/y_mm'); return;
      }
      if (c.x_mm < 0 || c.y_mm < 0) {
        errores.push(prefix + ' posición negativa');
      }
      var anchoCapa = c.ancho_mm || 0;
      var altoCapa  = c.alto_mm  || 0;
      // Para texto/icono estimamos
      if (c.tipo === 'icono') {
        var dots = c.tamano_dots || 48;
        anchoCapa = dots / DOTS_POR_MM;
        altoCapa  = dots / DOTS_POR_MM;
      } else if (c.tipo === 'texto') {
        var fpx = _fontDots(c.font || 3);
        anchoCapa = (String(c.texto || '').length * fpx * 0.55) / DOTS_POR_MM;
        altoCapa  = fpx / DOTS_POR_MM;
      } else if (c.tipo === 'barcode') {
        var alto = (c.alto_dots || 48);
        altoCapa = alto / DOTS_POR_MM;
        anchoCapa = 370 / DOTS_POR_MM;  // ancho típico
      } else if (c.tipo === 'qr') {
        var sz = c.tamano_dots || 64;
        anchoCapa = sz / DOTS_POR_MM;
        altoCapa  = sz / DOTS_POR_MM;
      }
      // No bloqueamos por texto/icono parcialmente fuera porque el cálculo es
      // estimativo. Solo validamos posición de origen.
      if (c.x_mm > anchoMm) errores.push(prefix + ' X fuera del lienzo (X=' + c.x_mm + ' > ' + anchoMm + ')');
      if (c.y_mm > altoMm)  errores.push(prefix + ' Y fuera del lienzo (Y=' + c.y_mm + ' > ' + altoMm + ')');

      // Validaciones específicas
      if (c.tipo === 'texto' && (!c.texto || !String(c.texto).trim())) {
        errores.push(prefix + ' texto vacío');
      }
      if (c.tipo === 'icono' && !c.idIcono) {
        errores.push(prefix + ' falta idIcono');
      }
      if (c.tipo === 'barcode' && !c.codigo) {
        errores.push(prefix + ' falta código de barra');
      }
      if (c.tipo === 'barcode' && String(c.codigo || '').length > 14) {
        errores.push(prefix + ' código muy largo (' + c.codigo.length + ' chars) — puede ser ilegible');
      }
    });
    return errores;
  }

  // ── JSON → SVG preview pixel-perfect ────────────────────────────
  function _json2svg(plantilla, opts) {
    opts = opts || {};
    var anchoDots = _mm2dots(plantilla.tamano.ancho_mm);
    var altoDots  = _mm2dots(plantilla.tamano.alto_mm);
    var anchoPx = _dots2px(anchoDots);
    var altoPx  = _dots2px(altoDots);

    var elementos = [];
    (plantilla.capas || []).forEach(function(c) {
      var x = _mm2px(c.x_mm), y = _mm2px(c.y_mm);
      switch (c.tipo) {
        case 'texto':
          elementos.push(_svgTexto(c, x, y));
          break;
        case 'icono':
          elementos.push(_svgIcono(c, x, y));
          break;
        case 'linea':
          var w = _mm2px(c.ancho_mm || 0), h = _mm2px(c.alto_mm || 0.25);
          elementos.push('<rect x="' + x + '" y="' + y + '" width="' + w + '" height="' + Math.max(2, h) + '" fill="#000"/>');
          break;
        case 'rectangulo':
          elementos.push(_svgRect(c, x, y));
          break;
        case 'barcode':
          elementos.push(_svgBarcode(c, x, y));
          break;
        case 'qr':
          elementos.push(_svgQR(c, x, y));
          break;
      }
    });

    var grid = opts.grid ? _svgGrid(anchoPx, altoPx, opts.gridMm || 5) : '';
    return ''
      + '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + anchoPx + ' ' + altoPx + '"'
      +    ' width="' + anchoPx + '" height="' + altoPx + '"'
      +    ' style="background:#fff;display:block">'
      +   grid
      +   elementos.join('')
      + '</svg>';
  }

  function _svgGrid(w, h, gridMm) {
    var gridPx = _mm2px(gridMm);
    var lines = [];
    for (var x = 0; x <= w; x += gridPx) {
      lines.push('<line x1="' + x + '" y1="0" x2="' + x + '" y2="' + h + '" stroke="#e2e8f0" stroke-width="1"/>');
    }
    for (var y = 0; y <= h; y += gridPx) {
      lines.push('<line x1="0" y1="' + y + '" x2="' + w + '" y2="' + y + '" stroke="#e2e8f0" stroke-width="1"/>');
    }
    return '<g class="grid">' + lines.join('') + '</g>';
  }

  function _svgTexto(c, x, y) {
    var fpx = _fontPx(c.font || 3);
    var anchor = c.alineacion === 'center' ? 'middle' : (c.alineacion === 'right' ? 'end' : 'start');
    var anchoCanvasPx = c._anchoCanvasPx || 9999;
    // Para alineación: middle/end necesitan X de referencia
    var tx = x;
    if (c.alineacion === 'center' && c.ancho_mm) tx = x + _mm2px(c.ancho_mm) / 2;
    if (c.alineacion === 'right' && c.ancho_mm)  tx = x + _mm2px(c.ancho_mm);
    var rot = c.rotacion ? ' transform="rotate(' + c.rotacion + ' ' + tx + ' ' + (y + fpx) + ')"' : '';
    var weight = c.negrita ? '900' : '700';
    // Multilinea por \n
    var lineas = String(c.texto || '').split('\n');
    return lineas.map(function(ln, i) {
      return '<text x="' + tx + '" y="' + (y + fpx + i * fpx * 1.05) + '" font-family="Arial Black, sans-serif" font-size="' + fpx + 'px" font-weight="' + weight + '" fill="#000" text-anchor="' + anchor + '"' + rot + '>' + _esc(ln) + '</text>';
    }).join('');
  }

  function _svgIcono(c, x, y) {
    var dots = c.tamano_dots || 48;
    var sizePx = _dots2px(dots);
    if (!window.IconosAdhesivo) {
      return '<rect x="' + x + '" y="' + y + '" width="' + sizePx + '" height="' + sizePx + '" fill="none" stroke="#000" stroke-dasharray="4,4"/>'
           + '<text x="' + (x + sizePx/2) + '" y="' + (y + sizePx/2 + 5) + '" font-size="10" text-anchor="middle" fill="#94a3b8">' + _esc(c.idIcono) + '</text>';
    }
    var dataUri = IconosAdhesivo.dataUri(c.idIcono);
    if (!dataUri) {
      return '<rect x="' + x + '" y="' + y + '" width="' + sizePx + '" height="' + sizePx + '" fill="none" stroke="#f43f5e" stroke-dasharray="4,4"/>'
           + '<text x="' + (x + sizePx/2) + '" y="' + (y + sizePx/2 + 5) + '" font-size="10" text-anchor="middle" fill="#f43f5e">?' + _esc(c.idIcono) + '</text>';
    }
    return '<image x="' + x + '" y="' + y + '" width="' + sizePx + '" height="' + sizePx + '" href="' + dataUri + '" style="image-rendering:pixelated"/>';
  }

  function _svgRect(c, x, y) {
    var w = _mm2px(c.ancho_mm || 5), h = _mm2px(c.alto_mm || 5);
    var grosor = c.grosor || 1;
    if (c.relleno) {
      return '<rect x="' + x + '" y="' + y + '" width="' + w + '" height="' + h + '" fill="#000"/>';
    }
    return '<rect x="' + x + '" y="' + y + '" width="' + w + '" height="' + h + '" fill="none" stroke="#000" stroke-width="' + (grosor * 1.5) + '"/>';
  }

  function _svgBarcode(c, x, y) {
    var alto = (c.alto_dots || 48);
    var altoPx = _dots2px(alto);
    // Estimar ancho del barcode con misma lógica adaptativa
    var bcLen = String(c.codigo || '').length;
    var modules = 11 * bcLen + 35;
    var narrow = c.narrow || 2;
    var widthPx = _dots2px(modules * narrow);
    var svgId = 'edBcSVG_' + Math.random().toString(36).slice(2, 8);
    // Mientras JsBarcode lo dibuja después, mostramos placeholder visual
    return ''
      + '<g class="bc-placeholder">'
      +   '<svg id="' + svgId + '" data-codigo="' + _esc(c.codigo) + '" x="' + x + '" y="' + y + '" width="' + widthPx + '" height="' + altoPx + '"></svg>'
      +   '<text x="' + (x + widthPx/2) + '" y="' + (y + altoPx + 14) + '" font-family="Consolas,monospace" font-size="11" text-anchor="middle" fill="#333">' + _esc(c.codigo) + '</text>'
      + '</g>';
  }

  function _svgQR(c, x, y) {
    var sz = _dots2px(c.tamano_dots || 64);
    return ''
      + '<rect x="' + x + '" y="' + y + '" width="' + sz + '" height="' + sz + '" fill="#fff" stroke="#000" stroke-width="2"/>'
      + '<text x="' + (x + sz/2) + '" y="' + (y + sz/2 + 5) + '" font-size="11" text-anchor="middle" fill="#333">QR</text>'
      + '<text x="' + (x + sz/2) + '" y="' + (y + sz - 4) + '" font-size="8" text-anchor="middle" fill="#666">' + _esc(String(c.codigo || '').substring(0, 12)) + '</text>';
  }

  // Dibujar barcodes con JsBarcode en los SVG ya inyectados
  function _dibujarBarcodes(rootEl) {
    if (typeof JsBarcode === 'undefined') return;
    var nodos = rootEl.querySelectorAll('svg[data-codigo]');
    nodos.forEach(function(svgEl) {
      var codigo = svgEl.getAttribute('data-codigo');
      if (!codigo) return;
      try {
        // narrow adaptativo (mismo helper que backend)
        var bcLen = codigo.length;
        var modules = 11 * bcLen + 35;
        var bcWidth = 2.1, bcMargin = 20;
        if (modules * 3 <= 340) { bcWidth = 2.1; bcMargin = 30; }
        else                     { bcWidth = 1.4; bcMargin = 12; }
        JsBarcode(svgEl, codigo, {
          format: 'CODE128',
          width: bcWidth,
          height: parseInt(svgEl.getAttribute('height')) || 72,
          displayValue: false,
          margin: bcMargin,
          background: '#ffffff', lineColor: '#000000'
        });
      } catch(e) {
        console.warn('[Converter] barcode fail', e.message);
      }
    });
  }

  window.EditorAdhesivosConverter = {
    DOTS_POR_MM: DOTS_POR_MM,
    PX_POR_DOT:  PX_POR_DOT,
    mm2dots: _mm2dots,
    dots2px: _dots2px,
    mm2px:   _mm2px,
    fontPx:  _fontPx,
    fontDots: _fontDots,
    validar: _validar,
    json2svg: _json2svg,
    dibujarBarcodes: _dibujarBarcodes
  };
})();
