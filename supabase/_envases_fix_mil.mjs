// corrige sufijo de celofanes: ' MLL' → ' MIL' (decisión final del dueño; coincide con SUNAT cat.03)
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = await c.query(`update mos.productos
   set descripcion = regexp_replace(descripcion, ' MLL$', ' MIL'), updated_at = now()
 where es_insumo = true and descripcion like '% MLL' returning descripcion`);
console.log('renombrados a MIL:', r.rowCount);
console.log(r.rows.slice(0, 5).map(x => x.descripcion).join('\n'));
await c.end();
