// Verificación byte-a-byte: GAS _adhJson2tspl (referencia verbatim) vs el port del Edge.
// Corre: node _verify_tspl.mjs  → debe imprimir "TODOS IDENTICOS".
const ADH_DOTS_POR_MM = 8;

// ───────────────────────── REFERENCIA: copia VERBATIM del GAS ─────────────────────────
function gas_json2tspl(jsonObj, offsetY, iconosMap, gapMm, density, speed) {
  var lines = [
    'SIZE ' + jsonObj.tamano.ancho_mm + ' mm,' + jsonObj.tamano.alto_mm + ' mm',
    'GAP ' + gapMm + ' mm,0 mm',
    'DIRECTION 1',
    'DENSITY ' + density,
    'SPEED ' + speed,
    'CLS'
  ];
  jsonObj.capas.forEach(function(c) {
    var x = Math.round(c.x_mm * ADH_DOTS_POR_MM);
    var y = Math.round(c.y_mm * ADH_DOTS_POR_MM) + offsetY;
    if (c.tipo === 'texto') {
      var font = String(c.font || 3);
      var rot = c.rotacion || 0;
      var xMul = c.negrita ? 2 : 1, yMul = c.negrita ? 2 : 1;
      var texto = String(c.texto || '').replace(/"/g, "'");
      var fontW = { '1': 8, '2': 12, '3': 16, '4': 24, '5': 32 }[font] || 16;
      var fpx = { '1': 12, '2': 20, '3': 24, '4': 32, '5': 48 }[font] || 24;
      var lineas = texto.split('\n');
      lineas.forEach(function(ln, idx) {
        var lineWidth = ln.length * fontW * xMul;
        var xFinal = x;
        var anchoDisponibleDots;
        if (isFinite(c.ancho_mm) && c.ancho_mm > 0) {
          anchoDisponibleDots = c.ancho_mm * ADH_DOTS_POR_MM;
        } else {
          anchoDisponibleDots = jsonObj.tamano.ancho_mm * ADH_DOTS_POR_MM - x;
        }
        if (c.alineacion === 'center') {
          xFinal = x + Math.round((anchoDisponibleDots - lineWidth) / 2);
          if (xFinal < 0) xFinal = 0;
        } else if (c.alineacion === 'right') {
          xFinal = x + Math.round(anchoDisponibleDots - lineWidth);
          if (xFinal < 0) xFinal = 0;
        }
        var yLine = y + idx * Math.round(fpx * 1.05);
        lines.push('TEXT ' + xFinal + ',' + yLine + ',"' + font + '",' + rot + ',' + xMul + ',' + yMul + ',"' + ln + '"');
      });
    }
    else if (c.tipo === 'icono') {
      var dots = c.tamano_dots || 48;
      var key = c.idIcono + '__' + dots;
      var hex = iconosMap[key];
      if (!hex) { hex = iconosMap[c.idIcono + '__48']; dots = hex ? 48 : 0; }
      if (hex && dots > 0) {
        var wBytes = dots / 8;
        lines.push('__BITMAP__' + x + ',' + y + ',' + wBytes + ',' + dots + ',' + hex);
      }
    }
    else if (c.tipo === 'linea') {
      var w = Math.round((c.ancho_mm || 0) * ADH_DOTS_POR_MM);
      var h = Math.max(1, Math.round((c.alto_mm || 0.25) * ADH_DOTS_POR_MM));
      lines.push('BAR ' + x + ',' + y + ',' + w + ',' + h);
    }
    else if (c.tipo === 'rectangulo') {
      var rw = Math.round((c.ancho_mm || 5) * ADH_DOTS_POR_MM);
      var rh = Math.round((c.alto_mm || 5) * ADH_DOTS_POR_MM);
      var g = c.grosor || 1;
      if (c.relleno) {
        lines.push('BAR ' + x + ',' + y + ',' + rw + ',' + rh);
      } else {
        lines.push('BAR ' + x + ',' + y + ',' + rw + ',' + g);
        lines.push('BAR ' + x + ',' + (y + rh - g) + ',' + rw + ',' + g);
        lines.push('BAR ' + x + ',' + y + ',' + g + ',' + rh);
        lines.push('BAR ' + (x + rw - g) + ',' + y + ',' + g + ',' + rh);
      }
    }
    else if (c.tipo === 'barcode') {
      var codigo = String(c.codigo || '').replace(/"/g, '');
      var alto = isFinite(c.alto_dots) ? Math.max(16, Math.min(200, c.alto_dots)) : 48;
      var narrow = isFinite(c.narrow) ? Math.max(1, Math.min(5, c.narrow)) : 2;
      lines.push('BARCODE ' + x + ',' + y + ',"128",' + alto + ',0,0,' + narrow + ',' + narrow + ',"' + codigo + '"');
    }
    else if (c.tipo === 'qr') {
      var qrCod = String(c.codigo || '').replace(/"/g, '');
      var qrSize = Math.max(2, Math.min(10, Math.round((c.tamano_dots || 64) / 8)));
      lines.push('QRCODE ' + x + ',' + y + ',L,' + qrSize + ',A,0,"' + qrCod + '"');
    }
  });
  lines.push('PRINT 1,1');
  return gas_linesToBytes(lines);
}
function gas_linesToBytes(lines) {
  var bytes = [];
  lines.forEach(function(ln) {
    if (ln.indexOf('__BITMAP__') === 0) {
      var rest = ln.substring(10);
      var parts = rest.split(',');
      var prefix = 'BITMAP ' + parts[0] + ',' + parts[1] + ',' + parts[2] + ',' + parts[3] + ',0,';
      bytes = bytes.concat(gas_strToBytes(prefix));
      bytes = bytes.concat(gas_hexToBytes(parts[4]));
      bytes = bytes.concat(gas_strToBytes('\r\n'));
    } else {
      bytes = bytes.concat(gas_strToBytes(ln + '\r\n'));
    }
  });
  return bytes;
}
function gas_strToBytes(s) { var b=[]; for (var i=0;i<s.length;i++) b.push(s.charCodeAt(i)&0xFF); return b; }
function gas_hexToBytes(hex) {
  var b=[]; hex=String(hex||'').replace(/[^0-9A-Fa-f]/g,'');
  if (hex.length%2!==0) hex=hex.substring(0,hex.length-1);
  for (var i=0;i<hex.length;i+=2){ var val=parseInt(hex.substring(i,i+2),16); b.push(isNaN(val)?0:val); }
  return b;
}

// ───────────────────────── PORT del Edge (lo que se deploya) ─────────────────────────
import { adhJson2tspl } from './functions/print-adhesivo-plantilla/tspl.mjs';

// ───────────────────────── plantillas de prueba ─────────────────────────
const samples = [
  { tamano:{ancho_mm:50,alto_mm:25}, capas:[
    {tipo:'texto', texto:'Hola "Mundo"\nLinea 2', x_mm:2, y_mm:2, font:3, rotacion:0, negrita:true, alineacion:'center', ancho_mm:46},
    {tipo:'texto', texto:'Derecha', x_mm:0, y_mm:10, font:2, alineacion:'right'},
  ]},
  { tamano:{ancho_mm:50,alto_mm:25}, capas:[
    {tipo:'icono', idIcono:'estrella', tamano_dots:48, x_mm:1, y_mm:1},
    {tipo:'icono', idIcono:'sinmedida', tamano_dots:32, x_mm:5, y_mm:5},
    {tipo:'linea', x_mm:0, y_mm:20, ancho_mm:50, alto_mm:0.25},
    {tipo:'rectangulo', x_mm:2, y_mm:2, ancho_mm:10, alto_mm:8, grosor:2, relleno:false},
    {tipo:'rectangulo', x_mm:20, y_mm:2, ancho_mm:6, alto_mm:6, relleno:true},
  ]},
  { tamano:{ancho_mm:50,alto_mm:25}, capas:[
    {tipo:'barcode', codigo:'7501234567890', x_mm:2, y_mm:2, alto_dots:60, narrow:2},
    {tipo:'qr', codigo:'https://mos.pe/x', x_mm:30, y_mm:2, tamano_dots:64},
    {tipo:'texto', texto:'sin font', x_mm:1, y_mm:18},
  ]},
];
const iconosMap = { 'estrella__48':'00FF11AA55CCBBdd0102030405060708', 'sinmedida__48':'AABBCCDD' };
const calib = { gapMm:2, density:8, speed:4 };
const offsets = [0, 5, -1, 16];

let allOk = true;
samples.forEach((s, si) => {
  offsets.forEach(off => {
    const a = gas_json2tspl(s, off, iconosMap, calib.gapMm, calib.density, calib.speed);
    const b = adhJson2tspl(s, off, iconosMap, calib);
    const ba = Buffer.from(a), bb = Buffer.from(b);
    const ok = ba.equals(bb);
    if (!ok) {
      allOk = false;
      console.log(`DIFF sample#${si} off=${off}: gas=${ba.length}B port=${bb.length}B`);
      for (let i=0;i<Math.max(ba.length,bb.length);i++){ if(ba[i]!==bb[i]){ console.log(`  primer diff @${i}: gas=${ba[i]} port=${bb[i]} · ctx="${ba.slice(Math.max(0,i-15),i+5).toString('latin1')}"`); break; } }
    } else {
      console.log(`OK sample#${si} off=${off}: ${ba.length} bytes idénticos`);
    }
  });
});
console.log(allOk ? '\n✅ TODOS IDENTICOS' : '\n❌ HAY DIFERENCIAS');
process.exit(allOk ? 0 : 1);
