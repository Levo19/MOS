import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const r = (await c.query(`select id_plantilla, nombre, descripcion, tamano_canvas, json, activo
  from mos.adhesivo_plantillas where nombre ilike '%nispero%' or nombre ilike '%níspero%' or nombre ilike '%papito%'`)).rows;
for (const x of r) { console.log('==', x.id_plantilla, '·', x.nombre, '·', x.tamano_canvas, '· activo:', x.activo);
  console.log(JSON.stringify(x.json, null, 1).slice(0, 2500)); }
await c.end();
