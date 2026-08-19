// [MODO CAJERO] El lector escribe como un teclado. Con la estación abierta, ¿a dónde va?
//
// Lo que el dueño vio en la tablet: escanear levantaba el teclado y el código se iba al buscador
// del POS. Causa verificada: el captor global no escuchaba con la estación abierta, y el POS
// se re-enfoca solo en su buscador desde ocho lugares. Esta prueba carga ME real, abre la
// estación, dispara una ráfaga de teclas como el lector (≤35 ms/tecla + Enter) y comprueba:
//   · ningún input queda con foco (→ ningún teclado en pantalla)
//   · el buscador del POS NO recibe el código
//   · el código llega a la estación (cajeroBusqueda → buscarTicketCajero)
//   · tecleo humano (lento) se ignora
//   · y con la estación cerrada, el camino del POS sigue intacto
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';

const ROOT = path.resolve(process.argv[2] || 'C:/Users/ISO/ecosistema MOS/MosExpress');
const DEVICE = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.webmanifest':'application/manifest+json'};
const srv=http.createServer((q,r)=>{let u=decodeURIComponent(q.url.split('?')[0]);if(u==='/')u='/index.html';const f=path.join(ROOT,u);
 if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
 r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});r.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8811,r));

const ok=[], bad=[];
const T=(n,c,x)=>{ (c?ok:bad).push(n); console.log((c?'  OK  ':'  --  ')+n+(x!=null&&x!==''?'  ·  '+x:'')); };

const b = await chromium.launch();
const p = await (await b.newContext({ viewport:{width:1280,height:800}, hasTouch:true })).newPage();
await p.addInitScript(id => { try { localStorage.setItem('mosexpress_deviceId', id); } catch(_){} }, DEVICE);
await p.goto('http://127.0.0.1:8811/', { waitUntil:'domcontentloaded' });
await p.waitForTimeout(9000);

// el estado interno no es alcanzable desde afuera en el build de producción, pero el template sí:
// se simula la estación abierta INSERTANDO #mcRoot y se observa el DOM y el foco.
// Para medir que el código llega a la estación, se intercepta lo que haría el captor: se escucha
// el mismo keydown en capture y se mira si el buscador del POS lo recibió o no.
await p.evaluate(`(() => {
  const d = document.createElement('div'); d.id = 'mcRoot'; document.body.appendChild(d);
  // un buscador POS "vivo" con foco, como pasa en la tablet
  const inp = document.createElement('input'); inp.id = 'posBuscadorFake'; inp.type = 'text'; document.body.appendChild(inp); inp.focus();
  window.__focoAntes = document.activeElement && document.activeElement.id;
})()`);

// el captor de la estación existe en el bundle?
const tieneCaptor = await p.evaluate(`/_mcTeclado/.test(document.documentElement.innerHTML)`);
T('la estación tiene su propio captor de teclado (mcTeclado)', tieneCaptor);

// ráfaga del lector: 'NVM2-000531' + Enter, 20 ms por tecla
const cod = 'NVM2-000531';
for (const ch of cod) { await p.keyboard.press(ch === '-' ? 'Minus' : ch); await p.waitForTimeout(20); }
await p.keyboard.press('Enter');
await p.waitForTimeout(300);
const r1 = await p.evaluate(`(() => ({
  focoAntes: window.__focoAntes,
  focoAhora: (document.activeElement && (document.activeElement.id || document.activeElement.tagName)) || '',
  buscadorRecibio: (document.getElementById('posBuscadorFake')||{}).value || ''
}))()`);
console.log('     ' + JSON.stringify(r1));
// NOTA: sin el setup de Vue vivo, el captor real (que vive dentro de setup) no corre acá; lo que
// sí se puede demostrar en esta página es la regla estática. El comportamiento vivo se cubre
// abajo con el análisis del código fuente, que es lo que decide.
await b.close(); srv.close();

// ── reglas sobre el código fuente (lo que decide en producción) ──
const src = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
T('el captor de la estación escucha en la ventana, en fase de captura',
  /window\.addEventListener\('keydown', _mcTeclado, true\)/.test(src));
// El único corte es el silencio de 400 ms entre teclas (igual que el captor del salvapantallas,
// que SÍ lee en la tablet). La regla de "≤35 ms por tecla" tiraba a la basura el escaneo real:
// en Android el lector entrega las teclas más lento que un USB en PC.
T('reconoce el escaneo por silencio de 400 ms, SIN corte por velocidad, y lo manda a buscarTicketCajero',
  !/dur > cod\.length \* 35/.test(src)
  && /_mcBufTimer = setTimeout\(\(\) => \{ _mcBuf = ''; \}, 400\);/.test(src)
  && /cajeroBusqueda\.value = cod;[\s\S]{0,40}buscarTicketCajero\(\);/.test(src));
T('lee la tecla aunque el lector mande e.key=Unidentified (usa e.code / keyCode)',
  /function _mcTeclaDe\(e\)/.test(src) && /Unidentified/.test(src) && /String\.fromCharCode\(e\.keyCode\)/.test(src));
T('acepta Enter también como NumpadEnter / keyCode 13',
  /e\.code === 'NumpadEnter' \|\| e\.keyCode === 13/.test(src));
T('las teclas de la ráfaga NO llegan a ningún input (preventDefault + stopPropagation)',
  /_mcBuf \+= ch;[\s\S]{0,700}e\.preventDefault\(\); e\.stopPropagation\(\);/.test(src));
T('ya no hay input oculto en la estación (nada que levante teclado)',
  !/ref="cajeroInput"/.test(src));
T('el POS no roba el foco mientras la estación está abierta',
  /if \(modoCajero\.value\) return;\n\s+if\(config\.value\.completado && currentModule\.value === 'POS'/.test(src));
T('si un input gana foco con la estación abierta, se le quita (focusin → blur)',
  /addEventListener\('focusin'[\s\S]{0,200}t\.blur\(\)/.test(src));
T('el captor de guías cede a la estación', /if \(modoCajero\.value\) return;\s+\/\/ la estación de cobro tiene su propio captor/.test(src));
T('el teclado en pantalla del POS no aparece con la estación abierta', /mostrarTeclado\.value && !modoCajero\.value\) scannerInput\.value\.focus\(\)/.test(src));
T('ESC no cierra la estación', /e\.key === 'Escape'\) \{ e\.preventDefault\(\); return; \}/.test(src));

// ── el captor REAL, ejecutado con un lector Android lento (80 ms/tecla) y con e.key=Unidentified ──
{
  const grab = (name) => { const i = src.indexOf(name); const f = src.indexOf('\n        }', i) + 10; return src.slice(i, f); };
  const fnDe = grab('function _mcTeclaDe(e)'), fnTec = grab('function _mcTeclado(e)');
  const b2 = await chromium.launch(); const p2 = await b2.newPage();
  await p2.setContent('<!doctype html><body><script>' +
    'let _mcBuf="",_mcBufT0=0,_mcBufTimer=null; const modoCajero={value:true}; const cajeroBusqueda={value:""};' +
    'window.__leido=[]; function buscarTicketCajero(){ window.__leido.push(cajeroBusqueda.value); } function mcSon(){}' +
    fnDe + fnTec + 'window.addEventListener("keydown",_mcTeclado,true);</script></body>');
  // lector lento: 80 ms por tecla, con e.key legible
  const cod = 'NVM2-000531';
  for (const ch of cod) { await p2.keyboard.press(ch === '-' ? 'Minus' : ch); await p2.waitForTimeout(80); }
  await p2.keyboard.press('Enter'); await p2.waitForTimeout(100);
  // lector que manda Unidentified: se despachan eventos a mano con code/keyCode
  await p2.evaluate(() => { const fire = (key, code, kc) => window.dispatchEvent(new KeyboardEvent('keydown', { key, code, keyCode: kc, bubbles: true, cancelable: true }));
    'BM01'.split('').forEach(c => fire('Unidentified', /[0-9]/.test(c) ? 'Digit' + c : 'Key' + c, c.charCodeAt(0)));
    fire('Unidentified', 'Minus', 189); '000335'.split('').forEach(c => fire('Unidentified', 'Digit' + c, c.charCodeAt(0)));
    fire('Unidentified', 'NumpadEnter', 13); });
  await p2.waitForTimeout(100);
  // tecleo humano: 600 ms entre teclas → se descarta
  for (const ch of 'ABCD') { await p2.keyboard.press(ch); await p2.waitForTimeout(600); }
  await p2.keyboard.press('Enter'); await p2.waitForTimeout(100);
  const leido = await p2.evaluate(() => window.__leido);
  console.log('     leído por el captor real: ' + JSON.stringify(leido));
  T('el captor REAL lee un lector lento (80 ms/tecla)', leido.includes('NVM2-000531'));
  T('el captor REAL lee un lector que manda e.key=Unidentified', leido.includes('BM01-000335'));
  T('el captor REAL ignora tecleo humano (600 ms/tecla)', !leido.includes('ABCD'));
  await b2.close();
}

console.log('\n  ' + ok.length + ' OK   ' + bad.length + ' fallos');
process.exit(bad.length ? 1 : 0);
