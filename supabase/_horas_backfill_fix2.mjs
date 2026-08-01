// Fix backfill v2 — comparación 100% en SQL (sin roundtrip JS que trunca microsegundos).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const upd = await c.query(`
  with alter_ts as (
    select created_at ts from wh.guia_detalle group by 1 order by count(*) desc limit 1
  )
  update wh.guia_detalle gd
     set created_at = g.fecha
    from wh.guias g, alter_ts a
   where g.id_guia = gd.id_guia
     and gd.created_at = a.ts`);
console.log('líneas corregidas a la fecha de su guía:', upd.rowCount);
console.table((await c.query(`
  select g.id_guia, g.tipo, g.id_zona,
         to_char(g.fecha at time zone 'America/Lima','HH24:MI') hora_guia,
         to_char(min(gd.created_at) at time zone 'America/Lima','HH24:MI:SS') primera_linea,
         to_char(max(gd.created_at) at time zone 'America/Lima','HH24:MI:SS') ultima_linea
    from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
   where (g.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
   group by g.id_guia, g.tipo, g.id_zona, g.fecha
   order by g.fecha desc limit 6`)).rows);
await c.end();
