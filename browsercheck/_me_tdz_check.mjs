// [ME] Zona muerta: nada que corra AL MONTAR puede leer un `const` declarado después.
//
// Me costó dos pantallas blancas seguidas y casi una tercera. El patrón es siempre el mismo:
// escribo un `watch(..., { immediate: true })` cerca de donde está el tema, pero la constante
// que usa se declara miles de líneas más abajo. Como corre DENTRO de setup(), el
// ReferenceError aborta setup() entero: no se exporta nada, el render encuentra `undefined`
// y la app arranca en blanco. No falla el modo cajero — falla la app, para todos.
//
// Qué cuenta como "corre al montar": el cuerpo directo del callback de un watch immediate.
// Lo que está dentro de un setTimeout/función anidada NO corre ahí, y no se marca — si no,
// esto gritaría por medio archivo y dejaría de servir.
import fs from 'fs';

const ME = process.argv[2] || 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html';
const src = fs.readFileSync(ME, 'utf8');
const ini = src.indexOf('setup()');
const fin = src.lastIndexOf('}).mount(');
const cuerpo = src.slice(ini, fin > ini ? fin : src.length);

// declaraciones const/let de primer nivel del setup (8 espacios de indentación)
const decl = new Map();
for (const m of cuerpo.matchAll(/\n {8}(?:const|let) ([A-Za-z_$][\w$]*)\s*=/g))
  if (!decl.has(m[1])) decl.set(m[1], m.index);

// recorta desde un '(' hasta su paréntesis de cierre, contando de verdad
function hastaCierre(txt, abre) {
  let n = 0;
  for (let i = abre; i < txt.length; i++) {
    const c = txt[i];
    if (c === '(') n++;
    else if (c === ')') { if (--n === 0) return txt.slice(abre, i + 1); }
    else if (c === '"' || c === "'" || c === '`') {            // saltar literales
      const q = c; i++;
      while (i < txt.length && txt[i] !== q) { if (txt[i] === '\\') i++; i++; }
    } else if (c === '/' && txt[i+1] === '/') { while (i < txt.length && txt[i] !== '\n') i++; }
    else if (c === '/' && txt[i+1] === '*') { i = txt.indexOf('*/', i); if (i < 0) return txt.slice(abre); i++; }
  }
  return txt.slice(abre);
}
// borra el interior de las funciones anidadas: eso NO corre al montar
function soloNivelDirecto(bloque) {
  return bloque
    .replace(/setTimeout\s*\([\s\S]*?\)\s*;?/g, ' ')
    .replace(/setInterval\s*\([\s\S]*?\)\s*;?/g, ' ')
    .replace(/nextTick\s*\([\s\S]*?\)\s*;?/g, ' ')
    .replace(/\.then\s*\([\s\S]*?\)/g, ' ');
}

const hallazgos = [];
for (const m of cuerpo.matchAll(/\n {8}watch(?:Effect)?\s*\(/g)) {
  const abre = cuerpo.indexOf('(', m.index);
  const bloque = hastaCierre(cuerpo, abre);
  if (!/immediate:\s*true/.test(bloque)) continue;
  const directo = soloNivelDirecto(bloque);
  const linea = src.slice(0, ini + m.index).split('\n').length;
  for (const id of directo.matchAll(/(?<![.\w$])([A-Za-z_$][\w$]*)/g)) {
    const n = id[1], d = decl.get(n);
    if (d != null && d > m.index) hallazgos.push({ id: n, linea });
  }
}

const unicos = [...new Map(hallazgos.map(r => [r.id + '@' + r.linea, r])).values()];
console.log('  consts de setup revisadas: ' + decl.size + ' · watchs immediate: ' +
  [...cuerpo.matchAll(/\n {8}watch(?:Effect)?\s*\(/g)].length);
if (unicos.length) {
  console.log('  --  ' + unicos.length + ' lectura(s) en zona muerta — esto arranca la app en BLANCO:');
  unicos.forEach(r => console.log('        · "' + r.id + '" se lee en el watch immediate de la línea ~' +
                                  r.linea + ' y se declara después'));
  process.exit(1);
}
console.log('  OK  ningún watch immediate lee un const declarado después');
process.exit(0);
