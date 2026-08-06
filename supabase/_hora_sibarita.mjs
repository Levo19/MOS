import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.table((await c.query(`
  select g.id_guia, g.id_zona, to_char(g.fecha at time zone 'America/Lima','HH24:MI:SS') emision_guia,
         gd.cod_producto, gd.cant_recibida,
         to_char(gd.created_at at time zone 'America/Lima','DD/MM HH24:MI:SS') hora_linea_real
    from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
   where (g.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
     and gd.cod_producto = '7753121003261'
   order by g.fecha desc limit 3`)).rows);
await c.end();
