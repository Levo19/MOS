import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.table((await c.query(`select codigo_barra, descripcion, precio_venta, precio_costo, modo_venta, margen_pct
  from mos.productos where codigo_barra in ('77530967','7753749002059','7753749002295')`)).rows);
await c.end();
