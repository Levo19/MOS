import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = await c.query(`select id_producto, sku_base, descripcion, envase_sku, es_insumo
  from mos.productos
 where sku_base in ('LEV192','LEV1499','LEV1022') or codigo_barra = 'WHACXOVO250GR'
 order by descripcion`);
console.table(r.rows);
await c.end();
