import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const { rows } = await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='promo_sugerencias'`);
const L = rows[0].d.split('\r\n');
L.forEach((l,i)=>{
  if (l.includes("x.l_sku,   'cantidad'") || l.includes("lo anclamos al") || l.includes("'items',         e.items_j") || l.includes("'costoTotal',")) console.log(i, JSON.stringify(l));
});
await c.end();
