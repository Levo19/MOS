// Barrido fmt()→fmtQty() en cantidades de STOCK de WH (reemplazos literales, verifica conteo).
import fs from 'fs';
const F = 'C:/Users/ISO/ecosistema MOS/warehouseMos/js/app.js';
let t = fs.readFileSync(F, 'utf8');
const reps = [
  // historial producto (hero + proyección + movimientos + saldo + lotes + ticket)
  ["setKpi('histStockActual', fmt(stockTotal));", "setKpi('histStockActual', fmtQty(stockTotal));"],
  ["setKpi('histStockMin',    fmt(stockMin));", "setKpi('histStockMin',    fmtQty(stockMin));"],
  ["+${fmt(_proyH.porRecibir)} por recibir", "+${fmtQty(_proyH.porRecibir)} por recibir"],
  ["\u2212${fmt(_proyH.porSalir)} por salir", "\u2212${fmtQty(_proyH.porSalir)} por salir"],
  ["Real ${fmt(stockTotal)}", "Real ${fmtQty(stockTotal)}"],
  ["\u2248 ${fmt(_proyH.proyectado)}", "\u2248 ${fmtQty(_proyH.proyectado)}"],
  ["\u2212${fmt(cantidadConsumida)}u", "\u2212${fmtQty(cantidadConsumida)}u"],
  ["${sign}${fmt(m.cantidad)}", "${sign}${fmtQty(m.cantidad)}"],
  ["${m.bal == null ? '\u2014' : fmt(m.bal)}", "${m.bal == null ? '\u2014' : fmtQty(m.bal)}"],
  ["fmt(m.cantidad, 0)).padStart(COL_MON)", "fmtQty(m.cantidad)).padStart(COL_MON)"],
  ["${fmt(stock,    0).padStart(9)}", "${fmtQty(stock).padStart(9)}"],
  ["${fmt(stockMin, 0).padStart(9)}", "${fmtQty(stockMin).padStart(9)}"],
  // auditar / ajustar
  ["document.getElementById('auditStockSis').textContent = fmt(s.cantidadDisponible || 0);", "document.getElementById('auditStockSis').textContent = fmtQty(s.cantidadDisponible || 0);"],
  ["document.getElementById('ajusteStockSis').textContent = fmt(s.cantidadDisponible || 0);", "document.getElementById('ajusteStockSis').textContent = fmtQty(s.cantidadDisponible || 0);"],
  ["${fmt(diff, 2)} \u2014 stock: ${fmt(stockReal)}", "${fmtQty(diff)} \u2014 stock: ${fmtQty(stockReal)}"],
  // badges de stock en despachos/pickups/buscadores
  ["\u26a0 stock ${fmt(stockD,1)} \u00b7 faltar\u00e1n ${fmt(pendiente - stockD,1)}", "\u26a0 stock ${fmtQty(stockD)} \u00b7 faltar\u00e1n ${fmtQty(pendiente - stockD)}"],
  ["\u26a0 stock ${fmt(stockD,1)}", "\u26a0 stock ${fmtQty(stockD)}"],
  [">stock ${fmt(stockD,1)}</span>", ">stock ${fmtQty(stockD)}</span>"],
  ["\u00b7 Stock: ${fmt(stockD,1)}", "\u00b7 Stock: ${fmtQty(stockD)}"],
  ["\u00b7 Stock: ${fmt(stockD, 1)}", "\u00b7 Stock: ${fmtQty(stockD)}"],
  // envasador (catálogo + consumo en vivo)
  ["${fmt(d.stockD,1)} ${escHtml(d.unidad||'')}", "${fmtQty(d.stockD)} ${escHtml(d.unidad||'')}"],
  ["${fmt(base.stockBase,1)} ${escHtml(base.unidad)}", "${fmtQty(base.stockBase)} ${escHtml(base.unidad)}"],
  ["${fmt(consumo, 2)} ${unidadBase}", "${fmtQty(consumo)} ${unidadBase}"],
  ["${fmt(queda, 2)} ${unidadBase} \u00b7 alcanza ${alcanza} uds m\u00e1s", "${fmtQty(queda)} ${unidadBase} \u00b7 alcanza ${alcanza} uds m\u00e1s"],
  ["${fmt(queda, 2)} ${unidadBase}`;", "${fmtQty(queda)} ${unidadBase}`;"],
  ["${fmt(stockBase, 2)} ${unidadBase} en sistema", "${fmtQty(stockBase)} ${unidadBase} en sistema"],
  ["NEGATIVO (${fmt(queda, 2)} ${unidadBase})", "NEGATIVO (${fmtQty(queda)} ${unidadBase})"],
  ["Faltan ${fmt(cantBase - stockBase, 1)}", "Faltan ${fmtQty(cantBase - stockBase)}"],
  // mermas
  ["\u2713 ${fmt(m.cantidadReparada, 1)} recuperadas", "\u2713 ${fmtQty(m.cantidadReparada)} recuperadas"],
  ["\ud83d\uddd1 ${fmt(m.cantidadDesechada, 1)} eliminadas", "\ud83d\uddd1 ${fmtQty(m.cantidadDesechada)} eliminadas"],
];
let okN = 0, miss = [];
for (const [a, b] of reps) {
  if (t.includes(a)) { t = t.split(a).join(b); okN++; }
  else miss.push(a.slice(0, 60));
}
fs.writeFileSync(F, t);
console.log('reemplazos OK:', okN, '/', reps.length);
if (miss.length) { console.log('NO ENCONTRADOS:'); miss.forEach(m => console.log('  -', m)); }
