// [Tributario] El overlay de CPE renderizado con datos REALES de me.cpe_trazabilidad.
// Monta un mini-DOM con el CSS del módulo, ejecuta _tribRenderCPEDetalle tal cual está en
// app.js contra el JSON de agosto, y comprueba: agrupación por día, cliente primero, hora en
// el card, bajas sin sumar, motivo visible. Deja captura para MIRAR el diseño.
import { chromium } from 'playwright';
import fs from 'fs';

const APP = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js';
const HTML = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/index.html';
const src = fs.readFileSync(APP, 'utf8');
const html = fs.readFileSync(HTML, 'utf8');
const SH = 'C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/82e44282-8af6-4daa-b2da-5c5d8354cfcc/scratchpad/';

const ok = [], bad = [];
const T = (n, c, x) => { (c ? ok : bad).push(n); console.log((c ? '  OK  ' : '  --  ') + n + (x != null && x !== '' ? '  ·  ' + x : '')); };

// datos reales
const pg = (await import('pg')).default;
const cli = new pg.Client({ connectionString: fs.readFileSync('C:/Users/ISO/.sb_db.url', 'utf8').trim() });
await cli.connect();
await cli.query('begin');
await cli.query("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true)");
const tz = (await cli.query(`select me.cpe_trazabilidad('{"desde":"2026-08-01","hasta":"2026-08-31"}'::jsonb) r`)).rows[0].r;
await cli.query('rollback');
await cli.end();
if (!tz || tz.ok === false) { console.log('  --  la trazabilidad no respondió: ' + JSON.stringify(tz).slice(0,120)); process.exit(1); }
const lista = tz.cpe || [];
console.log('  comprobantes reales cargados: ' + lista.length);

// funciones del módulo, extraídas de app.js
const grab = (name, endMarker = '\n  }') => { const i = src.indexOf(name); const f = src.indexOf(endMarker, i) + endMarker.length; return src.slice(i, f); };
const fnClasif = grab('function _tribClasifCPE(c) {');
const fnIGV = grab('function _tribIGVdeCPE(c) {');
const fnSellos = grab('function _tribSellos(c, cls) {');
const fnHist = grab('function _tribHistorialHTML(c) {');
const fnRender = grab('function _tribRenderCPEDetalle() {');
// el CSS del módulo tributario, entero
const cssIni = html.indexOf('--trib-line:'); const cssBlockStart = html.lastIndexOf('<style', cssIni); const cssBlockEnd = html.indexOf('</style>', cssIni);
const CSS = html.slice(html.indexOf('>', cssBlockStart) + 1, cssBlockEnd);

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;background:#0b1220;color:#e2e8f0;font-family:ui-sans-serif,system-ui,sans-serif}
.trib-sheet-body{padding:16px;max-width:900px}
${CSS}</style></head><body>
<div id="tribOvEmitido"><div data-trib-chips style="display:flex;flex-wrap:wrap;gap:6px;padding:12px 16px"></div><div data-trib-body class="trib-sheet-body"></div></div>
<script>
const _tribCPECache = ${JSON.stringify(lista)};
const _tribCPEFiltro = { estado: 'TODOS', tipo: 'TODOS', zona: 'TODAS' };
let _tribCPEBusq = '';
const _tribCPEViaSupa = true;
const _escapeHtml = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const _money = n => Math.round(n * 100) / 100;
const _tribFmtSoles = n => 'S/ ' + (Number(n)||0).toLocaleString('es-PE',{minimumFractionDigits:2,maximumFractionDigits:2});
const _tribSheetEl = (id, sel) => document.querySelector('#' + id + ' ' + sel);
${fnClasif}
${fnIGV}
${fnSellos}
${fnHist}
${fnRender}
_tribRenderCPEDetalle();
</script></body></html>`;

const b = await chromium.launch();
const p = await (await b.newContext({ viewport: { width: 980, height: 1200 } })).newPage();
const errs = []; p.on('pageerror', e => errs.push(String(e.message)));
await p.setContent(PAGE, { waitUntil: 'load' });
await p.waitForTimeout(600);

const r = await p.evaluate(`(() => {
  const dias = [...document.querySelectorAll('.trib-dia')];
  const cards = [...document.querySelectorAll('.trib-gcard.cpe')];
  const first = cards[0];
  const cli = first && first.querySelector('.trib-gcli') && first.querySelector('.trib-gcli').textContent.trim();
  const corr = first && first.querySelector('.trib-gcorr') && first.querySelector('.trib-gcorr').textContent.trim();
  const meta = first && first.querySelector('.trib-gmeta') && first.querySelector('.trib-gmeta').textContent.replace(/\\s+/g,' ').trim();
  // el cliente aparece ANTES que el correlativo en el DOM
  const orden = first ? (first.innerHTML.indexOf('trib-gcli') < first.innerHTML.indexOf('trib-gcorr')) : false;
  const titulos = dias.slice(0,3).map(d => d.querySelector('.trib-dia-t').textContent.trim());
  const resumen = dias[0] && dias[0].querySelector('.trib-dia-s') && dias[0].querySelector('.trib-dia-s').textContent.trim();
  const bajas = [...document.querySelectorAll('.trib-gcard.baja')];
  const bajaChip = bajas[0] && bajas[0].querySelector('.trib-gchip') && bajas[0].querySelector('.trib-gchip').textContent.trim();
  const motivo = [...document.querySelectorAll('.trib-gaviso')].map(x=>x.textContent.trim()).find(x=>/anulada|rechazo/i.test(x)) || '';
  const motivoBaja = [...document.querySelectorAll('.trib-gcard.baja .trib-gaviso')].map(x=>x.textContent.trim()).find(x=>/Se emitió/i.test(x)) || '';
  const nota = ([...document.querySelectorAll('.trib-nota')].pop()||{}).textContent || '';
  const leyenda = !!document.querySelector('.trib-leyenda');
  const sellosOk = [...document.querySelectorAll('.trib-gcard.cpe')].filter(c => c.querySelectorAll('.trib-sello.ok').length === 2).length;
  const sellosEspera = [...document.querySelectorAll('.trib-gcard.cpe')].filter(c => c.querySelector('.trib-sello.espera')).length;
  const sellosBaja = [...document.querySelectorAll('.trib-gcard.cpe .trib-sello.baja')].length;
  const semaforo = document.querySelectorAll('.trib-gcard.cpe .trib-gocr').length;
  const conVendedor = [...document.querySelectorAll('.trib-gcard.cpe')].filter(c => /👤/.test(c.querySelector('.trib-gmeta').textContent)).length;
  const conHist = document.querySelectorAll('.trib-gcard.cpe .trib-hist').length;
  const histEj = (document.querySelector('.trib-gcard.cpe .trib-hist-f')||{}).textContent || '';
  const svgImg = document.querySelectorAll('.trib-gbtn.img svg').length, svgPdf = document.querySelectorAll('.trib-gbtn.wa svg').length;
  const fechaEnCard = /\\d{2}-[a-z]{3}\\./i.test(first ? first.textContent : '');
  return { conVendedor, conHist, histEj: histEj.replace(/\s+/g,' ').trim().slice(0,120), svgImg, svgPdf, leyenda, sellosOk, sellosEspera, sellosBaja, semaforo, dias: dias.length, cards: cards.length, cli, corr, meta, orden, titulos, resumen, bajas: bajas.length, bajaChip, motivo, motivoBaja, nota: nota.slice(0,240), fechaEnCard,
           scrollW: document.documentElement.scrollWidth, clientW: document.documentElement.clientWidth };
})()`);
console.log('     ' + JSON.stringify(r));
T('renderiza todos los comprobantes', r.cards === lista.length, r.cards + ' de ' + lista.length);
T('agrupados por día', r.dias >= 10, r.dias + ' días');
T('la cabecera del día dice cuándo ("Hoy · …" o "Ayer · …" si no hubo ventas hoy)', /^(Hoy|Ayer) · /.test(r.titulos[0] || ''), r.titulos.join(' | '));
T('la cabecera resume el día (docs + IGV)', /docs? · S\/ [\d,.]+ en contra/.test(r.resumen || ''), r.resumen);
T('el cliente va primero, el correlativo debajo', r.orden && !!r.cli && !!r.corr, r.cli + ' → ' + r.corr);
T('el card muestra hora, no fecha', !r.fechaEnCard && /\d{2}:\d{2}/.test(r.meta || ''), r.meta);
T('las bajas se ven y dicen que no cuentan', r.bajas > 0 && /anulada/.test(r.bajaChip || ''), r.bajas + ' bajas · chip: ' + r.bajaChip);
T('la baja cuenta su historia (emitida → anulada → baja comunicada)', /Se emitió y SUNAT la aceptó/.test(r.motivoBaja || ''), (r.motivoBaja||'').slice(0,80));
T('el motivo del anulado/rechazo se lee en el card', /Anulada|RECHAZO/i.test(r.motivo), r.motivo.slice(0, 70));
T('la nota aclara que las bajas no suman', /bajas no suman/.test(r.nota));
T('hay leyenda del ciclo arriba de la lista', r.leyenda);
T('los aceptados llevan dos sellos ✓ (NubeFact → SUNAT)', r.sellosOk >= 400, r.sellosOk + ' con doble sello');
// depende de la hora: de día hay boletas en el resumen diario (⏳); tras el cierre de SUNAT todas pasan a ✓
console.log('     boletas en espera ahora: ' + r.sellosEspera + ' (varía con la hora, no se exige)');
T('las bajas llevan el sello baja ⊘', r.sellosBaja >= 11, r.sellosBaja + ' sellos de baja');
T('el semáforo viejo ya no está en los cards', r.semaforo === 0, r.semaforo + ' semáforos');
T('cada card dice quién emitió (👤 vendedor)', r.conVendedor >= 440, r.conVendedor + ' con vendedor');
T('los que tuvieron movimientos traen su historial', r.conHist >= 10, r.conHist + ' con historial');
T('el historial dice quién, cuándo y qué', /anuló|cobró|cambió/.test(r.histEj), r.histEj);
T('los botones son íconos de imagen y PDF, no emojis', r.svgImg > 400 && r.svgPdf > 400, r.svgImg + '/' + r.svgPdf);
T('sin desborde horizontal', r.scrollW <= r.clientW + 1, r.scrollW + '/' + r.clientW);
T('sin errores de JS', errs.length === 0, errs.join(' | '));

await p.screenshot({ path: SH + 'trib_overlay.png', fullPage: false });
await p.setViewportSize({ width: 400, height: 900 }); await p.waitForTimeout(300);
const m = await p.evaluate(`document.documentElement.scrollWidth - document.documentElement.clientWidth`);
T('en celular tampoco desborda', m <= 1, m + 'px');
await p.screenshot({ path: SH + 'trib_overlay_movil.png', fullPage: false });
await b.close();
console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos');
process.exit(bad.length ? 1 : 0);
