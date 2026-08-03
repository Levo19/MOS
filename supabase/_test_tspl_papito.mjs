// Genera el TSPL real de ADH-PAPITO-01 con el MISMO generador del Edge (tspl.mjs)
// y los datos vivos de la BD (adhesivo_print_data). Verifica sin imprimir.
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
console.log('print_data ok · impresora PrintNode:', d.printerId, '· calib:', JSON.stringify(d.calib));
const bytes = adhJson2tspl(d.json, 0, d.iconos, d.calib);
console.log('bytes TSPL:', bytes.length);
const txt = Buffer.from(bytes).toString('latin1');
// asserts
const checks = [
  ['SIZE 50 mm,25 mm', txt.includes('SIZE 50 mm,25 mm')],
  ['BITMAP del cupcake 96 (12 bytes ancho, 96 alto)', /BITMAP \d+,\d+,12,96,/.test(txt)],
  ['TEXT POSTRES negrita (mul 2,2)', /TEXT \d+,\d+,"3",0,2,2,"POSTRES"/.test(txt)],
  ['TEXT PAPITO', /"PAPITO"/.test(txt)],
  ['TEXT eslogan', txt.includes('Dulzura hecha en casa')],
  ['BAR linea', /BAR \d+,\d+,\d+,\d+/.test(txt)],
  ['TEXT telefono 972 225 28 negrita', /TEXT \d+,\d+,"2",0,2,2,"972 225 28"/.test(txt)],
  ['PRINT 1', txt.includes('PRINT 1')],
  ['SIN membrete INVERSIONES MOS', !txt.includes('INVERSIONES')]
];
let ok = true;
for (const [n, v] of checks) { console.log((v ? '✅' : '❌'), n); if (!v) ok = false; }
console.log('\n── comandos (sin el hex del bitmap):');
console.log(txt.split('\r\n').map(l => l.length > 90 ? l.slice(0, 70) + '…(' + l.length + ')' : l).join('\n'));
process.exit(ok ? 0 : 1);
