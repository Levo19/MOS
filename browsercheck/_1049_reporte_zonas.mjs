// [1049/1050] Webcheck reporte-zonas.html: datos reales, 0 pageerrors, cascada, días, margen, simulador, tabla. 390 y 1280.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.cwd(), '..'); const DEV = process.env.DEV;
const srv = http.createServer((q, r) => { const f = path.join(ROOT, decodeURIComponent(q.url.split('?')[0])); fs.readFile(f, (e, b) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' }); r.end(b); }); }).listen(8791);
const br = await chromium.launch(); let fallas = 0;
for (const vp of [{ width: 390, height: 844 }, { width: 1280, height: 900 }]) {
  const pg = await br.newPage({ viewport: vp }); const errs = [];
  pg.on('pageerror', e => errs.push(e.message));
  await pg.addInitScript(d => { if (!sessionStorage.getItem('x')) { localStorage.clear(); sessionStorage.setItem('x', 1); } localStorage.setItem('mos_device_id', d); }, DEV);
  await pg.goto('http://localhost:8791/reporte-zonas.html');
  await pg.waitForSelector('#cCasc rect', { timeout: 40000 });
  const k = await pg.$$eval('.kpi .v', a => a.map(x => x.textContent));
  await pg.click('#cCasc .cb[data-i="3"]'); const casc = await pg.textContent('#cascTxt');
  await pg.click('#fDiaMet button[data-v="queda"]'); await pg.click('#cDias .db[data-i="3"]'); const dia = await pg.textContent('#diaTxt');
  await pg.click('#fMg button[data-v="poco"]'); const mg = await pg.$$eval('#hbMg .n', a => a.length);
  await pg.click('#simPre button[data-i="0"]'); const r0 = await pg.textContent('#simRes');
  await pg.click('#simPre button[data-i="3"]'); const r3 = await pg.textContent('#simRes');
  await pg.locator('#cSim').scrollIntoViewIfNeeded(); const box = await pg.locator('#cSim').boundingBox(); await pg.mouse.click(box.x + box.width * 0.5, box.y + box.height / 2);
  const pv = await pg.textContent('#simPctV');
  await pg.click('#simBase button[data-v="venta"]'); await pg.click('#simModo button[data-v="comision"]');
  await pg.locator('#simPct').fill('4'); const r4 = await pg.textContent('#simRes'); const pv4 = await pg.textContent('#simPctV');
  if (!/4%/.test(pv4)) errs.push('slider no cambia: ' + pv4);
  if (pv === '10%') errs.push('click en gráfico no cambia el %'); const cl = await pg.textContent('#simClaves');
  const filas = await pg.$$eval('#simTb tr', a => a.length); const cmp = await pg.$$eval('#simCmp tr', a => a.length);
  const sw = await pg.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  await pg.screenshot({ path: `_1050_${vp.width}_full.png`, fullPage: true });
  await pg.click('#btnTema'); await pg.waitForTimeout(200); await pg.screenshot({ path: `_1050_${vp.width}_dark.png` });
  console.log(vp.width, '| kpis', k.join(' | '), '\n  casc:', casc.slice(0, 90), '\n  dia:', dia.slice(0, 80), '| margen filas', mg,
    '\n  sim preset0:', r0.slice(0, 110), '\n  sim preset3:', r3.slice(0, 110), '\n  click 50% →', pv, '|', cl.slice(0, 160), '\n  personas', filas, 'comparar', cmp, '| overflow-x', sw, '| errores', errs.length, errs.join(';'));
  if (errs.length || sw > 2 || !filas || cmp < 6 || !mg) fallas++;
  await pg.close();
}
await br.close(); srv.close(); console.log(fallas ? 'FALLA' : 'PASS');
