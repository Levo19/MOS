const { chromium } = require('playwright');
const fs = require('fs');
const html = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/index.html', 'utf8');
const cssIni = html.indexOf('#infraContenedor .devt{position:relative');
const css = html.slice(cssIni, html.indexOf('/* Toggle switch', cssIni));
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1200, height: 800 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.setContent(`<style>${css}</style>
    <div id="infraContenedor" style="padding:80px">
      <div class="fleet"><div class="devt phone"><div class="face"><div class="avatar">L</div></div></div></div>
    </div>
    <script>
      const cont = document.getElementById('infraContenedor');
      cont.addEventListener('pointermove', (ev) => {
        const card = ev.target.closest && ev.target.closest('.devt');
        if (!card) return;
        const r = card.getBoundingClientRect();
        if (!r.width || !r.height) return;
        const px = (ev.clientX - r.left) / r.width, py = (ev.clientY - r.top) / r.height;
        card.style.setProperty('--mx', (px * 100).toFixed(1) + '%');
        card.style.setProperty('--my', (py * 100).toFixed(1) + '%');
        card.style.setProperty('--ry', ((px - 0.5) * 7).toFixed(2) + 'deg');
        card.style.setProperty('--rx', ((0.5 - py) * 7).toFixed(2) + 'deg');
      }, { passive: true });
    <\/script>`);
  const card = p.locator('.devt');
  const box = await card.boundingBox();
  await p.mouse.move(box.x + box.width * 0.85, box.y + box.height * 0.2);
  await p.waitForTimeout(300);
  const r = await p.evaluate(() => {
    const el = document.querySelector('.devt');
    return { rx: el.style.getPropertyValue('--rx'), ry: el.style.getPropertyValue('--ry'),
      transform: getComputedStyle(el).transform.slice(0, 60),
      afterOpacity: getComputedStyle(el, '::after').opacity };
  });
  console.log(JSON.stringify(r, null, 1), 'errs:', errs);
  // matrix3d con rotación real: los términos [2] y [6] dejan de ser 0 cuando hay rotateX/Y
  const rota = /matrix3d\(/.test(r.transform) && !/^matrix3d\(1\.02, 0, 0, 0, 0, 1\.02/.test(r.transform);
  console.log(r.rx && r.ry && rota && Number(r.afterOpacity) > 0.5
    ? '✅ tilt + spotlight FUNCIONAN (rotación real en la matriz)' : '❌ sigue sin rotar');
  await b.close();
})();
