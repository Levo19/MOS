import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = await c.query(`
  select id_guia, tipo, id_zona, id_proveedor, estado, usuario, comentario, numero_documento,
         to_char(fecha at time zone 'America/Lima','YYYY-MM-DD HH24:MI:SS') hora_lima
    from wh.guias
   where (fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
   order by fecha desc limit 5`);
console.table(r.rows);
await c.end();
