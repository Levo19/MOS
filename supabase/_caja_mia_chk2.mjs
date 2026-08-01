// Forense 2: la caja de Mia (zona02, 31/07), sus ventas, y los pickups de zona02.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— cajas de ZONA-02 últimas 48h:');
console.table((await c.query(`
  select id_caja, vendedor, estado, monto_inicial, monto_final,
         to_char(fecha_apertura at time zone 'America/Lima','MM-DD HH24:MI') abre,
         to_char(fecha_cierre   at time zone 'America/Lima','MM-DD HH24:MI') cierra
    from me.cajas
   where upper(coalesce(zona_id,'')) like '%02%' and fecha_apertura > now() - interval '48 hours'
   order by fecha_apertura desc`)).rows);
console.log('— cola me.pickups_pendientes_envio (si hay atorados):');
console.table((await c.query(`select * from me.pickups_pendientes_envio limit 8`)).rows);
console.log('— wh.pickups de zona02 últimos 3 días:');
const pkcols = await c.query(`select column_name from information_schema.columns
  where table_schema='wh' and table_name='pickups' order by ordinal_position`);
console.log('cols wh.pickups:', pkcols.rows.map(r => r.column_name).join(', '));
console.table((await c.query(`
  select id_pickup, id_zona, fuente, estado, creado_por,
         to_char(fecha_creado at time zone 'America/Lima','MM-DD HH24:MI') creado,
         jsonb_array_length(coalesce(items,'[]'::jsonb)) n_items
    from wh.pickups
   where upper(coalesce(id_zona,'')) like '%02%' and fecha_creado > now() - interval '4 days'
   order by fecha_creado desc limit 15`)).rows);
console.log('— ventas zona02 de AYER (conteo/total, no anuladas):');
console.table((await c.query(`
  select count(*) n, sum(total) total,
         to_char(min(fecha) at time zone 'America/Lima','HH24:MI') primera,
         to_char(max(fecha) at time zone 'America/Lima','HH24:MI') ultima
    from me.ventas
   where upper(coalesce(zona_id,'')) like '%02%'
     and (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date - 1
     and upper(coalesce(forma_pago,'')) not like 'ANULADO%'`)).rows);
console.log('— ACUMULADORES de zona02 (todos los estados, sin filtro de fecha):');
console.table((await c.query(`
  select id_pickup, fuente, estado, creado_por,
         to_char(fecha_creado at time zone 'America/Lima','MM-DD HH24:MI') creado,
         to_char(fecha_atendido at time zone 'America/Lima','MM-DD HH24:MI') atendido, atendido_por,
         jsonb_array_length(coalesce(items,'[]'::jsonb)) n_items
    from wh.pickups
   where upper(coalesce(id_zona,'')) like '%02%' and fuente not in ('ME_CIERRE_CAJA','RIZ')
   order by fecha_creado desc limit 8`)).rows);
console.log('— pickups VIVOS (no absorbidos/cerrados) por zona — lo que WH debería listar:');
console.table((await c.query(`
  select id_zona, fuente, estado, id_pickup,
         to_char(fecha_creado at time zone 'America/Lima','MM-DD HH24:MI') creado,
         jsonb_array_length(coalesce(items,'[]'::jsonb)) n_items
    from wh.pickups
   where upper(coalesce(estado,'')) not in ('ABSORBIDO','CERRADO','ATENDIDO','DESPACHADO','ANULADO')
   order by id_zona, fecha_creado desc limit 15`)).rows);
await c.end();
