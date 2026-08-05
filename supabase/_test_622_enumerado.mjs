// Verifica el cierre del enumerado CON el claim real de la app (como llega desde MOS).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const c = new Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim(), ssl: { rejectUnauthorized: false } });
await c.connect();
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

const v = (await c.query(`select id_venta, correlativo from me.ventas
  where coalesce(nf_enlace,'') <> '' and coalesce(correlativo,'') <> '' limit 1`)).rows[0];
console.log('ticket de prueba:', v.correlativo);

await c.query('begin');
try {
  await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ app: 'MOS', role: 'authenticated' })]);

  // "funcionó" = devolvió los datos del comprobante (la RPC no usa envoltorio {ok})
  const dio = (r) => !!(r && (r.pdf || r.enlace || r.correlativo) && r.error == null);

  const normal = (await c.query(`select mos.me_cpe_pdf_por_venta($1::jsonb) r`,
    [JSON.stringify({ id_venta: v.id_venta, correlativo: v.correlativo })])).rows[0].r;
  t('el uso normal (con id_venta) SIGUE funcionando', dio(normal), JSON.stringify(normal).slice(0, 90));
  t('y devuelve el comprobante correcto', String(normal.correlativo || v.correlativo) === v.correlativo);

  const ataque = (await c.query(`select mos.me_cpe_pdf_por_venta($1::jsonb) r`,
    [JSON.stringify({ correlativo: v.correlativo })])).rows[0].r;
  t('el ATAQUE (solo correlativo) es rechazado', !dio(ataque), JSON.stringify(ataque).slice(0, 90));
  t('y el error dice qué falta', /id_venta/i.test(String(ataque.error || '')), ataque.error);

  // enumerar la serie completa no devuelve nada
  let filtrados = 0;
  for (const n of ['FM02-000001', 'FM02-000002', 'BM02-000001', 'BBB1-000039']) {
    const r = (await c.query(`select mos.me_cpe_pdf_por_venta($1::jsonb) r`, [JSON.stringify({ correlativo: n })])).rows[0].r;
    if (!dio(r)) filtrados++;
  }
  t('recorrer la serie ya no devuelve comprobantes (4/4 bloqueados)', filtrados === 4, filtrados + '/4');
} finally { await c.query('rollback'); }

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
await c.end();
process.exit(fail === 0 ? 0 : 1);
