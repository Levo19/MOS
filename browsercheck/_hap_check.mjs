// Extrae TODOS los <script> inline de index.html y los pasa por node --check.
import fs from 'fs'; import { execSync } from 'child_process'; import os from 'os'; import path from 'path';
const SRC = process.argv[2] || 'C:/Users/ISO/ecosistema MOS/MosExpress/index.html';
const html = fs.readFileSync(SRC, 'utf8');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mechk-'));
const re = /<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g;
let m, n = 0, bad = 0;
while ((m = re.exec(html)) !== null) {
  n++;
  const code = m[1];
  const f = path.join(dir, 'S' + n + '.js');
  fs.writeFileSync(f, code, 'utf8');
  try { execSync('node --check "' + f + '"', { stdio: 'pipe' }); console.log('  ✓ script #' + n + '  (' + code.length + ' bytes)'); }
  catch (e) { bad++; console.log('  ✗ script #' + n + '  ' + String(e.stderr || e).split('\n').slice(0, 6).join('\n')); }
}
console.log('TOTAL scripts inline: ' + n + ' · con error: ' + bad);
process.exit(bad ? 1 : 0);
