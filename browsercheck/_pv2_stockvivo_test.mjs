// Verifica el stock en vivo de Proveedores (reclamo: WH actualiza y acá no se ve).
import fs from 'fs';
import { execSync } from 'child_process';
const P = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js';
const app = fs.readFileSync(P, 'utf8');
let ok = 0, fail = 0;
const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };

console.log('── sintaxis');
try { execSync(`node --check "${P}"`, { stdio: 'pipe' }); t('app.js parsea', true); }
catch (e) { t('app.js parsea', false, String(e.stderr || e).slice(0, 200)); }

console.log('── el stock se refresca solo');
t('hay un refresco periódico', app.includes('const PV2_STOCK_MS = 25 * 1000'));
t('refresca al volver el foco', /_pv2StockVis = \(\) => \{ if \(document\.visibilityState === 'visible'\) _pv2RefrescarStock\(\); \}/.test(app));
t('escucha visibilitychange y focus', app.includes("addEventListener('visibilitychange', _pv2StockVis)") && app.includes("addEventListener('focus', _pv2StockVis)"));
t('arranca al abrir un proveedor', app.includes('_pv2StockAutoIniciar(); } catch (_) {}   // [660]'));
t('se detiene al salir del módulo', app.includes('_pv2StockAutoDetener(); } catch (_) {}   // [660]'));
t('se detiene al volver al home de proveedores', /volver\(\) \{ _pv2UbiCerrar\(\); try \{ _pv2StockAutoDetener\(\); \}/.test(app));

console.log('── no molesta ni se pisa a sí mismo');
t('no lanza dos peticiones a la vez', app.includes('if (_pv2StockEnVuelo) return;'));
t('no refresca con la pestaña oculta', app.includes("if (document.visibilityState !== 'visible') return;"));
t('no pisa al admin mientras edita', app.includes("if ($('pv2Modal') || $('provProductoModal')) return;"));
t('no aplica si cambiaste de proveedor mientras cargaba', app.includes('String(idAhora) !== String(id)'));
// El cuerpo REAL de la función, no una ventana de N caracteres adivinada.
const ini = app.indexOf('async function _pv2RefrescarStock()');
const fin = app.indexOf('function _pv2StockAutoIniciar()');
const cuerpo = (ini >= 0 && fin > ini) ? app.slice(ini, fin) : '';
t('se encontró el cuerpo de _pv2RefrescarStock', cuerpo.length > 100, `${cuerpo.length} chars`);
t('sólo re-pide el stock, no el catálogo ni el histórico',
  cuerpo.includes('getProvStockUbicaciones') &&
  !cuerpo.includes('getProductosProveedorConStock') &&
  !cuerpo.includes('getHistoricoProveedor'));
t('re-mergea las ubicaciones sobre los items en pantalla',
  cuerpo.includes('_pv2MergeUbicaciones(S.pv2.items, ubis)') && cuerpo.includes('pv2Render()'));

console.log('── no se rompió lo de la semana pasada');
t('sigue el merge por código canónico', app.includes('function _pv2MergeUbicaciones'));
t('sigue el reset de agregados entre proveedores', app.includes('S.pv2.addAgregados = []'));
t('sigue el toggle activo/desactivar', app.includes('_pv2TogHtml'));
t('sigue pidiendo ubicaciones al abrir', app.includes("API.get('getProvStockUbicaciones', { idProveedor: id })"));

console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
process.exit(fail === 0 ? 0 : 1);
