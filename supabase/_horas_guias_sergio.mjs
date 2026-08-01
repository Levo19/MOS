import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.table((await c.query(`
  select g.id_guia, g.tipo, g.id_zona, g.estado, g.usuario,
         to_char(g.fecha at time zone 'America/Lima','HH24:MI') hora_guia,
         gd.cod_producto, gd.cant_recibida,
         to_char(gd.created_at at time zone 'America/Lima','HH24:MI:SS') hora_linea
    from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
   where g.id_guia in ('G_L17855990159799s04s8f','G_L1785598803240fzmcuz7')
   order by g.fecha`)).rows);
await c.end();
