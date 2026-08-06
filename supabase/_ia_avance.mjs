import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const r = (await c.query(`select count(*) filter (where descripcion_ia is not null) hechos, count(*) total
  from mos.productos where tipo_producto::text='CANONICO' and coalesce(estado,true)`)).rows[0];
console.log(`descripcion_ia: ${r.hechos} de ${r.total} canónicos`);
await c.end();
