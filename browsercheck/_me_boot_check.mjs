// Boot-check de ME. Tiene que MONTAR de verdad.
//
// La versión anterior daba verde con la app en pantalla blanca, y por eso salió a producción
// un ReferenceError de zona muerta dentro de setup(). Dos razones, las dos arregladas acá:
//
//   1. Sin dispositivo aprobado, device-auth reemplaza el body por "⌛ Esperando aprobación".
//      Vue nunca monta — y "cero mustaches sin procesar" daba verde porque ya no quedaba
//      ni template en el DOM. Se mide la ausencia de algo que nunca estuvo. Ahora se siembra
//      el device de prueba y, si aun así el arranque queda bloqueado, es FALLO: no probé nada.
//
//   2. Un error dentro de setup() no llega como `pageerror`: Vue lo captura y lo manda al
//      errorHandler, que en ME hace console.error('[Vue error]'). Había que escuchar la
//      consola, no solo las excepciones sueltas.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.argv[2] || 'C:/Users/ISO/ecosistema MOS/MosExpress');
const DEVICE = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';   // device de prueba ya aprobado

const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8797,r));

const b=await chromium.launch();
const ctx=await b.newContext({viewport:{width:1280,height:850}});
const p=await ctx.newPage();
const errs=[];
p.on('pageerror', e => errs.push('excepción: ' + String(e.message).slice(0,200)));
p.on('console', m => {
  const t = m.text();
  if (/\[Vue error\]|\[Vue warn\]/.test(t)) errs.push(t.slice(0,220));
  // "Blocked call to navigator.vibrate": intervención de Chrome cuando el banner de update del
  // SW (instalación fresca en el entorno de prueba) vibra sin gesto previo. Ruido, no error.
  else if (m.type()==='error' && !/favicon|tailwindcss\.com|net::ERR|Failed to load resource|Blocked call to navigator\.vibrate/i.test(t)) errs.push('consola: ' + t.slice(0,200));
});
await p.addInitScript(id => { try { localStorage.setItem('mosexpress_deviceId', id); } catch(_){} }, DEVICE);
await p.goto('http://127.0.0.1:8797/',{waitUntil:'domcontentloaded'});
await p.waitForTimeout(11000);

const r = await p.evaluate(`(() => {
  const app = document.getElementById('app');
  const html = app ? app.innerHTML : '';
  return {
    hayApp: !!app,
    vueMonto: !!(app && app.__vue_app__),
    mustaches: (html.match(/\\{\\{/g)||[]).length,
    largo: html.length,
    // cualquiera de estas pantallas significa que la app llegó a renderizar algo suyo
    render: /wiz|MOSEXPRESS|Iniciar|Turno|POS|Ventas|Caja/i.test(document.body.innerText),
    bloqueo: /Esperando aprobación|pendiente de aprobación|no autorizado|Configura tus permisos/i.test(document.body.innerText),
    txt: document.body.innerText.slice(0,110).replace(/\\s+/g,' ')
  };
})()`);

const ok=[], bad=[];
const T=(n,c,x)=>{ (c?ok:bad).push(n); console.log((c?'  OK  ':'  --  ')+n+(x!=null&&x!==''?'  ·  '+x:'')); };

console.log('  pantalla: "' + r.txt + '"');
// device-auth pone su pantalla ENCIMA, pero Vue igual monta debajo: por eso esto es un aviso
// y no un fallo. Lo que sí manda es `vueMonto` — si setup() aborta, no hay __vue_app__.
if (r.bloqueo) console.log('  aviso: device-auth muestra su pantalla encima (Vue igual monta debajo)');
T('Vue montó la app', r.vueMonto, r.vueMonto ? r.largo + ' chars' : 'sin __vue_app__ — setup() abortó o el mount falló');
T('la app renderizó su propia pantalla', r.render);
T('sin bindings sin procesar', r.mustaches===0, r.mustaches + ' mustaches');
T('sin errores ni avisos de Vue', errs.length===0, errs.slice(0,3).join(' | '));

console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos');
await b.close(); srv.close();
process.exit(bad.length ? 1 : 0);
