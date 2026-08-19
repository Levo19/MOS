// [877] turno.html: sello de verificación en tickets virtuales + sección "Virtuales sin verificar" (HTML, WA, ESC/POS)
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve('C:/Users/ISO/ecosistema MOS/ProyectoMOS');
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8804,r));
const ok=[],bad=[]; const T=(n,c,x)=>{(c?ok:bad).push(n);console.log((c?'  OK  ':'  --  ')+n+(x?'  ·  '+x:''));};
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:480,height:900}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8804/turno.html?idCaja=CAJA-1787141488068',{waitUntil:'domcontentloaded'});
await p.waitForFunction(()=>!!window._turnoData,{timeout:60000});
const r = await p.evaluate(()=>{
  const d=window._turnoData; const cob=d.cobrados||[]; const vs=cob.filter(t=>{const m=String(t.metodo||'').toUpperCase();return m==='VIRTUAL'||m.startsWith('MIXTO');});
  const conY=vs.filter(t=>t.yape&&typeof t.yape==='object').length;
  const sellos=[...document.querySelectorAll('.tk-card .badge')].map(b=>b.textContent.trim()).filter(t=>/verificado|sin verificar/.test(t));
  const sec=document.getElementById('sec-virtsv'); const hdr=sec && sec.previousElementSibling ? sec.previousElementSibling.textContent.replace(/\s+/g,' ').trim() : '';
  const wa=(typeof buildWhatsapp==='function'?buildWhatsapp(d):(typeof buildWaText==='function'?buildWaText(d):''))||'';
  if (typeof buildPrintTicket==='function') buildPrintTicket(d); const esc=(document.getElementById('pkt-pre')||{}).textContent||'';
  return { virt:vs.length, conY, sellosOk:sellos.filter(t=>/✅/.test(t)).length, sellosNo:sellos.filter(t=>/sin verificar/.test(t)).length, hdr,
           escTiene:/VIRTUALES SIN VERIFICAR/.test(String(esc)), escVerif:/CON YAPE VERIFICADO/.test(String(esc)), escImpago:/sin verificar no es impago/.test(String(esc)) };
});
console.log('     '+JSON.stringify(r));
T('la caja tiene cobros virtuales con datos de Yape (me.datos_turno trae tk.yape)', r.virt>0);
T('cada ticket virtual lleva su sello: ✅ verificado (los que tienen Yape) o ◌ sin verificar', r.sellosOk===r.conY && r.sellosNo===2*(r.virt-r.conY) /* la lista + la sección repiten la card */, `virt ${r.virt} · ok ${r.sellosOk} · no ${r.sellosNo} (x2)`);
T('existe la sección "📱 Virtuales sin verificar" con el conteo y los verificados', /Virtuales sin verificar/.test(r.hdr) && /verificado/.test(r.hdr), r.hdr.slice(0,80));
T('el ticket físico (ESC/POS) trae la parte VIRTUALES SIN VERIFICAR con la lista y la nota', r.escTiene && r.escVerif && (r.virt===r.conY || r.escImpago));
T('sin errores de página', errs.length===0, errs.join(' | '));
await p.screenshot({path:'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_turno_sello_yape.png', fullPage:false});
await b.close(); srv.close();
console.log('\n  '+ok.length+' OK   '+bad.length+' fallos'); process.exit(bad.length?1:0);
