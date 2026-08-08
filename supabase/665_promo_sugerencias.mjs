// 665 · aplica mos.promo_sugerencias() (el radar) + helpers de precio.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
await c.query('begin');
try {
  await c.query(fs.readFileSync('665_promo_sugerencias.sql','utf8'));
  const { rows:[{ r }] } = await c.query(`select mos.promo_sugerencias('{}'::jsonb) r`);
  if (!r.ok) throw new Error(r.error);
  if (!Array.isArray(r.data) || r.data.length < 2) throw new Error('radar devolvió menos de 2 ideas: ' + r.data.length);
  for (const x of r.data) {
    if (!x.porqueDetalle || x.porqueDetalle.length < 60) throw new Error('sin explicación: ' + x.skuBase);
    if (!x.estrategia) throw new Error('sin estrategia: ' + x.skuBase);
    if (x.perdida) throw new Error('el radar NO debe proponer por debajo del costo: ' + x.skuBase);
    if (x.precioPromo >= x.precioNormal) throw new Error('precio promo >= normal: ' + x.skuBase);
  }
  const { rows:[{ g }] } = await c.query(`select has_function_privilege('authenticated','mos.promo_sugerencias(jsonb)','execute') g`);
  if (!g) throw new Error('authenticated sin execute');
  const { rows:[{ an }] } = await c.query(`select has_function_privilege('anon','mos.promo_sugerencias(jsonb)','execute') an`);
  if (an) throw new Error('anon NO debe poder ejecutar');
  console.log('· radar OK ·', r.data.length, 'ideas · reglas:', [...new Set(r.data.map(x=>x.regla))].join(','));
  await c.query('commit'); console.log('APLICADO ✓');
} catch(e){ await c.query('rollback'); console.error('FALLÓ:', e.message); process.exitCode = 1; }
await c.end();
