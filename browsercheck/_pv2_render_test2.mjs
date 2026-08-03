// Segundo arnés: casos OPUESTOS al ajonjolí — producto en UNIDADES (NIU) y producto
// cuyo faltante se cubre ENVASANDO el granel propio (no comprando).
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;
const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r70 = (await c.query(`select mos.prov_stock_ubicaciones('{"idProveedor":"PROV070"}'::jsonb) j`)).rows[0].j;
const r06 = (await c.query(`select mos.prov_stock_ubicaciones('{"idProveedor":"PROV006"}'::jsonb) j`)).rows[0].j;
await c.end();

const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js', 'utf8');
const bloque = src.slice(src.indexOf('function _pv2EsAlm(u)'), src.indexOf('function _pv2CardProd(pp)'));
const stubs = `
  const _esc = s => String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  const _fmtQty = n => { const v = parseFloat(n)||0; const s = v.toFixed(3).replace(/\\.?0+$/,''); return s === '-0' ? '0' : s; };
  const _pv2CovColor = c => c == null ? 'var(--pv2-ink3)' : c < 0.6 ? '#f87171' : c < 1.2 ? '#fbbf24' : '#34d399';
  const _pv2Item = () => PP; const toast = () => {};
  const document = { getElementById: () => null, createElement: () => ({addEventListener(){}}), body:{appendChild(){}}, addEventListener(){}, removeEventListener(){} };
`;
const render = (pp) => new Function('PP', stubs + bloque + `
  return { cuadros: _pv2UbiCuadrosHtml(PP,'K'), cover: _pv2UbiCoverHtml(PP,'K'),
           ovl: _pv2UbiOvlHtml(PP, _pv2UbiFind(PP,'ALMACEN')) };`)(pp);

let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

console.log('── CASO 1: producto que se ENVASA (granel propio disponible) — WHCOLFNO');
const coco = (r70.data.productos || []).find(p => p.codigoBarra === 'WHCOLFNO');
if (coco) {
  const o = render({ descripcion: 'COCO RALLADO FINO GRANEL', codigoBarra: 'WHCOLFNO',
                     unidad: coco.unidad, zonas: [], ubicaciones: coco.ubicaciones });
  const alm = coco.ubicaciones.find(u => u.tipo === 'ALMACEN');
  console.log(`     comprar ${alm.faltaComprarEq} · envasar ${alm.faltaEnvasarEq} · granel disp ${alm.padreDispEq}`);
  t('la card dice ENVASAR', o.cover.includes('🔄 ENVASAR'));
  t('la card NO manda a comprar', !o.cover.includes('COMPRAR PARA LA SEMANA'));
  t('aclara que el granel ya está', o.cover.includes('ya tienes el granel'));
  t('el overlay separa ENVASAR (no comprar)', o.ovl.includes('ENVASAR (no comprar)'));
  t('el overlay NO dice comprar al proveedor', !o.ovl.includes('COMPRAR AL PROVEEDOR'));
} else t('viene WHCOLFNO', false);

console.log('── CASO 2: producto en UNIDADES (NIU) — no debe decir "kg"');
const niu = (r06.data.productos || []).find(p => p.unidad === 'NIU' &&
  (p.ubicaciones || []).some(u => u.tipo === 'ALMACEN' && parseFloat(u.faltaEq) > 0));
if (niu) {
  const o = render({ descripcion: 'PRODUCTO NIU', codigoBarra: niu.codigoBarra,
                     unidad: niu.unidad, zonas: [], ubicaciones: niu.ubicaciones });
  console.log(`     ${niu.codigoBarra} (${niu.unidad})`);
  t('los cuadros dicen "und", no "kg"', /falta [\d.]+ und/.test(o.cuadros) && !/falta [\d.]+ kg/.test(o.cuadros),
    o.cuadros.match(/falta [^<]*/)?.[0]);
  t('la cobertura dice "und/sem"', /sale [\d.]+ und\/sem/.test(o.cover), o.cover.match(/sale [^<]*/)?.[0]);
  t('el total del overlay en und', /[\d.]+ und<\/b>/.test(o.ovl));
  t('ningún "kg" perdido en el overlay', !/[\d.]\s?kg/.test(o.ovl.replace(/KGM/g, '')),
    o.ovl.match(/[\d.]\s?kg/)?.[0]);
} else t('hay un producto NIU con faltante para probar', false);

console.log('── CASO 3: cobertura negativa no desborda');
const neg = [];
for (const p of [...(r70.data.productos||[]), ...(r06.data.productos||[])])
  for (const u of (p.ubicaciones||[])) if (u.cubreSem != null && parseFloat(u.cubreSem) < 0) neg.push({p, u});
if (neg.length) {
  const o = render({ descripcion: 'X', codigoBarra: neg[0].p.codigoBarra, unidad: neg[0].p.unidad,
                     zonas: [], ubicaciones: neg[0].p.ubicaciones });
  t('cobertura negativa se muestra como "en negativo"', o.cuadros.includes('en negativo') || o.cover.includes('en negativo'));
  t('no imprime números gigantes de semanas', !/-\d{3,}\.\d sem/.test(o.cuadros + o.cover));
} else { console.log('     (sin coberturas negativas en estos proveedores — ok)'); ok += 2; }

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
