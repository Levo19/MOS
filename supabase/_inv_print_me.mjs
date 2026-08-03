import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();

console.log('══ 1. La venta de níspero/palillo ~14.5 en ZONA-02 (hoy)');
const v = (await c.query(`
  select v.id_venta, v.correlativo, v.total, v.forma_pago, v.zona_id, v.vendedor,
         to_char(v.fecha at time zone 'America/Lima','DD/MM HH24:MI:SS') hora,
         to_char(v.created_at at time zone 'America/Lima','HH24:MI:SS') creada,
         to_char(v.updated_at at time zone 'America/Lima','HH24:MI:SS') actualizada,
         v.estado_envio, v.id_caja
    from me.ventas v
   where (v.fecha at time zone 'America/Lima')::date >= (now() at time zone 'America/Lima')::date - 1
     and v.total between 14 and 15
   order by v.fecha desc limit 6`)).rows;
console.table(v);
if (!v.length) { console.log('(no encontrada por monto — busco por producto)'); }

console.log('══ 2. Detalle de esas ventas');
for (const r of v) {
  const d = (await c.query(`select nombre, cantidad, subtotal from me.ventas_detalle where id_venta=$1`, [r.id_venta])).rows;
  console.log(`  ${r.correlativo} (${r.hora}) →`, d.map(x => `${x.cantidad}× ${x.nombre}`).join(' · '));
}

console.log('\n══ 3. Tablas de impresión disponibles');
console.log((await c.query(`select table_schema||'.'||table_name t from information_schema.tables
  where table_name ilike '%print%' or table_name ilike '%impres%' or table_name ilike '%ticket%'`)).rows.map(r=>r.t).join(', '));
await c.end();
