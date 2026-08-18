// Ritual obligatorio de ME: extraer cada <script> inline y node --check por separado.
// ME es UN index.html gigante: un error de sintaxis = Vue no monta = POS caído.
import fs from 'fs'; import { execFileSync } from 'child_process'; import os from 'os'; import path from 'path';
const html = fs.readFileSync(process.argv[2] || 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html', 'utf8');
const re = /<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/gi;
let m, i = 0, bad = 0;
const tmp = path.join(os.tmpdir(), 'me_scripts');
fs.mkdirSync(tmp, { recursive: true });
while ((m = re.exec(html)) !== null) {
  const attrs = m[1] || '', body = m[2] || '';
  if (/type\s*=\s*["'](?!text\/javascript|module|application\/javascript)/i.test(attrs)) continue;
  if (!body.trim()) continue;
  i++;
  const f = path.join(tmp, 's' + i + (/type\s*=\s*["']module/i.test(attrs) ? '.mjs' : '.js'));
  fs.writeFileSync(f, body);
  try { execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' }); }
  catch (e) { bad++; console.log('  ❌ script inline #' + i + ': ' + String(e.stderr || e).split('\n').slice(0, 4).join(' | ')); }
}
console.log('  scripts inline revisados: ' + i + ' · con error: ' + bad);
process.exit(bad ? 1 : 0);
