import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT=path.resolve('C:/Users/ISO/ecosistema MOS/MosExpress');
const M={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':M[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8806,r));
const b=await chromium.launch(); const p=await (await b.newContext()).newPage();
await p.addInitScript(()=>localStorage.setItem('mosexpress_deviceId','e60bf699-ae5a-4a9f-8ee0-05c58a1cbfd5'));
await p.goto('http://127.0.0.1:8806/',{waitUntil:'domcontentloaded'}); await p.waitForTimeout(16000);
console.log(await p.evaluate(()=>{
  const el=document.querySelector('#app');
  const out={ hayApp:!!el, vueApp:!!(el&&el.__vue_app__) };
  if(el&&el.__vue_app__) out.instance = !!el.__vue_app__._instance;
  // buscar __vueParentComponent en cualquier nodo del arbol
  let n=null;
  for(const x of document.querySelectorAll('#app *')){ if(x.__vueParentComponent){ n=x; break; } }
  out.nodoConComp = !!n;
  if(n){ out.proxyOk = !!n.__vueParentComponent.proxy;
         out.tieneModo = n.__vueParentComponent.proxy && 'abrirModoCajero' in n.__vueParentComponent.proxy; }
  out.claves = el && el.__vue_app__ ? Object.keys(el.__vue_app__).slice(0,14) : [];
  out.appId = el ? el.id : '';
  out.mountEl = document.querySelector('[data-v-app]') ? 'data-v-app' : '';
  out.tipoInst = typeof (el.__vue_app__ && el.__vue_app__._instance);
  out.pantalla = (document.body.innerText||'').replace(/\s+/g,' ').slice(0,110);
  out.nApps = document.querySelectorAll('[data-v-app]').length;
  return out;
}));
await b.close(); srv.close();
