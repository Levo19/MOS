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
  // costos fijos simulados (no escribe en producción)
  const guardados = [];
  await pg.route('**/rpc/costos_fijos_listar', r => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, items: [
    { id: 1, zona: 'ZONA-01', concepto: 'Alquiler', monto: 1500, frecuencia: 'MES' }, { id: 2, zona: 'ZONA-01', concepto: 'Luz', monto: 200, frecuencia: 'MES' },
    { id: 3, zona: 'GENERAL', concepto: 'Internet', monto: 100, frecuencia: 'MES' }] }) }));
  await pg.route('**/rpc/costos_fijos_guardar', r => { guardados.push(r.request().postDataJSON()); r.fulfill({ contentType: 'application/json', body: '{"ok":true,"nuevos":1,"cerrados":0}' }); });
  await pg.addInitScript(() => localStorage.setItem('mos_reporte_ctx', JSON.stringify({ u: 'Luis', r: 'MASTER', ts: Date.now() })));
  await pg.goto('http://localhost:8791/reporte-zonas.html');
  await pg.waitForSelector('#cDona path', { timeout: 40000 });
  const k = await pg.$$eval('.kpi .v', a => a.map(x => x.textContent));
  const kl = await pg.$$eval('.kpi .l', a => a.map(x => x.textContent));
  const nPartes = await pg.$$eval('#cDona path[data-i]', a => a.length);
  if (!kl.includes('Utilidad neta') && !kl.includes('Pérdida neta')) errs.push('KPI no es utilidad neta: ' + kl.join(','));
  if (nPartes !== 4) errs.push('dona sin costos fijos: ' + nPartes + ' partes');
  // modal: agregar Agua 15 a la semana en Zona 01 y guardar
  await pg.click('#btnCF'); await pg.waitForSelector('#cfModal');
  await pg.click('#cfZonas button[data-v="ZONA-01"]');
  await pg.click('#cfPre button[data-c="Agua"]');
  const filasCF = await pg.$$('#cfRows .cf-row'); await filasCF[filasCF.length - 1].$('.m').then(x => x.fill('15'));
  await filasCF[filasCF.length - 1].$('.f').then(x => x.selectOption('SEMANA'));
  const sumCF = await pg.textContent('#cfSum');
  await pg.screenshot({ path: `_1053_${vp.width}_modal.png` });
  await pg.click('#cfSave'); await pg.waitForSelector('#cfModal', { state: 'detached', timeout: 15000 });
  const g = guardados[0] || {};
  if (!(g.p && g.p.zona === 'ZONA-01' && g.p.usuario === 'Luis' && g.p.items.some(i => i.concepto === 'Agua' && i.monto === 15 && i.frecuencia === 'SEMANA'))) errs.push('guardar mal: ' + JSON.stringify(g).slice(0, 200));
  console.log('  CF: kpis', kl.join(','), '| partes dona', nPartes, '| modal', sumCF.replace(/\s+/g, ' '), '| guardó', JSON.stringify(g.p && g.p.items).slice(0, 160));
  await pg.click('#fVista button[data-v="casc"]'); const pasos = await pg.$$eval('#cCasc .cb', a => a.length); await pg.click('#fVista button[data-v="dona"]');
  if (pasos !== 6) errs.push('cascada sin paso de costos fijos: ' + pasos);
  await pg.click('#dnSide .dn-it[data-i="1"]'); await pg.click('#cDona path[data-j="0"]');
  const dona = (await pg.textContent('#cDona')) + ' | ' + (await pg.textContent('#dnSide')).slice(0, 120);
  const nSub = await pg.$$eval('#cDona path[data-j]', a => a.length);
  if (!nSub) errs.push('dona sin división');
  await pg.locator('#cDona').scrollIntoViewIfNeeded(); await pg.screenshot({ path: `_1052_${vp.width}_dona.png` });
  await pg.click('#dnBack'); await pg.click('#cDona path[data-i="2"]'); const dq = await pg.$$eval('#dnSide .dn-it', a => a.length);
  await pg.click('#fVista button[data-v="casc"]'); await pg.click('#cCasc .cb[data-i="3"]'); const casc = await pg.textContent('#cascTxt');
  await pg.click('#fVista button[data-v="dona"]');
  console.log('  DONA:', dona, '| subs', nSub, '| días semana', dq);
  await pg.click('#fDiaMet button[data-v="todo"]'); await pg.click('#cDias .db[data-i="5"]');
  const eqRes = await pg.textContent('#diaRes'); const eqDet = await pg.textContent('#diaTxt');
  if (!/días cubrieron/.test(eqRes) || !/al día/.test(eqRes)) errs.push('sin equilibrio: ' + eqRes);
  await pg.locator('#cDias').scrollIntoViewIfNeeded(); await pg.screenshot({ path: `_1054_${vp.width}_eq.png` });
  console.log('  EQ:', eqRes.slice(0, 230), '|| día:', eqDet.slice(0, 160));
  for (const m of ['venta', 'utilidad']) { await pg.click('#fDiaMet button[data-v="' + m + '"]'); }
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
  // caso Luis: Zona 02 · 4 semanas · solo comisión 10% de la venta → jefa ≈ 18.1%
  await pg.click('#fZona button[data-v="ZONA-02"]'); await pg.waitForSelector('#simJefa .jbar', { timeout: 40000 });
  await pg.click('#simBase button[data-v="venta"]'); await pg.click('#simModo button[data-v="comision"]'); await pg.locator('#simPct').fill('10');
  const jefa = (await pg.textContent('#simJefa')).replace(/\s+/g, ' ');
  const grp = await pg.$$eval('#simRoles button.on', a => a.map(x => x.textContent));
  { const m = jefa.match(/margen es ([\d.,]+)%.*?le queda ([\d.,]+)%/); const mg = m && parseFloat(m[1].replace(',', '.')), jf = m && parseFloat(m[2].replace(',', '.'));
    if (!m || Math.abs((mg - 10) - jf) > 0.15) errs.push('jefa Z2: con 10% debe quedar margen − 10: ' + jefa.slice(0, 200)); }
  await pg.locator('#simJefa').scrollIntoViewIfNeeded(); await pg.screenshot({ path: `_1051_${vp.width}_jefa.png` });
  console.log('  Z2 grupos marcados', grp.join(','), '|| JEFA:', jefa.slice(0, 330));
  await pg.click('#fZona button[data-v="TODAS"]'); await pg.waitForSelector('#simJefa .jbar', { timeout: 40000 });
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
