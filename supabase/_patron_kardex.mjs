import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='wh' and p.proname='crear_ajuste' limit 1`)).rows[0].d;
const i = d.indexOf('stock_movimientos');
console.log('── cómo registra el kardex wh.crear_ajuste:');
console.log(d.slice(Math.max(0,i-700), i+420));
// ¿existe un helper central?
console.table((await c.query(`select n.nspname||'.'||p.proname f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='wh' and p.proname ~* 'kardex|mov'`)).rows);
await c.end();
