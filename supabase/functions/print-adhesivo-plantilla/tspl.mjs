// tspl.mjs — Generador TSPL2 para el Editor de Adhesivos. PORT del GAS _adhJson2tspl
// (AdhesivosPersonalizados.gs). Fuente ÚNICA: lo testea _verify_tspl.mjs (byte-a-byte vs GAS)
// y lo importa el Edge index.ts. Plain JS para correr en node (test) y Deno (Edge).
//
// adhJson2tspl(jsonObj, offsetY, iconosMap, calib) → number[] (bytes, 0..255).
//   calib = { gapMm, density, speed }  (los del GAS: defaults 2 / 8 / 4)
const DOTS_POR_MM = 8;
const FONT_W = { '1': 8,  '2': 12, '3': 16, '4': 24, '5': 32 };
const FONT_PX = { '1': 12, '2': 20, '3': 24, '4': 32, '5': 48 };

export function adhJson2tspl(jsonObj, offsetY, iconosMap, calib) {
  const gapMm = calib.gapMm, density = calib.density, speed = calib.speed;
  const lines = [
    `SIZE ${jsonObj.tamano.ancho_mm} mm,${jsonObj.tamano.alto_mm} mm`,
    `GAP ${gapMm} mm,0 mm`,
    'DIRECTION 1',
    `DENSITY ${density}`,
    `SPEED ${speed}`,
    'CLS',
  ];

  for (const c of jsonObj.capas) {
    const x = Math.round(c.x_mm * DOTS_POR_MM);
    const y = Math.round(c.y_mm * DOTS_POR_MM) + offsetY;

    if (c.tipo === 'texto') {
      const font = String(c.font || 3);
      const rot = c.rotacion || 0;
      const xMul = c.negrita ? 2 : 1, yMul = c.negrita ? 2 : 1;
      const texto = String(c.texto || '').replace(/"/g, "'");
      const fontW = FONT_W[font] || 16;
      const fpx = FONT_PX[font] || 24;
      const reng = texto.split('\n');
      reng.forEach((ln, idx) => {
        const lineWidth = ln.length * fontW * xMul;
        let xFinal = x;
        let anchoDisponibleDots;
        if (isFinite(c.ancho_mm) && c.ancho_mm > 0) {
          anchoDisponibleDots = c.ancho_mm * DOTS_POR_MM;
        } else {
          anchoDisponibleDots = jsonObj.tamano.ancho_mm * DOTS_POR_MM - x;
        }
        if (c.alineacion === 'center') {
          xFinal = x + Math.round((anchoDisponibleDots - lineWidth) / 2);
          if (xFinal < 0) xFinal = 0;
        } else if (c.alineacion === 'right') {
          xFinal = x + Math.round(anchoDisponibleDots - lineWidth);
          if (xFinal < 0) xFinal = 0;
        }
        const yLine = y + idx * Math.round(fpx * 1.05);
        lines.push(`TEXT ${xFinal},${yLine},"${font}",${rot},${xMul},${yMul},"${ln}"`);
      });
    } else if (c.tipo === 'icono') {
      let dots = c.tamano_dots || 48;
      let hex = iconosMap[`${c.idIcono}__${dots}`];
      if (!hex) { hex = iconosMap[`${c.idIcono}__48`]; dots = hex ? 48 : 0; }
      if (hex && dots > 0) {
        const wBytes = dots / 8;
        lines.push(`__BITMAP__${x},${y},${wBytes},${dots},${hex}`);
      }
    } else if (c.tipo === 'linea') {
      const w = Math.round((c.ancho_mm || 0) * DOTS_POR_MM);
      const h = Math.max(1, Math.round((c.alto_mm || 0.25) * DOTS_POR_MM));
      lines.push(`BAR ${x},${y},${w},${h}`);
    } else if (c.tipo === 'rectangulo') {
      const rw = Math.round((c.ancho_mm || 5) * DOTS_POR_MM);
      const rh = Math.round((c.alto_mm || 5) * DOTS_POR_MM);
      const g = c.grosor || 1;
      if (c.relleno) {
        lines.push(`BAR ${x},${y},${rw},${rh}`);
      } else {
        lines.push(`BAR ${x},${y},${rw},${g}`);
        lines.push(`BAR ${x},${y + rh - g},${rw},${g}`);
        lines.push(`BAR ${x},${y},${g},${rh}`);
        lines.push(`BAR ${x + rw - g},${y},${g},${rh}`);
      }
    } else if (c.tipo === 'barcode') {
      const codigo = String(c.codigo || '').replace(/"/g, '');
      const alto = isFinite(c.alto_dots) ? Math.max(16, Math.min(200, c.alto_dots)) : 48;
      const narrow = isFinite(c.narrow) ? Math.max(1, Math.min(5, c.narrow)) : 2;
      lines.push(`BARCODE ${x},${y},"128",${alto},0,0,${narrow},${narrow},"${codigo}"`);
    } else if (c.tipo === 'qr') {
      const qrCod = String(c.codigo || '').replace(/"/g, '');
      const qrSize = Math.max(2, Math.min(10, Math.round((c.tamano_dots || 64) / 8)));
      lines.push(`QRCODE ${x},${y},L,${qrSize},A,0,"${qrCod}"`);
    }
  }

  lines.push('PRINT 1,1');
  return linesToBytes(lines);
}

function linesToBytes(lines) {
  let bytes = [];
  for (const ln of lines) {
    if (ln.indexOf('__BITMAP__') === 0) {
      const parts = ln.substring(10).split(',');
      const prefix = `BITMAP ${parts[0]},${parts[1]},${parts[2]},${parts[3]},0,`;
      bytes = bytes.concat(strToBytes(prefix));
      bytes = bytes.concat(hexToBytes(parts[4]));
      bytes = bytes.concat(strToBytes('\r\n'));
    } else {
      bytes = bytes.concat(strToBytes(ln + '\r\n'));
    }
  }
  return bytes;
}

function strToBytes(s) {
  const b = [];
  for (let i = 0; i < s.length; i++) b.push(s.charCodeAt(i) & 0xFF);
  return b;
}

function hexToBytes(hex) {
  const b = [];
  let h = String(hex || '').replace(/[^0-9A-Fa-f]/g, '');
  if (h.length % 2 !== 0) h = h.substring(0, h.length - 1);
  for (let i = 0; i < h.length; i += 2) {
    const val = parseInt(h.substring(i, i + 2), 16);
    b.push(isNaN(val) ? 0 : val);
  }
  return b;
}
