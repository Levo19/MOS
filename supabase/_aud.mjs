import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const cols=(await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='auditoria_admin'`)).rows.map(x=>x.column_name);
console.log('auditoria_admin cols:', cols.join(', '));
await c.end();
