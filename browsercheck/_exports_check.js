// Guardia contra el error que tumbó el 2.43.819: un nombre en la lista de exports del IIFE
// que ya no existe. Al evaluar el objeto se lanza ReferenceError, el IIFE muere y `const MOS`
// jamás se crea → la app entera no arranca ("MOS is not defined", pantalla colgada).
// `node --check` NO lo detecta: es sintaxis válida, revienta recién en ejecución.
//
//   node _exports_check.js ../js/app.js
//
// Sale con código 1 si algún export no tiene definición en el archivo.
const fs = require('fs');

const file = process.argv[2] || '../js/app.js';
const src = fs.readFileSync(file, 'utf8');

// El objeto que devuelve el IIFE principal: último `return {` de nivel 2 hasta su `};`
const ini = src.lastIndexOf('\n  return {');
if (ini < 0) { console.error('No se encontró el objeto de exports'); process.exit(2); }
const fin = src.indexOf('\n  };', ini);
if (fin < 0) { console.error('No se encontró el cierre del objeto de exports'); process.exit(2); }
const bloque = src.slice(ini, fin);

// nombres exportados: `nombre,` o `nombre` al final de línea (shorthand) y `alias: nombre`
const nombres = new Set();
bloque.split('\n').forEach(linea => {
  const l = linea.replace(/\/\/.*$/, '').trim();
  if (!l || l === 'return {') return;
  l.split(',').forEach(tok => {
    const t = tok.trim();
    if (!t) return;
    const m = t.match(/^([A-Za-z_$][\w$]*)$/) || t.match(/^[A-Za-z_$][\w$]*\s*:\s*([A-Za-z_$][\w$]*)$/);
    if (m) nombres.add(m[1]);
  });
});

const cuerpo = src.slice(0, ini);   // todo lo que está ANTES del return
const faltan = [];
nombres.forEach(n => {
  const esc = n.replace(/\$/g, '\\$');
  const definido =
    new RegExp('function\\s+' + esc + '\\s*\\(').test(cuerpo) ||
    new RegExp('(?:const|let|var)\\s+' + esc + '\\b').test(cuerpo) ||
    new RegExp('\\b' + esc + '\\s*=\\s*(?:async\\s*)?(?:function|\\()').test(cuerpo) ||
    new RegExp('\\b' + esc + '\\s*:\\s*').test(cuerpo);
  if (!definido) faltan.push(n);
});

console.log('exports revisados: ' + nombres.size + ' · sin definición: ' + faltan.length);
if (faltan.length) {
  faltan.forEach(n => console.log('  ❌ ' + n + ' — exportado pero NO definido'));
  process.exit(1);
}
console.log('  ✅ todos los exports tienen definición');
