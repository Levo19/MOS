// [MODO CAJERO v14] ligereza: el haz con sprites (nuevo) vs shadowBlur (viejo) — costo por frame con 30 hilos
import { chromium } from 'playwright'; import fs from 'fs';
const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosExpress/index.html','utf8');
const i = src.indexOf('        function _mcGlow(r, col) {'); const f = src.indexOf('\n        }', i) + 10; const FN = src.slice(i, f);
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  OK  ':'  --  ')+n+(x!=null?'  ·  '+x:''));};
T('los satélites ya no llevan backdrop-filter (30 desenfoques de fondo por frame)', !/#mcRoot \.mc-tk\{[^}]*backdrop-filter/.test(src) && !/#mcRoot \.mc-yp\{[^}]*backdrop-filter/.test(src));
T('las órbitas animan translate (compuesto), no margin (layout)', /@keyframes mcOrbFlota\{0%\{translate:0 0\}100%\{translate:6px 0\}\}/.test(src) && !/@keyframes mcOrbFlota\{0%\{margin-left/.test(src));
T('el haz ya no usa shadowBlur (brillo por sprite)', !/shadowBlur = 14|shadowBlur = 22|shadowBlur = 26/.test(src) && /drawImage\(_mcGlowChico/.test(src) && /drawImage\(_mcGlowGrande/.test(src));
T('el canvas del haz solo se limpia cuando hay algo que dibujar', /const hayHaz = /.test(src) && /_mcHazSucio/.test(src));
T('la voz: resume() si quedó en pausa y cancela atascos de >20 s', /speechSynthesis\.paused\) speechSynthesis\.resume\(\)/.test(src) && /Date\.now\(\) - _ttsUltimo > 20000/.test(src));
const b = await chromium.launch(); const p = await b.newPage();
await p.setContent('<canvas id="c" width="1280" height="800"></canvas>');
const r = await p.evaluate('(() => {' + FN + `
  const hx = document.getElementById('c').getContext('2d');
  const glow = _mcGlow(10, ['rgba(233,213,255,.95)', 'rgba(176,123,255,.55)']);
  const sin = Array.from({length:30},(_,k)=>({x1:100+k*30,y1:100,x2:1100-k*20,y2:700,f:k*.37}));
  const frame = (modo) => { hx.clearRect(0,0,1280,800); const fase=(performance.now()/1400)%1;
    sin.forEach(sn => { const mx=(sn.x1+sn.x2)/2, my=(sn.y1+sn.y2)/2; hx.beginPath(); hx.moveTo(sn.x1,sn.y1); hx.quadraticCurveTo(mx,my,sn.x2,sn.y2); hx.strokeStyle='rgba(176,123,255,.28)'; hx.lineWidth=1.2; hx.stroke();
      for (let k=0;k<2;k++){ const t=(fase+sn.f+k*.5)%1,u=1-t; const px=u*u*sn.x1+2*u*t*mx+t*t*sn.x2, py=u*u*sn.y1+2*u*t*my+t*t*sn.y2;
        if (modo==='viejo'){ hx.beginPath(); hx.arc(px,py,2.6,0,7); hx.fillStyle='rgba(233,213,255,.95)'; hx.shadowColor='#b07bff'; hx.shadowBlur=14; hx.fill(); hx.shadowBlur=0; }
        else hx.drawImage(glow, px-10, py-10); } }); };
  const mide = (modo) => { const t0=performance.now(); for (let n=0;n<40;n++) frame(modo); return (performance.now()-t0)/40; };
  mide('nuevo'); mide('viejo');
  return { viejo: mide('viejo'), nuevo: mide('nuevo'), glowOk: glow.width===20 };})()`);
console.log('     ms/frame con 30 hilos · viejo(shadowBlur)=' + r.viejo.toFixed(2) + ' · nuevo(sprite)=' + r.nuevo.toFixed(2));
T('el sprite de brillo se crea (20×20) y el frame nuevo corre sin error (el costo real se mide en GPU móvil, no en headless)', r.glowOk && isFinite(r.nuevo));
await b.close();
console.log('\n  '+ok.length+' OK   '+bad.length+' fallos'); process.exit(bad.length?1:0);
