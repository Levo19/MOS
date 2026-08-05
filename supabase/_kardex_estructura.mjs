import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── tablas de movimientos/kardex:');
console.table((await c.query(`select table_schema||'.'||table_name t,
   (select count(*) from information_schema.columns cc where cc.table_schema=t2.table_schema and cc.table_name=t2.table_name) cols
   from information_schema.tables t2
  where table_schema in ('wh','me','mos') and table_name ~* 'kardex|movimiento|mov_' order by 1`)).rows);
console.log('\n── columnas de wh.stock:');
console.table((await c.query(`select column_name, data_type from information_schema.columns where table_schema='wh' and table_name='stock' order by ordinal_position`)).rows);
await c.end();
