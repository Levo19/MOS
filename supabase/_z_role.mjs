import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
await c.query('begin');
try {
  await c.query(`set local role authenticated`);
  await c.query(`select set_config('request.jwt.claims','{"role":"authenticated","app":"MOS"}',true)`);
  const r = await c.query(`select mos.promo_sugerencias('{"n":6}'::jsonb) r`);
  console.log('OK n=', (r.rows[0].r.data||[]).length);
} catch(e){ console.log('ERR', e.code, e.message); }
await c.query('rollback');
// segunda llamada en la misma sesión (temp table persiste entre tx sin on-commit-drop?)
await c.query('begin');
try { await c.query(`set local role authenticated`); const r = await c.query(`select mos.promo_sugerencias('{"n":6}'::jsonb) r`); console.log('2da OK n=',(r.rows[0].r.data||[]).length); }
catch(e){ console.log('2da ERR', e.code, e.message); }
await c.query('rollback');
await c.end();
