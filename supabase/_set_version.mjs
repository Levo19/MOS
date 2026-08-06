// _set_version.mjs — escribe version.json SIEMPRE válido (JSON.stringify, imposible comerse la llave).
// Uso: node _set_version.mjs <rutaRepo> <version> "<build...>"
// También repara: si el archivo actual está corrupto por llave faltante, lo normaliza.
import fs from 'fs';
const [, , repo, version, ...buildParts] = process.argv;
if (!repo || !version) { console.error('uso: node _set_version.mjs <rutaRepo> <version> "<build>"'); process.exit(1); }
const f = repo.replace(/[\\/]+$/, '') + '/version.json';
let build = buildParts.join(' ');
if (!build) {
  // sin build nuevo → conservar el existente (aunque el JSON esté roto, extraer por regex)
  const raw = fs.readFileSync(f, 'utf8');
  const m = raw.match(/"build"\s*:\s*"([\s\S]*?)"\s*[},]?\s*$/) || raw.match(/"build"\s*:\s*"([\s\S]*?)"/);
  build = m ? m[1] : '';
}
fs.writeFileSync(f, JSON.stringify({ version, build }));
JSON.parse(fs.readFileSync(f, 'utf8'));   // autoverificación
console.log('OK', f, '→', version, '· build', build.slice(0, 60) + (build.length > 60 ? '…' : ''));

// [2.43.681 · bug del bucle de actualización] Si el index.html del repo trae el letrero
// `var V = 'x.y.z'` (el banner de consola de MOS + el chequeo de auto-update), se bumpea
// AQUÍ MISMO. Quedó en 2.43.651 durante ~30 versiones porque el ritual no lo cubría →
// cada carga "detectaba" versión nueva, vaciaba el caché del SW y recargaba (el bucle
// "actualizando solo… / borra datos del sitio" que reportó el dueño).
try {
  const idx = repo.replace(/[\\/]+$/, '') + '/index.html';
  if (fs.existsSync(idx)) {
    const html = fs.readFileSync(idx, 'utf8');
    const re = /var V = '(\d+\.\d+\.\d+)';(\s*\/\/ ⚠ bumpear)/;
    if (re.test(html)) {
      fs.writeFileSync(idx, html.replace(re, `var V = '${version}';$2`));
      console.log('OK', idx, '→ var V =', version);
    }
  }
} catch (e) { console.error('⚠ no pude bumpear var V del index:', e.message); process.exit(1); }
