// Verifica ME Academy: lecciones nuevas, progreso viejo intacto y sin candados injustos.
import { chromium, webkit } from 'playwright';
const URL = process.argv[2] || 'http://127.0.0.1:8125/academy.html';
const TAG = process.argv[3] || 'v2';
// progreso de un alumno "de antes": las 18 lecciones viejas hechas, 1800 XP
const VIEJO = { xp: 1800, done: {
  'pos-intro':1,'pos-venta':1,'pos-pres':1,'pos-granel':1,'pos-cobrar':1,'pos-ana':1,
  'caja-abrir':1,'caja-tickets':1,'caja-reimp':1,'caja-imp':1,'caja-perm':1,
  'tools-adh':1,'tools-ingreso':1,'tools-salida':1,'tools-dev':1,'tools-horario':1,
  'fin-exam':1,'fin-dip':1 } };

for (const [nm, bt] of [['chromium', chromium], ['webkit', webkit]]) {
  const b = await bt.launch();
  for (const modo of ['nuevo', 'veterano']) {
    for (const w of [390, 1280]) {
      const ctx = await b.newContext({ viewport: { width: w, height: w < 700 ? 820 : 900 }, hasTouch: w < 700, deviceScaleFactor: w < 700 ? 2 : 1 });
      const page = await ctx.newPage();
      const errs = [];
      page.on('pageerror', e => errs.push(String(e).slice(0, 160)));
      if (modo === 'veterano') await page.addInitScript(v => localStorage.setItem('me_academy_v1', v), JSON.stringify(VIEJO));
      await page.goto(URL, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(2500);
      const r = await page.evaluate(() => {
        const st = JSON.parse(localStorage.getItem('me_academy_v1') || '{}');
        const les = [...document.querySelectorAll('.les')];
        return {
          lecciones: les.length,
          hechas: les.filter(e => e.classList.contains('done')).length,
          cerradas: les.filter(e => e.classList.contains('locked')).length,
          cerradasYaHechas: les.filter(e => e.classList.contains('locked') && e.classList.contains('done')).length,
          xp: st.xp, doneN: Object.keys(st.done || {}).length,
          titulo: (document.querySelector('#stage h1') || {}).textContent || '',
          desborde: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          nuevasEnRuta: ['La tarjeta por dentro', 'Parecidos', 'Promociones', 'Escanear'].filter(t => (document.querySelector('#side') || {}).textContent?.includes(t)).length
        };
      });
      console.log(nm.padEnd(9) + modo.padEnd(10) + String(w).padStart(5) + ' ' + JSON.stringify(r) + (errs.length ? ' ERR:' + errs[0] : ''));
      await page.screenshot({ path: `_hap_acad_${TAG}_${nm}_${modo}_${w}.png` });
      await ctx.close();
    }
  }
  await b.close();
}
