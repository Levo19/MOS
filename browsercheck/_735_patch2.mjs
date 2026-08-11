// [735] Ajustes al parche: (a) des-indentar los dos bloques async reubicados,
// (b) en el refresco, re-aplicar los prellenados acumulados (limpieza/checks) SOLO
//     si el admin no los tocó — el lápiz de Liquidaciones abre con un resumen
//     sintético en 0 y necesita que el dato real los complete.
import fs from 'fs';
const APP = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js';
const EOL = '\r\n';
let A = fs.readFileSync(APP, 'utf8').split(EOL);
const unico = (ancla, ctx) => {
  const idx = []; A.forEach((l, i) => { if (l === ancla) idx.push(i); });
  if (idx.length !== 1) throw new Error(`ancla ${ctx}: ${idx.length} coincidencias`);
  return idx[0];
};

// (a) des-indentar desde el comentario [421] hasta el cierre de la función
const i421 = unico('      // [421] Refresco EN TIEMPO REAL de los tickets a crédito DEL DÍA del modal (una', '[421]');
let iEnd = -1;
for (let i = i421; i < i421 + 120; i++) if (A[i] === '  }') { iEnd = i; break; }
if (iEnd < 0) throw new Error('sin cierre tras [421]');
for (let i = i421; i < iEnd; i++) if (A[i].startsWith('  ') && A[i].trim()) A[i] = A[i].slice(2);
console.log('des-indentadas ' + (iEnd - i421) + ' líneas');

// (b) stash del prellenado en la apertura
const aStash = unico("      _evalState.auditChecks = Object.assign({}, (r.manual && r.manual.checksAcum) || {});", 'checksAcum');
A.splice(aStash + 1, 0,
  "      // [735] Huella del prellenado: si al llegar el dato fresco los controles siguen",
  "      // exactamente así, es que el admin no los tocó y se pueden completar con el valor",
  "      // real (el lápiz de Liquidaciones abre con un resumen sintético en 0).",
  "      _evalState.auditPrefill = {",
  "        limp: String(limpAcum), limpProf: String(limpProfAcum),",
  "        checks: JSON.stringify(_evalState.auditChecks)",
  "      };");

// (c) en el refresco, re-aplicar si sigue intacto
const aRef = unico('    if (!esRefresco) {', 'if !esRefresco');
A.splice(aRef, 0,
  "    if (esRefresco) {",
  "      // Solo si NADA fue tocado: nunca pisamos lo que el admin ya movió.",
  "      const pf = _evalState.auditPrefill;",
  "      const slL = $('auditLimpieza'), slP = $('auditLimpiezaProf');",
  "      const intacto = pf && slL && slP",
  "        && String(slL.value) === pf.limp",
  "        && String(slP.value) === pf.limpProf",
  "        && JSON.stringify(_evalState.auditChecks || {}) === pf.checks;",
  "      if (intacto) {",
  "        const limpAcum = Math.round(((r.manual && r.manual.limpiezaPct) || 0) / 10) * 10;",
  "        const limpProfAcum = Math.round(((r.manual && r.manual.limpiezaProfPct) || 0) / 10) * 10;",
  "        slL.value = String(limpAcum);",
  "        slP.value = String(limpProfAcum);",
  "        updateRateSlider('auditLimpieza', 'auditLimpiezaVal');",
  "        updateRateSlider('auditLimpiezaProf', 'auditLimpiezaProfVal');",
  "        _evalState.auditChecks = Object.assign({}, (r.manual && r.manual.checksAcum) || {});",
  "        _evalState.auditPrefill = {",
  "          limp: String(limpAcum), limpProf: String(limpProfAcum),",
  "          checks: JSON.stringify(_evalState.auditChecks)",
  "        };",
  "      }",
  "    }",
  "");

fs.writeFileSync(APP, A.join(EOL), 'utf8');
console.log('✓ app.js: ' + A.length + ' líneas');
