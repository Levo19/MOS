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
