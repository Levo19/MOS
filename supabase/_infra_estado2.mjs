import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
console.log('── estados × app × última zona:');
console.table((await c.query(`select estado, app, coalesce(ultima_zona,'—') zona, count(*) n,
  min(ultima_conexion)::date viejo, max(ultima_conexion)::date nuevo
  from mos.dispositivos group by 1,2,3 order by 4 desc limit 20`)).rows);
console.log('── suspendidos: ¿hace cuánto?');
console.table((await c.query(`select estado, count(*) n,
  round(avg(extract(epoch from (now()-coalesce(suspendido_desde, ultima_conexion)))/86400)::numeric,1) dias_prom,
  max(round(extract(epoch from (now()-coalesce(suspendido_desde, ultima_conexion)))/86400)::numeric) dias_max
  from mos.dispositivos where upper(coalesce(estado,'')) ~ 'SUSP' group by 1`)).rows);
console.log('── tablas solicitudes:');
console.log((await c.query(`select table_name from information_schema.tables where table_schema='mos' and table_name ~* 'solicitud|extension|permiso'`)).rows.map(x=>x.table_name).join(', ') || '(ninguna)');
console.log('── RPCs:');
console.log((await c.query(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname ~* 'solicitud|extension' order by 1`)).rows.map(x=>x.proname).join(' · ') || '(ninguna)');
await c.end();
