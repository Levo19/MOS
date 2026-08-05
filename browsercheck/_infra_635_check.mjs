// Infraestructura 635: solicitudes agrupadas+TTL, suspendidos fuera de zonas, grupo MosGo.
import fs from 'fs';
import { execSync } from 'child_process';
const R = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/';
const app = fs.readFileSync(R + 'js/app.js', 'utf8');
const api = fs.readFileSync(R + 'js/api.js', 'utf8');
let ok = 0, fail = 0;
const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };

console.log('── sintaxis');
try { execSync(`node --check "${R}js/app.js"`, { stdio: 'pipe' }); t('app.js parsea', true); }
catch (e) { t('app.js parsea', false, String(e.stderr || e).slice(0, 120)); }

console.log('── solicitudes (sección A)');
t('los dos tipos agrupados con subtítulos', app.includes("sub('📱', 'Acceso de dispositivo (UUID)'") && app.includes("sub('🕐', 'Extensión de horario'"));
t('TTL 1h en dispositivos pendientes', app.includes('(Date.now() - pd) <= 3600e3'));
t('TTL 1h en extensiones de horario', app.includes("(Date.now() - (Date.parse(a.fecha || '') || 0)) <= 3600e3"));
t('cada solicitud dice hace cuánto se pidió', app.includes("' · 📨 ' + hace") && app.includes('_fmtHace(a.fecha)'));
t('la solicitud muestra si venía suspendido y hace cuánto', (app.match(/venía suspendido/g) || []).length >= 2);
t('aprobar/rechazar horario cableados y exportados', app.includes('async function aprobarExtHorario') && app.includes('aprobarExtHorario, rechazarExtHorario,'));
t('api: alertas de horario se leen de seguridad_alertas', api.includes("_sbRpcMOS('seguridad_alertas', { p: { tipo: 'EXTENSION_HORARIO_PENDIENTE' } })"));
t('api: aprobar/rechazar registrados en el mapa directo', api.includes('aprobarExtensionHorario:    () => true'));
t('las alertas se cargan con la pestaña infra', (api.includes("getAlertasExtensionHorario") && (app.match(/getAlertasExtensionHorario/g) || []).length >= 2));

console.log('── suspendidos y zonas');
t('un SUSPENDIDO jamás aparece en zonas (VIP incluido)', /SUSPENDIDO'\) return _cfgVerTodos;/.test(app));
t('sección ⏸ Suspendidos con duración y reactivar', (() => {
  const i = app.indexOf('function _cfgSuspendidos');
  const c = i >= 0 ? app.slice(i, app.indexOf('function _cfgZonaGo')) : '';
  return c.includes('⏸ suspendido') && c.includes('Reactivar');
})());
t('archivados muestran cuánto llevan suspendidos', app.includes("⏸ suspendido hace ' + _suspT"));
t('renderInfra incluye las secciones nuevas en orden', /_cfgPend\(\) \+\s*_cfgZonaVip\(\) \+\s*_cfgZonaGo\(\) \+/.test(app) && app.includes('_cfgSuspendidos() +'));

console.log('── MosGo en infraestructura');
t('grupo MosGo existe', app.includes('function _cfgZonaGo') && app.includes("'MosGo · venta en ruta'"));
t('badge de app conoce mosGo', app.includes("app === 'mosgo'") && app.includes("label = 'MosGo'"));

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
