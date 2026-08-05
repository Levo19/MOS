// Estudio de Avisos — catálogo agrupado en navegador REAL a 3 viewports.
// Mide: overflow horizontal, deformación de previews (svg fuera del card),
// botones amontonados (overlap), y que el scroll vertical funcione.
const { chromium, webkit } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');
const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const plantillas = JSON.parse(fs.readFileSync(path.join(ROOT, 'browsercheck/_plantillas_dump.json'), 'utf8'));

const HARNESS = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"></head>
<body style="margin:0;background:#0b1220">
<script>window.EDITOR_ADHESIVOS_BASE='/assets/editor-adhesivos/';
window.MOS_API={post:function(action){ if(action==='listarAdhesivosPlantillas') return Promise.resolve({ok:true, plantillas:${JSON.stringify(plantillas)}});
  return Promise.resolve({ok:true}); }};<\/script>
<script src="/assets/editor-adhesivos/iconos.js"><\/script>
<script src="/assets/editor-adhesivos/converter.js"><\/script>
<script src="/assets/editor-adhesivos/editor.js"><\/script>
<script>window.addEventListener('load',function(){ EditorAdhesivos.abrir(); });<\/script>
</body></html>`;

const srv = http.createServer((req, res) => {
  const u = req.url.split('?')[0];
  if (u === '/') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(HARNESS); return; }
  try { const d = fs.readFileSync(path.join(ROOT, u));
    res.writeHead(200, { 'Content-Type': u.endsWith('.css') ? 'text/css' : u.endsWith('.js') ? 'text/javascript' : 'application/octet-stream' });
    res.end(d);
  } catch (_) { res.writeHead(404); res.end('nf'); }
});

const VP = [
  ['movil', 390, 844], ['tablet', 768, 1024], ['pc', 1366, 768]
];

(async () => {
  await new Promise(r => srv.listen(8191, r));
  let ok = 0, fail = 0;
  const t = (n, c, x) => { if (c) { ok++; console.log('  ✅', n); } else { fail++; console.log('  ❌', n, x ?? ''); } };
  for (const [nom, w, h] of VP) {
    const b = await chromium.launch();
    const p = await b.newPage({ viewport: { width: w, height: h } });
    const errs = []; p.on('pageerror', e => errs.push(e.message));
    await p.goto('http://localhost:8191/');
    await p.waitForTimeout(1400);
    const m = await p.evaluate(() => {
      const grid = document.getElementById('ed2Grid');
      const cards = [...document.querySelectorAll('.ed2-card')];
      const grupos = [...document.querySelectorAll('.ed2-grupo')].map(x => x.textContent.trim());
      // ¿algún svg se sale de su card? ¿aspect deformado?
      let svgFuera = 0, svgDeforme = 0;
      cards.forEach(c => {
        const svg = c.querySelector('svg'); if (!svg) return;
        const rc = c.getBoundingClientRect(), rs = svg.getBoundingClientRect();
        if (rs.right > rc.right + 1 || rs.left < rc.left - 1) svgFuera++;
        const vb = svg.getAttribute('viewBox');
        if (vb) { const [, , vw, vh] = vb.split(/\s+/).map(Number);
          const esperado = vw / vh, real = rs.width / rs.height;
          if (isFinite(esperado) && isFinite(real) && Math.abs(esperado - real) / esperado > 0.08) svgDeforme++; }
      });
      // ¿botones amontonados? (se montan entre sí dentro del card)
      let overlap = 0;
      cards.forEach(c => {
        const bs = [...c.querySelectorAll('.ed2-card-acts button')];
        for (let i = 1; i < bs.length; i++) {
          const a = bs[i - 1].getBoundingClientRect(), d = bs[i].getBoundingClientRect();
          if (a.right > d.left + 1 && a.top < d.bottom && a.bottom > d.top) overlap++;
        }
      });
      const panel = grid ? grid.closest('.ed2-overlay') || document.body : document.body;
      return {
        nCards: cards.length, grupos,
        anchoCardMin: Math.round(Math.min(...cards.map(c => c.getBoundingClientRect().width))),
        overflowX: document.documentElement.scrollWidth > window.innerWidth + 1
          || (grid ? grid.scrollWidth > grid.clientWidth + 1 : false),
        scrollVertical: grid ? grid.scrollHeight > grid.clientHeight : false,
        gridAlto: grid ? grid.clientHeight : 0,
        svgFuera, svgDeforme, overlap
      };
    });
    t(`[${nom} ${w}px] pintan las ${plantillas.length} plantillas en grupos`, m.nCards === plantillas.length && m.grupos.length >= 3, JSON.stringify({ n: m.nCards, g: m.grupos }));
    t(`[${nom}] SIN overflow horizontal (nada se sale)`, !m.overflowX);
    t(`[${nom}] previews SIN deformar y dentro del card`, m.svgFuera === 0 && m.svgDeforme === 0, `fuera=${m.svgFuera} deforme=${m.svgDeforme}`);
    t(`[${nom}] botones sin amontonarse`, m.overlap === 0, m.overlap);
    t(`[${nom}] cards con ancho digno (no achicadas a nada)`, m.anchoCardMin >= 140, m.anchoCardMin + 'px');
    t(`[${nom}] hay scroll vertical (la lista larga se desplaza, no se aplasta)`, m.scrollVertical === true, `alto=${m.gridAlto}`);
    t(`[${nom}] sin errores JS`, errs.length === 0, errs.join('|').slice(0, 120));
    await p.screenshot({ path: path.join(ROOT, 'browsercheck', `_estudio_${nom}.png`) });
    await b.close();
  }
  console.log(`\n${fail === 0 ? '✅ TODO OK' : '❌ FALLOS'} — ${ok} pasaron, ${fail} fallaron`);
  srv.close();
  process.exit(fail === 0 ? 0 : 1);
})();
