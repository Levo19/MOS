import fs from 'fs';
import vm from 'vm';
const P = process.argv[2];
const s = fs.readFileSync(P,'utf8');
const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
let m, i=0, bad=0;
while ((m = re.exec(s))) {
  const attrs = m[1] || '';
  if (/\bsrc\s*=/.test(attrs)) continue;
  if (/type\s*=\s*["'](?!text\/javascript|module|application\/javascript)/i.test(attrs)) continue;
  i++;
  const code = m[2];
  const line = s.slice(0, m.index).split('\n').length;
  try { new vm.Script(code, { filename: P + ':' + line }); }
  catch (e) { bad++; console.log('SCRIPT #'+i+' (linea '+line+') ERROR:', e.message); }
}
console.log('scripts inline verificados:', i, '· con error:', bad);
process.exit(bad ? 1 : 0);
