// Smoke 604 en TX + ROLLBACK: aviso 20h, anulación 24h sin escaneos, auto-cierre con escaneos.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (sql, args) => (await c.query(sql, args)).rows;
let fallos = 0;
const ok = (n, cond, x) => { console.log((cond ? '✓' : '✗ FALLO'), n, x ?? ''); if (!cond) fallos++; };
await c.query('begin');
try {
  // fabricar 3 listas: A=25h con escaneos (auto-cierre) · B=25h sin escaneos (anular) · C=21h sin escaneos (aviso)
  const itemsA = JSON.stringify([
    { skuBase: 'LEV192', nombre: 'ACHIOTE GRANEL', cantidad: 5, cantidadEscaneada: 3 },
    { skuBase: 'LEV149', nombre: 'AJONJOLI BLANCO', cantidad: 10, cantidadEscaneada: 0 }
  ]);
  const itemsB = JSON.stringify([{ skuBase: 'LEV192', nombre: 'ACHIOTE', cantidad: 4, cantidadEscaneada: 0 }]);
  await c.query(`insert into wh.listas_sombra (id_lista, fecha_creacion, usuario_creador, items, estado, zona)
    values ('LSTEST604A', now() - interval '25 hours', 'PRUEBA CLAUDE', $1::jsonb, 'DISPONIBLE', 'ZONA-01'),
           ('LSTEST604B', now() - interval '25 hours', 'PRUEBA CLAUDE', $2::jsonb, 'DISPONIBLE', 'ZONA-01'),
           ('LSTEST604C', now() - interval '21 hours', 'PRUEBA CLAUDE', $2::jsonb, 'DISPONIBLE', 'ZONA-01')`,
    [itemsA, itemsB]);

  const r1 = (await q(`select wh.vencer_listas_sombra() r`))[0].r;
  console.log('cron →', JSON.stringify(r1));
  ok('B anulada + C avisada + A auto-cerrada contadas', r1.autoCerradas >= 1 && r1.avisadas >= 1 && r1.vencidasDisponibles >= 1, '');

  const a = (await q(`select estado, nota from wh.listas_sombra where id_lista='LSTEST604A'`))[0];
  ok('A → COMPLETADA con nota 604', a.estado === 'COMPLETADA' && /604: auto-cierre/.test(a.nota), a.nota?.slice(-70));
  const guiaA = await q(`select id_guia, (select count(*) from wh.guia_detalle gd where gd.id_guia=g.id_guia) lineas
    from wh.guias g where id_guia='GLSC_LSTEST604A'`);
  ok('A → guía GLSC creada con 1 línea (solo lo escaneado)', guiaA.length === 1 && Number(guiaA[0].lineas) === 1, JSON.stringify(guiaA));
  const pickA = await q(`select estado, jsonb_array_length(items) n from wh.pickups where id_pickup='PCK-LSC-LSTEST604A'`);
  ok('A → pickup PCK-LSC (sol/desp al acumulado)', pickA.length === 1, JSON.stringify(pickA));
  const b = (await q(`select estado, nota from wh.listas_sombra where id_lista='LSTEST604B'`))[0];
  ok('B → ANULADA sin acumular', b.estado === 'ANULADA' && /vencida/.test(b.nota), '');
  const pickB = await q(`select 1 from wh.pickups where id_pickup='PCK-LSC-LSTEST604B'`);
  ok('B → sin pickup', pickB.length === 0);
  const cRow = (await q(`select estado, nota from wh.listas_sombra where id_lista='LSTEST604C'`))[0];
  ok('C → sigue DISPONIBLE con [aviso-ttl]', cRow.estado === 'DISPONIBLE' && /\[aviso-ttl\]/.test(cRow.nota), '');

  // idempotencia: 2ª corrida no re-avisa ni re-cierra
  const r2 = (await q(`select wh.vencer_listas_sombra() r`))[0].r;
  ok('2ª corrida: 0 avisos y 0 auto-cierres nuevos', r2.avisadas === 0 && r2.autoCerradas === 0, JSON.stringify(r2));
} finally {
  await c.query('rollback');
  console.log('ROLLBACK OK — nada persistió · FALLOS:', fallos);
}
const resid = await q(`select count(*) n from wh.listas_sombra where id_lista like 'LSTEST604%'`);
console.log('residuos:', resid[0].n);
await c.end();
process.exit(fallos ? 1 : 0);
