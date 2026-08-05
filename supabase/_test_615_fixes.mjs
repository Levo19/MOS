// Verifica los 8 fixes de 615 con datos reales de producción.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };
const call = async prov => (await c.query(`select mos.prov_stock_ubicaciones($1::jsonb) j`,
  [JSON.stringify({ idProveedor: prov })])).rows[0].j;

console.log('── H1: los 26% que no matcheaban');
const p005 = await call('PROV005');                    // celofanes: antes 0 productos
t('PROV005 (celofanes) ya devuelve productos', (p005.data.productos || []).length > 0,
  (p005.data.productos || []).length);
const p070 = await call('PROV070');
t('PROV070 no perdió productos', (p070.data.productos || []).length >= 13, (p070.data.productos || []).length);

console.log('── H3: unidad emitida');
const unid = new Set((p070.data.productos || []).map(x => x.unidad));
t('cada producto trae su unidad', [...unid].every(u => u === 'KGM' || u === 'NIU'), [...unid].join(','));
const p006 = await call('PROV006');
const conNIU = (p006.data.productos || []).filter(x => x.unidad === 'NIU').length;
t('hay productos NIU (no todo es kg)', conNIU > 0, conNIU);

console.log('── H2: comprar vs envasar');
const coco = (p070.data.productos || []).find(x => x.codigoBarra === 'WHCOLFNO');
if (coco) {
  const alm = coco.ubicaciones.find(u => u.tipo === 'ALMACEN');
  console.log(`     WHCOLFNO: cubre ${alm.cubreSem} sem · granel disp ${alm.padreDispEq} · falta ${alm.faltaEq} → comprar ${alm.faltaComprarEq} / envasar ${alm.faltaEnvasarEq}`);
  t('WHCOLFNO ya NO manda a comprar (lo cubre su granel)', parseFloat(alm.faltaComprarEq) === 0, alm.faltaComprarEq);
  t('WHCOLFNO manda a ENVASAR', parseFloat(alm.faltaEnvasarEq) > 0, alm.faltaEnvasarEq);
} else { t('viene WHCOLFNO', false); }
// [rev500] La REGLA, no un producto concreto: el stock cambia día a día (el 04/08 entró
// granel de ajonjolí y su respuesta correcta pasó de "comprar" a "envasar" — el assert
// viejo, atado a ese estado, fallaba aunque el código estuviera bien).
let nReglas = 0, malReglas = 0;
for (const p of (p070.data.productos || [])) {
  const alm = (p.ubicaciones || []).find(u => u.tipo === 'ALMACEN');
  if (!alm || !(parseFloat(alm.faltaEq) > 0)) continue;
  nReglas++;
  const falta = parseFloat(alm.faltaEq), comprar = parseFloat(alm.faltaComprarEq) || 0;
  const envasar = parseFloat(alm.faltaEnvasarEq) || 0, granel = parseFloat(alm.padreDispEq) || 0;
  const sumaOk = Math.abs(comprar + envasar - falta) < 0.01;
  const envOk = Math.abs(envasar - Math.min(falta, granel)) < 0.01;   // se envasa lo que el granel cubre
  const comOk = Math.abs(comprar - Math.max(0, falta - granel)) < 0.01; // se compra solo el resto
  if (!(sumaOk && envOk && comOk)) { malReglas++;
    console.log(`     ✗ ${p.codigoBarra}: falta ${falta} · granel ${granel} → comprar ${comprar} / envasar ${envasar}`); }
}
console.log(`     productos con faltante evaluados: ${nReglas}`);
t('comprar + envasar = faltante, en TODOS', malReglas === 0, malReglas + ' incoherentes');
t('lo que cubre el granel se ENVASA, el resto se COMPRA', malReglas === 0);

console.log('── H4: tope al stock corrupto');
const p007 = await call('PROV007');
let maxFalta = 0, marcados = 0;
for (const p of (p007.data.productos || [])) for (const u of (p.ubicaciones || [])) {
  const f = parseFloat(u.faltaEq) || 0, d = parseFloat(u.demandaEqSem) || 0;
  if (f > maxFalta) maxFalta = f;
  if (u.hayCorrupto) marcados++;
  if (d > 0 && f > d * 8 + 0.01) { fail++; console.log('  ❌ faltante sin tope:', p.codigoBarra, u.id, f, 'vs demanda', d); }
}
t('ningún faltante supera 8 semanas de demanda', true);
t('las líneas con stock corrupto quedan marcadas', marcados > 0, marcados);
console.log(`     faltante máximo ahora: ${maxFalta} (antes 768.25)`);

console.log('── M4: zonas mock fuera');
let mock = 0;
for (const prov of ['PROV002','PROV004','PROV006','PROV044']) {
  const r = await call(prov);
  for (const p of (r.data.productos || [])) for (const u of (p.ubicaciones || []))
    if (/MOCK|FALLBACK|TEST/i.test(u.id)) mock++;
}
t('ninguna ubicación MOCK/FALLBACK', mock === 0, mock);

console.log('── H5: presentaciones suman demanda pero NO stock');
let presCount = 0, presConStock = 0;
for (const p of (p006.data.productos || [])) for (const u of (p.ubicaciones || []))
  for (const l of (u.lineas || [])) if (l.soloDemanda) { presCount++; if (parseFloat(l.stock) !== 0) presConStock++; }
t('las presentaciones nunca aportan stock', presConStock === 0, presConStock);
console.log(`     líneas de presentación consideradas: ${presCount}`);

console.log('── coherencia general');
for (const p of (p070.data.productos || [])) for (const u of (p.ubicaciones || [])) {
  const suma = (u.lineas || []).reduce((a, l) => a + parseFloat(l.stockEq), 0);
  if (Math.abs(suma - parseFloat(u.totalEq)) > 0.01) { fail++; console.log('  ❌ total ≠ suma de líneas:', p.codigoBarra, u.id); }
}
t('todos los totales = suma exacta de sus líneas', true);
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
await c.end();
process.exit(fail === 0 ? 0 : 1);
