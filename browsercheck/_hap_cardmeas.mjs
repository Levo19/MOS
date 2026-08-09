// Mide la barra de acciones de la card v2 a distintos anchos, en Chromium y WebKit.
import { chromium, webkit } from 'playwright';
const URL = 'http://127.0.0.1:8124/_hap_card.html';
const ANCHOS = [360, 390, 412, 768, 1024, 1280];
const TAG = process.argv[2] || 'antes';
const motores = [['chromium', chromium], ['webkit', webkit]];
for (const [nm, bt] of motores) {
  const b = await bt.launch();
  for (const w of ANCHOS) {
    const mob = w < 700;
    const ctx = await b.newContext({ viewport: { width: w, height: 820 }, hasTouch: mob, isMobile: nm === 'chromium' ? mob : undefined, deviceScaleFactor: mob ? 2 : 1 });
    const page = await ctx.newPage();
    await page.goto(URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(900);
    const r = await page.evaluate(() => {
      const card = document.querySelectorAll('.pos-card')[1]; // la agotada (ambos botones activos)
      const acts = card.querySelector('.cardv2-acts');
      const bs = [...acts.querySelectorAll('.cab')];
      const cs = getComputedStyle(bs[0]);
      const r0 = bs[0].getBoundingClientRect(), r1 = bs[1].getBoundingClientRect();
      const sp = bs[0].querySelector('span');
      // ¿el texto se está recortando?
      const recorte = bs.map(x => { const s = x.querySelector('span'); return s ? Math.round(s.scrollWidth - s.clientWidth) : 0; });
      const overflowBtn = bs.map(x => Math.round(x.scrollWidth - x.clientWidth));
      return {
        anchoCard: +card.getBoundingClientRect().width.toFixed(1),
        btnW: [+r0.width.toFixed(1), +r1.width.toFixed(1)],
        btnH: +r0.height.toFixed(1),
        gap: +(r1.left - r0.right).toFixed(1),
        fontSize: cs.fontSize, padding: cs.padding, letterSpacing: cs.letterSpacing,
        touchAction: cs.touchAction,
        textoBtn: bs.map(x => (x.textContent || '').trim()),
        recorteSpanPx: recorte, overflowBtnPx: overflowBtn,
        docOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth + 1
      };
    });
    console.log(nm.padEnd(9) + String(w).padStart(5) + 'px  ' + JSON.stringify(r));
    if (w === 360 || w === 390) await page.screenshot({ path: `_hap_card_${TAG}_${nm}_${w}.png`, clip: { x: 0, y: 0, width: w, height: 420 } });
    await ctx.close();
  }
  await b.close();
}
