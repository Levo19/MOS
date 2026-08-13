// Captura puntual: el filtro "Sin foto" del overlay de IGV a favor (aviso ámbar)
// y el filtro "Recuperables" al que salta la franja de alerta.
import { createRequire } from 'node:module';
import { MOCK } from './_trib_mock.mjs';
const require = createRequire('C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/package.json');
const { chromium } = require('playwright');
const w = ms => new Promise(r => setTimeout(r, ms));
const OUT = 'C:/Users/ISO/ecosistema MOS/ProyectoMOS/.claude/worktrees/agent-a92f86812f5457f83/browsercheck/_trib_shots/';
(async () => {
  const b = await chromium.launch({ headless: true });
  for (const v of [{ n: '390', width: 390, height: 844 }, { n: '1280', width: 1280, height: 900 }]) {
    const ctx = await b.newContext({ viewport: { width: v.width, height: v.height }, deviceScaleFactor: 2 });
    await ctx.addInitScript(() => {
      localStorage.setItem('mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906474');
      localStorage.setItem('MOS_SESSION', '{"idPersonal":"TEST-CLAUDE","nombre":"PRUEBA CLAUDE","rol":"MASTER","idSesion":"testclaude1"}');
    });
    const p = await ctx.newPage();
    const errs = [];
    p.on('pageerror', e => errs.push(e.message));
    await p.goto('http://127.0.0.1:8203/index.html', { waitUntil: 'domcontentloaded' });
    await w(9000);
    await p.evaluate(() => {
      const limpiar = () => {
        document.documentElement.classList.remove('da-pre-block');
        document.body.classList.remove('da-blocked');
        ['deviceAuthOverlay', 'daApproveToast', 'da-fatal-fallback', 'mosPermsOverlay', 'segBadge'].forEach(id => document.getElementById(id)?.remove());
        document.querySelectorAll('.da-insitu-overlay').forEach(e => e.remove());
      };
      limpiar(); setInterval(limpiar, 400);
    });
    await p.evaluate(MOCK);
    await p.evaluate(() => MOS.nav('tributario'));
    await w(7000);
    await p.evaluate(() => MOS.tribAbrirIGVFavor('SIN_FOTO'));
    await w(2600);
    await p.screenshot({ path: OUT + 'trib_ov_sinfoto_' + v.n + '.png' });
    await p.evaluate(() => MOS._tribSetIGVFiltro('ILEGIBLE'));
    await w(900);
    await p.screenshot({ path: OUT + 'trib_ov_ilegibles_' + v.n + '.png' });
    console.log(v.n, 'pageerrors:', errs.length, errs.slice(0, 3));
    await ctx.close();
  }
  await b.close();
})();
