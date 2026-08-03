// Verifica el fix del envío de ticket en ME: extrae los scripts inline, valida sintaxis
// y comprueba la lógica del reintento + banner (sin navegador).
import fs from 'fs';
const html = fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosExpress/index.html', 'utf8');
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };

console.log('── 1. Sintaxis de los scripts inline');
const scripts = [...html.matchAll(/<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
console.log('     scripts inline:', scripts.length);
let errores = 0;
scripts.forEach((s, i) => {
  if (!s.trim()) return;
  try { new Function(s); } catch (e) {
    // los módulos/JSON-LD no son funciones válidas; solo reportamos errores de sintaxis reales
    if (/Unexpected|Invalid|missing/i.test(e.message)) { errores++; console.log(`     ❌ script #${i}: ${e.message.slice(0, 90)}`); }
  }
});
t('todos los scripts inline parsean', errores === 0, errores);

console.log('── 2. El fix del envío de ticket');
t('existe la función de envío con reintento', html.includes('const _enviarTicket = (intento)'));
t('reintenta 1 vez antes de rendirse', /if \(intento === 0\)[\s\S]{0,400}_enviarTicket\(1\)/.test(html));
t('el fallo definitivo entra al banner persistente', /_enviarTicket[\s\S]{0,900}_meFalloDuroImpresion\(titulo, _pnId, _contenido/.test(html));
// El flujo de VENTA ya no puede terminar en un toast que se desvanece. (Los otros dos
// `catch` con toast son de reimpresión manual y aviso de sesión: ahí el usuario está mirando.)
const bloqueVenta = html.slice(html.indexOf('const _enviarTicket'), html.indexOf('const _enviarTicket') + 1400);
t('la venta ya NO se traga el error con un toast suelto', !bloqueVenta.includes("agregarToast('Error Impresión'"));
t('sigue siendo fire-and-forget (no bloquea la venta)', html.includes('_enviarTicket(0);') && !/await _enviarTicket/.test(html));

console.log('── 3. El banner de fallo sabe reimprimir esto');
t('reimprimirUltimoTicket reenvía con printerId+contenido de la cola',
  /reimprimirUltimoTicket[\s\S]{0,700}mandarImpresionPrintNode\(printerId, titulo, contenido/.test(html));
t('el fallo guarda el contenido para poder reimprimir', /meImpFallos\.value\.push\(\{[^}]*contenido: contenido/.test(html));

console.log('── 3b. Voz: precalentado del motor');
t('existe _ttsWarm (utterance mudo)', /const _ttsWarm[\s\S]{0,300}u\.volume = 0/.test(html));
t('se precalienta al agregar al carrito', /_flyToCart[\s\S]{0,400}_ttsWarm\(\)/.test(html) || /if \(bBuscador\.value\)[\s\S]{0,300}_ttsWarm\(\)/.test(html));
t('al abrir el cobro espera si estaba frío', /_ttsNecesitaWarm\(\)[\s\S]{0,300}setTimeout\(\(\) => \{ try \{ leerMontoEnVoz/.test(html));
t('speakES marca el motor como caliente', /speechSynthesis\.speak\(u\);\s*\n\s*_ttsUltimo = Date\.now\(\)/.test(html));
t('no molesta si ya está caliente (15s)', html.includes('if (!_ttsNecesitaWarm()) return;'));

console.log('── 4. Ritual de versión (los 3 obligatorios)');
const V = (html.match(/var V\s*=\s*'([\d.]+)'/) || [])[1];
const sw = (fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosExpress/sw.js', 'utf8').match(/VERSION\s*=\s*'([\d.]+)'/) || [])[1];
const vj = JSON.parse(fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosExpress/version.json', 'utf8')).version;
console.log(`     index var V=${V} · sw.js=${sw} · version.json=${vj}`);
t('las 3 versiones coinciden', V === sw && sw === vj, `${V}/${sw}/${vj}`);
console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
