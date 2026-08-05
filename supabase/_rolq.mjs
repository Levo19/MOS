import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.table((await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='personal' and column_name ~* 'rol|nivel|id_personal|nombre'`)).rows);
console.table((await c.query(`select distinct rol from mos.personal limit 10`)).rows.slice(0,10));
await c.end();
