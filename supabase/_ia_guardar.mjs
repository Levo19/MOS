// _ia_guardar.mjs <codigo_barra> <archivo.txt> [marca]
// Guarda descripcion_ia de UN canónico (y la marca SOLO si el campo estaba vacío).
// session_replication_role=replica → no dispara el bump de catálogo (las cajas no
// re-descargan el catálogo por cada descripción guardada).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const [, , codigo, archivo, marca] = process.argv;
if (!codigo || !archivo) { console.error('uso: node _ia_guardar.mjs <codigo_barra> <archivo.txt> [marca]'); process.exit(1); }
const texto = fs.readFileSync(archivo, 'utf8').trim();
if (texto.length < 60 || !texto.includes('🏷') || !texto.includes('✅')) {
  console.error('RECHAZADO: el texto no tiene el formato de 6 líneas (🏷…✅)'); process.exit(1);
}
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
try { await c.query(`set session_replication_role = replica`); } catch (_) { /* sin permiso → acepta el bump */ }
const r = await c.query(
  `update mos.productos
      set descripcion_ia = $2,
          marca = case when nullif(btrim(coalesce(marca,'')),'') is null and nullif(btrim($3),'') is not null
                       then btrim($3) else marca end
    where codigo_barra = $1 and tipo_producto::text = 'CANONICO'`,
  [codigo, texto, marca || '']);
console.log('OK', r.rowCount);
await c.end();
process.exit(r.rowCount === 1 ? 0 : 2);
