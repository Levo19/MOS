// [759-restore] Las suites validate_mos_84/86 y apply_mos_81 re-aplicaron esta noche los SQL
// viejos 81/84/85/86 con `create or replace` — pisando las versiones vivas de funciones que
// migraciones POSTERIORES habían parchado (167, 227, 293, 299, 304, 419, 544, 571, 572, 574…).
// Cura: para cada función definida en esos 4 archivos, extraer su definición del ÚLTIMO archivo
// numerado que la define y re-aplicarla, en una sola transacción. Reproduce "el último gana"
// de la historia de migraciones, sin ejecutar backfills ni inserts de esos archivos.
import fs from 'fs';
import pg from 'pg';

const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const REAPLICADOS = ['81_mos_proveedores_pedidos_pagos.sql', '84_mos_jornadas.sql',
                     '85_mos_liquidaciones_dia.sql', '86_mos_liquidaciones_pagos.sql'];

const fnDefRe = /create\s+or\s+replace\s+function\s+(mos\.[a-z0-9_]+)/gi;
const afectadas = new Set();
for (const f of REAPLICADOS) {
  if (!fs.existsSync(f)) { console.log('⚠ no existe:', f); continue; }
  const t = fs.readFileSync(f, 'utf8');
  let m; while ((m = fnDefRe.exec(t))) afectadas.add(m[1].toLowerCase());
}
console.log('funciones afectadas (' + afectadas.size + '):', [...afectadas].join(', '));

const files = fs.readdirSync('.').filter(f => /^\d+_.*\.sql$/.test(f))
  .sort((a, b) => parseInt(a) - parseInt(b));

function extraer(texto, fn) {
  const startRe = new RegExp('create\\s+or\\s+replace\\s+function\\s+' + fn.replace('.', '\\.') + '\\s*\\(', 'i');
  const m = startRe.exec(texto);
  if (!m) return null;
  const start = m.index;
  const asM = /\bas\s+(\$[a-z_]*\$)/i.exec(texto.slice(start));
  if (!asM) return null;
  const tag = asM[1];
  const bodyStart = start + asM.index + asM[0].length;
  const close = texto.indexOf(tag, bodyStart);
  if (close < 0) return null;
  let end = close + tag.length;
  while (end < texto.length && /\s/.test(texto[end])) end++;
  if (texto[end] === ';') end++;
  return texto.slice(start, end);
}

const plan = [];
for (const fn of afectadas) {
  let ultimo = null;
  for (const f of files) {
    const t = fs.readFileSync(f, 'utf8');
    if (new RegExp('function\\s+' + fn.replace('.', '\\.') + '\\s*\\(', 'i').test(t)) ultimo = f;
  }
  const def = ultimo ? extraer(fs.readFileSync(ultimo, 'utf8'), fn) : null;
  plan.push({ fn, ultimo, extraida: def ? def.length : 0 });
  if (def) fs.writeFileSync('_restore_def_' + fn.replace('mos.', '') + '.sql', def);
}
console.table(plan);

const c = new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
try {
  await c.query('begin');
  let aplicadas = 0;
  for (const p of plan) {
    if (!p.extraida) { console.log('⚠ SIN DEF EXTRAÍBLE:', p.fn, '(revisar a mano)'); continue; }
    const def = fs.readFileSync('_restore_def_' + p.fn.replace('mos.', '') + '.sql', 'utf8');
    await c.query(def);
    aplicadas++;
  }
  await c.query('commit');
  console.log('✅ RESTAURADAS', aplicadas, 'funciones a su última versión de la historia de migraciones');
} catch (e) {
  await c.query('rollback').catch(() => {});
  console.error('❌ ROLLBACK:', e.message);
  process.exit(1);
} finally { await c.end(); }
