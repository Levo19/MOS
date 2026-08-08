import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const q = async (t,s,p)=>{ try{ const r=await c.query(s,p); console.log('###',t); console.dir(r.rows,{depth:3,maxArrayLength:80}); }catch(e){ console.log('###',t,'ERR',e.message); } };
await q('cols_promos', `select column_name, data_type from information_schema.columns where table_schema='mos' and table_name='promociones' order by ordinal_position`);
await q('claim_ok', `select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='mos' and p.proname='_claim_ok'`);
await c.end();
