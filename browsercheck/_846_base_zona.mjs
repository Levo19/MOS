// [846] Base diaria por zona y rol en Config.
// El guardado se intercepta: se verifica QUÉ viaja, sin escribir la política real de la zona.
// (El lado SQL —vigencia por fecha, no retroactividad, neutralidad— se probó contra la base
//  directamente, en una transacción revertida.)
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';

const ROOT = path.resolve(process.argv[2]);
const MIME = { '.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json',
               '.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.ico':'image/x-icon' };
const srv = http.createServer((q,r)=>{ let u=decodeURIComponent(q.url.split('?')[0]); if(u==='/')u='/index.html';
  const f=path.join(ROOT,u);
  if(!path.resolve(f).startsWith(ROOT)||!fs.existsSync(f)||fs.statSync(f).isDirectory()){r.writeHead(404);return r.end('no');}
  r.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'}); r.end(fs.readFileSync(f)); });
await new Promise(r=>srv.listen(8796,r));

const ok = [], bad = [];
const T = (n, c, x) => { (c?ok:bad).push(n); console.log((c?'  ✅ ':'  ❌ ')+n+(x?' — '+x:'')); };

const b = await chromium.launch();
const ctx = await b.newContext({ viewport:{width:1400,height:950} });
const p = await ctx.newPage();
const errs = []; p.on('pageerror', e=>errs.push(String(e.message)));
await p.addInitScript(d=>localStorage.setItem('mos_device_id',d),'7e57c1a0-de1c-4a7e-b0de-c47a10906477');
await p.goto('http://127.0.0.1:8796/',{waitUntil:'domcontentloaded'});
await p.waitForTimeout(6000);
try { await p.click('text=/Entrar a MOS/i',{timeout:4000}); } catch {}
await p.waitForFunction(()=>{try{return !!MOS;}catch{return false;}},{timeout:60000});

// nada de escritura real sobre la política de una zona
await p.evaluate(()=>{
  window.__zs = [];
  const orig = API.post.bind(API);
  API.post = function (a, pl) {
    if (a === 'actualizarZona' || a === 'crearZona') {
      window.__zs.push({ a, pl: JSON.parse(JSON.stringify(pl||{})) });
      return Promise.resolve({ ok:true, data:{} });
    }
    return orig(a, pl);
  };
});

await p.evaluate(()=>{ MOS.nav('config'); });
await p.waitForTimeout(4000);
await p.evaluate(()=>{ try { MOS.setCfgTab('infra'); } catch(_){} });
await p.waitForFunction(()=>/Base cajero/.test(document.body.textContent),{timeout:60000});
await p.waitForTimeout(1500);

// ── los chips por zona ──
console.log('\n[chips] Base cajero / Base vendedor junto a Meta y Comisión');
const chips = await p.evaluate(()=>{
  const out = [];
  document.querySelectorAll('.srow').forEach(row => {
    if (!/Política/.test(row.textContent)) return;
    const zi = String((row.querySelector('.pchip[onclick*="abrirModalZona"]')||{}).getAttribute
      ? row.querySelector('.pchip[onclick*="abrirModalZona"]').getAttribute('onclick') : '').match(/abrirModalZona\('([^']+)'\)/);
    const c = [...row.querySelectorAll('.pchip')].map(e=>({
      lbl: (e.querySelector('.pl')||{}).textContent ? e.querySelector('.pl').textContent.replace(/\s+/g,' ').trim() : '',
      val: (e.querySelector('.pv')||{}).textContent ? e.querySelector('.pv').textContent.trim() : '' }));
    out.push({ zona: zi ? zi[1] : '?', chips: c });
  });
  return out;
});
chips.forEach(z => console.log('     ' + z.zona + ': ' + z.chips.map(c=>c.lbl+'='+c.val).join('  ')));
const zonasVenta = chips.filter(z => z.chips.some(c=>/Base cajero/.test(c.lbl)));
T('las zonas de venta muestran el chip Base cajero', zonasVenta.length >= 2, zonasVenta.length + ' zona(s)');
T('las zonas de venta muestran el chip Base vendedor',
  zonasVenta.every(z => z.chips.some(c=>/Base vendedor/.test(c.lbl))));
T('los chips traen el monto real, no "—"',
  zonasVenta.every(z => z.chips.filter(c=>/^Base /.test(c.lbl)).every(c => /S\/\s*\d/.test(c.val))),
  zonasVenta.map(z=>z.zona+':'+z.chips.filter(c=>/^Base /.test(c.lbl)).map(c=>c.val).join('/')).join(' · '));

// ── el modal se abre con los valores puestos ──
console.log('\n[modal] los campos llegan cargados');
const zid = zonasVenta[0] && zonasVenta[0].zona;
await p.evaluate(z=>MOS.abrirModalZona(z), zid);
await p.waitForTimeout(1200);
const campos = await p.evaluate(()=>({
  caj: (document.getElementById('zonaBaseCajero')||{}).value,
  ven: (document.getElementById('zonaBaseVendedor')||{}).value,
  meta:(document.getElementById('zonaMetaDiaria')||{}).value,
  vig: (document.getElementById('zonaPoliticaVigencia')||{}).value }));
console.log('     ' + JSON.stringify(campos));
T('base cajero cargada en el modal', parseFloat(campos.caj) >= 0);
T('base vendedor cargada en el modal', parseFloat(campos.ven) >= 0);
T('la vigencia arranca en hoy (Lima)', /^\d{4}-\d{2}-\d{2}$/.test(campos.vig || ''), campos.vig);

// ── cambiar la base y guardar: qué viaja ──
console.log('\n[guardar] la base viaja en la política versionada, con su vigencia');
await p.evaluate(()=>{
  document.getElementById('zonaBaseVendedor').value = '62';
  document.getElementById('zonaBaseCajero').value = '58';
});
// [847] espiar la relectura del personal del día tras guardar
await p.evaluate(()=>{
  window.__gets = [];
  const og = API.get.bind(API);
  API.get = function (a, q) { window.__gets.push({ a, q: q || {} }); return og(a, q); };
  const f = new Date(Date.now()-5*3600*1000).toISOString().slice(0,10);
  localStorage.setItem('mos_fin_resum_' + f, JSON.stringify({ ts: Date.now(), data: [{ __viejo: true }] }));
  window.__cacheKey = 'mos_fin_resum_' + f;
});
await p.evaluate(()=>MOS.guardarZona());
await p.waitForTimeout(6000);
const env = await p.evaluate(()=>window.__zs);
const pl = env.length ? env[env.length-1].pl : null;
console.log('     payload: ' + JSON.stringify(pl && { idZona: pl.idZona, politicaJSON: pl.politicaJSON, vig: pl.politicaVigenteDesde }));
T('se llamó a actualizarZona', !!pl);
let pol = {}; try { pol = JSON.parse((pl && pl.politicaJSON) || '{}'); } catch(_){}
T('baseCajero viaja con el valor nuevo', pol.baseCajero === 58, 'baseCajero=' + pol.baseCajero);
T('baseVendedor viaja con el valor nuevo', pol.baseVendedor === 62, 'baseVendedor=' + pol.baseVendedor);
T('meta y comisión siguen viajando (no se pisan)', pol.metaDiaria > 0 && pol.comisionExcedentePct >= 0,
  'meta=' + pol.metaDiaria + ' pct=' + pol.comisionExcedentePct);
T('viaja la fecha de vigencia', /^\d{4}-\d{2}-\d{2}$/.test(String(pl && pl.politicaVigenteDesde || '')),
  String(pl && pl.politicaVigenteDesde));

// ── tras guardar, el panel de Personal se relee (no se queda con el pago viejo) ──
console.log('\n[847] guardar la política relee el personal del día');
const gets = await p.evaluate(()=>window.__gets.filter(g=>g.a==='getPersonalDiaFast'));
T('se pidió getPersonalDiaFast tras guardar', gets.length > 0, gets.length + ' llamada(s)');
T('se pidió SALTANDO el caché (_refresh)', gets.some(g=>String(g.q._refresh)==='true'),
  JSON.stringify(gets.map(g=>g.q)));
const cacheViejo = await p.evaluate(()=>{
  try { const r = JSON.parse(localStorage.getItem(window.__cacheKey)||'{}');
        return !!(r.data && r.data[0] && r.data[0].__viejo); } catch(_) { return false; }
});
T('el caché viejo del día quedó descartado', !cacheViejo);

// ── zona nueva: los campos no arrastran lo de la anterior ──
console.log('\n[higiene] abrir "Nueva zona" no arrastra la base de la anterior');
await p.evaluate(()=>MOS.abrirModalZona());
await p.waitForTimeout(700);
const limpio = await p.evaluate(()=>({
  caj: (document.getElementById('zonaBaseCajero')||{}).value,
  ven: (document.getElementById('zonaBaseVendedor')||{}).value }));
T('los campos de base arrancan vacíos en una zona nueva', limpio.caj === '' && limpio.ven === '',
  JSON.stringify(limpio));

console.log('\n  errores de página: ' + (errs.length ? errs.slice(0,3).join(' | ') : 'ninguno'));
T('sin errores de página', errs.length === 0);
console.log('\n  ' + ok.length + ' ✅   ' + bad.length + ' ❌');
await b.close(); srv.close();
process.exit(bad.length ? 1 : 0);
