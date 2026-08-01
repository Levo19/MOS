import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.table((await c.query(`
  select id_producto_nuevo, descripcion, usuario, estado, aprobado_por,
         to_char(fecha_registro   at time zone 'America/Lima','MM-DD HH24:MI') registrado,
         to_char(fecha_aprobacion at time zone 'America/Lima','MM-DD HH24:MI') aprobado,
         coalesce(foto,'') <> '' con_foto, id_guia
    from wh.producto_nuevo
   where descripcion ilike '%nescafe%'
   order by fecha_registro desc`)).rows);
// ¿hay fotos huérfanas de HOY en el bucket wh-fotos/producto_nuevo? (objetos subidos sin PN linkeado)
console.table((await c.query(`
  select name, to_char(created_at at time zone 'America/Lima','MM-DD HH24:MI') subida
    from storage.objects
   where bucket_id = 'wh-fotos' and name like 'producto_nuevo/%'
     and created_at > now() - interval '8 hours'
   order by created_at desc limit 10`)).rows);
await c.end();
