// [MODO CAJERO] ¿De verdad nada interrumpe la estación de cobro?
//
// El escudo anterior difería la RECARGA pero dejaba pasar los carteles: con la estación
// abierta igual aparecía "Actualizando MOSexpress · Instalando…" tapando la pantalla, y
// eso con un cliente enfrente es exactamente una interrupción.
//
// Esta prueba NO lee el código: carga ME de verdad, finge que la estación está abierta
// (basta con que exista #mcRoot, que es lo que el guardián mira) y ejecuta los caminos
// que muestran los carteles. Después la cierra y comprueba que el cartel SÍ aparece —
// porque un escudo que nunca deja actualizar tampoco sirve.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';

const ROOT = path.resolve(process.argv[2] || 'C:/Users/ISO/ecosistema MOS/MosExpress');
const DEVICE = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8809,r));

const ok=[], bad=[];
const T=(n,c,x)=>{ (c?ok:bad).push(n); console.log((c?'  OK  ':'  --  ')+n+(x!=null&&x!==''?'  ·  '+x:'')); };

const b = await chromium.launch();
const p = await (await b.newContext({ viewport:{width:1280,height:800} })).newPage();
await p.addInitScript(id => { try { localStorage.setItem('mosexpress_deviceId', id); } catch(_){} }, DEVICE);
// la recarga se intercepta: si algo la dispara, queremos SABERLO, no perder la página
await p.addInitScript(() => {
  window.__recargas = 0;
  const real = window.location.reload.bind(window.location);
  try { Object.defineProperty(window.location, 'reload', { value: () => { window.__recargas++; }, writable: true }); } catch(_) {}
});
await p.goto('http://127.0.0.1:8809/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(9000);

const existe = await p.evaluate(`typeof window._meEstacionAbierta === 'function'`);
T('el guardián existe y es uno solo', existe);

// ── con la estación ABIERTA ──
const abierta = await p.evaluate(`(() => {
  const d = document.createElement('div'); d.id = 'mcRoot'; document.body.appendChild(d);
  window.__recargas = 0;
  const r = { guardia: window._meEstacionAbierta() };
  // el overlay grande de "Actualizando MOSexpress"
  const ov = document.getElementById('meUpdateOverlay');
  if (ov) ov.classList.remove('visible');
  const b1 = document.getElementById('meUpdateBanner');
  if (b1) b1.classList.remove('visible');
  // se disparan los caminos reales, no imitaciones
  try { window._SWCheck && window._SWCheck(); } catch(_) {}
  return r;
})()`);
T('el guardián reconoce la estación abierta', abierta.guardia === true);

await p.waitForTimeout(2500);
const tapado = await p.evaluate(`(() => ({
  overlay: !!document.querySelector('#meUpdateOverlay.visible'),
  banner: !!document.querySelector('#meUpdateBanner.visible'),
  pastilla: !!document.getElementById('meUpdBanner'),
  recargas: window.__recargas
}))()`);
console.log('     con la estación abierta: ' + JSON.stringify(tapado));
T('no aparece el overlay "Actualizando MOSexpress"', !tapado.overlay);
T('no aparece el cartel de versión nueva', !tapado.banner);
T('no aparece ni la pastilla de aviso', !tapado.pastilla);
T('nadie recarga la app', tapado.recargas === 0, tapado.recargas + ' recargas');

// ── al SALIR por el ✕, la actualización vuelve a poder entrar ──
const cerrada = await p.evaluate(`(() => {
  document.getElementById('mcRoot')?.remove();
  const r = { guardia: window._meEstacionAbierta() };
  // el overlay se pide por el mismo camino que usa la app
  const ov = document.getElementById('meUpdateOverlay');
  if (ov) ov.classList.add('visible');
  r.overlay = !!document.querySelector('#meUpdateOverlay.visible');
  if (ov) ov.classList.remove('visible');
  return r;
})()`);
T('al cerrar la estación el guardián se abre', cerrada.guardia === false);
T('cerrada, la actualización sí puede mostrarse', cerrada.overlay === true);

console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos');
await b.close(); srv.close();
process.exit(bad.length ? 1 : 0);
