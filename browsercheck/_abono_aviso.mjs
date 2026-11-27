// Aviso al eliminar/editar un extra 'Abono deuda' (MOS 2.44.77). Prueba la función real extraída de js/app.js
// + el modal real _modalConfirm, en un solo Chromium. Ejecutar desde browsercheck/:  node _abono_aviso.mjs
import { chromium } from 'playwright'; import fs from 'fs'; import path from 'path';
const src = fs.readFileSync(path.resolve(process.cwd(), '../js/app.js'), 'utf8').replace(/\r/g, '');
const cut = (re) => { const m = re.exec(src); if (!m) throw new Error('no encontrado ' + re); return m[0]; };
const fnAviso = cut(/function _cjExAvisoAbono\(ex\) \{[\s\S]*?\n  \}\n/);
const fnModal = cut(/function _modalConfirm\(msg, opts\) \{[\s\S]*?\n  \}\n/);
const br = await chromium.launch(); let fallas = 0; const ok = (c, m) => { if (!c) { fallas++; console.log('  FALLA:', m); } };
try {
  const pg = await br.newPage();
  await pg.setContent('<body></body>');
  await pg.addScriptTag({ content: fnAviso + fnModal + 'window.__av=_cjExAvisoAbono; window.__mc=_modalConfirm;' });
  const r = await pg.evaluate(() => ({
    abono: window.__av({ concepto: 'Abono deuda', obs: 'ticket V-0123 cobrado' }),
    abonoCaja: window.__av({ concepto: 'abono  deuda', obs: 'Cobró ticket V-77 de caja CJ-9' }),
    sinObs: window.__av({ concepto: 'Abono deuda', obs: '' }),
    otro: window.__av({ concepto: 'Gasolina', obs: 'ticket V-1' }),
    nulo: window.__av(null)
  }));
  ok(r.abono.includes('ticket V-0123') && r.abono.includes('el ticket Z reimpreso de esa caja cambiará'), 'aviso con ticket');
  ok(r.abonoCaja.includes('V-77') && r.abonoCaja.includes('caja CJ-9'), 'caja de la obs');
  ok(r.sinObs.includes('(ver observación)'), 'sin ticket en obs no rompe');
  ok(r.otro === '' && r.nulo === '', 'otros conceptos sin aviso');
  // el modal real muestra el aviso y NO bloquea (se puede confirmar)
  const pr = pg.evaluate((m) => window.__mc(m, { danger: true, titulo: 'Eliminar', okText: 'Sí, eliminar' }), 'Detalle\n\n' + r.abono);
  await pg.waitForSelector('.mos-modal-generic-body');
  ok((await pg.textContent('.mos-modal-generic-body')).includes('V-0123'), 'modal muestra el aviso');
  await pg.click('[data-ok]').catch(() => {});
  const res = await Promise.race([pr, new Promise(x => setTimeout(() => x('timeout'), 3000))]);
  ok(res === true, 'confirmar resuelve true (no bloquea): ' + res);
} catch (e) { fallas++; console.log('EXCEPCION', e.message); }
await br.close();
console.log(fallas ? 'RESULTADO: ' + fallas + ' FALLA(S)' : 'RESULTADO: TODO OK'); process.exit(fallas ? 1 : 0);
