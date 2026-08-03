// Regresión 613 — "el ajuste fija lo que cuentas". Todo en tx + ROLLBACK.
// Casos reales de Luis: achiote 24.9→25, arándano -0.21→0, pasa rubia -0.1→0,
// + concurrencia (envasado intercalado) + idempotencia + vía legacy.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };
const stock = async cod => parseFloat((await c.query(`select cantidad_disponible v from wh.stock where cod_producto=$1`, [cod])).rows[0].v);

await c.query('begin');
try {
  console.log('── 1. Casos reales (SET absoluto, vía WH nueva)');
  for (const [cod, conteo, nombre] of [['WHACXOVO', 25, 'achiote 24.9→25'],
                                       ['WHAREADO', 0, 'arándano -0.21→0'],
                                       ['WHPAARDA', 0, 'pasa rubia -0.1→0']]) {
    const r = (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify({
      id_ajuste: 'T613_' + cod, codigo_producto: cod, conteo, motivo: 'test', usuario: 'TEST',
      id_mov: 'T613MOV_' + cod })])).rows[0].r;
    const s = await stock(cod);
    t(`${nombre} → queda EXACTAMENTE ${conteo}`, r.ok === true && s === conteo, `dio ${s} · ${JSON.stringify(r)}`);
  }

  console.log('── 2. Decimal fino (insumo por millar): 0.001 NO se pierde');
  await c.query(`insert into wh.stock (id_stock,cod_producto,cantidad_disponible,ultima_actualizacion)
    values ('T613STK','T613COD',5,now())`);
  const r2 = (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify({
    id_ajuste: 'T613_mil', codigo_producto: 'T613COD', conteo: 0.001, motivo: 'test', usuario: 'TEST', id_mov: 'T613MOV_mil' })])).rows[0].r;
  t('conteo 0.001 se guarda como 0.001 (no 0.00)', r2.ok === true && (await stock('T613COD')) === 0.001, `dio ${await stock('T613COD')}`);

  console.log('── 3. Concurrencia: envasado intercalado NO altera lo contado');
  await c.query(`update wh.stock set cantidad_disponible=10 where cod_producto='T613COD'`);
  // simula consumo por envasado ANTES de que el ajuste commitee
  await c.query(`update wh.stock set cantidad_disponible=cantidad_disponible-3 where cod_producto='T613COD'`);
  const r3 = (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify({
    id_ajuste: 'T613_conc', codigo_producto: 'T613COD', conteo: 50, motivo: 'test', usuario: 'TEST', id_mov: 'T613MOV_conc' })])).rows[0].r;
  t('conté 50 → queda 50 (no 50±consumo)', (await stock('T613COD')) === 50, `dio ${await stock('T613COD')}`);
  t('el kardex registra el delta real (50−7=43)', Math.abs(parseFloat(r3.delta) - 43) < 0.001, `delta ${r3.delta}`);

  console.log('── 4. Idempotencia (doble tap / reintento)');
  const r4 = (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify({
    id_ajuste: 'T613_conc', codigo_producto: 'T613COD', conteo: 999, motivo: 'test', usuario: 'TEST', id_mov: 'T613MOV_conc' })])).rows[0].r;
  t('reintento del mismo gesto NO re-toca el stock', r4.dedup === true && (await stock('T613COD')) === 50);

  console.log('── 5. Contar lo mismo que ya hay → no-op limpio');
  const r5 = (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify({
    id_ajuste: 'T613_noop', codigo_producto: 'T613COD', conteo: 50, motivo: 'test', usuario: 'TEST', id_mov: 'T613MOV_noop' })])).rows[0].r;
  t('conteo == stock → noop sin fila basura', r5.ok === true && r5.noop === true);

  console.log('── 6. Vía LEGACY (cola offline vieja: tipo+cantidad) sigue viva y redondea');
  const r6 = (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify({
    id_ajuste: 'T613_leg', codigo_producto: 'T613COD', tipo: 'DEC', cantidad: 5, motivo: 'test', usuario: 'TEST', id_mov: 'T613MOV_leg' })])).rows[0].r;
  t('legacy INC/DEC sigue funcionando (50−5=45)', r6.ok === true && (await stock('T613COD')) === 45, `dio ${await stock('T613COD')}`);

  console.log('── 7. Guardas');
  const r7 = (await c.query(`select wh.crear_ajuste($1::jsonb) r`, [JSON.stringify({
    id_ajuste: 'T613_neg', codigo_producto: 'T613COD', conteo: -5, usuario: 'TEST' })])).rows[0].r;
  t('conteo negativo se rechaza', r7.ok === false && r7.error === 'CONTEO_NEGATIVO');

  console.log('── 8. Vía MOS/RIZ (set absoluto + redondeo)');
  await c.query(`update wh.stock set cantidad_disponible=-0.21000000000000004 where cod_producto='T613COD'`);
  const r8 = (await c.query(`select mos.almacen_crear_ajuste($1::jsonb) r`, [JSON.stringify({
    codProducto: 'T613COD', conteo: 0, idAjuste: 'T613_mos', usuario: 'TEST', zona: 'ALMACEN' })])).rows[0].r;
  t('MOS: -0.21000000000000004 → 0 exacto', r8.ok === true && (await stock('T613COD')) === 0, `dio ${await stock('T613COD')}`);
} finally {
  await c.query('rollback');
  console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron (rollback: nada persistió)`);
  await c.end();
}
process.exit(fail === 0 ? 0 : 1);
