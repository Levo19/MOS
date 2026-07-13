const fs = require('fs');
const p = 'C:/Users/ISO/ProyectoMOS/js/app.js';
const DEAD = ['_renderOpCard','abrirCostosGuia','abrirCostosGuiaLegacy','_renderCostosGuiaBody','cerrarCostosGuia','_mostrarPanelImpactoSkeleton','_mostrarPanelImpacto','_ocultarSeccionSugerencias','aplicarSugerenciasSeleccionadas','_impactoTogglesel','_impactoSetPrecio','cerrarImpactoCostos','_prefetchCostosGuias','costosUsarOrigenFoto','costosUsarOrigenManual','_opsMostrarBadgeOcrAuto','_opsOcultarBadgeOcrAuto'];
let L = fs.readFileSync(p, 'utf8').split('\n');
let removed = 0; const notfound = [];
for (const fn of DEAD) {
  let s = -1;
  for (let i = 0; i < L.length; i++) {
    const m = L[i].match(/^  (?:async )?function ([A-Za-z0-9_]+)\b/);
    if (m && m[1] === fn) { s = i; break; }
  }
  if (s < 0) { notfound.push(fn); continue; }
  let e = -1;
  for (let i = s + 1; i < L.length; i++) {
    if (L[i] === '  }') { e = i; break; }
    if (/^  (?:async )?function /.test(L[i])) break; // llegó a la siguiente sin cerrar → abortar esta
  }
  if (e < 0) { notfound.push(fn + '(sin cierre)'); continue; }
  L.splice(s, e - s + 1);
  removed++;
}
fs.writeFileSync(p, L.join('\n'));
console.log('eliminadas:', removed, '/', DEAD.length);
if (notfound.length) console.log('NO encontradas:', notfound.join(', '));
