// Webcheck reporte-cajas.html en MODO DEMO (la RPC aún no existe: se simula 404 PGRST202).
// Un solo Chromium. Ejecutar desde browsercheck/:  node _cajas_semana.mjs
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const ROOT = path.resolve(process.cwd(), '..');
const srv = http.createServer((q, r) => { const f = path.join(ROOT, decodeURIComponent(q.url.split('?')[0])); fs.readFile(f, (e, b) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' }); r.end(b); }); }).listen(8793);
const br = await chromium.launch(); let fallas = 0;
const ok = (c, m) => { if (!c) { fallas++; console.log('  FALLA:', m); } };
const FIX = 'C:/Users/ISO/AppData/Local/Temp/claude/43303b92a4ef8780/6d204972-8c5d-4519-bbcf-417fdee11edf/scratchpad/';
const SIZES = [[360, 740], [412, 915], [768, 1024], [1024, 768], [1440, 900]];
try {
  for (const [w, h] of SIZES) {
    const ctx = await br.newContext({ viewport: { width: w, height: h }, hasTouch: w < 1000, isMobile: w < 800 });
    const pg = await ctx.newPage(); const errs = [];
    pg.on('pageerror', e => errs.push(e.message));
    await pg.addInitScript(() => { localStorage.setItem('mos_device_id', 'test-dev'); localStorage.setItem('mos_reporte_ctx', JSON.stringify({ u: 'Luis', r: 'MASTER', ts: Date.now() })); });
    await pg.route('**/functions/v1/mint-mos', r => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, token: 'x.y.z', exp: Date.now() / 1000 + 3000 }) }));
    await pg.goto('http://localhost:8793/reporte-cajas.html?demo=1');
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
      await pg.waitForTimeout(600); await pg.click('.pend [data-act="obs"]'); await pg.waitForSelector('#mdl');
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
    const ctx = await br.newContext({ viewport: { width: w, height: 800 } }); const pg = await ctx.newPage(); const errs = []; const reqs = []; let usuariosOk = true;
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
    await pg.route('**/rpc/reporte_cajas_semana', r => { const b = r.request().postDataJSON(); reqs.push(b.p.ventas || 'FULL'); if (b.p.usuario !== 'Luis') usuariosOk = false; const o = JSON.parse(full); if (b.p.ventas === 'OBSERVABLES') o.ventas = o.ventas.filter(v => v.metodo !== 'EFECTIVO'); r.fulfill({ contentType: 'application/json', body: JSON.stringify(o) }); });
    await pg.route('**/rpc/control_caja_marcar', r => r.fulfill({ contentType: 'application/json', body: '{"ok":false,"error":"ROL_NO_AUTORIZADO"}' }));
    await pg.reload(); await pg.waitForSelector('.kpi');
    ok(!(await pg.isVisible('.demo')), w + ': con respuesta real no hay banner demo');
    ok(usuariosOk, w + ': la RPC lleva usuario');
    ok(w === 360 ? reqs[0] === 'OBSERVABLES' : reqs[0] === 'FULL', w + ': primera carga ' + reqs[0]);
    if (w === 360) { ok(/parcial/.test(await pg.textContent('.tabs > button[data-v="ventas"]')), 'celular: Ventas indica parcial'); await pg.click('.tabs > button[data-v="ventas"]'); await pg.waitForSelector('table, tbody tr', { timeout: 8000 }); ok(reqs.includes('FULL'), 'Ventas pide la carga completa: ' + reqs.join(',')); }
    await pg.click('.tabs > button[data-v="pend"]'); const p0 = await pg.textContent('.prog b');
    await pg.click('.pend [data-act="ok"]'); await pg.waitForTimeout(400);
    const p1 = await pg.textContent('.prog b'); const t1 = await pg.textContent('.toast').catch(() => '');
    ok(p0 === p1 && /no puede marcar/i.test(t1), w + ': rollback + mensaje en español: ' + t1);
    ok(!errs.length, w + ' real: pageerrors ' + errs.join(' / '));
    console.log(w + ' RPC real: primera carga=' + reqs[0] + ' | peticiones=' + reqs.join(',') + ' | toast=' + t1.slice(0, 70));
    await ctx.close();
  }
  // --- usuario obligatorio, ROL_NO_AUTORIZADO, rango máx 31 días, MES semana por semana (cliente une y deduplica)
  {
    const ctx = await br.newContext({ viewport: { width: 1280, height: 900 } }); let pg = await ctx.newPage(); const errs = [];
    pg.on('pageerror', e => errs.push(e.message));
    await ctx.route('**/functions/v1/mint-mos', r => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, token: 'x.y.z', exp: Date.now() / 1000 + 3000 }) }));
    // sin mos_reporte_ctx: pide abrir desde MOS
    await pg.addInitScript(() => { localStorage.setItem('mos_device_id', 'test-dev'); });
    await pg.goto('http://localhost:8793/reporte-cajas.html'); await pg.waitForSelector('#btnRe');
    ok(/Abre este reporte desde el botón/.test(await pg.textContent('#cuerpo')), 'sin ctx pide abrir desde MOS');
    await pg.close(); pg = await ctx.newPage(); pg.on('pageerror', e => errs.push(e.message));
    await pg.addInitScript(() => { localStorage.setItem('mos_device_id', 'test-dev'); localStorage.setItem('mos_reporte_ctx', JSON.stringify({ u: 'Luis', r: 'MASTER', ts: Date.now() })); });
    // ROL_NO_AUTORIZADO al cargar
    await pg.route('**/rpc/reporte_cajas_semana', r => r.fulfill({ contentType: 'application/json', body: '{"ok":false,"error":"ROL_NO_AUTORIZADO"}' }));
    await pg.goto('http://localhost:8793/reporte-cajas.html?periodo=mes'); await pg.waitForSelector('#btnRe');
    ok(/no tiene permiso de administrador/.test(await pg.textContent('#cuerpo')), 'ROL_NO_AUTORIZADO al cargar: mensaje claro');
    await pg.unroute('**/rpc/reporte_cajas_semana');
    // mes simulado: cada llamada devuelve un demo del tramo pedido
    const calls = []; let usuarios = 0; pg.on('console', m => { if (m.type() === 'error') console.log('CONSOLE', m.text().slice(0, 200)); });
    await pg.route('**/rpc/reporte_cajas_semana', async r => {
      const b = r.request().postDataJSON().p; calls.push([b.desde, b.hasta, b.ventas || 'FULL']); if (b.usuario === 'Luis') usuarios++;
      const fx = FIX + 'r_' + b.desde + '_' + b.hasta + '.json'; const real = b.hasta >= '2026-11-01' && fs.existsSync(fx);
      const body = real ? fs.readFileSync(fx, 'utf8') : await pg.evaluate(([d, h]) => JSON.stringify(Object.assign(demoData(d, h), { ok: true })), [b.desde, b.hasta]);
      r.fulfill({ contentType: 'application/json', body });
    });
    await pg.goto('http://localhost:8793/reporte-cajas.html?periodo=mes'); await pg.waitForSelector('.kpi', { timeout: 60000 });
    const dias = calls.map(c => (Date.parse(c[1]) - Date.parse(c[0])) / 864e5 + 1);
    ok(calls.length >= 4 && calls.length <= 6, 'mes = 4-6 llamadas en serie, hubo ' + calls.length + ': ' + JSON.stringify(calls));
    ok(dias.every(n => n <= 7), 'cada llamada <= 7 días: ' + dias.join(','));
    ok(usuarios === calls.length, 'todas las llamadas llevan usuario');
    ok(!(await pg.isVisible('.demo')), 'mes real: sin banner demo');
    ok((await pg.evaluate(() => location.search)).includes('periodo=mes'), 'periodo en la URL');
    ok((await pg.$$eval('#atajos button.on', a => a.map(x => x.dataset.a))).join() === 'mes', 'atajo Este mes activo');
    const nCajas = await pg.evaluate(() => st.D.cajas.length); const ids = await pg.evaluate(() => new Set(st.D.cajas.map(c => c.id_caja)).size);
    ok(nCajas === ids && nCajas >= 1, 'cajas unidas sin duplicados: ' + nCajas + '/' + ids);
    ok((await pg.$$eval('.tabs > button', a => a.some(x => x.dataset.v === 'semanas'))), 'pestaña Semana a semana en modo mes');
    if (fs.existsSync(FIX + 'r_2026-11-01_2026-11-27.json')) { const vt = await pg.textContent('.kpi:nth-child(2) .v'); ok(/136[.,]491[.,]80/.test(vt), 'mes unido: venta total 136,491.80, dice ' + vt); }
    await pg.click('.tabs > button[data-v="semanas"]');
    const wk = await pg.$$eval('.tw table thead tr:first-child th', a => a.length); ok(wk >= 6, 'tabla semana a semana con ' + wk + ' columnas');
    const sw = await pg.evaluate(() => [document.documentElement.scrollWidth, innerWidth]); ok(sw[0] <= sw[1], 'semanas sin scroll horizontal');
    await pg.screenshot({ path: '_cajas_mes_semanas.png' });
    // rango > 31 días: aviso y no consulta
    const n0 = calls.length;
    await pg.fill('#fDesde', '2026-09-01'); await pg.dispatchEvent('#fDesde', 'change'); await pg.waitForTimeout(150);
    ok(/máximo es de 31/.test(await pg.textContent('.toast').catch(() => '')) && calls.length === n0, 'rango > 31 días avisa y no consulta');
    // Mes pasado
    calls.length = 0; await pg.click('#atajos button[data-a="mpas"]'); await pg.waitForSelector('.kpi'); await pg.waitForTimeout(300);
    ok(calls.length >= 4 && calls.every(c => c[0] >= '2026-10-01' && c[1] <= '2026-10-31'), 'mes pasado: ' + calls.length + ' llamadas dentro de octubre');
    console.log('MES: ' + calls.length + ' llamadas (mes pasado); semanas=' + wk + '; errores JS: ' + errs.length);
    ok(!errs.length, 'mes: pageerrors ' + errs.join(' / '));
    await ctx.close();
  }
  // --- QA: nada de demo salvo ?demo=1; null/404/500 = error con Reintentar; seq; método; CSV; doble toque; URL
  {
    const ctx = await br.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true }); const errs = [];
    await ctx.route('**/functions/v1/mint-mos', r => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, token: 'x.y.z', exp: Date.now() / 1000 + 3000 }) }));
    const nuevaPag = async () => { const p = await ctx.newPage(); p.on('pageerror', e => errs.push(e.message)); await p.addInitScript(() => { localStorage.setItem('mos_device_id', 'test-dev'); localStorage.setItem('mos_reporte_ctx', JSON.stringify({ u: 'Luis', r: 'MASTER', ts: Date.now() })); }); return p; };
    const casos = [['404 PGRST202', 404, '{"code":"PGRST202","message":"Could not find the function"}'], ['500 does not exist', 500, '{"message":"function mos.reporte_cajas_semana does not exist"}'], ['null', 200, 'null'], ['texto', 200, '"hola"']];
    for (const [n, status, body] of casos) {
      const pg = await nuevaPag(); await pg.route('**/rpc/reporte_cajas_semana', r => r.fulfill({ status, contentType: 'application/json', body }));
      await pg.goto('http://localhost:8793/reporte-cajas.html'); await pg.waitForSelector('#btnRe', { timeout: 20000 });
      ok(!(await pg.isVisible('.demo')) && !(await pg.$('.kpi')), n + ': error con Reintentar, nunca demo');
      await pg.close();
    }
    // mes: si una semana falla no hay datos parciales
    { const pg = await nuevaPag(); let k = 0;
      await pg.route('**/rpc/reporte_cajas_semana', async r => { k++; const b = r.request().postDataJSON().p; if (b.desde === '2026-11-09') return r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"boom"}' }); r.fulfill({ contentType: 'application/json', body: await pg.evaluate(([d, h]) => JSON.stringify(Object.assign(demoData(d, h), { ok: true })), [b.desde, b.hasta]) }); });
      await pg.goto('http://localhost:8793/reporte-cajas.html?periodo=mes'); await pg.waitForSelector('#btnRe', { timeout: 30000 }); ok(!(await pg.$('.kpi')), 'mes con semana fallida: error y sin datos parciales'); await pg.close(); }
    // seq: "Esta semana" lenta + "Hoy" -> solo hoy
    { const pg = await nuevaPag(); let n = 0;
      await pg.route('**/rpc/reporte_cajas_semana', async r => { const b = r.request().postDataJSON().p; const lento = b.desde !== b.hasta; n++; if (lento) await new Promise(x => setTimeout(x, 1500)); r.fulfill({ contentType: 'application/json', body: await pg.evaluate(([d, h]) => JSON.stringify(Object.assign(demoData(d, h), { ok: true })), [b.desde, b.hasta]) }); });
      await pg.goto('http://localhost:8793/reporte-cajas.html'); await pg.waitForSelector('.spin');
      ok(await pg.evaluate(() => document.getElementById('btnAct').disabled && [...document.querySelectorAll('#atajos button')].every(b => b.disabled)), 'atajos y ↻ deshabilitados mientras carga');
      await pg.evaluate(() => { st.periodo = 'hoy'; st.desde = st.hasta = hoy; cargar(); });   // otra carga mientras la semana sigue en vuelo
      await pg.waitForSelector('.kpi', { timeout: 15000 }); await pg.waitForTimeout(2200);
      const r = await pg.evaluate(() => [st.desde, st.hasta, new Set(st.D.cajas.map(c => limaYMD(c._t0))).size, st.D.raw.desde]);
      ok(r[0] === r[1] && r[3] === r[1], 'Hoy gana a la semana en vuelo: ' + JSON.stringify(r)); await pg.close(); }
    // método, CSV, doble toque, URL
    { const pg = await nuevaPag(); let marcas = 0;
      await pg.route('**/rpc/control_caja_marcar', async r => { marcas++; await new Promise(x => setTimeout(x, 600)); r.fulfill({ contentType: 'application/json', body: '{"ok":true}' }); });
      await pg.goto('http://localhost:8793/reporte-cajas.html?demo=1&dia=abc&tab=hack&met=XX&zona=9&rev=zz&estado=Q&desde=2026-02-31'); await pg.waitForSelector('.kpi');
      ok(await pg.evaluate(() => st.f.dia === '' && st.f.zona === 'TODAS' && st.f.metodo === '' && st.f.rev === '' && st.f.estado === '' && st.tab === 'pend' && st.periodo === 'sem'), 'URL con basura se ignora');
      // H4: KPI de venta con método = suma de las ventas filtradas
      await pg.selectOption('#fMetodo', 'EFECTIVO'); await pg.waitForTimeout(100);
      const kv = await pg.textContent('.kpi:nth-child(2) .v'); const esp = await pg.evaluate(() => S(derive().ventas.reduce((s, v) => s + (+v.total || 0), 0)));
      ok(kv === esp, 'KPI venta con método EFECTIVO: ' + kv + ' vs ' + esp); await pg.selectOption('#fMetodo', '');
      // H7: CSV neutraliza fórmulas
      await pg.evaluate(() => { st.exp = { name: 'x', head: ['a'], rows: [['=1+1'], ['-5'], [-5], ['@x'], ['ok']] }; });
      const [dl] = await Promise.all([pg.waitForEvent('download'), pg.click('#btnCsv')]); const txt = fs.readFileSync(await dl.path(), 'utf8');
      ok(txt.includes("'=1+1") && txt.includes("'-5") && txt.includes("'@x") && /\r\n-5\r\n/.test(txt), 'CSV: texto con = - @ prefijado, número negativo intacto');
      // H8: segundo toque a la misma marca en vuelo se ignora (en modo real)
      await pg.close(); }
    {
      const pg = await nuevaPag(); let marcas = 0;
      await pg.route('**/rpc/reporte_cajas_semana', async r => { const b = r.request().postDataJSON().p; r.fulfill({ contentType: 'application/json', body: await pg.evaluate(([d, h]) => JSON.stringify(Object.assign(demoData(d, h), { ok: true })), [b.desde, b.hasta]) }); });
      await pg.route('**/rpc/control_caja_marcar', async r => { marcas++; await new Promise(x => setTimeout(x, 700)); r.fulfill({ contentType: 'application/json', body: '{"ok":true}' }); });
      await pg.goto('http://localhost:8793/reporte-cajas.html'); await pg.waitForSelector('.kpi');
      await pg.evaluate(() => { const it = st.D.items[0]; marcar(it.tipo, it.ref, 'OK', ''); marcar(it.tipo, it.ref, 'OK', ''); });
      await pg.waitForTimeout(1200); ok(marcas === 1, 'doble toque: una sola llamada (' + marcas + ')'); await pg.close();
    }
    {   // H8 real: doble clic en el primer ✔ = una sola marca; la tarjeta se queda en su sitio con Deshacer
      const pg = await nuevaPag(); let marcas = 0;
      await pg.route('**/rpc/reporte_cajas_semana', async r => { const b = r.request().postDataJSON().p; r.fulfill({ contentType: 'application/json', body: await pg.evaluate(([d, h]) => JSON.stringify(Object.assign(demoData(d, h), { ok: true })), [b.desde, b.hasta]) }); });
      await pg.route('**/rpc/control_caja_marcar', async r => { marcas++; r.fulfill({ contentType: 'application/json', body: '{"ok":true}' }); });
      await pg.goto('http://localhost:8793/reporte-cajas.html'); await pg.waitForSelector('.pend [data-act="ok"]');
      const antes = await pg.evaluate(() => REV.size); const primero = await pg.$eval('.pend .t', e => e.textContent);
      await pg.dblclick('.pend [data-act="ok"]'); await pg.waitForTimeout(800);
      const despues = await pg.evaluate(() => REV.size); const primeroDespues = await pg.$eval('.pend .t', e => e.textContent);
      ok(marcas === 1 && despues === antes + 1, 'dblclick en ✔: 1 llamada y 1 marca (' + marcas + ' llamadas, ' + (despues - antes) + ' marcas)');
      ok(primero === primeroDespues && (await pg.$$eval('.pend.hecho [data-act="deshacer"]', a => a.length)) === 1, 'la tarjeta marcada se queda en su sitio con Deshacer');
      await pg.click('.pend.hecho [data-act="deshacer"]'); await pg.waitForTimeout(200);
      ok((await pg.evaluate(() => REV.size)) === antes, 'Deshacer quita la marca'); await pg.close();
    }
    ok(!errs.length, 'QA: pageerrors ' + errs.join(' / '));
    await ctx.close(); console.log('QA nuevo: ok');
  }
} catch (e) { fallas++; console.log('EXCEPCION', e.message); }
await br.close(); srv.close();
console.log(fallas ? 'RESULTADO: ' + fallas + ' FALLA(S)' : 'RESULTADO: TODO OK');
process.exit(fallas ? 1 : 0);
