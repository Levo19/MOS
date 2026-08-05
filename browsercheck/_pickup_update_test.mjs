// Verifica (a) el pickup que quedaba pegado tras despachar y (b) la actualización
// forzada en las 3 apps.
import fs from 'fs';
import { execSync } from 'child_process';
const R = 'C:/Users/ISO/ecosistema MOS/';
const whApp = fs.readFileSync(R + 'warehouseMos/js/app.js', 'utf8');
const whHtml = fs.readFileSync(R + 'warehouseMos/index.html', 'utf8');
const meHtml = fs.readFileSync(R + 'MosExpress/index.html', 'utf8');
const mosHtml = fs.readFileSync(R + 'ProyectoMOS/index.html', 'utf8');
let ok = 0, fail = 0;
const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };

console.log('── sintaxis');
try { execSync(`node --check "${R}warehouseMos/js/app.js"`, { stdio: 'pipe' }); t('WH app.js parsea', true); }
catch (e) { t('WH app.js parsea', false, String(e.stderr || e).slice(0, 160)); }
for (const [nom, html] of [['WH', whHtml], ['ME', meHtml], ['MOS', mosHtml]]) {
  const scripts = [...html.matchAll(/<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  let err = 0, det = '';
  scripts.forEach((s, i) => { if (!s.trim()) return; try { new Function(s); } catch (e) {
    if (/Unexpected|Invalid|missing/i.test(e.message)) { err++; det += `#${i}:${e.message.slice(0,60)} `; } } });
  t(`${nom}: los ${scripts.length} scripts inline parsean`, err === 0, det);
}

console.log('── el pickup se suelta solo cuando ya se despachó');
t('marca el momento en que se toma el pickup', whApp.includes('tsTomado: Date.now()'));
t('guarda también la última actividad local', whApp.includes('_pickupActivo.tsGuardado = Date.now()'));
t('existe la reconciliación', whApp.includes('function _reconciliarPickupActivo'));
t('corre en cada poll', whApp.includes('_reconciliarPickupActivo(lista); } catch (_) {}'));
t('suelta si el servidor ya no lo lista como despachable', /if \(!srv\) \{[\s\S]{0,140}cerrado = true/.test(whApp));
t('suelta si fue atendido después de tomarlo', whApp.includes('atendido > tsTomado + 5000'));
t('tolera el desfase de reloj del celular', whApp.includes('+ 5000'));
t('NO toca un cierre en curso', whApp.includes('if (!_pickupActivo || _pickupClosing) return;'));
t('sin ninguna marca temporal no arriesga', whApp.includes('if (!tsTomado) return;'));
t('avisa al operador cuando lo libera', whApp.includes('Pickup liberado'));
t('limpia también el localStorage', /_reconciliarPickupActivo[\s\S]{0,1600}_clearPickup\(\)/.test(whApp));

console.log('── actualización forzada');
// El cuerpo real de _checkForcedUpdate en cada app (no una ventana adivinada).
const cuerpoCheck = (html) => {
  const i = html.indexOf('async function _checkForcedUpdate()');
  return i < 0 ? '' : html.slice(i, i + 1400);
};
t('WH: chequeo de versión con timeout', cuerpoCheck(whHtml).includes('signal: _ac.signal'),
  cuerpoCheck(whHtml) ? '' : 'no se encontró la función');
t('WH: sigue revalidando el SW cada 5 min', whHtml.includes('setInterval(() => _reg?.update().catch(() => {}), 5 * 60 * 1000)'));
t('ME: chequeo de versión con timeout', cuerpoCheck(meHtml).includes('signal: _ac.signal'),
  cuerpoCheck(meHtml) ? '' : 'no se encontró la función');
t('ME: ahora revalida el SW cada 5 min', meHtml.includes('_reg && _reg.update().catch(() => {}); } catch (_) {} }, 5 * 60 * 1000)'));
t('MOS: chequeo de versión con timeout', /_watchVersionJson[\s\S]{0,500}signal: _ac\.signal/.test(mosHtml));
t('MOS: la actualización ya no se puede posponer para siempre', mosHtml.includes('MOS_UPD_LIMITE_MS'));
t('MOS: arranca el plazo al detectar versión nueva', mosHtml.includes('if (!_mosUpdPendienteDesde) _mosUpdPendienteDesde = Date.now()'));
t('MOS: revisa el plazo periódicamente', mosHtml.includes('setInterval(_mosForzarSiVencio, 30 * 1000)'));
t('MOS: NUNCA recarga con un modal abierto o un campo en edición', mosHtml.includes('if (_mosHayTrabajoAbierto()) return;'));
t('MOS: ante la duda no recarga', /catch \(_\) \{ return true; \}\s*\/\/ ante la duda, NO recargar/.test(mosHtml));

console.log('── no se rompió lo de hoy');
t('WH: sigue el fix del cuelgue al generar guía', whHtml.includes('const _ac = new AbortController()') && whHtml.includes('}, 3500)'));
t('WH: sigue el tope de granel', whApp.includes('es más de 10× lo pedido'));
t('ME: sigue el bloqueo de crédito sin cliente', meHtml.includes('Sin cliente la deuda no se le puede cobrar a nadie'));

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
