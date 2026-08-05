// Regla del saco (SQL 628/629): asserts estáticos de ME + MOS.
import fs from 'fs';
import { execSync } from 'child_process';
const R = 'C:/Users/ISO/ecosistema MOS/';
const me = fs.readFileSync(R + 'MosExpress/index.html', 'utf8');
const app = fs.readFileSync(R + 'ProyectoMOS/js/app.js', 'utf8');
const api = fs.readFileSync(R + 'ProyectoMOS/js/api.js', 'utf8');
let ok = 0, fail = 0;
const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };

console.log('── sintaxis');
try { execSync(`node --check "${R}ProyectoMOS/js/app.js"`, { stdio: 'pipe' }); t('MOS app.js parsea', true); }
catch (e) { t('MOS app.js parsea', false, String(e.stderr || e).slice(0, 150)); }
try { execSync(`node --check "${R}ProyectoMOS/js/api.js"`, { stdio: 'pipe' }); t('MOS api.js parsea', true); }
catch (e) { t('MOS api.js parsea', false, String(e.stderr || e).slice(0, 150)); }
const scripts = [...me.matchAll(/<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
let err = 0;
scripts.forEach((s, i) => { if (!s.trim()) return; try { new Function(s); } catch (e) {
  if (/Unexpected|Invalid|missing/i.test(e.message)) { err++; console.log(`     ME script #${i}: ${e.message.slice(0, 80)}`); } } });
t(`ME: los ${scripts.length} scripts inline parsean`, err === 0, err);

console.log('── ME cobra la etiqueta del saco');
t('detecta el flag Precio_Fijo', me.includes("const _esFijo = pres.Precio_Fijo === true || pres.Precio_Fijo === 'true'"));
t('el override por-kg del granel SOLO corre sin el flag', me.includes('if (_esGranel && !_esFijo) {'));
t('los tramos por kg tampoco aplican al FIJO', /parsear segmentos_precio del canónico \(no aplica al FIJO\)/.test(me));
t('el ítem FIJO viaja como unidad (NIU) → cantidad 1 y stock por factor',
  me.includes("unidadMedida: _esFijo ? 'NIU' : prodBase.unidadMedida,"));
t('el caso legacy (maní 250g por kg) queda documentado e intacto', me.includes('presCanonica.Precio_Venta) || precioFinal'));

console.log('── MOS: candado reemplazado + toggle 🛵 solo MASTER');
t('el candado viejo ya NO bloquea', !app.includes('Un granel no lleva presentación: su precio se ignora'));
t('el modal marca PRECIO FIJO sobre granel', app.includes('PRECIO FIJO sobre granel: se cobra la etiqueta'));
t('la presentación de granel se guarda con precioFijo', app.includes("if (_satState.padreGranel) params.precioFijo = '1';"));
t('el guardarraíl avisa si el escalón no ahorra (sin bloquear)', app.includes('El escalón no ahorra'));
t('existe _togglesMosgoHtml (solo MASTER)', /function _togglesMosgoHtml[\s\S]{0,120}_esMasterSession\(\)/.test(app));
t('el 🛵 aparece en los 4 renders (base, presentación, pack, derivado)',
  (app.match(/_togglesMosgoHtml\(/g) || []).length === 5, (app.match(/_togglesMosgoHtml\(/g) || []).length + ' usos (4 renders + def)');
t('el toggle de ESTADO también quedó solo-MASTER en los 4 renders',
  (app.match(/\$\{_esMasterSession\(\) \? `<button type="button" class="toggle-sw/g) || []).length === 4);
t('[632] apagar GO ya NO apaga el producto en ME', app.includes('Fuera de MosGo — en ME sigue a la venta') && !app.includes('lo APAGA en el catálogo (ME)'));
t('toggleMosgo exportado en MOS', app.includes('toggleProductoActivo, toggleMosgo,'));

console.log('── api.js: el canal viaja completo');
t('spec del catálogo trae canalMayoreo y precioFijo', api.includes("['canal_mayoreo','canalMayoreo','bool10'], ['precio_fijo','precioFijo','bool10']"));
t('crearProducto reenvía precioFijo', api.includes('precioFijo: p.precioFijo,'));
t('actualizarProducto acepta precioFijo', api.includes("'precioFijo',             // [629]"));
t('acción toggleMosgo llama a catalogo_toggle_mosgo', api.includes("_sbRpcMOSWrite('catalogo_toggle_mosgo'"));
// [672] el toggle DEBE estar registrado en el mapa de escrituras directas — sin esta
// entrada, la acción caía a GAS y respondía "Acción no reconocida" (bug reportado).
{
  const i = api.indexOf('const _MOS_POST_DIRECTO = {');
  const mapa = i >= 0 ? api.slice(i, api.indexOf('};', i)) : '';
  t('toggleMosgo registrado en _MOS_POST_DIRECTO (no cae a GAS)', mapa.includes('toggleMosgo:                () => true,'));
}

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
