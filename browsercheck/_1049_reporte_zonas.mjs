// [1049] Webcheck reporte-zonas.html: datos reales, 0 pageerrors, filtros, expandir padre. 390 y 1280.
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.cwd(), '..'); const DEV = process.env.DEV;
const srv = http.createServer((q, r) => { const f = path.join(ROOT, decodeURIComponent(q.url.split('?')[0])); fs.readFile(f, (e, b) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' }); r.end(b); }); }).listen(8791);
const br = await chromium.launch(); let fallas = 0;
for (const vp of [{ width: 390, height: 844 }, { width: 1280, height: 900 }]) {
  const pg = await br.newPage({ viewport: vp }); const errs = [];
  pg.on('pageerror', e => errs.push(e.message));
  await pg.addInitScript(d => { localStorage.setItem('mos_device_id', d); localStorage.removeItem('mos_reporte_zonas_filtros'); }, DEV);
  await pg.goto('http://localhost:8791/reporte-zonas.html');
  await pg.waitForSelector('.kpi', { timeout: 30000 });
  const k1 = await pg.$$eval('.kpi .v', a => a.map(x => x.textContent));
  await pg.click('#fDias button[data-v="28"]'); await pg.waitForSelector('#chartDias rect', { timeout: 40000 });
  await pg.click('#fZona button[data-v="ZONA-02"]'); await pg.waitForSelector('#chartDias rect', { timeout: 40000 });
  await pg.fill('#busca', 'pimienta negra molida'); await pg.click('tr.padre');
  const hijos = await pg.$$eval('tr.hijo td:first-child', a => a.map(x => x.textContent));
  const sw = await pg.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  await pg.screenshot({ path: `_1049_${vp.width}.png`, fullPage: false });
  await pg.fill('#busca', ''); await pg.screenshot({ path: `_1049_${vp.width}_full.png`, fullPage: true });
  console.log(vp.width, 'kpis hoy', k1.join(' | '), '| hijos pimienta', hijos.length, hijos.slice(0, 4).join(' / '), '| overflow-x', sw, '| errores', errs.length, errs.join(';'));
  if (errs.length || sw > 2 || !hijos.length) fallas++;
  await pg.close();
}
await br.close(); srv.close(); console.log(fallas ? 'FALLA' : 'PASS');
