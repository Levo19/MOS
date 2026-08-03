// Verifica el módulo nuevo en 3 viewports reales (móvil iPhone / tablet / PC).
// Mide DESBORDE horizontal — el defecto clásico de una tabla de 5 columnas en 375px.
import { chromium } from 'playwright';

const VIEWS = [
  { n: 'MÓVIL iPhone SE', w: 375, h: 667, m: true },
  { n: 'MÓVIL Android',   w: 412, h: 915, m: true },
  { n: 'TABLET',          w: 820, h: 1180, m: true },
  { n: 'PC',              w: 1366, h: 860, m: false }
];
const SES = { idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' };
const browser = await chromium.launch();
let fail = 0;

for (const v of VIEWS) {
  const ctx = await browser.newContext({ viewport: { width: v.w, height: v.h },
    ...(v.m ? devices['iPhone 13'] : {}), viewport2: undefined });
  const page = await ctx.newPage();
  await page.addInitScript(([s]) => {
    localStorage.setItem('mos_device_id', '7e57c1a0-de1c-4a7e-b0de-c47a10906474');
    localStorage.setItem('MOS_SESSION', s);
  }, [JSON.stringify(SES)]);
  await page.setViewportSize({ width: v.w, height: v.h });
  await page.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(9000);
  await page.evaluate(() => { const b = [...document.querySelectorAll('button,a')].find(e => /Entrar a MOS/i.test(e.textContent||'')); if (b) b.click(); });
  await page.waitForTimeout(3000);
  await page.evaluate(() => { try { MOS.nav('proveedores'); } catch(_){} });
  await page.waitForTimeout(5000);
  await page.evaluate(() => { try { MOS.pv2.abrir('PROV070'); } catch(_){} });
  // espera ACTIVA a que la card exista (la red de Pages/Supabase varía por corrida;
  // un timeout fijo daba falsos negativos con la lista aún cargando)
  try {
    await page.waitForFunction(() => [...document.querySelectorAll('.pv2-prod')]
      .some(c => /AJONJOLI BLANCO PREMIUM GRANEL/i.test(c.textContent || '')), { timeout: 45000 });
  } catch (_) { console.log('     ⚠ la card no apareció en 45s (reintentando abrir)');
    await page.evaluate(() => { try { MOS.pv2.abrir('PROV070'); } catch(_){} });
    try { await page.waitForFunction(() => [...document.querySelectorAll('.pv2-prod')]
      .some(c => /AJONJOLI BLANCO PREMIUM GRANEL/i.test(c.textContent || '')), { timeout: 30000 }); } catch (_) {}
  }
  await page.waitForTimeout(1200);

  const r = await page.evaluate(() => {
    const out = {};
    const doc = document.documentElement;
    out.scrollHoriz = doc.scrollWidth > doc.clientWidth + 1;
    const cards = [...document.querySelectorAll('.pv2-prod')];
    const aj = cards.find(c => /AJONJOLI BLANCO PREMIUM GRANEL/i.test(c.textContent||''));
    out.hayCard = !!aj;
    if (aj) {
      // ¿los cuadros se salen de la card?
      const cw = aj.getBoundingClientRect().width;
      out.cuadrosDesbordan = [...aj.querySelectorAll('.pv2-ubi')].some(e => e.getBoundingClientRect().right > aj.getBoundingClientRect().right + 2);
      out.anchoCard = Math.round(cw);
      const b = aj.querySelector('button.pv2-ubi.alm');
      if (b) b.click();
    }
    return out;
  });
  await page.waitForTimeout(1300);
  const o = await page.evaluate(() => {
    const ov = document.getElementById('pv2UbiOvl');
    if (!ov) return { abre: false };
    const box = ov.querySelector('.pv2-ovlbox').getBoundingClientRect();
    const sc = ov.querySelector('.pv2-ovlscroll');
    const tb = ov.querySelector('.pv2-ovltb');
    const cerrar = ov.querySelector('.pv2-ovlx').getBoundingClientRect();
    const call = ov.querySelector('.pv2-ovlcall');
    return {
      abre: true,
      boxDentroPantalla: box.left >= -1 && box.right <= window.innerWidth + 1 && box.bottom <= window.innerHeight + 1,
      anchoBox: Math.round(box.width), altoBox: Math.round(box.height),
      tablaCortada: !!(sc && tb && tb.scrollWidth > sc.clientWidth + 1),
      tapCerrar: Math.round(cerrar.width) + 'x' + Math.round(cerrar.height),
      callVisible: !!call && call.getBoundingClientRect().width > 0,
      docScrollH: document.documentElement.scrollWidth > document.documentElement.clientWidth + 1
    };
  });
  const ok = r.hayCard && !r.scrollHoriz && !r.cuadrosDesbordan && o.abre && o.boxDentroPantalla && !o.tablaCortada && !o.docScrollH;
  if (!ok) fail++;
  console.log(`${ok ? '✅' : '❌'} ${v.n} (${v.w}×${v.h})`);
  console.log(`     card ${r.anchoCard}px · scroll-horizontal-pagina:${r.scrollHoriz} · cuadros-desbordan:${r.cuadrosDesbordan}`);
  console.log(`     overlay ${o.anchoBox}×${o.altoBox} · dentro-pantalla:${o.boxDentroPantalla} · tabla-cortada:${o.tablaCortada} · cerrar:${o.tapCerrar}`);
  await page.screenshot({ path: `C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/shot_resp_${v.w}.png` });
  await ctx.close();
}
await browser.close();
console.log(fail === 0 ? '\n✅ RESPONSIVE OK en los 4 tamaños' : `\n❌ ${fail} tamaño(s) con problemas`);
process.exit(fail === 0 ? 0 : 1);
