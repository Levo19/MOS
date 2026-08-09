// ════════════════════════════════════════════════════════════════════
// AdhesivoPreview — módulo compartido de preview visual del adhesivo
// v1.1.0 — 2026-06-05 — Preview MEMBRETE_ME + MEMBRETE_WH (góndola/almacén)
//          pixel-perfect con TSPL backend. MOS catálogo muestra ambos.
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

  // ════════════════════════════════════════════════════════════════════
  // [v1.1.0] PREVIEW MEMBRETES (MEMBRETE_ME góndola + MEMBRETE_WH andamio)
  //
  // Pixel-perfect espejo del TSPL backend (gas/Membretes.gs).
  // Regla: 1 dot TSPL = 1.5 px CSS. Adhesivo 50×25 mm = 400×200 dots = 600×300 px.
  // Posicionamiento absoluto con coords X/Y exactas del TSPL.
  //
  // ⚠ MANTENER SINCRONIZADO: si cambias el layout en _buildTSPLMembreteMe o
  // _buildTSPLMembreteWh (Membretes.gs), actualizá las constantes acá.
  // El usuario admin confía en este preview — debe ser idéntico al impreso.
  // ════════════════════════════════════════════════════════════════════

  // Conversor TSPL dots → px CSS (1 dot = 1.5 px porque 50 mm × 8 dots/mm = 400 dots,
  // pero visualmente queremos 600px → factor 1.5).
  function _dotsToPx(dots) { return Math.round(dots * 1.5); }

  // ── CSS para los dos previews de membrete ────────────────────────────
  var CSS_MEMBRETE_ID = 'adhesivo-membrete-preview-css';
  function _inyectarCssMembretes() {
    if (document.getElementById(CSS_MEMBRETE_ID)) return;
    var s = document.createElement('style');
    s.id = CSS_MEMBRETE_ID;
    s.textContent = [
      // Contenedor adhesivo membrete — mismo tamaño que adhesivo envasado (50×25 mm).
      '.mb-prev{position:relative;width:600px;height:300px;background:#fff;border-radius:8px;box-shadow:0 10px 32px -8px rgba(99,102,241,.45),0 0 0 2px rgba(99,102,241,.55),inset 0 0 0 1px rgba(0,0,0,.05);overflow:hidden;font-family:"Arial Black",sans-serif;color:#000;animation:mbPrevGlow 3s ease-in-out infinite alternate}',
      '@keyframes mbPrevGlow{from{box-shadow:0 10px 32px -8px rgba(99,102,241,.45),0 0 0 2px rgba(99,102,241,.55),inset 0 0 0 1px rgba(0,0,0,.05)}to{box-shadow:0 14px 44px -10px rgba(99,102,241,.65),0 0 0 2px rgba(99,102,241,.85),inset 0 0 0 1px rgba(0,0,0,.05)}}',
      '.mb-prev-me{box-shadow:0 10px 32px -8px rgba(16,185,129,.45),0 0 0 2px rgba(16,185,129,.55),inset 0 0 0 1px rgba(0,0,0,.05);animation:mbPrevGlowMe 3s ease-in-out infinite alternate}',
      '@keyframes mbPrevGlowMe{from{box-shadow:0 10px 32px -8px rgba(16,185,129,.45),0 0 0 2px rgba(16,185,129,.55),inset 0 0 0 1px rgba(0,0,0,.05)}to{box-shadow:0 14px 44px -10px rgba(16,185,129,.65),0 0 0 2px rgba(16,185,129,.85),inset 0 0 0 1px rgba(0,0,0,.05)}}',
      // Elementos absolutos genéricos
      '.mb-abs{position:absolute;font-family:"Arial Black",sans-serif;color:#000;letter-spacing:.5px;line-height:1;white-space:nowrap}',
      // Font 1 TSPL = 8×12 dots ≈ 12×18 px. Usamos 11px monospace para texto código.
      '.mb-f1{font-size:11px;font-family:"Consolas","Courier New",monospace;font-weight:700;letter-spacing:1.5px}',
      // Font 2 TSPL = 12×20 dots ≈ 18×30 px.
      '.mb-f2{font-size:15px;font-weight:700}',
      // Font 3 TSPL = 16×24 dots ≈ 24×36 px. Usamos 22px para descripción.
      '.mb-f3{font-size:22px;font-weight:800}',
      // Font 4 TSPL = 24×32 dots ≈ 36×48 px. Usamos 30px para highlights desc WH.
      '.mb-f4{font-size:28px;font-weight:900}',
      // Font 5 TSPL = 32×48 dots ≈ 48×72 px. Precio MEGA MEMBRETE_ME.
      '.mb-f5{font-size:48px;font-weight:900;letter-spacing:1px;font-family:"Arial Black",sans-serif}',
      // Línea decorativa
      '.mb-line{position:absolute;background:#000}',
      // Frame con corner marks (igual estilo que adhesivo envasado)
      '.mb-frame{position:absolute;pointer-events:none}',
      '.mb-cm{position:absolute;width:18px;height:18px;border-color:#000;border-style:solid;border-width:0}',
      '.mb-cm-tl{border-top-width:2px;border-left-width:2px}',
      '.mb-cm-tr{border-top-width:2px;border-right-width:2px}',
      '.mb-cm-bl{border-bottom-width:2px;border-left-width:2px}',
      '.mb-cm-br{border-bottom-width:2px;border-right-width:2px}',
      // Barcode contenedor + SVG animado draw-in
      '.mb-bc-wrap{position:absolute;display:flex;align-items:center;justify-content:center}',
      '.mb-bc-wrap svg{height:100%;max-width:100%;animation:adhesivoBcDrawIn .55s cubic-bezier(.34,1.56,.64,1)}',
      // Tag CAB / N/M esquina sup-derecha MEMBRETE_WH
      '.mb-tag-multi{position:absolute;background:rgba(99,102,241,.12);color:#4338ca;padding:2px 8px;border-radius:9999px;font-size:11px;font-weight:900;border:1px solid rgba(99,102,241,.35);font-family:monospace}',
      // Logo WH almacén (placeholder texto si no hay bitmap real)
      '.mb-logo-wh{position:absolute;font-family:"Arial Black",sans-serif;font-weight:900;font-size:14px;color:#1e293b;letter-spacing:2px;display:flex;align-items:center;gap:6px}',
      '.mb-logo-wh-icon{font-size:18px}',
      // Header chip dentro del preview (ME / WH)
      '.mb-prev-chip{position:absolute;top:-12px;left:14px;padding:3px 10px;border-radius:9999px;font-size:11px;font-weight:900;letter-spacing:1.5px;text-transform:uppercase;box-shadow:0 4px 12px -2px rgba(0,0,0,.25)}',
      '.mb-prev-chip-me{background:#10b981;color:#fff}',
      '.mb-prev-chip-wh{background:#6366f1;color:#fff}'
    ].join('\n');
    document.head.appendChild(s);
  }

  // ── Render MEMBRETE_ME (góndola tienda — PRECIO PROTAGONISTA) ──────
  // SYNC con _buildTSPLMembreteMe (Membretes.gs líneas 101-200 aprox):
  //   Y=2-26    desc Font 3, 1 línea forzada centrada, truncada con ".."
  //   Y=30-78   PRECIO Font 5 MEGA centrado
  //   Y=82-85   línea decorativa gruesa 3 dots bajo precio
  //   Y=88-148  frame + barcode altura 48 + corner marks
  //   Y=152-164 código texto Font 1
  function _renderMembreteMeHtml(datos, opts) {
    if (!datos) return '';
    opts = opts || {};
    var svgId = opts.svgId || ('mbMeBcSVG_' + Date.now() + '_' + (++_svgSeq));
    var precio = parseFloat(datos.precio) || 0;
    var precioStr = 'S/ ' + precio.toFixed(2);
    var codigo = String(datos.codigoBarra || datos.skuBase || datos.idProducto || '');
    if (!codigo) codigo = 'SIN-CODIGO';
    var descripcion = String(datos.descripcion || '');
    // Truncar desc 1 línea ~30 chars (matchea wrap del backend para Y=2-26)
    var descShort = descripcion.length > 32 ? descripcion.substring(0, 30) + '..' : descripcion;

    // Posiciones TSPL → px
    var descY  = _dotsToPx(2);    // 3 px
    var precioY = _dotsToPx(30);  // 45 px — bien lejos del tope
    var lineaY  = _dotsToPx(82);  // 123 px — línea bajo precio
    var lineaH  = _dotsToPx(3);   // 5 px gruesa
    var frameY1 = _dotsToPx(88);  // 132 px
    var frameY2 = _dotsToPx(148); // 222 px → altura 90 px
    var frameH  = frameY2 - frameY1;
    var bcY     = _dotsToPx(94);  // 141 px — dentro del frame
    var bcH     = _dotsToPx(48);  // 72 px (igual envasado)
    var codigoY = _dotsToPx(152); // 228 px

    // [v1.2.0 SYNC rediseño góndola] Layout NUEVO (= buildTSPLMembreteMe del Edge):
    //   nombre IZQ (centrado V+H en su mitad) │ precio focalizado DER (S/ + entero
    //   grande + céntimos chico, en recuadro, SIN medida) · barcode IZQ + monograma
    //   "ME" DER · ⧉ canónico pegado al divisor si multi-código.
    var esCanonico = !!(datos.esSkuBase || datos.esCanonico);
    var ent = Math.floor(precio).toString();
    var cen = Math.round((precio - Math.floor(precio)) * 100).toString();
    if (cen.length < 2) cen = ('0' + cen).slice(-2);
    // Indicador de tipo de código (acompaña al "ME", a la derecha del barcode):
    // 2 cuadritos = multi-código (canónico+equivalentes) · 1 cuadrito = código único.
    var squaresHtml = esCanonico
      ? '<div style="position:absolute;top:183px;left:452px;width:34px;height:30px">'
        + '<div style="position:absolute;top:10px;left:0;width:20px;height:20px;border:2px solid #111;background:#fff"></div>'
        + '<div style="position:absolute;top:0;left:12px;width:20px;height:20px;border:2px solid #111;background:#fff"></div>'
        + '</div>'
      : '<div style="position:absolute;top:188px;left:458px;width:22px;height:22px;border:2px solid #111"></div>';

    return ''
      + '<div class="mb-prev mb-prev-me">'
      +   '<div class="mb-prev-chip mb-prev-chip-me">🏪 ME · Góndola</div>'
      // Nombre IZQUIERDA, centrado V+H en su mitad (X12..224 dots → 18..336px)
      +   '<div class="mb-f3" style="position:absolute;top:21px;left:18px;width:318px;height:138px;display:flex;align-items:center;justify-content:center;text-align:center;line-height:1.15">'
      +     _esc(descripcion)
      +   '</div>'
      // Divisor (X232 → 348px)
      +   '<div class="mb-line" style="top:27px;left:348px;width:3px;height:120px"></div>'
      // Precio focalizado DERECHA en recuadro, SIN medida (S/ chico + entero grande + céntimos chico)
      +   '<div style="position:absolute;top:33px;left:360px;width:216px;height:96px;border:2px solid #111;border-radius:6px;display:flex;align-items:center;justify-content:center">'
      +     '<div style="display:flex;align-items:flex-start;gap:3px">'
      +       '<span class="mb-f2" style="margin-top:8px">S/</span>'
      +       '<span style="font-size:48px;font-weight:900;line-height:1;font-family:\'Arial Black\',sans-serif">' + _esc(ent) + '</span>'
      +       '<span class="mb-f2" style="margin-top:3px">' + _esc(cen) + '</span>'
      +     '</div>'
      +   '</div>'
      // Barcode IZQUIERDA (capado) + código izq
      +   '<div class="mb-bc-wrap" style="top:168px;left:18px;width:415px;height:84px;justify-content:flex-start;overflow:hidden">'
      +     '<svg id="' + svgId + '"></svg>'
      +   '</div>'
      +   '<div class="mb-f1" style="position:absolute;top:258px;left:18px;text-align:left">' + _esc(codigo) + '</div>'
      // [cuadritos][ME] a la derecha del barcode (sin caja) — acompañan al logo
      +   squaresHtml
      +   '<div style="position:absolute;top:176px;left:505px;font-size:40px;font-weight:900;font-family:\'Arial Black\',sans-serif">ME</div>'
      + '</div>';
  }

  // ── Render MEMBRETE_WH (andamio almacén — DESCRIPCIÓN PROTAGONISTA) ──
  // SYNC con _buildTSPLMembreteWh (Membretes.gs líneas 262-368):
  //   Y=2-38    LOGO ALMACEN (placeholder visual)
  //   Y=4       tag CAB / N/M esquina sup-der si total>1 (Font 2)
  //   Y=46-118  descripción Font 3/4 centrada (highlights)
  //   Y=118-196 frame + barcode altura 48 + corner marks
  //   Y=172     texto código Font 1
  function _renderMembreteWhHtml(datos, opts) {
    if (!datos) return '';
    opts = opts || {};
    var svgId = opts.svgId || ('mbWhBcSVG_' + Date.now() + '_' + (++_svgSeq));
    var codigo = String(datos.codigoBarra || datos.codigo || datos.skuBase || '');
    if (!codigo) codigo = 'SIN-CODIGO';
    var descripcion = String(datos.descripcion || '');
    // Procesar tokens + highlights + wrap (mismo algoritmo que adhesivo envasado)
    var descNorm = _normalize(descripcion).toUpperCase();
    var tokens = descNorm.split(/\s+/).filter(Boolean);
    var siblings = datos.siblings || [];
    var highlights = _detectHighlights(tokens, siblings);
    var lines = _wrap(tokens, highlights);
    var esCabecera = !!datos.esCabecera;
    var indice = parseInt(datos.indice) || 0;
    var total = parseInt(datos.total) || 1;

    var logoY  = _dotsToPx(2);    // 3 px
    var tagY   = _dotsToPx(4);    // 6 px
    var descY  = _dotsToPx(46);   // 69 px
    var frameY1 = _dotsToPx(118); // 177 px
    var frameY2 = _dotsToPx(196); // 294 px
    var frameH  = frameY2 - frameY1;
    var bcY     = _dotsToPx(124); // 186 px
    var bcH     = _dotsToPx(48);  // 72 px
    var codigoY = _dotsToPx(172); // 258 px

    // Descripción Font 3/4 con highlights
    var linesHtml = lines.slice(0, 2).map(function(line) {
      var parts = line.map(function(p) {
        var cls = p.hl ? 'mb-f4' : 'mb-f3';
        return '<span class="' + cls + '" style="margin:0 6px">' + _esc(p.tok) + '</span>';
      }).join('');
      return '<div style="display:flex;justify-content:center;align-items:baseline;line-height:1.05;margin:4px 0">' + parts + '</div>';
    }).join('');

    var tagTexto = '';
    if (total > 1) tagTexto = esCabecera ? 'CAB' : (indice + '/' + total);

    return ''
      + '<div class="mb-prev">'
      +   '<div class="mb-prev-chip mb-prev-chip-wh">📦 WH · Andamio</div>'
      // 1) Logo ALMACEN Y=2-38 (placeholder visual — el TSPL imprime bitmap WH real)
      +   '<div class="mb-logo-wh" style="top:' + logoY + 'px;left:8px">'
      +     '<span class="mb-logo-wh-icon">📦</span> ALMACÉN MOS'
      +   '</div>'
      // 2) Tag CAB / N/M esquina sup-der si total > 1
      +   (tagTexto ? '<div class="mb-tag-multi" style="top:' + (tagY + 2) + 'px;right:10px">' + _esc(tagTexto) + '</div>' : '')
      // 3) Descripción Font 3/4 highlights centrada Y=46-118
      +   '<div class="mb-abs" style="top:' + descY + 'px;left:0;width:100%;text-align:center">'
      +     linesHtml
      +   '</div>'
      // 4) Frame con corner marks + barcode Y=118-196
      +   '<div class="mb-frame" style="top:' + frameY1 + 'px;left:15px;width:570px;height:' + frameH + 'px">'
      +     '<span class="mb-cm mb-cm-tl" style="top:0;left:0"></span>'
      +     '<span class="mb-cm mb-cm-tr" style="top:0;right:0"></span>'
      +     '<span class="mb-cm mb-cm-bl" style="bottom:0;left:0"></span>'
      +     '<span class="mb-cm mb-cm-br" style="bottom:0;right:0"></span>'
      +   '</div>'
      +   '<div class="mb-bc-wrap" style="top:' + bcY + 'px;left:30px;right:30px;height:' + bcH + 'px">'
      +     '<svg id="' + svgId + '"></svg>'
      +   '</div>'
      // 5) Código texto Font 1 Y=172
      +   '<div class="mb-abs mb-f1" style="top:' + codigoY + 'px;left:0;width:100%;text-align:center">'
      +     _esc(codigo)
      +   '</div>'
      + '</div>';
  }

  // ── API pública ──────────────────────────────────────────────────────
  window.AdhesivoPreview = {
    LOGO_DATAURI:         LOGO_DATAURI,
    inyectarCss:          _inyectarCss,
    inyectarCssMembretes: _inyectarCssMembretes,
    calcVto:              _calcVto,
    normalize:            _normalize,
    procesar:             _procesar,
    renderHtml:           _renderHtml,
    renderMembreteMeHtml: _renderMembreteMeHtml,
    renderMembreteWhHtml: _renderMembreteWhHtml,
    dibujarBarcode:       _dibujarBarcode,
    esc:                  _esc
  };
})();
