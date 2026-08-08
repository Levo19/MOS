import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const ID='7e57c1a0-de1c-4a7e-b0de-c47a10906474';
let r = await c.query(`select id_dispositivo, nombre_equipo, app, estado from mos.dispositivos where id_dispositivo=$1`,[ID]);
if (!r.rows.length) {
  await c.query(`insert into mos.dispositivos (id_dispositivo, nombre_equipo, app, estado, ultima_conexion) values ($1,'TEST-CLAUDE MOS (browsercheck)','mos','ACTIVO', now())`,[ID]);
  console.log('creado');
} else {
  await c.query(`update mos.dispositivos set estado='ACTIVO', suspendido_desde=null, forzar_logout=false, forzar_reverify=false, bloqueado_desde=null, pendiente_desde=null, ultima_conexion=now() where id_dispositivo=$1`,[ID]);
  console.log('reactivado');
}
r = await c.query(`select id_dispositivo, nombre_equipo, app, estado from mos.dispositivos where id_dispositivo like '7e57c1a0%'`);
console.dir(r.rows);
await c.end();
