// Genera el TSPL real de ADH-PAPITO-01 (v2 Dulce Níspero) con el MISMO generador
// del Edge (tspl.mjs) y datos vivos de la BD. Verifica sin imprimir:
// tilde CP437, icono teléfono, y que NINGÚN texto pase de 44 mm (desborde v1).
import fs from 'fs';
import pkg from 'pg';
import { adhJson2tspl } from '../supabase/functions/print-adhesivo-plantilla/tspl.mjs';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const d = (await c.query(`select mos.adhesivo_print_data('ADH-PAPITO-01') j`)).rows[0].j;
await c.end();
if (!d.ok) { console.log('❌ print_data:', d.error); process.exit(1); }
console.log('print_data ok · impresora PrintNode:', d.printerId);
const bytes = adhJson2tspl(d.json, 0, d.iconos, d.calib);
const txt = Buffer.from(bytes).toString('latin1');
// ancho por comando TEXT: FONT_W teórico + colchón 15% y tope 46 mm (regla
// post-desborde v1: apuntar fin TEÓRICO ≤ 40 mm para que el real quede < 46)
const FW = { '1': 8, '2': 12, '3': 16, '4': 24, '5': 32 };
let anchosOk = true;
for (const m of txt.matchAll(/TEXT (\d+),\d+,"(\d)",\d+,(\d),\d+,"([^"]*)"/g)) {
  const fin = parseInt(m[1]) + m[4].length * FW[m[2]] * parseInt(m[3]) * 1.15;
  const ok = fin <= 368;   // 46 mm
  if (!ok) anchosOk = false;
  console.log((ok ? '  ✓' : '  ✗ DESBORDA'), `"${m[4]}" fin estimado ${(fin / 8).toFixed(1)}mm`);
}
const checks = [
  ['Título Dulce presente', /"Dulce"/.test(txt)],
  ['Níspero con í transliterada CP437 (0xA1)', bytes.includes(0xA1) && /"N.spero"/.test(txt)],
  ['SIN byte latin1 crudo 0xED (basura en CP437)', !bytes.includes(0xED)],
  ['Postres Papito segunda línea', txt.includes('Postres Papito')],
  ['BITMAP cupcake 96', /BITMAP \d+,\d+,12,96,/.test(txt)],
  ['BITMAP teléfono 32 (4 bytes ancho)', /BITMAP \d+,\d+,4,32,/.test(txt)],
  ['Número 976 222 528 (9 dígitos) font 3 normal', /TEXT \d+,\d+,"3",0,1,1,"976 222 528"/.test(txt)],
  ['NO quedó ningún número viejo (972…/972 225 28)', !/97[0-9] 22[0-9] 2[0-9]/.test(txt.replace(/"976 222 528"/, ''))],
  ['Título en font 4 nativo (grueso, sin ×2 que desborda)', /TEXT \d+,\d+,"4",0,1,1,"Dulce"/.test(txt)],
  ['Todos los textos con fin teórico seguro (≤46mm con colchón)', anchosOk],
  ['SIN membrete', !txt.includes('INVERSIONES')]
];
let ok = true;
for (const [n, v] of checks) { console.log((v ? '✅' : '❌'), n); if (!v) ok = false; }
process.exit(ok ? 0 : 1);
