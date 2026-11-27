// Webcheck reporte-cajas.html en MODO DEMO (la RPC aún no existe: se simula 404 PGRST202).
// Un solo Chromium. Ejecutar desde browsercheck/:  node _cajas_semana.mjs
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.cwd(), '..');
const srv = http.createServer((q, r) => { const f = path.join(ROOT, decodeURIComponent(q.url.split('?')[0])); fs.readFile(f, (e, b) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' }); r.end(b); }); }).listen(8793);
const br = await chromium.launch(); let fallas = 0;
const ok = (c, m) => { if (!c) { fallas++; console.log('  FALLA:', m); } };
const SIZES = [[360, 740], [412, 915], [768, 1024], [1024, 768], [1440, 900]];
try {
  for (const [w, h] of SIZES) {
    const ctx = await br.newContext({ viewport: { width: w, height: h }, hasTouch: w < 1000, isMobile: w < 800 });
    const pg = await ctx.newPage(); const errs = [];
    pg.on('pageerror', e => errs.push(e.message));
    await pg.addInitScript(() => { localStorage.setItem('mos_device_id', 'test-dev'); localStorage.setItem('mos_reporte_ctx', JSON.stringify({ u: 'Luis', r: 'MASTER', ts: Date.now() })); });
    await pg.route('**/functions/v1/mint-mos', r => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, token: 'x.y.z', exp: Date.now() / 1000 + 3000 }) }));
    await pg.route('**/rpc/reporte_cajas_semana', r => r.fulfill({ status: 404, contentType: 'application/json', body: '{"code":"PGRST202","message":"Could not find the function mos.reporte_cajas_semana"}' }));
    await pg.goto('http://localhost:8793/reporte-cajas.html');
    await pg.waitForSelector('.kpi', { timeout: 20000 });
    ok(await pg.isVisible('.demo'), w + ': banner de ejemplo');
    const nTabs = await pg.$$eval('.tabs > button', a => a.length); ok(nTabs === 9, w + ': 9 pestañas, hay ' + nTabs);
    const scrolls = {};
    for (const tab of ['pend', 'cajas', 'cajero', 'zonas', 'extras', 'ventas', 'anul', 'yape', 'clientes']) {
      await pg.click('.tabs > button[data-v="' + tab + '"]'); await pg.waitForTimeout(80);
      const sw = await pg.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
      scrolls[tab] = sw; ok(sw[0] <= sw[1], w + ' pestaña ' + tab + ' scrollWidth ' + sw[0] + ' > ' + sw[1]);
    }
    await pg.click('.tabs > button[data-v="yape"]'); await pg.click('#segYv button[data-v="B"]'); await pg.waitForTimeout(80);
    let sw = await pg.evaluate(() => [document.documentElement.scrollWidth, innerWidth]); ok(sw[0] <= sw[1], w + ' yape B scroll ' + sw[0]);
    await pg.click('#segYv button[data-v="A"]');
    const sinT = await pg.$$eval('.ycard.sin', a => a.length); ok(sinT > 0, w + ': yapes NUEVO sin ticket en rojo');
    if (w === 1440 || w === 360) {
      // --- filtros: zona se aplica a todo
      await pg.click('.tabs > button[data-v="cajas"]');
      const todas = await pg.$$eval('.card', a => a.length); ok(todas === 10, w + ': 10 cajas, hay ' + todas);
      if (w === 360) { await pg.click('#btnMas'); ok(await pg.isVisible('#panelSec'), 'hoja de filtros abre'); await pg.click('#btnCerrarF'); ok(!(await pg.isVisible('#panelSec')), 'hoja cierra'); }
      await pg.click('#fZona button[data-v="ZONA-02"]'); await pg.waitForTimeout(80);
      const z2 = await pg.$$eval('.card', a => a.map(c => c.className)); ok(z2.length === 6 && z2.every(c => c.includes('z2c')), w + ': solo Z02 (' + z2.length + ')');
      ok((await pg.evaluate(() => location.search)).includes('zona=ZONA-02'), w + ': zona en la URL');
      const kv = await pg.$$eval('.kpi .v', a => a.map(x => x.textContent)); ok(kv[0].includes('abiertas'), 'KPIs presentes');
      await pg.selectOption('#fCajero', 'Diego'); await pg.waitForTimeout(80);
      const dg = await pg.$$eval('.card h3', a => a.map(x => x.textContent)); ok(dg.length === 2 && dg.every(t => t.includes('Diego')), w + ': cajero Diego (' + dg.length + ')');
      ok((await pg.evaluate(() => location.search)).includes('cajero=Diego'), 'cajero en URL');
      // KPIs cambian con filtro
      const kpiDiego = (await pg.$$eval('.kpi .v', a => a.map(x => x.textContent)))[1];
      await pg.click('#btnLimpiar', { force: true }).catch(() => pg.click('[data-act="limpiar"]'));
      await pg.waitForTimeout(80);
      const kpiTodo = (await pg.$$eval('.kpi .v', a => a.map(x => x.textContent)))[1]; ok(kpiDiego !== kpiTodo, w + ': KPI venta cambia al filtrar');
      // selector de cajas: solo esta
      await pg.click('.card [data-act="solo"]'); await pg.waitForTimeout(80);
      ok((await pg.$$eval('.card', a => a.length)) === 1, w + ': solo esta caja'); ok((await pg.evaluate(() => location.search)).includes('caja='), 'caja en URL');
      await pg.click('[data-act="limpiar"]');
      // pendientes: marcar OK optimista + observar con nota
      await pg.click('.tabs > button[data-v="pend"]');
      const prog0 = await pg.textContent('.prog b');
      await pg.click('.pend [data-act="ok"]'); await pg.waitForTimeout(80);
      const prog1 = await pg.textContent('.prog b'); ok(prog0 !== prog1, w + ': progreso cambia (' + prog0 + ' -> ' + prog1 + ')');
      await pg.click('.pend [data-act="obs"]'); await pg.waitForSelector('#mdl');
      await pg.click('#mdOk'); ok((await pg.textContent('#mdErr')).includes('nota'), 'exige nota al observar');
      await pg.fill('#mdNota', 'Falta comprobante'); await pg.click('#mdOk'); await pg.waitForSelector('#mdl', { state: 'detached' });
      await pg.check('#chkHechos'); ok((await pg.$$eval('.pend.hecho .chip.c-warn', a => a.some(x => x.textContent.includes('Obs')))), 'queda marcado Observado'); await pg.uncheck('#chkHechos');
      // detalle de caja
      await pg.click('.tabs > button[data-v="cajas"]'); await pg.click('.card h3'); await pg.waitForSelector('#ovSheet');
      ok((await pg.$$eval('#ovSheet .tabs button', a => a.length)) === 5, 'detalle con 5 subpestañas');
      await pg.screenshot({ path: '_cajas_' + w + '_detalle.png' });
      await pg.click('[data-act="cerrarSheet"]');
      // ventas: 1280 filas paginadas + orden
      await pg.click('.tabs > button[data-v="ventas"]');
      const info = await pg.textContent('.pg span').catch(() => ''); ok(/de 12\d\d/.test(info), w + ': paginación de ~1280 ventas: ' + info);
      // CSV
      const [dl] = await Promise.all([pg.waitForEvent('download'), pg.click('#btnCsv')]); ok(/control-cajas-ventas/.test(dl.suggestedFilename()), 'CSV ' + dl.suggestedFilename());
      // zonas
      await pg.click('.tabs > button[data-v="zonas"]'); const zrows = await pg.$$eval('.tw table tbody tr', a => a.length); ok(zrows >= 18, 'comparativa Z01 vs Z02');
      // yape B: semáforo y candidatos
      await pg.click('.tabs > button[data-v="yape"]'); await pg.click('#segYv button[data-v="B"]');
      const prog = await pg.textContent('.prog b'); ok(/tickets verificados/.test(prog), 'contador tickets verificados: ' + prog);
      await pg.click('#segTv button[data-v="SIN_VERIFICAR"]'); ok((await pg.$$eval('.cand', a => a.length)) > 0, 'posibles Yapes (candidatos)');
      // tema
      await pg.click('#btnTema'); ok((await pg.evaluate(() => document.documentElement.dataset.theme)) === 'dark', 'tema oscuro'); await pg.click('#btnTema');
    }
    // capturas en cada tamaño: pendientes y cajas
    await pg.click('.tabs > button[data-v="pend"]'); await pg.screenshot({ path: '_cajas_' + w + '_pend.png' });
    await pg.click('.tabs > button[data-v="ventas"]'); await pg.screenshot({ path: '_cajas_' + w + '_ventas.png' });
    await pg.click('.tabs > button[data-v="yape"]'); await pg.screenshot({ path: '_cajas_' + w + '_yape.png' });
    console.log(w + 'x' + h + ': scrollWidth<=innerWidth', JSON.stringify(scrolls), '| errores JS:', errs.length ? errs.join(' / ') : '0');
    ok(!errs.length, w + ': pageerrors ' + errs.join(' / '));
    await ctx.close();
  }
  // --- RPC "real": errores del backend, modo liviano en celular, rollback de marcas
  for (const w of [360, 1280]) {
    const ctx = await br.newContext({ viewport: { width: w, height: 800 } }); const pg = await ctx.newPage(); const errs = []; const reqs = [];
    pg.on('pageerror', e => errs.push(e.message));
    await pg.addInitScript(() => { localStorage.setItem('mos_device_id', 'test-dev'); localStorage.setItem('mos_reporte_ctx', JSON.stringify({ u: 'Luis', r: 'MASTER', ts: Date.now() })); });
    await pg.route('**/functions/v1/mint-mos', r => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, token: 'x.y.z', exp: Date.now() / 1000 + 3000 }) }));
    // 1) ok:false -> mensaje, no demo
    await pg.route('**/rpc/reporte_cajas_semana', r => r.fulfill({ contentType: 'application/json', body: '{"ok":false,"error":"RANGO_INVALIDO"}' }));
    await pg.goto('http://localhost:8793/reporte-cajas.html'); await pg.waitForSelector('.estado');
    const tx = await pg.textContent('#cuerpo'); ok(/Rango de fechas/.test(tx) && !(await pg.isVisible('.demo')), w + ': error RANGO_INVALIDO claro, sin demo: ' + tx.slice(0, 60));
    // 2) respuesta con ok:true (forma real) generada con el demo
    const full = await pg.evaluate(() => JSON.stringify(Object.assign(demoData(st.desde, st.hasta), { ok: true })));
    await pg.unroute('**/rpc/reporte_cajas_semana');
    await pg.route('**/rpc/reporte_cajas_semana', r => { const b = r.request().postDataJSON(); reqs.push(b.p.ventas || 'FULL'); const o = JSON.parse(full); if (b.p.ventas === 'OBSERVABLES') o.ventas = o.ventas.filter(v => v.metodo !== 'EFECTIVO'); r.fulfill({ contentType: 'application/json', body: JSON.stringify(o) }); });
    await pg.route('**/rpc/control_caja_marcar', r => r.fulfill({ contentType: 'application/json', body: '{"ok":false,"error":"ROL_NO_AUTORIZADO"}' }));
    await pg.reload(); await pg.waitForSelector('.kpi');
    ok(!(await pg.isVisible('.demo')), w + ': con respuesta real no hay banner demo');
    ok(w === 360 ? reqs[0] === 'OBSERVABLES' : reqs[0] === 'FULL', w + ': primera carga ' + reqs[0]);
    if (w === 360) { await pg.click('.tabs > button[data-v="ventas"]'); await pg.waitForSelector('table, tbody tr', { timeout: 8000 }); ok(reqs.includes('FULL'), 'Ventas pide la carga completa: ' + reqs.join(',')); }
    await pg.click('.tabs > button[data-v="pend"]'); const p0 = await pg.textContent('.prog b');
    await pg.click('.pend [data-act="ok"]'); await pg.waitForTimeout(400);
    const p1 = await pg.textContent('.prog b'); const t1 = await pg.textContent('.toast').catch(() => '');
    ok(p0 === p1 && /no puede marcar/i.test(t1), w + ': rollback + mensaje en español: ' + t1);
    ok(!errs.length, w + ' real: pageerrors ' + errs.join(' / '));
    console.log(w + ' RPC real: primera carga=' + reqs[0] + ' | peticiones=' + reqs.join(',') + ' | toast=' + t1.slice(0, 70));
    await ctx.close();
  }
} catch (e) { fallas++; console.log('EXCEPCION', e.message); }
await br.close(); srv.close();
console.log(fallas ? 'RESULTADO: ' + fallas + ' FALLA(S)' : 'RESULTADO: TODO OK');
process.exit(fallas ? 1 : 0);
