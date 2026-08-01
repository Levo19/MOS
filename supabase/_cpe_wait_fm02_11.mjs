// Espera hasta que FM02-11 cambie de estado (o 90s) y muestra el resultado.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = () => c.query(`select correlativo, nf_estado, nf_aceptada_sunat, nf_sunat_code,
  left(coalesce(nf_sunat_desc,''),70) descr,
  to_char(nf_ultima_consulta at time zone 'America/Lima','MM-DD HH24:MI:SS') ult
  from me.ventas where correlativo='FM02-000011'`);
for (let i = 0; i < 18; i++) {
  const r = await q();
  const row = r.rows[0];
  if (row.nf_estado !== 'RECHAZADO' || i === 17) { console.table(r.rows); break; }
  await new Promise(s => setTimeout(s, 5000));
}
await c.end();
