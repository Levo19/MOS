// ════════════════════════════════════════════════════════════════════
// AdhesivoPreview — módulo compartido de preview visual del adhesivo
// v1.0.2 — 2026-06-05 — UX: animación draw-in del barcode SVG.
// v1.0.1 — 2026-06-05 — Senior review fixes:
//          - CSS heights del barcode sync con backend (66→72 px = 48 dots)
//          - svgId con contador incremental (sin colisión cuando >1 modal)
//          - _calcVto defensa contra fecha inválida (ENE/NaN)
//          - _detectHighlights guard targetTokens vacío
// v1.0.0 — 2026-06-05
//
// Lo cargan MOS y WH vía CDN MOS pages. Centraliza el render visual
// del adhesivo de envasado para que ambas apps muestren EXACTAMENTE
// lo mismo en sus respectivos modales (MOS: abrirModalImprimirAdhesivo,
// WH: WhAdhesivoReprint).
//
// Pixel-perfect match con el TSPL backend de Envasados.gs (TSC TTP-244CE
// 50×25mm, 203 DPI). Cada dot TSPL = 1.5 px en el preview.
//
// Uso:
//   AdhesivoPreview.inyectarCss();
//   const datosProc = AdhesivoPreview.procesar({
//     codigoBarra: 'wh-12345678',
//     descripcion: 'AJI AMARILLO MOLIDO 250 GR',
//     fechaEnvasado: '2026-06-05',
//     siblings: [['AJI','AMARILLO','MOLIDO','500','GR'], ...]  // opcional
//   });
//   container.innerHTML = AdhesivoPreview.renderHtml(datosProc, {
//     cantidad: 5,
//     svgId: 'miBarcode'
//   });
//   AdhesivoPreview.dibujarBarcode(
//     document.getElementById('miBarcode'),
//     datosProc.codigoBarra
//   );  // requiere JsBarcode cargado en el cliente
//
// Sincronizado con backend WH Envasados.gs (commit 2026-06-05).
// ════════════════════════════════════════════════════════════════════
(function() {
  'use strict';
  if (window.AdhesivoPreview) return;  // dedupe

  // Logo Tony's bitmap REAL (mismo PNG que LOGO_TSPL_HEX en Envasados.gs).
  // Fuente: /ProyectoMOS/assets/adhesivo/logo-tonys-S.b64
  var LOGO_DATAURI = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAALgAAAAkAQAAAAAS7M1SAAABDUlEQVR42oWSMVLDMBAAV5pAVARwSeknUFI5egrfoEKZ4SF+iklFyQsYp0tBkWFcOIzRUciKbZDDNWftnKXT6pSQDM0sb2f4B7yofGd3j1dm83zMIn8HoHyjAnj9jHztAHEtwIZKei6hjg50B+AC99SA73OgoOk4TBquer6noVD1BaDQqFhf48Pu4b9T/xWDCsEOn/DkVbtUtblxS0FERER/A+XYQGhIN8A+kCCqTPk0uEOCW7BN2n/u0zzrvV0D96fijFX0ln5YTUExnArKpffXtvpnHsTFUyd8y/bMXC3m5k0gi97H/CtqtnbM9a/OhtUiXm7iQTmDAcjVtP7hLuTby5A94tbyJ854SMYP+etgtFLO5vAAAAAASUVORK5CYII=';

  var MESES_ES = ['ENE','FEB','MAR','ABR','MAY','JUN','JUL','AGO','SEP','OCT','NOV','DIC'];
  // [v1.0.1] Contador global para svgId — evita colisiones cuando se llama
  // _renderHtml() dos veces dentro del mismo milisegundo.
  var _svgSeq = 0;

  // ── Helpers internos ────────────────────────────────────────────────
  function _esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c];
    });
  }

  function _normalize(s) {
    if (s === null || s === undefined) return '';
    return String(s).normalize('NFD').replace(/[̀-ͯ]/g, '');
  }

  function _calcVto(fechaEnvasado) {
    // [v1.0.1 BUG #3 FIX] Defensa: si fechaEnvasado es string corrupto,
    // new Date() retorna NaN y getMonth()/getFullYear() retornan NaN.
    // Resultado: "ENE/NaN" en el preview. Mejor fallback a hoy.
    var d = fechaEnvasado ? new Date(fechaEnvasado) : new Date();
    if (isNaN(d.getTime())) d = new Date();
    d.setFullYear(d.getFullYear() + 1);
    return MESES_ES[d.getMonth()] + '/' + d.getFullYear();
  }

  // Detecta tokens diferenciadores comparando contra siblings (otros productos
  // envasables). Replica de _detectHighlightsEtq en backend WH.
  // minPrefix=1 + último siempre highlight.
  function _detectHighlights(targetTokens, allTokenized) {
    // [v1.0.1 BUG #4 FIX] Si targetTokens está vacío, no destacamos nada.
    // Antes seteaba hl[-1]=true (key inválida, benigna pero confusa).
    if (!targetTokens || !targetTokens.length) return [];
    var hl = {};
    hl[targetTokens.length - 1] = true;  // último (peso) siempre destacado
    for (var i = 0; i < allTokenized.length; i++) {
      var s = allTokenized[i];
      if (s === targetTokens) continue;
      if (!s.length || s[0] !== targetTokens[0]) continue;
      for (var pos = 1; pos < targetTokens.length; pos++) {
        if (hl[pos]) continue;
        var prior = true;
        for (var k = 0; k < pos; k++) {
          if (s[k] !== targetTokens[k]) { prior = false; break; }
        }
        if (prior && s[pos] !== undefined && s[pos] !== targetTokens[pos]) {
          hl[pos] = true;
          break;
        }
      }
    }
    var out = [];
    for (var key in hl) if (hl[key]) out.push(parseInt(key));
    out.sort(function(a, b) { return a - b; });
    return out;
  }

  // Word-wrap a max 2 líneas (replica de _wrapTokensEtq).
  function _wrap(tokens, highlights) {
    var MAX_W = 370, SPACE = 8;
    function fontW(isHl) { return isHl ? 24 : 16; }
    function isHl(i) { return highlights.indexOf(i) >= 0; }
    var widths = tokens.map(function(t, i) { return t.length * fontW(isHl(i)); });

    var total = 0;
    for (var i = 0; i < widths.length; i++) total += widths[i] + (i > 0 ? SPACE : 0);
    if (total <= MAX_W) {
      return [tokens.map(function(t, i) { return { tok: t, hl: isHl(i), w: widths[i] }; })];
    }
    var firstHl = highlights.length > 0 ? highlights[0] : tokens.length;
    if (firstHl > 0 && firstHl < tokens.length) {
      var l1 = [], l2 = [], w1 = 0, w2 = 0;
      for (var a = 0; a < firstHl; a++) {
        w1 += widths[a] + (l1.length > 0 ? SPACE : 0);
        l1.push({ tok: tokens[a], hl: false, w: widths[a] });
      }
      for (var b = firstHl; b < tokens.length; b++) {
        w2 += widths[b] + (l2.length > 0 ? SPACE : 0);
        l2.push({ tok: tokens[b], hl: isHl(b), w: widths[b] });
      }
      if (w1 <= MAX_W && w2 <= MAX_W) return [l1, l2];
    }
    // Fallback greedy
    var lines = [[]];
    var curW = 0;
    for (var c = 0; c < tokens.length; c++) {
      var sep = lines[lines.length - 1].length === 0 ? 0 : SPACE;
      if (curW + sep + widths[c] <= MAX_W) {
        lines[lines.length - 1].push({ tok: tokens[c], hl: isHl(c), w: widths[c] });
        curW += sep + widths[c];
      } else if (lines.length === 1) {
        lines.push([{ tok: tokens[c], hl: isHl(c), w: widths[c] }]);
        curW = widths[c];
      } else {
        lines[1].push({ tok: tokens[c], hl: isHl(c), w: widths[c] });
        curW += sep + widths[c];
      }
    }
    return lines;
  }

  // ── CSS injection ───────────────────────────────────────────────────
  var CSS_ID = 'adhesivo-preview-css';
  function _inyectarCss() {
    if (document.getElementById(CSS_ID)) return;
    var s = document.createElement('style');
    s.id = CSS_ID;
    s.textContent = [
      // Adhesivo container: 50×25 mm reales = 600×300 px (1 dot = 1.5 px).
      '.adhesivo-etiqueta{width:600px;height:300px;background:#fff;border-radius:8px;box-shadow:0 10px 32px -8px rgba(251,191,36,.45),0 0 0 2px rgba(251,191,36,.55),inset 0 0 0 1px rgba(0,0,0,.05);position:relative;padding:3px 7px;display:flex;flex-direction:column;color:#000;font-family:"Arial Black",sans-serif;animation:adhesivoGlow 3s ease-in-out infinite alternate}',
      '@keyframes adhesivoGlow{from{box-shadow:0 10px 32px -8px rgba(251,191,36,.45),0 0 0 2px rgba(251,191,36,.55),inset 0 0 0 1px rgba(0,0,0,.05)}to{box-shadow:0 14px 44px -10px rgba(251,191,36,.65),0 0 0 2px rgba(251,191,36,.85),inset 0 0 0 1px rgba(0,0,0,.05)}}',
      '.adhesivo-etq-top{display:flex;align-items:flex-start;justify-content:space-between;gap:14px;min-height:54px}',
      '.adhesivo-logo-real{width:276px;height:auto;image-rendering:pixelated;image-rendering:-moz-crisp-edges;image-rendering:crisp-edges;display:block}',
      '.adhesivo-vto{text-align:right;font-family:"Consolas","Courier New",monospace;padding-top:12px}',
      '.adhesivo-vto-lbl{font-size:11px;color:#555;font-weight:600;letter-spacing:.5px}',
      '.adhesivo-vto-val{font-size:18px;font-weight:900;color:#111;letter-spacing:.5px}',
      '.adhesivo-divider{height:1.5px;background:#000;margin:6px 0}',
      '.adhesivo-desc{flex:1;display:flex;flex-direction:column;justify-content:center;align-items:center;gap:4px;text-align:center;min-height:96px}',
      '.adhesivo-linea{display:flex;gap:12px;flex-wrap:wrap;justify-content:center;align-items:baseline}',
      '.adhesivo-tok{font-size:22px;font-weight:700;color:#111;font-family:"Arial Black",sans-serif;letter-spacing:1px;line-height:1.05}',
      '.adhesivo-tok-hl{font-size:32px;font-weight:900;color:#000;animation:adhesivoTokPulse 2.4s ease-in-out infinite}',
      '@keyframes adhesivoTokPulse{0%,100%{text-shadow:0 0 0 rgba(251,191,36,0)}50%{text-shadow:0 0 12px rgba(251,191,36,.55)}}',
      '.adhesivo-codigo-frame{position:relative;margin:6px 8px 0;padding:12px 14px 14px;height:117px;box-sizing:border-box;display:flex;flex-direction:column;align-items:center;justify-content:center}',
      '.adhesivo-cm{position:absolute;width:18px;height:18px;border-color:#000;border-style:solid;border-width:0}',
      '.adhesivo-cm-tl{top:0;left:0;border-top-width:2px;border-left-width:2px}',
      '.adhesivo-cm-tr{top:0;right:0;border-top-width:2px;border-right-width:2px}',
      '.adhesivo-cm-bl{bottom:0;left:0;border-bottom-width:2px;border-left-width:2px}',
      '.adhesivo-cm-br{bottom:0;right:0;border-bottom-width:2px;border-right-width:2px}',
      // [v1.0.1 BUG #1 FIX] Altura sync con backend (barcodeHeight=48 dots).
      // 48 dots TSPL × 1.5 px/dot = 72 px. Antes 66 px = 44 dots (versión vieja).
      '.adhesivo-barcode-wrap{display:flex;flex-direction:row;align-items:center;justify-content:center;height:72px;width:100%}',
      '.adhesivo-barcode-wrap svg{height:72px;max-width:100%;animation:adhesivoBcDrawIn .55s cubic-bezier(.34,1.56,.64,1)}',
      // [v1.0.2 UX] Animación "draw-in" del barcode SVG cuando aparece.
      // Scale 0.6 → 1 con rebote sutil + opacity 0 → 1. Da sensación
      // de que el código de barras "se imprime" en vivo dentro del preview.
      '@keyframes adhesivoBcDrawIn{from{opacity:0;transform:scaleX(.6)}to{opacity:1;transform:scaleX(1)}}',
      '.adhesivo-codigo{font-family:"Consolas","Courier New",monospace;font-size:13px;color:#333;letter-spacing:1.5px;text-align:center;margin-top:6px;width:100%}',
      '.adhesivo-cantidad-tag{position:absolute;top:10px;right:92px;background:rgba(251,191,36,.18);color:#b45309;padding:3px 10px;border-radius:9999px;font-size:12px;font-weight:900;border:1px dashed rgba(180,83,9,.4);font-family:monospace}'
    ].join('\n');
    document.head.appendChild(s);
  }

  // ── Procesar datos: tokens + highlights + wrap + vto ────────────────
  function _procesar(opts) {
    if (!opts || !opts.codigoBarra || !opts.descripcion) {
      console.error('[AdhesivoPreview] procesar() requiere { codigoBarra, descripcion }');
      return null;
    }
    var descNorm = _normalize(opts.descripcion).toUpperCase();
    var tokens = descNorm.split(/\s+/).filter(Boolean);
    // siblings: lista de arrays de tokens de otros productos envasables (para
    // detectar diferencias). Si no se pasa, el highlight solo aplica al último.
    var siblings = opts.siblings || [];
    var highlights = _detectHighlights(tokens, siblings);
    var lines = _wrap(tokens, highlights);
    var vto = opts.vto || _calcVto(opts.fechaEnvasado);
    return {
      codigoBarra: opts.codigoBarra,
      descripcion: opts.descripcion,
      tokens: tokens,
      highlights: highlights,
      lines: lines,
      vto: vto
    };
  }

  // ── Render HTML del adhesivo ────────────────────────────────────────
  function _renderHtml(datos, opts) {
    if (!datos) return '';
    opts = opts || {};
    var cantidad = opts.cantidad || 1;
    // [v1.0.1 BUG #2 FIX] svgId con contador incremental + ms — sin colisión
    // si se llama renderHtml() dos veces en el mismo ms (modal + tooltip, etc).
    var svgId = opts.svgId || ('adhesivoBcSVG_' + Date.now() + '_' + (++_svgSeq));

    var linesHtml = datos.lines.map(function(line) {
      var parts = line.map(function(p) {
        return '<span class="adhesivo-tok ' + (p.hl ? 'adhesivo-tok-hl' : '') + '">' + _esc(p.tok) + '</span>';
      }).join(' ');
      return '<div class="adhesivo-linea">' + parts + '</div>';
    }).join('');

    // [SYNC con backend Envasados.gs] Algoritmo adaptativo de narrow
    var bcLen = (datos.codigoBarra || '').length;
    var modules = 11 * bcLen + 35;
    var bWidth;
    if (modules * 3 <= 340)      { bWidth = modules * 3; }
    else                          { bWidth = modules * 2; }  // narrow=2 (estándar o forzado)
    var bWidthPct = (bWidth / 400 * 100).toFixed(2);

    return ''
      + '<div class="adhesivo-etiqueta">'
      +   '<div class="adhesivo-etq-top">'
      +     '<img class="adhesivo-logo-real" src="' + LOGO_DATAURI + '" alt="Tony\'s">'
      +     '<div class="adhesivo-vto">'
      +       '<span class="adhesivo-vto-lbl">Vto</span> '
      +       '<span class="adhesivo-vto-val">' + _esc(datos.vto) + '</span>'
      +     '</div>'
      +   '</div>'
      +   '<div class="adhesivo-divider"></div>'
      +   '<div class="adhesivo-desc">' + linesHtml + '</div>'
      +   '<div class="adhesivo-codigo-frame">'
      +     '<span class="adhesivo-cm adhesivo-cm-tl"></span>'
      +     '<span class="adhesivo-cm adhesivo-cm-tr"></span>'
      +     '<span class="adhesivo-cm adhesivo-cm-bl"></span>'
      +     '<span class="adhesivo-cm adhesivo-cm-br"></span>'
      +     '<div class="adhesivo-barcode-wrap">'
      +       '<svg id="' + svgId + '" style="width:' + bWidthPct + '%"></svg>'
      +     '</div>'
      +     '<div class="adhesivo-codigo">' + _esc(datos.codigoBarra) + '</div>'
      +   '</div>'
      +   '<div class="adhesivo-cantidad-tag">×' + cantidad + '</div>'
      + '</div>';
  }

  // ── Dibujar barcode SVG con JsBarcode (debe estar cargado en cliente) ─
  function _dibujarBarcode(svgEl, codigoBarra) {
    if (!svgEl) return;
    if (typeof JsBarcode === 'undefined') {
      console.warn('[AdhesivoPreview] JsBarcode no cargado — barcode no se dibujará');
      return;
    }
    try {
      // [SYNC con backend Envasados.gs] Algoritmo adaptativo replica del backend
      var bcLen = String(codigoBarra).length;
      var modules = 11 * bcLen + 35;
      var bcWidth, bcMargin;
      if (modules * 3 <= 340)      { bcWidth = 2.1; bcMargin = 30; }
      else if (modules * 2 <= 360) { bcWidth = 1.4; bcMargin = 20; }
      else if (modules * 2 <= 376) { bcWidth = 1.4; bcMargin = 12; }
      else                          { bcWidth = 1.4; bcMargin = 8;  }
      JsBarcode(svgEl, String(codigoBarra), {
        format: 'CODE128', width: bcWidth, height: 32,
        displayValue: false, margin: bcMargin,
        background: '#ffffff', lineColor: '#000000'
      });
    } catch(e) {
      console.warn('[AdhesivoPreview] barcode render fail:', e.message);
    }
  }

  // ── API pública ──────────────────────────────────────────────────────
  window.AdhesivoPreview = {
    LOGO_DATAURI:   LOGO_DATAURI,
    inyectarCss:    _inyectarCss,
    calcVto:        _calcVto,
    normalize:      _normalize,
    procesar:       _procesar,
    renderHtml:     _renderHtml,
    dibujarBarcode: _dibujarBarcode,
    esc:            _esc
  };
})();
