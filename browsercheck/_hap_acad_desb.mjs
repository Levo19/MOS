// ¿Qué elemento desborda la Academy en móvil? Recorre las lecciones y mide.
import { chromium, webkit } from 'playwright';
const URL = process.argv[2] || 'http://127.0.0.1:8125/academy.html';
const TODO = { xp: 2200, done: {} };
['pos-intro','pos-venta','pos-card','pos-pres','pos-agotado','pos-promo','pos-granel','pos-scan','pos-cobrar','pos-ana',
 'caja-abrir','caja-tickets','caja-reimp','caja-imp','caja-perm',
 'tools-adh','tools-ingreso','tools-salida','tools-dev','tools-horario','fin-exam','fin-dip'].forEach(k => TODO.done[k] = 1);

for (const [nm, bt] of [['chromium', chromium], ['webkit', webkit]]) {
  const b = await bt.launch();
  for (const w of [360, 390, 768, 1024, 1280]) {
    const ctx = await b.newContext({ viewport: { width: w, height: w < 700 ? 820 : 900 }, hasTouch: w < 700, deviceScaleFactor: w < 700 ? 2 : 1 });
    const page = await ctx.newPage();
    await page.addInitScript(v => localStorage.setItem('me_academy_v1', v), JSON.stringify(TODO));
    await page.goto(URL, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1800);
    const ids = ['pos-intro','pos-card','pos-pres','pos-agotado','pos-promo','pos-scan','pos-ana','caja-tickets','tools-ingreso','fin-exam','fin-dip'];
    for (const id of ids) {
      await page.evaluate(i => { const e = document.querySelector('[data-go="' + i + '"]'); if (e) e.click(); }, id);
      await page.waitForTimeout(700);
      const r = await page.evaluate(() => {
        const W = window.innerWidth, doc = document.documentElement;
        const vis = el => { const q = el.getBoundingClientRect(); const s = getComputedStyle(el);
          return q.width > 0 && q.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
        const sel = el => { let s = el.tagName.toLowerCase(); if (el.id) s += '#' + el.id;
          const c = (el.className || '').toString().trim().split(/[ ]+/).filter(Boolean).slice(0, 2).join('.'); if (c) s += '.' + c; return s; };
        const out = { d: doc.scrollWidth - doc.clientWidth, f: [] };
        document.querySelectorAll('body *').forEach(el => { if (!vis(el)) return;
          const q = el.getBoundingClientRect();
          if (q.right > W + 1 && q.width < W * 3) out.f.push(sel(el) + '@' + Math.round(q.right) + '/w' + Math.round(q.width)); });
        out.f = [...new Set(out.f)].slice(0, 6);
        const tac = [...document.querySelectorAll('button,[data-go],.opt,.fopt,.lopt,.chip')].filter(vis)
          .filter(e => { const q = e.getBoundingClientRect(); return q.height < 40 || q.width < 26; })
          .map(e => sel(e) + ' ' + Math.round(e.getBoundingClientRect().width) + 'x' + Math.round(e.getBoundingClientRect().height));
        out.t = [...new Set(tac)].slice(0, 6);
        return out;
      });
      if (r.d > 0 || r.f.length || r.t.length) console.log(nm.padEnd(9) + String(w).padStart(5) + ' ' + id.padEnd(14) + ' desb=' + r.d + ' | ' + r.f.join(' ; ') + ' | tactil: ' + r.t.join(' ; '));
    }
    await ctx.close();
  }
  await b.close();
}
console.log('fin');
