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
  const d = await p.evaluate(()=>{
    const card=document.querySelector('.ed2-card');
    const body=card?.querySelector('.ed2-card-body');
    const acts=card?.querySelector('.ed2-card-acts');
    const grid=document.getElementById('ed2Grid');
    const ov=document.querySelector('.ed2-overlay');
    const cs=el=>el?{h:el.getBoundingClientRect().height,disp:getComputedStyle(el).display,ovf:getComputedStyle(el).overflow}:null;
    return { card:cs(card), body:cs(body), acts:cs(acts), grid:cs(grid),
      gridRows:getComputedStyle(grid).gridAutoRows, gridTemplateRows:getComputedStyle(grid).gridTemplateRows.slice(0,80),
      ovH:ov?ov.getBoundingClientRect().height:0, ovPos:ov?getComputedStyle(ov).position:'',
      cardHTML: card?card.outerHTML.slice(0,500):'' };
  });
  console.log(JSON.stringify(d,null,1));
  const d2 = await p.evaluate(()=>{
    const card=document.querySelector('.ed2-card');
    const r=el=>el?{t:Math.round(el.getBoundingClientRect().top),h:Math.round(el.getBoundingClientRect().height),w:Math.round(el.getBoundingClientRect().width)}:null;
    const cs=getComputedStyle(card);
    return { card:r(card), th:r(card.querySelector('.ed2-card-th')), holder:r(card.querySelector('.ed2-th-holder')),
      svg:r(card.querySelector('svg')), body:r(card.querySelector('.ed2-card-body')),
      csH:cs.height, csMinH:cs.minHeight, anim:cs.animationName, gridAlignItems:getComputedStyle(document.getElementById('ed2Grid')).alignItems,
      svgAttrs:(function(){const s2=card.querySelector('svg');return s2?{w:s2.getAttribute('width'),h:s2.getAttribute('height'),vb:s2.getAttribute('viewBox'),styleH:s2.style.height}:null})() };
  });
  console.log('DETALLE:', JSON.stringify(d2,null,1));
  await b.close(); srv.close();
})();
