// Paso 2: registrar documento de Jesús (PER2607251158418560a6) + verificación del match de crédito.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const up = await c.query(`
  update mos.personal
     set documento = '72793090'
   where id_personal = 'PER2607251158418560a6'
     and coalesce(documento,'') = ''            -- guard: no pisar si alguien ya lo llenó
  returning id_personal, nombre, rol, documento`);
console.table(up.rows);
console.log('— verificación: tickets CREDITO que matchean su documento (lo que verá la liquidación):');
console.table((await c.query(`
  select v.id_venta, to_char(v.fecha at time zone 'America/Lima','MM-DD') f, v.total, v.cliente_doc, v.forma_pago
    from me.ventas v
    join mos.personal p on btrim(v.cliente_doc) = btrim(p.documento)
   where p.id_personal = 'PER2607251158418560a6' and upper(v.forma_pago) = 'CREDITO'
   order by v.fecha`)).rows);
console.log('— sanity: ningún OTRO personal comparte ese documento:');
console.table((await c.query(`
  select id_personal, nombre, documento from mos.personal where btrim(coalesce(documento,'')) = '72793090'`)).rows);
await c.end();
