// Arnés Node: corre el render nuevo (cuadros + overlay) con los DATOS REALES de la RPC 614.
// Verifica que el HTML sea correcto sin necesidad de navegador.
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;

const url = fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim();
const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();
const r = (await c.query(`select mos.prov_stock_ubicaciones('{"idProveedor":"PROV070"}'::jsonb) j`)).rows[0].j;
await c.end();
const prod = r.data.productos.find(p => p.codigoBarra === 'WHAJARUM');

// --- extraer las funciones del app.js real y evaluarlas con stubs ---
const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js', 'utf8');
const desde = src.indexOf('function _pv2EsAlm(u)');
const hasta = src.indexOf('function _pv2CardProd(pp)');
if (desde < 0 || hasta < 0) { console.log('❌ no ubiqué el bloque de ubicaciones'); process.exit(1); }
const bloque = src.slice(desde, hasta);

const stubs = `
  const _esc = s => String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  const _fmtQty = n => { const v = parseFloat(n)||0; const s = v.toFixed(3).replace(/\\.?0+$/,''); return s === '-0' ? '0' : s; };
  const _pv2CovColor = c => c == null ? 'var(--pv2-ink3)' : c < 0.6 ? '#f87171' : c < 1.2 ? '#fbbf24' : '#34d399';
  const _pv2Item = () => PP; const toast = () => {};
  const document = { getElementById: () => null, createElement: () => ({ addEventListener(){}, }), body:{appendChild(){}}, addEventListener(){}, removeEventListener(){} };
`;
const PP = { descripcion: 'AJONJOLI BLANCO PREMIUM GRANEL EXO', codigoBarra: 'WHAJARUM',
             unidad: prod.unidad,                       // [615·H3] kg vs und
             zonas: [{ idZona: 'ZONA-01', nombre: 'Zona 01' }, { idZona: 'ZONA-02', nombre: 'Zona 02' }],
             ubicaciones: prod.ubicaciones };
console.log('unidad del producto:', prod.unidad);
const f = new Function('PP', stubs + bloque + `
  return { cuadros: _pv2UbiCuadrosHtml(PP,'K1'), cover: _pv2UbiCoverHtml(PP,'K1'),
           ovlAlm: _pv2UbiOvlHtml(PP, _pv2UbiFind(PP,'ALMACEN')),
           ovlZona: _pv2UbiOvlHtml(PP, _pv2UbiFind(PP,'ZONA-02')) };`);
const out = f(PP);

let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

console.log('── CUADROS');
const nBotones = (out.cuadros.match(/<button[^>]*class="pv2-ubi /g) || []).length;
t('3 cuadros cliqueables (almacén + 2 zonas)', nBotones === 3, 'botones=' + nBotones);
t('Σ TOTAL presente y NO cliqueable', out.cuadros.includes('pv2-ubi tot') && !/<button[^>]*pv2-ubi tot/.test(out.cuadros));
t('almacén muestra 66.55 (ya no 0)', out.cuadros.includes('>66.55<'));
t('nombre bonito de zona ("Zona 02", no "ZONA-02")', out.cuadros.includes('Zona 02') && !out.cuadros.includes('>🏪 ZONA-02<'));
t('cuadros llaman a MOS.pv2.ubi', (out.cuadros.match(/MOS\.pv2\.ubi\(/g) || []).length === 3);
t('almacén marca el faltante con la unidad correcta', /falta 2\.938 kg/.test(out.cuadros), out.cuadros.match(/falta [^<]*/)?.[0]);
t('zona 02 marcada como negativa', out.cuadros.includes('pv2-ubi zona neg'));

console.log('── COBERTURA (card principal = ALMACÉN)');
t('dice "el almacén cubre"', out.cover.includes('el almacén cubre'));
t('muestra 2.4 sem', out.cover.includes('2.4 sem'));
t('muestra la salida semanal en kg (producto KGM)', /sale 27\.2\d* kg\/sem/.test(out.cover), out.cover.match(/sale [^<]*/)?.[0]);
t('bloque de faltante presente y cliqueable', out.cover.includes('pv2-ubifalta') && out.cover.includes("MOS.pv2.ubi('K1','ALMACEN')"));
t('desglose corto de faltantes', out.cover.includes('GRANEL') && out.cover.includes('250GR'));
// [615·H2] el ajonjolí tiene el granel en 0 → debe decir COMPRAR, no ENVASAR
t('dice COMPRAR (granel en cero)', out.cover.includes('COMPRAR PARA LA SEMANA'));
t('NO ofrece envasar lo que no hay', !out.cover.includes('🔄 ENVASAR'));

console.log('── OVERLAY ALMACÉN');
t('columna "Sale" (no "Vende")', out.ovlAlm.includes('>Sale<') && !out.ovlAlm.includes('>Vende<'));
t('5 filas (padre + 4 derivados)', (out.ovlAlm.match(/<tr class="/g) || []).length === 5);
t('fila del padre destacada', out.ovlAlm.includes('<tr class="padre'));
t('250GR marcado como alerta (cubre 0.9)', /WHAJARUM250GR[\s\S]{0,400}/.test(out.ovlAlm) && out.ovlAlm.includes('alerta'));
t('llamado a la acción = COMPRAR al proveedor', out.ovlAlm.includes('COMPRAR AL PROVEEDOR'));
t('sin columna "= en kg" separada (vista limpia)', !out.ovlAlm.includes('>= en kg<'));
t('el 5KG sin rotación no divide por cero', out.ovlAlm.includes('sin rotación'));

console.log('── OVERLAY ZONA');
t('columna "Vende"', out.ovlZona.includes('>Vende<'));
t('llamado a la acción = DESPACHAR (no compra)', out.ovlZona.includes('lo despacha el almacén'));
t('stock negativo con clase roja', out.ovlZona.includes('class="r neg"'));
t('faltan 4 und del 500GR', /<b>4<\/b>/.test(out.ovlZona));
t('avisa cuántos en negativo', out.ovlZona.includes('en negativo'));

console.log('── SEGURIDAD/FORMATO');
t('sin toFixed(0) ni Math.round en cantidades', !/toFixed\(0\)|Math\.round\(.*stock/i.test(bloque));
t('todo texto de datos escapado', (bloque.match(/_esc\(/g) || []).length >= 8);
t('sin dvh', !bloque.includes('dvh'));
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
