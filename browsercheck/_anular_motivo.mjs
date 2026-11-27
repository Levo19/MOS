// Modal de motivo de anulación (MOS 2.44.77, SQL 1056): chips + texto libre, botón deshabilitado hasta >=5. 1 Chromium.
import { chromium } from 'playwright'; import fs from 'fs'; import path from 'path';
const src = fs.readFileSync(path.resolve(process.cwd(), '../js/app.js'), 'utf8').replace(/\r/g, '');
const m = /function _pedirMotivoAnulacion\(label\) \{[\s\S]*?\n  \}\n/.exec(src); if (!m) throw new Error('no encontrado');
const calls = src.match(/API\.post\('anularTicketME', \{[^}]*\}/g) || [];
const br = await chromium.launch(); let fallas = 0; const ok = (c, t) => { if (!c) { fallas++; console.log('  FALLA:', t); } };
try {
  ok(calls.length === 2 && calls.every(c => c.includes('motivo')), 'las 2 llamadas anularTicketME envían motivo');
  const pg = await br.newPage(); await pg.setContent('<body></body>');
  await pg.addScriptTag({ content: m[0] + 'window.__p=_pedirMotivoAnulacion;' });
  await pg.evaluate(() => { window.__r = 'pend'; window.__p('Ticket B001-1').then(v => { window.__r = v; }); }); await pg.waitForSelector('#anuMotivo');
  ok(await pg.isDisabled('[data-ok]'), 'botón deshabilitado al inicio');
  await pg.fill('#anuMotivo', 'abc'); ok(await pg.isDisabled('[data-ok]'), 'deshabilitado con <5');
  await pg.click('[data-chip="Venta duplicada"]'); ok(!(await pg.isDisabled('[data-ok]')), 'chip habilita');
  await pg.click('[data-ok]'); await pg.waitForFunction(() => window.__r !== 'pend'); ok((await pg.evaluate(() => window.__r)) === 'Venta duplicada', 'devuelve el motivo'); await pg.waitForSelector('#anuMotivo', { state: 'detached' });
  await pg.evaluate(() => { window.__r = 'pend'; window.__p('x').then(v => { window.__r = v; }); }); await pg.waitForSelector('#anuMotivo'); await pg.click('[data-cancel] >> nth=1');
  await pg.waitForFunction(() => window.__r !== 'pend'); ok((await pg.evaluate(() => window.__r)) === null, 'cancelar devuelve null');
} catch (e) { fallas++; console.log('EXCEPCION', e.message); }
await br.close(); console.log(fallas ? 'RESULTADO: ' + fallas + ' FALLA(S)' : 'RESULTADO: TODO OK'); process.exit(fallas ? 1 : 0);
