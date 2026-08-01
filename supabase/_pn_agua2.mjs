// ¿Las 2 aguas aprobadas existen en el catálogo (productos o equivalencias)?
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
console.log('— mos.productos con esos códigos o descripcion agua:');
console.table((await c.query(`
  select id_producto, sku_base, codigo_barra, descripcion, estado,
         to_char(fecha_creacion at time zone 'America/Lima','MM-DD HH24:MI') creado, creado_por
    from mos.productos
   where codigo_barra in ('77530967','7753749002059') or descripcion ilike '%agua%'
   order by fecha_creacion desc nulls last limit 10`)).rows);
console.log('— mos.equivalencias con esos códigos:');
console.table((await c.query(`
  select id_equiv, sku_base, codigo_barra, descripcion, activo
    from mos.equivalencias where codigo_barra in ('77530967','7753749002059')`)).rows);
await c.end();
