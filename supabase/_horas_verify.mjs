// Verificación 607 con datos reales (read-only): historial con hora + despachos + created_at en guías.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = (await c.query(`select wh.zona_pickup_detalle(jsonb_build_object('zona','ZONA-02')) r`)).rows[0].r;
console.log('ok:', r.ok, '· items:', r.total_items, '· pendiente:', r.total_pendiente);
const conHist = (r.items || []).find(i => (i.historial || []).length >= 2) || (r.items || [])[0];
console.log('— ejemplo:', conHist?.nombre);
console.table((conHist?.historial || []).slice(0, 6));
const tiposEnHist = new Set((r.items || []).flatMap(i => (i.historial || []).map(h => h.tipo)));
console.log('tipos de evento presentes:', [...tiposEnHist].join(' · '));
const conHora = (r.items || []).some(i => (i.historial || []).some(h => String(h.fecha).includes('T')));
console.log('¿historial con HORA?:', conHora);
console.log('— guia_detalle.created_at (última guía GPCK de hoy, primeras 3 líneas):');
console.table((await c.query(`
  select gd.linea, left(gd.cod_producto,14) cod, gd.cant_recibida,
         to_char(gd.created_at at time zone 'America/Lima','HH24:MI:SS') hora
    from wh.guia_detalle gd
   where gd.id_guia = (select id_guia from wh.guias where tipo='SALIDA_ZONA' and fecha::date=current_date order by fecha desc limit 1)
   order by gd.linea limit 3`)).rows);
await c.end();
