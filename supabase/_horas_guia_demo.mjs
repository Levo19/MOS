// Buscar la mejor guía para VER horas por línea en WH (idealmente con horas DISTINTAS entre líneas).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— guías de HOY con sus rangos de hora por línea:');
console.table((await c.query(`
  select g.id_guia, g.tipo, g.id_zona, g.usuario, g.estado,
         count(gd.linea) lineas,
         to_char(min(gd.created_at) at time zone 'America/Lima','HH24:MI:SS') primera_linea,
         to_char(max(gd.created_at) at time zone 'America/Lima','HH24:MI:SS') ultima_linea,
         count(distinct to_char(gd.created_at at time zone 'America/Lima','HH24:MI')) horas_distintas
    from wh.guias g
    join wh.guia_detalle gd on gd.id_guia = g.id_guia
   where (g.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
   group by g.id_guia, g.tipo, g.id_zona, g.usuario, g.estado
   order by max(gd.created_at) desc limit 8`)).rows);
await c.end();
