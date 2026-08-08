import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
await c.query('begin');
try {
  await c.query(fs.readFileSync('665_promo_sugerencias.sql','utf8'));
  const { rows:[{ r }] } = await c.query(`select mos.promo_sugerencias('{}'::jsonb) r`);
  console.log('ok=',r.ok,'n=',(r.data||[]).length,'seed=',r.seed,'gen=',r.generado);
  (r.data||[]).forEach((x,i) => console.log(`\n[${i+1}] ${x.emoji} ${x.regla} · ${x.descripcion} (${x.skuBase})
   POR QUÉ: ${x.porque}
   JUGADA : ${x.estrategia} → ${x.tipo} cantMin=${x.cantMin} modo=${x.valorModo} valorPromo=${x.valorPromo} horas=${x.horaDesde||'—'}-${x.horaHasta||'—'}
   PRECIO : normal S/${x.precioNormal} → promo S/${x.precioPromo} (-${x.descuentoPct}%) | costo S/${x.precioCosto} | margen ${x.margenResultante}% (S/${x.margenSoles}) | perdida=${x.perdida}
   DETALLE: ${x.porqueDetalle}`));
  const { rows:[{ r2 }] } = await c.query(`select mos.promo_sugerencias('{"seed":"OTRA"}'::jsonb) r2`);
  console.log('\n--- reshuffle seed=OTRA:', (r2.data||[]).map(x=>x.skuBase).join(', '));
  console.log('--- playbook:', JSON.stringify(r.playbook, null, 1));
} catch(e){ console.log('ERR', e.message, e.position||''); }
await c.query('rollback'); await c.end();
