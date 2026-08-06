// _ia_repesca_check.mjs <rep_XX.json> — imprime los del lote que AÚN tienen la marca
// "sin ficha web específica" (pendientes de repesca).
import fs from 'fs'; import pkg from 'pg'; const { Client } = pkg;
const lote = process.argv[2];
const items = JSON.parse(fs.readFileSync(lote, 'utf8'));
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim(), ssl:{rejectUnauthorized:false} });
await c.connect();
const cods = items.map(x => x.codigo_barra);
const aun = new Set((await c.query(`select codigo_barra from mos.productos
  where codigo_barra = any($1) and descripcion_ia like '%sin ficha web específica%'`, [cods])).rows.map(r => r.codigo_barra));
const pend = items.filter(x => aun.has(x.codigo_barra));
console.log(JSON.stringify(pend, null, 1));
console.error(`pendientes de repesca: ${pend.length} de ${items.length}`);
await c.end();
