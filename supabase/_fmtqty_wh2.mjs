// Barrido 2 fmt()→fmtQty() WH — lista stock, detalle guía, despachos, kardex, lotes.
import fs from 'fs';
const F = 'C:/Users/ISO/ecosistema MOS/warehouseMos/js/app.js';
let t = fs.readFileSync(F, 'utf8');
const reps = [
  ["${fmt(a.stockReal,1)}", "${fmtQty(a.stockReal)}"],
  ["${fmt(a.stockTeorico,1)}", "${fmtQty(a.stockTeorico)}"],
  ["'\u00d7' + fmt(d.cantidadRecibida, Number.isInteger(parseFloat(d.cantidadRecibida)) ? 0 : 2)", "'\u00d7' + fmtQty(d.cantidadRecibida)"],
  ["${fmt(e.cantidadBase, 1)} ${escHtml(e.unidadBase || '')}", "${fmtQty(e.cantidadBase)} ${escHtml(e.unidadBase || '')}"],
  ["const qtyFmt = fmt(it.cantidad, Number.isInteger(parseFloat(it.cantidad)) ? 0 : 2);", "const qtyFmt = fmtQty(it.cantidad);"],
  ["const qtyFmt = fmt(item.cantidad, Number.isInteger(parseFloat(item.cantidad)) ? 0 : 2);", "const qtyFmt = fmtQty(item.cantidad);"],
  ["'Pickup \u00b7 ' + fmt(activo.cantidad, activo.esGranel ? 3 : 0) + '/'", "'Pickup \u00b7 ' + fmtQty(activo.cantidad) + '/'"],
  ["'<span class=\"despflot-val\">' + fmt(activo.cantidad, 0) + '</span>'", "'<span class=\"despflot-val\">' + fmtQty(activo.cantidad) + '</span>'"],
  ["\u26a0 stock:${fmt(item.stockDisp,1)}", "\u26a0 stock:${fmtQty(item.stockDisp)}"],
  ["\u26a0 stock: ${fmt(item.stockDisp,1)}", "\u26a0 stock: ${fmtQty(item.stockDisp)}"],
  ["pides <b>${fmt(c.cantidad,2)}</b>, stock <b>${fmt(c.stockDisp,1)}</b>", "pides <b>${fmtQty(c.cantidad)}</b>, stock <b>${fmtQty(c.stockDisp)}</b>"],
  ["'text-emerald-400'}\">${fmt(g.stockTotal)}</span>", "'text-emerald-400'}\">${fmtQty(g.stockTotal)}</span>"],
  ["setKpi('prodDetKpiStock', fmt(grupo.stockTotal));", "setKpi('prodDetKpiStock', fmtQty(grupo.stockTotal));"],
  ["'text-slate-500'}\">${fmt(cant)}</span>", "'text-slate-500'}\">${fmtQty(cant)}</span>"],
  ["${fmt(grupo.stockTotal)}</span> unidades", "${fmtQty(grupo.stockTotal)}</span> unidades"],
  ["antes: <b class=\"text-slate-300\">${fmt(m.stockAntes, 1)}</b>", "antes: <b class=\"text-slate-300\">${fmtQty(m.stockAntes)}</b>"],
  ["despu\u00e9s: <b class=\"text-slate-300\">${fmt(m.stockDespues, 1)}</b>", "despu\u00e9s: <b class=\"text-slate-300\">${fmtQty(m.stockDespues)}</b>"],
  ["<span class=\"vq-n\">${fmt(l.cantidadActual, 1)}</span>", "<span class=\"vq-n\">${fmtQty(l.cantidadActual)}</span>"],
];
let okN = 0, miss = [];
for (const [a, b] of reps) {
  if (t.includes(a)) { t = t.split(a).join(b); okN++; }
  else miss.push(a.slice(0, 70));
}
fs.writeFileSync(F, t);
console.log('reemplazos OK:', okN, '/', reps.length);
if (miss.length) { console.log('NO ENCONTRADOS:'); miss.forEach(m => console.log('  -', m)); }
