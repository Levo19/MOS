// Verifica que el bloque @media(pointer:coarse) del 844 realmente aplique, sobre el árbol LOCAL.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.argv[2]);
const MIME = { '.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json',
               '.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon' };
const srv = http.createServer((req,res)=>{ let u=decodeURIComponent(req.url.split('?')[0]); if(u==='/')u='/index.html';
  const f=path.join(ROOT,u);
  if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){res.writeHead(404);return res.end('no');}
  res.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'}); res.end(fs.readFileSync(f)); });
await new Promise(r=>srv.listen(8793,r));
const b = await chromium.launch();
const ctx = await b.newContext({ viewport:{width:393,height:852}, hasTouch:true, isMobile:true, deviceScaleFactor:2 });
const p = await ctx.newPage();
await p.addInitScript(dev=>localStorage.setItem('mos_device_id',dev),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8793/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(6000);
try { await p.click('text=/Entrar a MOS/i', { timeout:4000 }); } catch {}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});
console.log('  pointer:coarse activo →', await p.evaluate(()=>matchMedia('(pointer: coarse)').matches));
await p.evaluate(()=>MOS.nav('finanzas'));
await p.waitForTimeout(15000);
await p.evaluate(()=>{try{MOS.finAbrirModalProductos();}catch(e){}});
await p.waitForTimeout(2500);
await p.evaluate(()=>{const r=[...document.querySelectorAll('.fin-prod-row')].find(x=>/LEV024/.test(x.textContent))||document.querySelector('.fin-prod-row'); if(r)r.click();});
await p.waitForTimeout(6000);
await p.evaluate(()=>{const t=document.querySelector('.fpd-tk'); if(t)t.click();});
await p.waitForTimeout(6000);
const doc = await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth);
const m = await p.evaluate(()=>{
  const o={};
  const area=(s)=>{const el=document.querySelector(s); if(!el) return 'ausente';
    const r=el.getBoundingClientRect(); let h=r.height,w=r.width;
    const a=getComputedStyle(el,'::after');
    if(a && a.content==='""' && a.position==='absolute'){
      const t=parseFloat(a.top)||0, bt=parseFloat(a.bottom)||0, l=parseFloat(a.left)||0, rt=parseFloat(a.right)||0;
      h=r.height-t-bt; w=r.width-l-rt; }
    return Math.round(w)+'x'+Math.round(h)+(h<34?'  ⚠ chico':'  ✅'); };
  ['.fin-mg-btn','.fpd-tk','.fpd-tk-mini','.ftk-x'].forEach(s=>o[s]=area(s)); return o; });
Object.entries(m).forEach(([k,v])=>console.log('  '+k.padEnd(16)+v));
console.log('  desborde horizontal →', doc>1 ? ('❌ '+doc+'px') : '✅ 0px');
await b.close(); srv.close();
