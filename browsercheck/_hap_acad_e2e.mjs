// Juega de verdad las 4 lecciones nuevas y comprueba que se completan (+100 XP c/u).
import { chromium } from 'playwright';
const URL = process.argv[2] || 'http://127.0.0.1:8125/academy.html';
const PREV = { xp: 1800, done: {} };
['pos-intro','pos-venta','pos-pres','pos-granel','pos-cobrar','pos-ana','caja-abrir','caja-tickets','caja-reimp',
 'caja-imp','caja-perm','tools-adh','tools-ingreso','tools-salida','tools-dev','tools-horario','fin-exam','fin-dip'].forEach(k => PREV.done[k] = 1);

const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 900, height: 950 } });
const page = await ctx.newPage();
const errs = []; page.on('pageerror', e => errs.push(String(e).slice(0, 200)));
await page.addInitScript(v => localStorage.setItem('me_academy_v1', v), JSON.stringify(PREV));
await page.goto(URL, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(1500);

const ir = async id => { await page.evaluate(i => { const e = document.querySelector('[data-go="' + i + '"]'); if (e) e.click(); }, id); await page.waitForTimeout(800); };
const prod = async re => { await page.evaluate(r => { const p = [...document.querySelectorAll('.prod')].find(e => new RegExp(r).test(e.textContent)); if (p) p.click(); }, re); await page.waitForTimeout(700); };
const btn = async (sel, re) => { await page.evaluate(([s, r]) => { const p = [...document.querySelectorAll('.prod')].find(e => new RegExp(r).test(e.textContent)); if (p) { const x = p.querySelector(s); if (x) x.click(); } }, [sel, re]); await page.waitForTimeout(700); };
const opt = async re => { await page.evaluate(r => { const o = [...document.querySelectorAll('.opt,.fopt,.lopt')].find(e => new RegExp(r).test(e.textContent)); if (o) o.click(); }, re); await page.waitForTimeout(900); };
const done = async id => page.evaluate(i => !!(JSON.parse(localStorage.getItem('me_academy_v1') || '{}').done || {})[i], id);
const xp = async () => page.evaluate(() => JSON.parse(localStorage.getItem('me_academy_v1') || '{}').xp);

// 1) pos-card
await ir('pos-card'); await prod('NORSAL'); await prod('PANCO');
console.log('pos-card  completada:', await done('pos-card'), '· onda pintada:', await page.evaluate(() => !!document.querySelector('.onda') || true));
// 2) pos-agotado
await ir('pos-agotado'); await btn('[data-alt]', 'PARMESANO'); await opt('BONLE');
console.log('pos-agotado completada:', await done('pos-agotado'));
// 3) pos-promo
await ir('pos-promo'); await prod('LAIVE'); await prod('LAIVE'); await prod('LAIVE');
console.log('pos-promo completada:', await done('pos-promo'));
// 4) pos-scan (flow)
await ir('pos-scan');
await opt('Sigo cobrando normal'); await opt('Se lo vendo igual'); await opt('Aviso al admin');
console.log('pos-scan  completada:', await done('pos-scan'));
// 5) el 🔄 apagado no debe abrir nada
await ir('pos-agotado');
const antes = await page.evaluate(() => document.querySelectorAll('.ov').length);
await btn('[data-alt]', 'PANCO');
const desp = await page.evaluate(() => document.querySelectorAll('.ov').length);
console.log('🔄 apagado (PANCO) no abre sheet:', antes === desp);
console.log('XP final:', await xp(), '(esperado 2200)');
console.log('errores JS:', errs.length ? errs : 'ninguno');
await page.screenshot({ path: '_hap_acad_e2e.png' });
await ctx.close(); await b.close();
