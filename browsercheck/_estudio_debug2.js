const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');
const ROOT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS';
const plantillas = JSON.parse(fs.readFileSync(path.join(ROOT, 'browsercheck/_plantillas_dump.json'), 'utf8'));
const HARNESS = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:#0b1220">
<script>window.EDITOR_ADHESIVOS_BASE='/assets/editor-adhesivos/';
window.MOS_API={post:function(a){ if(a==='listarAdhesivosPlantillas') return Promise.resolve({ok:true, plantillas:${JSON.stringify(plantillas)}});
  return Promise.resolve({ok:true}); }};<\/script>
<script src="/assets/editor-adhesivos/iconos.js"><\/script>
<script src="/assets/editor-adhesivos/converter.js"><\/script>
<script src="/assets/editor-adhesivos/editor.js"><\/script>
<script>window.addEventListener('load',function(){ EditorAdhesivos.abrir(); });<\/script></body></html>`;
const srv = http.createServer((req, res) => {
  const u = req.url.split('?')[0];
  if (u === '/') { res.writeHead(200, {'Content-Type':'text/html'}); res.end(HARNESS); return; }
  try { const d = fs.readFileSync(path.join(ROOT, u));
    res.writeHead(200, {'Content-Type': u.endsWith('.css')?'text/css':u.endsWith('.js')?'text/javascript':'application/octet-stream'}); res.end(d);
  } catch(_){ res.writeHead(404); res.end('nf'); }
});
(async()=>{
  await new Promise(r=>srv.listen(8191,r));
  const b = await chromium.launch();
  const p = await b.newPage({ viewport:{width:390,height:844} });
  await p.goto('http://localhost:8191/'); await p.waitForTimeout(1400);
  const probar = (nombre, fn) => p.evaluate(fn).then(h => console.log(nombre, '→ card', h, 'px'));
  const alturaCard = () => Math.round(document.querySelector('.ed2-card').getBoundingClientRect().height);
  await probar('base', alturaCard);
  await probar('FIX grid-auto-rows:max-content (con cabeceras)', () => { const g=document.getElementById('ed2Grid'); g.style.gridAutoRows='max-content'; return Math.round(document.querySelector('.ed2-card').getBoundingClientRect().height); });
  await probar('y ¿scrollea?', () => { const g=document.getElementById('ed2Grid'); return g.scrollHeight > g.clientHeight ? 1 : 0; });
  await probar('sin animación', () => { document.querySelectorAll('.ed2-card').forEach(c => { c.style.animation='none'; c.style.opacity='1'; }); return Math.round(document.querySelector('.ed2-card').getBoundingClientRect().height); });
  await probar('sin cabeceras de grupo', () => { document.querySelectorAll('.ed2-grupo').forEach(x => x.remove()); return Math.round(document.querySelector('.ed2-card').getBoundingClientRect().height); });
  await probar('align-content start forzado', () => { const g=document.getElementById('ed2Grid'); g.style.alignContent='start'; return Math.round(document.querySelector('.ed2-card').getBoundingClientRect().height); });
  const ac = await p.evaluate(() => getComputedStyle(document.getElementById('ed2Grid')).alignContent);
  console.log('align-content computado:', ac);
  const cssRules = await p.evaluate(() => {
    const out=[];
    for (const sh of document.styleSheets) { try { for (const r of sh.cssRules) {
      if (r.selectorText && /ed2-card(?![-\w])|ed2-grid/.test(r.selectorText)) out.push(r.cssText.slice(0,150)); } } catch(_){} }
    return out;
  });
  console.log(cssRules.join('\n'));
  await b.close(); srv.close();
})();
