// Backfill de ultima_sesion para equipos MOS sin dueño registrado: el último
// nombre que AUTORIZÓ algo desde ese device (mos.auditoria_admin).
import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
try { await c.query(`set session_replication_role = replica`); } catch(_){}
const r = await c.query(`
  update mos.dispositivos d
     set ultima_sesion = q.quien
    from (select distinct on (device_id) device_id, nombre_autoriza quien
            from mos.auditoria_admin
           where nullif(btrim(device_id),'') is not null and nullif(btrim(nombre_autoriza),'') is not null
           order by device_id, fecha desc) q
   where q.device_id = d.id_dispositivo
     and nullif(btrim(d.ultima_sesion),'') is null
  returning d.nombre_equipo, d.ultima_sesion`);
console.table(r.rows);
console.log('backfilleados:', r.rowCount);
const chk = (await c.query(`select app, count(*) n, count(*) filter (where nullif(btrim(ultima_sesion),'') is not null) con
  from mos.dispositivos where upper(estado)='ACTIVO' group by 1`)).rows;
console.table(chk);
await c.end();
