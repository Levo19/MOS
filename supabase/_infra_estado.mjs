import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── mos.dispositivos columnas:');
console.log((await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='dispositivos' order by ordinal_position`)).rows.map(x=>x.column_name).join(', '));
console.log('\n── estados y apps actuales:');
console.table((await c.query(`select estado, app_origen, count(*) n,
  min(date_trunc('day', ultima_actividad))::date mas_viejo
  from mos.dispositivos group by 1,2 order by 3 desc limit 15`)).rows);
console.log('\n── tablas de solicitudes:');
console.log((await c.query(`select table_name from information_schema.tables where table_schema='mos' and table_name ~* 'solicitud|extension|permiso'`)).rows.map(x=>x.table_name).join(', '));
console.log('\n── RPCs de solicitudes/dispositivos:');
console.log((await c.query(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname ~* 'solicitud|dispositivo|extension' order by 1`)).rows.map(x=>x.proname).join(' · '));
await c.end();
