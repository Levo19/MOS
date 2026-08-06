// _ia_check.mjs <lote_XX.json> — imprime SOLO los códigos del lote que siguen pendientes
// (para que un agente relanzado no repita los ya guardados).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const lote = process.argv[2];
if (!lote) { console.error('uso: node _ia_check.mjs <ruta lote.json>'); process.exit(1); }
const items = JSON.parse(fs.readFileSync(lote, 'utf8'));
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const cods = items.map(x => x.codigo_barra);
const hechos = new Set((await c.query(
  `select codigo_barra from mos.productos where codigo_barra = any($1) and descripcion_ia is not null`, [cods]
)).rows.map(r => r.codigo_barra));
const pend = items.filter(x => !hechos.has(x.codigo_barra));
console.log(JSON.stringify(pend, null, 1));
console.error(`pendientes: ${pend.length} de ${items.length}`);
await c.end();
