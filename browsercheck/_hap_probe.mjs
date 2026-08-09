// Sonda ME: espera activa a que cargue el catálogo y llegue al POS.
import { chromium } from 'playwright';
const DEV = '7e57c1a0-de1c-4a7e-b0de-c47a10906476';
const URL = process.argv[2] || 'http://127.0.0.1:8123/index.html';
const SHOT = process.argv[3] || '_hap_probe.png';
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, deviceScaleFactor: 2 });
const page = await ctx.newPage();
const logs = [], fails = [];
page.on('console', m => logs.push(m.type() + ': ' + m.text().slice(0, 220)));
page.on('requestfailed', r => fails.push(r.url().slice(0, 120) + ' :: ' + (r.failure() || {}).errorText));
await page.addInitScript((d) => { localStorage.setItem('mosexpress_deviceId', d); }, DEV);
await page.goto(URL, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(30000);
// intenta pasar la pantalla de permisos
await page.evaluate(() => {
  const b = [...document.querySelectorAll('button')].find(e => /Entrar a ME/i.test(e.textContent || ''));
  if (b) b.click();
});
await page.waitForTimeout(20000);
const r = await page.evaluate(() => ({
  txt: (document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 800),
  users: [...document.querySelectorAll('button,div')].filter(e => (e.className || '').toString().includes('user')).length,
  cards: document.querySelectorAll('.pos-card').length,
  dbRaw: !!localStorage.getItem('mosexpress_db'),
  dbLen: (localStorage.getItem('mosexpress_db') || '').length
}));
console.log(JSON.stringify(r, null, 1));
console.log('--- reqfailed ---\n' + fails.slice(0, 15).join('\n'));
console.log('--- logs ---\n' + logs.slice(-20).join('\n'));
await page.screenshot({ path: SHOT, fullPage: false });
await browser.close();
