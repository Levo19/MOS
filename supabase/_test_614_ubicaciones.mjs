// Verifica 614 contra los números que ya validamos a mano con el AJONJOLI.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

const r = (await c.query(`select mos.prov_stock_ubicaciones($1::jsonb) j`,
  [JSON.stringify({ idProveedor: 'PROV070' })])).rows[0].j;
t('RPC responde ok', r.ok === true);
console.log('  ventana:', JSON.stringify(r.ventana));
const prods = r.data.productos || [];
console.log('  productos con ubicaciones:', prods.length);

const aj = prods.find(x => x.codigoBarra === 'WHAJARUM');
t('viene el AJONJOLI', !!aj);
if (aj) {
  const alm = aj.ubicaciones.find(u => u.tipo === 'ALMACEN');
  console.log('\n── ALMACÉN:', JSON.stringify({ totalEq: alm.totalEq, demandaEqSem: alm.demandaEqSem,
    cubreSem: alm.cubreSem, faltaEq: alm.faltaEq, nPres: alm.nPresentaciones }));
  t('almacén totalEq = 66.55 (lo verificado a mano)', Math.abs(alm.totalEq - 66.55) < 0.01, alm.totalEq);
  t('almacén demanda = 27.24 kg/sem', Math.abs(alm.demandaEqSem - 27.24) < 0.05, alm.demandaEqSem);
  t('almacén cubre 2.4 sem', Math.abs(alm.cubreSem - 2.4) < 0.15, alm.cubreSem);
  t('almacén falta ≈ 2.95 kg', Math.abs(alm.faltaEq - 2.95) < 0.1, alm.faltaEq);
  console.log('  líneas almacén:');
  for (const l of alm.lineas) console.log('   ', JSON.stringify(l));
  const l250 = alm.lineas.find(l => /250GR/.test(l.cod));
  t('250GR cubre 0.9 sem (el que se esconde en el agregado)', l250 && Math.abs(l250.cubreSem - 0.9) < 0.1, l250 && l250.cubreSem);
  t('250GR falta ~3.8 und', l250 && Math.abs(l250.faltaUnd - 3.75) < 0.5, l250 && l250.faltaUnd);
  const lgranel = alm.lineas.find(l => l.esPadre);
  t('el padre (granel) aparece aunque tenga 0', !!lgranel);

  const z2 = aj.ubicaciones.find(u => u.id === 'ZONA-02');
  if (z2) {
    console.log('\n── ZONA-02:', JSON.stringify({ totalEq: z2.totalEq, demandaEqSem: z2.demandaEqSem,
      cubreSem: z2.cubreSem, faltaEq: z2.faltaEq, nNeg: z2.nNegativos }));
    for (const l of z2.lineas) console.log('   ', JSON.stringify(l));
    const l500 = z2.lineas.find(l => /500GR/.test(l.cod));
    t('zona02: 500GR en negativo detectado', z2.nNegativos >= 1);
    t('zona02: 500GR falta 4 und (2 del hueco + 2 de la semana)', l500 && Math.abs(l500.faltaUnd - 4) < 0.2, l500 && l500.faltaUnd);
    // 0(granel) + 10×0.1 + 10×0.25 + (−2)×0.5 = 2.50 → el negativo RESTA
    t('zona02 total 2.50 kg (el −2 del 500GR RESTA)', Math.abs(z2.totalEq - 2.5) < 0.02, z2.totalEq);
    const sumaLineas = z2.lineas.reduce((a, l) => a + parseFloat(l.stockEq), 0);
    t('el total de la ubicación = suma exacta de sus líneas', Math.abs(sumaLineas - z2.totalEq) < 0.005, sumaLineas);
  } else { t('viene ZONA-02', false); }
  console.log('\n  ubicaciones devueltas:', aj.ubicaciones.map(u => u.id).join(', '));
  t('ALMACEN va primero', aj.ubicaciones[0].tipo === 'ALMACEN');
}
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
await c.end();
process.exit(fail === 0 ? 0 : 1);
