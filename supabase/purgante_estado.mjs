// PURGANTE · AVANCE — quién ya se purgó y quién falta.
//   node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/purgante_estado.mjs"
//   node "C:/Users/ISO/ecosistema MOS/ProyectoMOS/supabase/purgante_estado.mjs" --dias 7
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;

const i = process.argv.indexOf('--dias');
const dias = i > -1 ? Number(process.argv[i + 1]) || 30 : 30;

const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
const E = (await c.query(`select mos.purgante_estado($1::jsonb) r`, [JSON.stringify({ dias })])).rows[0].r;

console.log(`\n🧹 PURGANTE · token ${E.token}  ${E.armado ? 'ARMADO' : 'DORMIDO (nadie hará nada)'}`);
console.log(`   ${E.purgados}/${E.total} purgados · ${E.pendientes} pendientes  (equipos ACTIVOS vistos en ${dias} días)\n`);

for (const x of (E.detalle || [])) {
  const cuando = x.purgado_at ? new Date(x.purgado_at).toISOString().slice(0, 16).replace('T', ' ') : '';
  console.log(`   ${x.purgado ? '✔' : '·'} ${String(x.app).padEnd(11)} ${String(x.device).slice(0, 8)}  ` +
    `${String(x.nombre || '(sin nombre)').padEnd(34).slice(0, 34)} ` +
    `${x.purgado ? cuando + (x.version_antes ? '  desde v' + x.version_antes : '') : 'PENDIENTE'}`);
}
await c.end();
