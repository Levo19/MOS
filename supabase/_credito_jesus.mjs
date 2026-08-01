// Paso 1 (read-only): tickets CREDITO de Jesús Guerrero + su ficha en mos.personal.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— tickets CREDITO con nombre parecido a Jesús:');
console.table((await c.query(`
  select id_venta, to_char(fecha at time zone 'America/Lima','MM-DD HH24:MI') f, total,
         cliente_doc, cliente_nombre, tipo_doc_cliente, forma_pago
    from me.ventas
   where upper(forma_pago) = 'CREDITO' and cliente_nombre ilike '%jesus%'
   order by fecha`)).rows);
console.log('— fichas de personal con nombre Jesús:');
console.table((await c.query(`
  select id_personal, nombre, apellido, rol, estado, documento, app_origen
    from mos.personal where nombre ilike '%jesus%' or apellido ilike '%guerrero%'`)).rows);
await c.end();
