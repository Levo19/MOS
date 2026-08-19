// [MODO CAJERO v10] El sumidero REAL (extraído del index) ante un QR de CPE que llega letra por letra:
//   · entrega apenas llegó "SERIE | NÚMERO |" (no espera el resto ni el silencio)
//   · la cola del QR que sigue llegando NO dispara una segunda búsqueda
//   · un código de barras (sin |) entrega al Enter, o a 180 ms de silencio si no hay Enter
import { chromium } from 'playwright'; import fs from 'fs';
const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/MosExpress/index.html', 'utf8');
const i0 = src.indexOf('        let _mcSumDrenHasta = 0;'); const i1 = src.indexOf('function mcSumideroEnter()', i0);
const i2 = src.indexOf('\n', i1);
const FN = src.slice(i0, i2);
const ok=[], bad=[]; const T=(n,c,x)=>{ (c?ok:bad).push(n); console.log((c?'  OK  ':'  --  ')+n+(x!=null?'  ·  '+x:'')); };
const b = await chromium.launch(); const p = await b.newPage();
await p.setContent('<!doctype html><body><input id="mcSumidero"><script>' +
  'const mcSumidero={value:document.getElementById("mcSumidero")}; const mcSumideroTxt={value:""}; let _mcSumTimer=null;' +
  'const cajeroBusqueda={value:""}; window.__busq=[]; function buscarTicketCajero(){ window.__busq.push({q:cajeroBusqueda.value,t:Date.now()}); }' +
  'function mcSon(){} function _mcOjoAnota(){}' + FN +
  'const el=document.getElementById("mcSumidero"); el.addEventListener("input",mcSumideroInput); el.addEventListener("keyup",e=>{ if(e.key==="Enter") mcSumideroEnter(); }); el.focus();</script></body>');
const QR = '20602634177|01|FM02|000079|4.58|30.00|2026-08-19|6|20123456789|AbCdEf=|';
const t0 = Date.now();
let tNum=0, tFin=0; for (let k=0;k<QR.length;k++) { await p.keyboard.type(QR[k]); if (k===26) tNum=Date.now(); await p.waitForTimeout(25); } tFin=Date.now();
await p.waitForTimeout(700);
let r = await p.evaluate(() => window.__busq);
T('el QR entrega UNA sola búsqueda', r.length === 1, JSON.stringify(r.map(x=>x.q)));
T('entregó apenas llegó el "|" tras el número (≤ 80 ms después), mucho antes de que terminara el QR',
  r.length && (r[0].t - tNum) <= 80 && r[0].t < tFin - 500, r.length ? (r[0].t - tNum) + ' ms tras el número · ' + (tFin - r[0].t) + ' ms antes del fin' : '');
T('lo entregado contiene serie y número', r.length && /FM02\|000079/.test(r[0].q));
// código de barras sin Enter → silencio 180 ms
await p.waitForTimeout(1000);
await p.evaluate(() => { window.__busq = []; });
for (const ch of 'NVM2-000531') { await p.keyboard.type(ch); await p.waitForTimeout(25); }
await p.waitForTimeout(350);
r = await p.evaluate(() => window.__busq);
T('código de barras sin Enter: entrega tras el silencio', r.length === 1 && r[0].q === 'NVM2-000531', JSON.stringify(r));
// con Enter → inmediato
await p.waitForTimeout(1000);
await p.evaluate(() => { window.__busq = []; });
for (const ch of 'BM01-000335') { await p.keyboard.type(ch); await p.waitForTimeout(25); }
const tE = Date.now(); await p.keyboard.press('Enter'); await p.waitForTimeout(60);
r = await p.evaluate(() => window.__busq);
T('con Enter entrega de inmediato (<60 ms)', r.length === 1 && r[0].q === 'BM01-000335' && (r[0].t - tE) < 60, JSON.stringify(r));
await b.close();
console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos'); process.exit(bad.length ? 1 : 0);
