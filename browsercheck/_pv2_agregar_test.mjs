// Reproduce el caso de Luis: agregar un producto al catálogo del proveedor y CERRAR
// el modal antes de que el servidor responda. Debe aparecer igual (optimista).
import fs from 'fs';
const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js', 'utf8');
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

// ── simulación del flujo real (addPick + _mx) con la API lenta ──
const addPickSrc = src.slice(src.indexOf('    addPick(i) {'), src.indexOf('    _addPaintAgregados()'));
const mxSrc      = src.slice(src.indexOf('    _mx() {'), src.indexOf('  };\n  function _pv2Modal'));

let resolverApi;
const S = { pv2: { prov: { idProveedor: 'PROV-X' }, items: [{ skuBase: 'LEV001', descripcion: 'YA ESTABA' }],
                   _mRes: [{ skuBase: 'LEV999', descripcion: 'BADIA COMINO 100GR', codigoBarra: '00999' }],
                   addQ: '', view: 'pedido', _dirty: false, addAgregados: [], cand: [] } };
const llamadas = [];
const env = {
  S, toast: () => {}, pv2Render: () => {}, _renderProvProductos: () => {},
  $: () => null,
  API: { post: (a, p) => { llamadas.push(a); return new Promise(res => { resolverApi = () => res({ ok: true }); }); } },
  pv2: { addBuscar: () => {}, _addPaintAgregados: () => {}, _addPaint: () => {} }
};
const run = new Function(...Object.keys(env), `
  const pv2obj = { ${addPickSrc} ${mxSrc} };
  Object.assign(pv2, pv2obj);
  return { pick: (i) => pv2.addPick(i), cerrar: () => pv2._mx() };
`)(...Object.values(env));

console.log('── Caso: agregar BADIA COMINO y cerrar el modal ANTES de la respuesta');
run.pick(0);
t('se llamó a agregarProductoProveedor', llamadas.includes('agregarProductoProveedor'));
t('quedó marcado para refrescar SIN esperar al servidor', S.pv2._dirty === true, S.pv2._dirty);
run.cerrar();                                   // el cajero cierra el modal enseguida
const hay = (S.pv2.items || []).some(x => String(x.skuBase) === 'LEV999');
t('el producto APARECE en la lista al cerrar (optimista)', hay, JSON.stringify(S.pv2.items.map(x => x.skuBase)));
const ph = (S.pv2.items || []).find(x => String(x.skuBase) === 'LEV999');
t('se marca como ⏳ pendiente', ph && ph._pend === true);
t('el placeholder lleva su código de barras', ph && ph.codigoBarra === '00999', ph && ph.codigoBarra);
t('no se perdió lo que ya estaba', (S.pv2.items || []).some(x => String(x.skuBase) === 'LEV001'));
resolverApi();                                   // ahora sí responde el servidor

console.log('── El refresco posterior no debe borrarlo si el server aún no lo trae');
const shim = src.slice(src.indexOf('  function _renderProvProductos()'), src.indexOf('  function _fmtFechaLarga'));
t('el refetch preserva los pendientes huérfanos', /_huerfanos\s*=\s*_prev\.filter\(x => x\._pend/.test(shim));
t('y los vuelve a concatenar', /S\.pv2\.items\.concat\(_huerfanos\)/.test(shim));

console.log('── Rollback si el servidor rechaza');
t('addPick saca el placeholder de la lista al fallar', /catch\(\(\) => \{[\s\S]{0,400}x\._pend && String\(x\.skuBase\) === sku/.test(addPickSrc));
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
