import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const tb = (await c.query(`select table_schema||'.'||table_name t from information_schema.tables where table_name ~* 'plantilla' order by 1`)).rows;
console.log('tablas:', tb.map(x=>x.t).join(', '));
for (const {t} of tb) {
  const [sch,tab] = t.split('.');
  const cols = (await c.query(`select column_name from information_schema.columns where table_schema=$1 and table_name=$2 order by ordinal_position`,[sch,tab])).rows.map(x=>x.column_name);
  console.log('\n== '+t+': '+cols.join(', '));
  try { console.table((await c.query(`select * from ${t} limit 6`)).rows.map(r => Object.fromEntries(Object.entries(r).map(([k,v])=>[k, typeof v==='string'&&v.length>60? v.slice(0,60)+'…' : (typeof v==='object'&&v? JSON.stringify(v).slice(0,60)+'…' : v)])))); } catch(e){ console.log('  ', e.message.slice(0,60)); }
}
await c.end();
