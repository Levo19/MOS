// Boot-check fuerte de ME: Vue tiene que MONTAR. La señal no es el tamaño del DOM (un template
// crudo también es grande) sino que no quede ni un mustache sin procesar.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.argv[2]);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8797,r));
const b=await chromium.launch(); const p=await (await b.newContext({viewport:{width:420,height:900}})).newPage();
const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.goto('http://127.0.0.1:8797/',{waitUntil:'domcontentloaded'});
await p.waitForTimeout(9000);
const r = await p.evaluate(()=>({
  mustaches: document.body.innerHTML.split('{'+'{').length - 1,
  vue: !!document.querySelector('#app')?.__vue_app__ || !!window.__VUE__ || document.body.innerHTML.length > 5000,
  txt: document.body.innerText.slice(0,90).replace(/\s+/g,' ')
}));
console.log('  mustaches sin procesar: ' + r.mustaches + (r.mustaches===0?'  ✅':'  ❌ Vue NO montó'));
console.log('  pantalla: "' + r.txt + '"');
console.log('  errores de página: ' + (errs.length? errs.slice(0,3).join(' | ') : 'ninguno'));
await b.close(); srv.close();
process.exit((r.mustaches===0 && errs.length===0) ? 0 : 1);
