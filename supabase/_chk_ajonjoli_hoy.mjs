import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('── stock del granel de ajonjolí HOY (¿repusieron?)');
console.table((await c.query(`select cod_producto, cantidad_disponible,
   to_char(ultima_actualizacion at time zone 'America/Lima','DD/MM HH24:MI') act
  from wh.stock where cod_producto='WHAJARUM'`)).rows);
console.log('── movimientos desde el 03/08');
console.table((await c.query(`select to_char(fecha at time zone 'America/Lima','DD/MM HH24:MI') f,
   delta, stock_antes, stock_despues, tipo_operacion, usuario
  from wh.stock_movimientos where cod_producto='WHAJARUM'
   and fecha > now() - interval '3 days' order by fecha desc limit 6`)).rows);
await c.end();
