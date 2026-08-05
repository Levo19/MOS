// 630 · Plantilla de adhesivo "Papito · Dulce de Camote" — clon exacto de la de
// Dulce Níspero (ADH-PAPITO-01), cambiando solo el título del producto.
// Título en dos renglones font 4 (3 mm/char): "Dulce de" (24 mm desde x=15 → 39 mm) ✓
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();

const base = (await c.query(`select json, tamano_canvas from mos.adhesivo_plantillas where id_plantilla='ADH-PAPITO-01'`)).rows[0];
if (!base) { console.log('❌ no existe ADH-PAPITO-01'); process.exit(1); }

const j = JSON.parse(JSON.stringify(base.json));
const t1 = j.capas.find(x => x.id === 't1');
const t2 = j.capas.find(x => x.id === 't2');
if (!t1 || !t2 || t1.texto !== 'Dulce' || t2.texto !== 'Níspero') {
  console.log('❌ la plantilla base cambió de forma — capas:', j.capas.map(x => x.id + ':' + (x.texto || x.tipo)).join(' · '));
  process.exit(1);
}
t1.texto = 'Dulce de';
t2.texto = 'Camote';
j.metadata.nombre = 'Papito · Dulce de Camote';

await c.query(`insert into mos.adhesivo_plantillas (id_plantilla, nombre, descripcion, tamano_canvas, json, creado_por, fecha_creado, fecha_ult_mod, activo)
  values ('ADH-PAPITO-02', 'Papito · Dulce de Camote', 'Adhesivo Postres Papito · Dulce de Camote · tel 976 222 528', $1, $2::jsonb, 'Claude', now(), now(), true)
  on conflict (id_plantilla) do update set nombre = excluded.nombre, descripcion = excluded.descripcion,
    json = excluded.json, fecha_ult_mod = now(), activo = true`, [base.tamano_canvas, JSON.stringify(j)]);

// verificación
const v = (await c.query(`select nombre, tamano_canvas, activo, json from mos.adhesivo_plantillas where id_plantilla='ADH-PAPITO-02'`)).rows[0];
const capas = v.json.capas;
const ck = [
  ['existe y activa 50x25', v.activo === true && v.tamano_canvas === '50x25'],
  ['título: "Dulce de" + "Camote"', capas.find(x => x.id === 't1')?.texto === 'Dulce de' && capas.find(x => x.id === 't2')?.texto === 'Camote'],
  ['marca "Postres Papito" intacta', capas.find(x => x.id === 't3')?.texto === 'Postres Papito'],
  ['teléfono 976 222 528 con su icono', capas.find(x => x.id === 't4')?.texto === '976 222 528' && capas.find(x => x.id === 'tf')?.idIcono === 'telefono'],
  ['icono de postre y línea siguen', capas.find(x => x.id === 'ic')?.idIcono === 'postre' && capas.some(x => x.id === 'ln')],
  ['"Dulce de" cabe: 15 + 8×3 = 39 mm de 50', 15 + 'Dulce de'.length * 3 <= 48],
  ['la de Níspero NO se tocó', (await c.query(`select json->'capas' cc from mos.adhesivo_plantillas where id_plantilla='ADH-PAPITO-01'`)).rows[0].cc.find(x => x.id === 't2').texto === 'Níspero'],
];
let fail = 0;
ck.forEach(([n, ok]) => { console.log(' ', ok ? '✅' : '❌', n); if (!ok) fail++; });
console.log(fail ? `\n❌ ${fail} fallos` : '\n✅ ADH-PAPITO-02 "Dulce de Camote" lista en el Estudio');
await c.end();
process.exit(fail ? 1 : 0);
