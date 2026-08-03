// Reproduce los hallazgos de la revisión adversarial y verifica que quedaron cerrados.
import fs from 'fs';
let ok = 0, fail = 0;
const t = (n, cond, extra) => { if (cond) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, extra ?? ''); } };
const me  = fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosExpress/index.html', 'utf8');
const mos = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js', 'utf8');

console.log('══ CRÍTICO 1 — doble ticket por reintento tras timeout');
const bloque = me.slice(me.indexOf('let _yaSalio = false;'), me.indexOf('_enviarTicket(0);') + 40);
t('NO se reintenta cuando el resultado es incierto (timeout/abort)', /intento === 0 && !_incierto\(e\)/.test(bloque));
t('si el envío llega tarde, se aborta la alarma (_yaSalio)', /if \(_yaSalio\) return true;/.test(bloque));
t('el banner espera 6s por si la respuesta venía en camino', /setTimeout\(\(\) => \{[\s\S]{0,120}if \(!_yaSalio\) _meFalloDuroImpresion/.test(bloque));
// simulación real del escenario
const sim = async (respondeEnMs, raceMs = 8000) => {
  let jobs = 0;
  const enviar = () => new Promise((res, rej) => { jobs++; setTimeout(() => res({ printJobId: jobs }), respondeEnMs); });
  let yaSalio = false;
  const incierto = e => /timeout|abort|no respondió/i.test(String(e && e.message || ''));
  const run = (intento) => {
    const p = enviar().then(d => { yaSalio = true; return d; });
    const to = new Promise((_, rej) => setTimeout(() => rej(new Error('la impresora no respondió en 8s')), raceMs));
    return Promise.race([p, to]).catch(e => {
      if (yaSalio) return;
      if (intento === 0 && !incierto(e)) return new Promise(r => setTimeout(r, 50)).then(() => run(1));
    });
  };
  await run(0);
  await new Promise(r => setTimeout(r, respondeEnMs + 120));
  return jobs;
};
const jobsLento = await sim(300, 100);   // la respuesta tarda más que el race
t('escenario "red lenta": UN SOLO job (antes: 2)', jobsLento === 1, 'jobs=' + jobsLento);

console.log('══ CRÍTICO 2 — el reintento estrenaba su propio watch-job (hasta 4 papeles)');
t('el nº de intento se propaga al watch-job', /mandarImpresionPrintNode\(_pnId, titulo, _contenido, intento\)/.test(bloque));

console.log('══ CRÍTICO 3 — producto de un proveedor apareciendo en otro');
t('addAgregados se limpia al abrir otro proveedor', /S\.pv2\.cand = null; S\.pv2\.ubis = null; S\.pv2\.addAgregados = \[\];/.test(mos));

console.log('══ ALTO 4 — el pedido salía con la línea DUPLICADA');
const shim = mos.slice(mos.indexOf('function _renderProvProductos'), mos.indexOf('function _fmtFechaLarga'));
t('el carrito se reclava de skuBase → idPP', /_c\.items\[kPP\] = Object\.assign/.test(shim) && /delete _c\.items\[kSku\]/.test(shim));
t('y se persiste el carrito reclavado', /_provCarritosSave\(\)/.test(shim));

console.log('══ ALTO 5 — el warm-up de voz se cancelaba a sí mismo');
t('solo se cancela si de verdad está hablando', me.includes('if (window.speechSynthesis.speaking) window.speechSynthesis.cancel();'));
t('ya no hay cancel incondicional en leerMontoEnVoz',
  !/leerMontoEnVoz[\s\S]{0,700}\n\s*window\.speechSynthesis\.cancel\(\);\s*\n\s*window\.speechSynthesis\.speak/.test(me));

console.log('══ MEDIO 6 — podía leer en voz alta un monto viejo');
t('el total se captura ANTES del diferido', /const _totVoz = granTotal\.value;/.test(me) && /leerMontoEnVoz\(_totVoz\)/.test(me));

console.log('══ MEDIO 7 — "Reimprimir" que no hacía nada sin impresora');
t('avisa que falta configurar la impresora', /Esta estación no tiene impresora/.test(me));

console.log('══ MEDIO 8 — respuesta lenta pintada en el proveedor equivocado');
t('guardia de proveedor en el refetch', /const _pidReq = S\.pv2\.prov\.idProveedor;/.test(shim) &&
  /S\.pv2\.prov\.idProveedor !== _pidReq\) return;/.test(shim));

console.log('══ BAJO 9 — la voz ignoraba su propio switch');
t('leerMontoEnVoz respeta voiceEnabled', /const leerMontoEnVoz[\s\S]{0,150}if \(!voiceEnabled\.value/.test(me));
const lmv = me.slice(me.indexOf('const leerMontoEnVoz'), me.indexOf('const leerMontoEnVoz') + 1400);
t('el monto hablado también calienta el motor', /_ttsUltimo = Date\.now\(\)/.test(lmv), lmv.slice(-140).replace(/\s+/g, ' '));

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
