import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const d = (await c.query(`select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='mos' and p.proname='_venta_canonico' limit 1`)).rows[0].d;
console.log(d);
// prueba directa: ¿cómo convierte la presentación x25 del granel?
console.log('── prueba con P-NKMGLT-X25 (presentación factor 25 del granel KGM), 1 unidad:');
console.table((await c.query(`select * from mos._venta_canonico('P-NKMGLT-X25', 1, 'NIU')`)).rows);
console.log('── y una fracción de granel legacy (250g de maní o similar), 1 unidad:');
console.table((await c.query(`select * from mos._venta_canonico('P-ACHENT-D10', 1, 'NIU')`)).rows);
await c.end();
