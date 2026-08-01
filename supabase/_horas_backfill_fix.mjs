// Fix backfill 607: ALTER..DEFAULT now() estampó TODAS las filas viejas con la hora del deploy
// (no quedaron NULL) → el backfill original no matcheó nada. Detectar ese timestamp único
// (compartido por miles de filas) y reemplazarlo por la fecha de la guía de cada línea.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const top = (await c.query(`
  select created_at, count(*) n from wh.guia_detalle group by 1 order by n desc limit 3`)).rows;
console.table(top.map(r => ({ ts: r.created_at?.toISOString?.() || String(r.created_at), n: r.n })));
const alterTs = top[0];
if (Number(alterTs.n) < 100) { console.log('ABORT: el timestamp más común tiene pocas filas — no parece el del ALTER'); process.exit(1); }
const upd = await c.query(`
  update wh.guia_detalle gd
     set created_at = g.fecha
    from wh.guias g
   where g.id_guia = gd.id_guia
     and gd.created_at = $1`, [alterTs.created_at]);
console.log('líneas corregidas a la fecha de su guía:', upd.rowCount);
console.log('— re-verificación guías de hoy:');
console.table((await c.query(`
  select g.id_guia, g.tipo, g.id_zona,
         to_char(g.fecha at time zone 'America/Lima','HH24:MI') hora_guia,
         to_char(min(gd.created_at) at time zone 'America/Lima','HH24:MI:SS') primera_linea,
         to_char(max(gd.created_at) at time zone 'America/Lima','HH24:MI:SS') ultima_linea
    from wh.guias g join wh.guia_detalle gd on gd.id_guia = g.id_guia
   where (g.fecha at time zone 'America/Lima')::date = (now() at time zone 'America/Lima')::date
   group by g.id_guia, g.tipo, g.id_zona, g.fecha
   order by g.fecha desc limit 8`)).rows);
await c.end();
