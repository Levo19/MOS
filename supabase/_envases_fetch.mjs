// _envases_fetch.mjs — trae celofanes + derivados del catálogo vivo para el match de envases.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();

const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();

const cols = await c.query(`select column_name from information_schema.columns where table_schema='mos' and table_name='productos' order by ordinal_position`);
console.log('COLS:', cols.rows.map(r => r.column_name).join(', '));

const celo = await c.query(`select codigo_barra, sku_base, descripcion, codigo_producto_base, factor_conversion, estado, stock_minimo
  from mos.productos where descripcion ilike '%celofan%' order by descripcion`);
console.log('CELOFANES (' + celo.rows.length + '):');
console.log(JSON.stringify(celo.rows, null, 1));

const der = await c.query(`select codigo_barra, sku_base, descripcion, codigo_producto_base, factor_conversion, estado, stock_minimo
  from mos.productos where coalesce(codigo_producto_base,'') <> '' order by descripcion`);
console.log('DERIVADOS (' + der.rows.length + '):');
fs.writeFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/_envases_derivados.json', JSON.stringify({ celofanes: celo.rows, derivados: der.rows }, null, 1));
console.log('guardado _envases_derivados.json');
console.log(JSON.stringify(der.rows.slice(0, 8), null, 1));

await c.end();
