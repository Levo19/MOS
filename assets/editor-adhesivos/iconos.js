// ════════════════════════════════════════════════════════════════════
// IconosAdhesivo — catálogo de 24 iconos pixel-art para Editor de Avisos
// v1.0.0 — 2026-06-05
//
// Cada icono se diseña como matriz 48×48 bits (0/1). Helpers de dibujo
// con primitivas geométricas (línea, círculo, triángulo, rectángulo).
//
// Output dual:
//   • bitmapHex(idIcono) → hex string para BITMAP TSPL (backend impresión)
//   • dataUri(idIcono)   → PNG base64 (frontend preview SVG/IMG)
//
// PIXEL-PERFECT GARANTIZADO: la MISMA matriz alimenta backend y frontend.
// Lo que ves en el preview es exactamente lo que se imprime.
//
// 24 iconos en 4 categorías:
//   COMERCIALES   estrella · porcentaje · 2x1 · sale · new · oferta
//   ALERTAS       triangulo · prohibido · xgrande · stop · rayo · biohazard
//   OPERACIONALES escoba · caja · candado · copo · sol · reciclar
//   DESTAQUE      diamante · diana · fuego · calendario · reloj · check
//
// ⚠ MANTENER sincronizado con backend (gas/AdhesivosPersonalizados.gs).
//   El _getIconoBitmap() del backend debe generar EXACTAMENTE las mismas
//   matrices. Hoy: catálogo compartido por copia (este archivo se replica
//   en el backend como string template literal).
// ════════════════════════════════════════════════════════════════════
(function() {
  'use strict';
  if (window.IconosAdhesivo) return;

  var TAMANO = 48;  // dots TSPL = px CSS × 0.667 (con regla 1 dot = 1.5 px)

  // ── Primitivas de dibujo pixel-art ────────────────────────────────
  function _crearMatriz() {
    var m = new Array(TAMANO);
    for (var i = 0; i < TAMANO; i++) {
      m[i] = new Array(TAMANO);
      for (var j = 0; j < TAMANO; j++) m[i][j] = 0;
    }
    return m;
  }

  function _set(m, x, y, val) {
    if (x < 0 || y < 0 || y >= TAMANO || x >= TAMANO) return;
    m[y][x] = (val === undefined ? 1 : val);
  }

  function _lineaH(m, x1, x2, y, grosor) {
    grosor = grosor || 1;
    if (x1 > x2) { var t = x1; x1 = x2; x2 = t; }
    for (var dy = 0; dy < grosor; dy++) {
      for (var x = x1; x <= x2; x++) _set(m, x, y + dy);
    }
  }

  function _lineaV(m, x, y1, y2, grosor) {
    grosor = grosor || 1;
    if (y1 > y2) { var t = y1; y1 = y2; y2 = t; }
    for (var dx = 0; dx < grosor; dx++) {
      for (var y = y1; y <= y2; y++) _set(m, x + dx, y);
    }
  }

  function _linea(m, x1, y1, x2, y2, grosor) {
    grosor = grosor || 1;
    var dx = Math.abs(x2 - x1), dy = Math.abs(y2 - y1);
    var sx = x1 < x2 ? 1 : -1, sy = y1 < y2 ? 1 : -1;
    var err = dx - dy;
    while (true) {
      // Dibujar punto con grosor (cuadrado grosor×grosor)
      for (var g1 = 0; g1 < grosor; g1++) {
        for (var g2 = 0; g2 < grosor; g2++) _set(m, x1 + g1, y1 + g2);
      }
      if (x1 === x2 && y1 === y2) break;
      var e2 = 2 * err;
      if (e2 > -dy) { err -= dy; x1 += sx; }
      if (e2 < dx)  { err += dx; y1 += sy; }
    }
  }

  function _circulo(m, cx, cy, r, filled) {
    if (filled) {
      for (var y = -r; y <= r; y++) {
        for (var x = -r; x <= r; x++) {
          if (x * x + y * y <= r * r) _set(m, cx + x, cy + y);
        }
      }
    } else {
      // Anillo grosor 1 con midpoint
      var x = r, y = 0, err = 0;
      while (x >= y) {
        _set(m, cx + x, cy + y); _set(m, cx + y, cy + x);
        _set(m, cx - y, cy + x); _set(m, cx - x, cy + y);
        _set(m, cx - x, cy - y); _set(m, cx - y, cy - x);
        _set(m, cx + y, cy - x); _set(m, cx + x, cy - y);
        if (err <= 0) { y++; err += 2 * y + 1; }
        if (err > 0)  { x--; err -= 2 * x + 1; }
      }
    }
  }

  function _circuloAnillo(m, cx, cy, r, grosor) {
    for (var g = 0; g < grosor; g++) _circulo(m, cx, cy, r - g, false);
  }

  function _rect(m, x1, y1, x2, y2, filled, grosor) {
    grosor = grosor || 1;
    if (filled) {
      for (var y = y1; y <= y2; y++) for (var x = x1; x <= x2; x++) _set(m, x, y);
    } else {
      _lineaH(m, x1, x2, y1, grosor);
      _lineaH(m, x1, x2, y2 - grosor + 1, grosor);
      _lineaV(m, x1, y1, y2, grosor);
      _lineaV(m, x2 - grosor + 1, y1, y2, grosor);
    }
  }

  function _triangulo(m, x1, y1, x2, y2, x3, y3, filled) {
    if (filled) {
      // Scanline fill por barrido Y
      var minY = Math.min(y1, y2, y3), maxY = Math.max(y1, y2, y3);
      for (var y = minY; y <= maxY; y++) {
        var xs = [];
        // Intersecciones con cada arista
        [[x1, y1, x2, y2], [x2, y2, x3, y3], [x3, y3, x1, y1]].forEach(function(seg) {
          var ax = seg[0], ay = seg[1], bx = seg[2], by = seg[3];
          if ((ay <= y && by > y) || (by <= y && ay > y)) {
            xs.push(ax + (y - ay) * (bx - ax) / (by - ay));
          }
        });
        xs.sort(function(a, b) { return a - b; });
        for (var i = 0; i < xs.length - 1; i += 2) {
          for (var x = Math.ceil(xs[i]); x <= Math.floor(xs[i + 1]); x++) _set(m, x, y);
        }
      }
    } else {
      _linea(m, x1, y1, x2, y2, 1);
      _linea(m, x2, y2, x3, y3, 1);
      _linea(m, x3, y3, x1, y1, 1);
    }
  }

  // Letras 5×7 simples para textos cortos en iconos (SALE, NEW, %, etc.)
  // Cada letra es un array de 7 strings de 5 chars (# = pixel, . = vacío).
  var LETRAS_5x7 = {
    'A': ['.###.','#...#','#...#','#####','#...#','#...#','#...#'],
    'B': ['####.','#...#','#...#','####.','#...#','#...#','####.'],
    'C': ['.####','#....','#....','#....','#....','#....','.####'],
    'D': ['####.','#...#','#...#','#...#','#...#','#...#','####.'],
    'E': ['#####','#....','#....','####.','#....','#....','#####'],
    'F': ['#####','#....','#....','####.','#....','#....','#....'],
    'G': ['.####','#....','#....','#.###','#...#','#...#','.####'],
    'H': ['#...#','#...#','#...#','#####','#...#','#...#','#...#'],
    'I': ['#####','..#..','..#..','..#..','..#..','..#..','#####'],
    'L': ['#....','#....','#....','#....','#....','#....','#####'],
    'M': ['#...#','##.##','#.#.#','#...#','#...#','#...#','#...#'],
    'N': ['#...#','##..#','#.#.#','#.#.#','#..##','#...#','#...#'],
    'O': ['.###.','#...#','#...#','#...#','#...#','#...#','.###.'],
    'P': ['####.','#...#','#...#','####.','#....','#....','#....'],
    'R': ['####.','#...#','#...#','####.','#.#..','#..#.','#...#'],
    'S': ['.####','#....','#....','.###.','....#','....#','####.'],
    'T': ['#####','..#..','..#..','..#..','..#..','..#..','..#..'],
    'U': ['#...#','#...#','#...#','#...#','#...#','#...#','.###.'],
    'V': ['#...#','#...#','#...#','#...#','#...#','.#.#.','..#..'],
    'W': ['#...#','#...#','#...#','#...#','#.#.#','##.##','#...#'],
    'X': ['#...#','#...#','.#.#.','..#..','.#.#.','#...#','#...#'],
    'Y': ['#...#','#...#','.#.#.','..#..','..#..','..#..','..#..'],
    'Z': ['#####','....#','...#.','..#..','.#...','#....','#####'],
    '0': ['.###.','#...#','#..##','#.#.#','##..#','#...#','.###.'],
    '1': ['..#..','.##..','..#..','..#..','..#..','..#..','.###.'],
    '2': ['.###.','#...#','....#','...#.','..#..','.#...','#####'],
    '3': ['.###.','#...#','....#','..##.','....#','#...#','.###.'],
    '4': ['...#.','..##.','.#.#.','#..#.','#####','...#.','...#.'],
    '5': ['#####','#....','####.','....#','....#','#...#','.###.'],
    '6': ['.###.','#....','#....','####.','#...#','#...#','.###.'],
    '7': ['#####','....#','...#.','..#..','.#...','#....','#....'],
    '8': ['.###.','#...#','#...#','.###.','#...#','#...#','.###.'],
    '9': ['.###.','#...#','#...#','.####','....#','....#','.###.'],
    '%': ['##..#','##.#.','..#..','.#...','#..##','...##','....#'],
    '!': ['..#..','..#..','..#..','..#..','..#..','.....','..#..'],
    '?': ['.###.','#...#','....#','...#.','..#..','.....','..#..'],
    ' ': ['.....','.....','.....','.....','.....','.....','.....']
  };

  // Dibuja texto en matriz con escala (cada pixel de letra → bloque escala×escala)
  function _texto(m, str, x, y, escala) {
    escala = escala || 1;
    str = str.toUpperCase();
    var cursor = x;
    for (var i = 0; i < str.length; i++) {
      var letra = LETRAS_5x7[str[i]];
      if (!letra) { cursor += 6 * escala; continue; }
      for (var ly = 0; ly < 7; ly++) {
        for (var lx = 0; lx < 5; lx++) {
          if (letra[ly][lx] === '#') {
            for (var sy = 0; sy < escala; sy++) {
              for (var sx = 0; sx < escala; sx++) {
                _set(m, cursor + lx * escala + sx, y + ly * escala + sy);
              }
            }
          }
        }
      }
      cursor += 6 * escala;  // 5 chars + 1 espacio
    }
  }

  // ════════════════════════════════════════════════════════════════
  // CATÁLOGO 24 ICONOS — cada uno devuelve matriz 48×48
  // ════════════════════════════════════════════════════════════════

  // ── COMERCIALES ──────────────────────────────────────────────────
  function _estrella() {
    var m = _crearMatriz();
    // Estrella de 5 puntas rellena con vértices precomputados
    var cx = 24, cy = 24;
    var puntas = [];
    for (var i = 0; i < 10; i++) {
      var ang = -Math.PI / 2 + i * Math.PI / 5;
      var r = (i % 2 === 0) ? 22 : 9;
      puntas.push([Math.round(cx + r * Math.cos(ang)), Math.round(cy + r * Math.sin(ang))]);
    }
    // Rellenar como polígono: 10 triángulos desde el centro
    for (var j = 0; j < 10; j++) {
      var a = puntas[j], b = puntas[(j + 1) % 10];
      _triangulo(m, cx, cy, a[0], a[1], b[0], b[1], true);
    }
    return m;
  }

  function _porcentaje() {
    var m = _crearMatriz();
    // % grande centrado
    _texto(m, '%', 8, 8, 6);
    return m;
  }

  function _dosPorUno() {
    var m = _crearMatriz();
    _texto(m, '2', 1, 14, 3);
    _texto(m, 'X', 17, 14, 3);
    _texto(m, '1', 33, 14, 3);
    return m;
  }

  function _sale() {
    var m = _crearMatriz();
    _rect(m, 2, 12, 45, 35, false, 2);
    _texto(m, 'SALE', 7, 18, 2);
    return m;
  }

  function _newicon() {
    var m = _crearMatriz();
    _rect(m, 4, 12, 43, 35, true);
    // Texto NEW en blanco (inversión)
    for (var y = 0; y < TAMANO; y++) for (var x = 0; x < TAMANO; x++) {
      if (m[y][x] === 1 && y >= 14 && y <= 33 && x >= 6 && x <= 41) {
        // marca region interior para luego invertir letras
      }
    }
    // Pintamos letras blancas borrando bits del rectángulo lleno
    var tmp = _crearMatriz();
    _texto(tmp, 'NEW', 8, 15, 2);
    for (var yy = 0; yy < TAMANO; yy++) for (var xx = 0; xx < TAMANO; xx++) {
      if (tmp[yy][xx] === 1) m[yy][xx] = 0;
    }
    return m;
  }

  function _oferta() {
    var m = _crearMatriz();
    _rect(m, 1, 10, 46, 37, false, 2);
    _texto(m, 'OFERTA', 4, 18, 2);
    return m;
  }

  // ── ALERTAS ──────────────────────────────────────────────────────
  function _triangulo_alerta() {
    var m = _crearMatriz();
    // Triángulo equilátero con borde grueso + ! adentro
    _linea(m, 24, 4, 4, 42, 2);
    _linea(m, 24, 4, 44, 42, 2);
    _linea(m, 4, 42, 44, 42, 2);
    // !
    _rect(m, 22, 16, 26, 30, true);
    _rect(m, 22, 34, 26, 38, true);
    return m;
  }

  function _prohibido() {
    var m = _crearMatriz();
    _circuloAnillo(m, 24, 24, 22, 4);
    // Línea diagonal de NW a SE
    _linea(m, 10, 10, 38, 38, 4);
    return m;
  }

  function _xgrande() {
    var m = _crearMatriz();
    _linea(m, 6, 6, 42, 42, 5);
    _linea(m, 42, 6, 6, 42, 5);
    return m;
  }

  function _stop() {
    var m = _crearMatriz();
    // Octágono
    var p = [[12, 4], [36, 4], [44, 12], [44, 36], [36, 44], [12, 44], [4, 36], [4, 12]];
    for (var i = 0; i < 8; i++) {
      var a = p[i], b = p[(i + 1) % 8];
      _linea(m, a[0], a[1], b[0], b[1], 2);
    }
    _texto(m, 'STOP', 6, 19, 2);
    return m;
  }

  function _rayo() {
    var m = _crearMatriz();
    // Rayo zigzag
    var poly = [[28, 2], [10, 26], [22, 26], [16, 46], [38, 22], [26, 22], [32, 2]];
    // Cerrar polígono y triangular en abanico desde poly[0]
    for (var k = 1; k < poly.length - 1; k++) {
      _triangulo(m, poly[0][0], poly[0][1], poly[k][0], poly[k][1], poly[k+1][0], poly[k+1][1], true);
    }
    return m;
  }

  function _biohazard() {
    var m = _crearMatriz();
    // 3 círculos overlap formando trébol
    _circuloAnillo(m, 24, 12, 8, 2);
    _circuloAnillo(m, 12, 32, 8, 2);
    _circuloAnillo(m, 36, 32, 8, 2);
    // Círculo central pequeño relleno
    _circulo(m, 24, 24, 4, true);
    return m;
  }

  // ── OPERACIONALES ────────────────────────────────────────────────
  function _escoba() {
    var m = _crearMatriz();
    // Palo (diagonal)
    _linea(m, 8, 4, 32, 28, 3);
    // Cuerpo escoba (trapecio)
    _triangulo(m, 28, 24, 44, 40, 20, 44, true);
    _triangulo(m, 28, 24, 44, 40, 36, 22, true);
    // Cerdas verticales
    for (var i = 22; i <= 42; i += 3) {
      _linea(m, i + 2, 38, i, 46, 1);
    }
    return m;
  }

  function _caja() {
    var m = _crearMatriz();
    _rect(m, 6, 12, 42, 42, false, 2);
    // Tapa
    _lineaH(m, 6, 42, 18, 1);
    // Cinta vertical
    _lineaV(m, 22, 12, 42, 2);
    _lineaV(m, 26, 12, 42, 2);
    // Solapas tapa
    _linea(m, 24, 18, 14, 12, 2);
    _linea(m, 24, 18, 34, 12, 2);
    return m;
  }

  function _candado() {
    var m = _crearMatriz();
    // Cuerpo
    _rect(m, 8, 22, 40, 44, true);
    // Arco
    for (var ang = Math.PI; ang <= 2 * Math.PI; ang += 0.05) {
      var x = Math.round(24 + 12 * Math.cos(ang));
      var y = Math.round(22 + 12 * Math.sin(ang));
      _set(m, x, y); _set(m, x + 1, y); _set(m, x - 1, y); _set(m, x, y + 1); _set(m, x, y - 1);
    }
    // Cerradura
    _circulo(m, 24, 31, 3, false);
    _rect(m, 22, 33, 26, 38, true);
    return m;
  }

  function _copo() {
    var m = _crearMatriz();
    var cx = 24, cy = 24;
    // 6 brazos
    for (var a = 0; a < 6; a++) {
      var ang = a * Math.PI / 3;
      var dx = Math.cos(ang), dy = Math.sin(ang);
      // Brazo principal
      _linea(m, cx, cy, Math.round(cx + 22 * dx), Math.round(cy + 22 * dy), 2);
      // 2 ramas pequeñas a 60°
      var bx = Math.round(cx + 14 * dx), by = Math.round(cy + 14 * dy);
      var ang2 = ang + Math.PI / 3;
      var ang3 = ang - Math.PI / 3;
      _linea(m, bx, by, Math.round(bx + 6 * Math.cos(ang2)), Math.round(by + 6 * Math.sin(ang2)), 1);
      _linea(m, bx, by, Math.round(bx + 6 * Math.cos(ang3)), Math.round(by + 6 * Math.sin(ang3)), 1);
    }
    return m;
  }

  function _sol() {
    var m = _crearMatriz();
    _circulo(m, 24, 24, 9, true);
    // Rayos
    for (var i = 0; i < 8; i++) {
      var ang = i * Math.PI / 4;
      _linea(m,
        Math.round(24 + 13 * Math.cos(ang)),
        Math.round(24 + 13 * Math.sin(ang)),
        Math.round(24 + 22 * Math.cos(ang)),
        Math.round(24 + 22 * Math.sin(ang)),
        3
      );
    }
    return m;
  }

  function _reciclar() {
    var m = _crearMatriz();
    // 3 flechas formando círculo (versión simple: triángulos + arcos)
    for (var a = 0; a < 3; a++) {
      var base = a * 2 * Math.PI / 3 - Math.PI / 2;
      // Cuerpo de flecha como triángulo desplazado del centro
      var p1 = [Math.round(24 + 18 * Math.cos(base)), Math.round(24 + 18 * Math.sin(base))];
      var p2 = [Math.round(24 + 18 * Math.cos(base + 0.9)), Math.round(24 + 18 * Math.sin(base + 0.9))];
      var p3 = [Math.round(24 + 8 * Math.cos(base + 0.5)), Math.round(24 + 8 * Math.sin(base + 0.5))];
      _triangulo(m, p1[0], p1[1], p2[0], p2[1], p3[0], p3[1], true);
      // Arco que conecta puntas
      for (var t = 0.9; t <= 2 * Math.PI / 3; t += 0.05) {
        var x = Math.round(24 + 14 * Math.cos(base + t));
        var y = Math.round(24 + 14 * Math.sin(base + t));
        _set(m, x, y); _set(m, x+1, y); _set(m, x, y+1);
      }
    }
    return m;
  }

  // ── DESTAQUE ─────────────────────────────────────────────────────
  function _diamante() {
    var m = _crearMatriz();
    _triangulo(m, 24, 4, 4, 24, 44, 24, true);
    _triangulo(m, 4, 24, 44, 24, 24, 44, true);
    // Hueco interior para darle look de diamante (sustracción)
    var tmp = _crearMatriz();
    _triangulo(tmp, 24, 10, 12, 22, 36, 22, false);
    _triangulo(tmp, 12, 22, 36, 22, 24, 38, false);
    return m;
  }

  function _diana() {
    var m = _crearMatriz();
    _circuloAnillo(m, 24, 24, 22, 3);
    _circuloAnillo(m, 24, 24, 16, 2);
    _circuloAnillo(m, 24, 24, 10, 2);
    _circulo(m, 24, 24, 4, true);
    return m;
  }

  function _fuego() {
    var m = _crearMatriz();
    // Llama: 2 curvas que se unen arriba
    var ll = [[24, 2], [16, 12], [20, 18], [12, 26], [16, 38], [24, 46], [32, 38], [36, 26], [28, 18], [32, 12]];
    for (var i = 1; i < ll.length - 1; i++) {
      _triangulo(m, ll[0][0], ll[0][1], ll[i][0], ll[i][1], ll[i+1][0], ll[i+1][1], true);
    }
    return m;
  }

  function _calendario() {
    var m = _crearMatriz();
    _rect(m, 4, 10, 44, 44, false, 2);
    _lineaH(m, 4, 44, 18, 2);
    // Anillos arriba
    _rect(m, 12, 4, 16, 14, true);
    _rect(m, 32, 4, 36, 14, true);
    // Cuadrículas días
    for (var ix = 12; ix <= 36; ix += 8) _lineaV(m, ix, 22, 40, 1);
    for (var iy = 22; iy <= 40; iy += 6) _lineaH(m, 8, 40, iy, 1);
    return m;
  }

  function _reloj() {
    var m = _crearMatriz();
    _circuloAnillo(m, 24, 24, 21, 3);
    // Marcas 12-3-6-9
    _lineaV(m, 24, 5, 9, 2);
    _lineaV(m, 24, 39, 43, 2);
    _lineaH(m, 5, 9, 24, 2);
    _lineaH(m, 39, 43, 24, 2);
    // Manecillas hora 10:10
    _linea(m, 24, 24, 16, 14, 2);
    _linea(m, 24, 24, 34, 18, 2);
    _circulo(m, 24, 24, 2, true);
    return m;
  }

  function _check() {
    var m = _crearMatriz();
    _linea(m, 6, 24, 20, 38, 5);
    _linea(m, 20, 38, 42, 10, 5);
    return m;
  }

  // ── REGISTRO maestro ─────────────────────────────────────────────
  var CATALOGO = {
    // Comerciales
    estrella:   { label: '★ Estrella',     categoria: 'comercial', factory: _estrella },
    porcentaje: { label: '% Porcentaje',   categoria: 'comercial', factory: _porcentaje },
    dos_por_uno:{ label: '2×1',            categoria: 'comercial', factory: _dosPorUno },
    sale:       { label: 'SALE',           categoria: 'comercial', factory: _sale },
    nuevo:      { label: 'NEW',            categoria: 'comercial', factory: _newicon },
    oferta:     { label: 'OFERTA',         categoria: 'comercial', factory: _oferta },
    // Alertas
    triangulo:  { label: '⚠ Alerta',       categoria: 'alerta',    factory: _triangulo_alerta },
    prohibido:  { label: '🚫 Prohibido',   categoria: 'alerta',    factory: _prohibido },
    xgrande:    { label: '❌ X grande',    categoria: 'alerta',    factory: _xgrande },
    stop:       { label: '⛔ STOP',         categoria: 'alerta',    factory: _stop },
    rayo:       { label: '⚡ Rayo',         categoria: 'alerta',    factory: _rayo },
    biohazard:  { label: '☣ Biohazard',    categoria: 'alerta',    factory: _biohazard },
    // Operacionales
    escoba:     { label: '🧹 Escoba',      categoria: 'operativo', factory: _escoba },
    caja:       { label: '📦 Caja',        categoria: 'operativo', factory: _caja },
    candado:    { label: '🔒 Candado',     categoria: 'operativo', factory: _candado },
    copo:       { label: '❄ Copo nieve',  categoria: 'operativo', factory: _copo },
    sol:        { label: '☀ Sol',         categoria: 'operativo', factory: _sol },
    reciclar:   { label: '♻ Reciclar',    categoria: 'operativo', factory: _reciclar },
    // Destaque
    diamante:   { label: '💎 Diamante',    categoria: 'destaque',  factory: _diamante },
    diana:      { label: '🎯 Diana',       categoria: 'destaque',  factory: _diana },
    fuego:      { label: '🔥 Fuego',       categoria: 'destaque',  factory: _fuego },
    calendario: { label: '📅 Calendario',  categoria: 'destaque',  factory: _calendario },
    reloj:      { label: '⏰ Reloj',        categoria: 'destaque',  factory: _reloj },
    check:      { label: '✓ Check',        categoria: 'destaque',  factory: _check }
  };

  // ── Cache de matrices (evitar regenerar) ─────────────────────────
  var _cache = {};
  function _matriz(idIcono) {
    if (_cache[idIcono]) return _cache[idIcono];
    var def = CATALOGO[idIcono];
    if (!def) return null;
    var m = def.factory();
    _cache[idIcono] = m;
    return m;
  }

  // ── Conversión matriz → hex TSPL ─────────────────────────────────
  // TSPL BITMAP usa raster horizontal byte-packed. 48 dots wide / 8 = 6 bytes/fila.
  // Bit 1 = blanco, bit 0 = negro (convención XOR_MODE 0 que usamos).
  // OJO: nuestro modelo es 1=pintar, 0=fondo. Invertimos al exportar.
  function _matrizToHex(m) {
    var W = TAMANO, H = TAMANO;
    var wBytes = W / 8;  // 6
    var hex = '';
    for (var y = 0; y < H; y++) {
      for (var b = 0; b < wBytes; b++) {
        var byte = 0;
        for (var bit = 0; bit < 8; bit++) {
          var x = b * 8 + bit;
          // BITMAP TSPL: bit=0 → imprime, bit=1 → no imprime. Invertir.
          if (m[y][x] !== 1) byte |= (1 << (7 - bit));
        }
        var h = byte.toString(16).toUpperCase();
        hex += (h.length === 1 ? '0' + h : h);
      }
    }
    return hex;
  }

  // ── Conversión matriz → dataURI PNG (para preview frontend) ──────
  function _matrizToDataUri(m) {
    var W = TAMANO, H = TAMANO;
    var canvas = document.createElement('canvas');
    canvas.width = W;
    canvas.height = H;
    var ctx = canvas.getContext('2d');
    ctx.fillStyle = 'transparent';
    ctx.clearRect(0, 0, W, H);
    var img = ctx.createImageData(W, H);
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        var idx = (y * W + x) * 4;
        if (m[y][x] === 1) {
          img.data[idx] = 0; img.data[idx+1] = 0; img.data[idx+2] = 0; img.data[idx+3] = 255;
        } else {
          img.data[idx+3] = 0;
        }
      }
    }
    ctx.putImageData(img, 0, 0);
    return canvas.toDataURL('image/png');
  }

  // ── API pública ──────────────────────────────────────────────────
  window.IconosAdhesivo = {
    TAMANO_DOTS: TAMANO,
    catalogo: CATALOGO,
    listar: function() {
      return Object.keys(CATALOGO).map(function(id) {
        return { id: id, label: CATALOGO[id].label, categoria: CATALOGO[id].categoria };
      });
    },
    matriz: _matriz,
    hexTSPL: function(idIcono) {
      var m = _matriz(idIcono);
      return m ? _matrizToHex(m) : null;
    },
    dataUri: function(idIcono) {
      var m = _matriz(idIcono);
      return m ? _matrizToDataUri(m) : null;
    },
    // Útil para debug visual en consola
    debug: function(idIcono) {
      var m = _matriz(idIcono);
      if (!m) return '(no encontrado: ' + idIcono + ')';
      return m.map(function(fila) {
        return fila.map(function(b) { return b ? '█' : ' '; }).join('');
      }).join('\n');
    }
  };
})();
