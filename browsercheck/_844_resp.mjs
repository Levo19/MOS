// Auditoría responsive de la cadena de Finanzas: tabla de Productos Vendidos → desglose →
// overlay de tickets → cockpit de la curva. Mide desborde horizontal real y elementos que se
// salen de la pantalla, en los tamaños que usa el equipo.
import { chromium, webkit, devices } from 'playwright';

const VIEWPORTS = [
  { n: 'iPhone SE',      w: 375,  h: 667,  touch: true,  wk: true  },
  { n: 'iPhone 14 Pro',  w: 393,  h: 852,  touch: true,  wk: true  },
  { n: 'Android grande', w: 412,  h: 915,  touch: true,  wk: false },
  { n: 'iPad',           w: 820,  h: 1180, touch: true,  wk: true  },
  { n: 'PC 1280',        w: 1280, h: 800,  touch: false, wk: false },
  { n: 'PC 1920',        w: 1920, h: 1080, touch: false, wk: false },
];

const midiendo = `(() => {
  const doc = document.documentElement;
  const out = { desbordeDoc: Math.max(0, doc.scrollWidth - doc.clientWidth), culpables: [] };
  const W = doc.clientWidth;
  document.querySelectorAll('body *').forEach(el => {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return;
    if (r.right > W + 1.5 || r.left < -1.5) {
      const st = getComputedStyle(el);
      if (st.position === 'fixed' && r.width <= W + 2) return;      // overlays a pantalla completa
      let cont = el.parentElement, scrollable = false;
      for (let i = 0; i < 4 && cont; i++, cont = cont.parentElement) {
        const cs = getComputedStyle(cont);
        if (cs.overflowX === 'auto' || cs.overflowX === 'scroll') { scrollable = true; break; }
      }
      if (scrollable) return;                                        // desborde intencional con scroll propio
      out.culpables.push({
        tag: el.tagName.toLowerCase(),
        cls: String(el.className || '').toString().split(' ').filter(Boolean).slice(0, 3).join('.'),
        sale: Math.round(Math.max(r.right - W, -r.left))
      });
    }
  });
  const vistos = new Set();
  out.culpables = out.culpables.filter(c => { const k = c.tag + '.' + c.cls; if (vistos.has(k)) return false; vistos.add(k); return true; }).slice(0, 6);
  return out;
})()`;

const chicos = `(() => {
  // objetivos táctiles menores a 32px: incómodos en teléfono
  const малы = [];
  document.querySelectorAll('button, .fin-prod-row, .fpd-tk, .cov-tab, .cov-ab').forEach(el => {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return;
    if (r.height < 32) малы.push({ cls: String(el.className||'').split(' ').filter(Boolean)[0] || el.tagName.toLowerCase(), h: Math.round(r.height) });
  });
  const v = new Set();
  return малы.filter(x => { if (v.has(x.cls)) return false; v.add(x.cls); return true; }).slice(0, 5);
})()`;

for (const vp of VIEWPORTS) {
  const motor = vp.wk ? webkit : chromium;
  const b = await motor.launch();
  const ctx = await b.newContext({ viewport: { width: vp.w, height: vp.h }, hasTouch: vp.touch, isMobile: vp.touch, deviceScaleFactor: 2 });
  const p = await ctx.newPage();
  await p.addInitScript(dev => localStorage.setItem('mos_device_id', dev), '7e57c1a0-de1c-4a7e-b0de-c47a10906477');
  const linea = [vp.n.padEnd(15), (vp.w + 'x' + vp.h).padEnd(10), (vp.wk ? 'WebKit' : 'Chromium').padEnd(9)];
  try {
    await p.goto('https://levo19.github.io/MOS/', { waitUntil: 'domcontentloaded' });
    await p.waitForTimeout(7000);
    try { await p.click('text=/Entrar a MOS/i', { timeout: 4000 }); } catch {}
    await p.waitForFunction(() => { try { return !!MOS; } catch { return false; } }, { timeout: 60000 });
    await p.evaluate(() => MOS.nav('finanzas'));
    await p.waitForTimeout(15000);
    await p.evaluate(() => { try { MOS.finAbrirModalProductos(); } catch(e){} });
    await p.waitForTimeout(2500);
    const tabla = await p.evaluate(midiendo);

    await p.evaluate(() => { const r=[...document.querySelectorAll('.fin-prod-row')].find(x=>/LEV024/.test(x.textContent))||document.querySelector('.fin-prod-row'); if(r) r.click(); });
    await p.waitForTimeout(6000);
    const desg = await p.evaluate(midiendo);
    const tap = await p.evaluate(chicos);

    await p.evaluate(() => { const t=document.querySelector('.fpd-tk'); if(t) t.click(); });
    await p.waitForTimeout(6000);
    const tick = await p.evaluate(midiendo);
    await p.evaluate(() => { try { MOS.finTicketsCerrar(); } catch(e){} });
    await p.waitForTimeout(600);

    await p.evaluate(() => {
      window._paso2Filas = [{ nombre:'GLUTAMATO 1KG', precioActual:14.5,
        x:{ idCanonico:'IDPRO0000035', descripcion:'GLUTAMATO 1KG', costoNuevo:13.2 } }];
      return MOS.curvaOverlay(0);
    });
    await p.waitForTimeout(9000);
    const curva = await p.evaluate(midiendo);
    const lienzo = await p.evaluate(() => { const c=document.getElementById('covCanvas'); if(!c) return null;
      const r=c.getBoundingClientRect(); return Math.round(r.width)+'x'+Math.round(r.height); });

    const fmt = (o) => (o.desbordeDoc > 1 ? ('❌ ' + o.desbordeDoc + 'px' + (o.culpables.length ? ' ['+o.culpables.map(c=>c.tag+'.'+c.cls+' +'+c.sale).join(', ')+']' : '')) : '✅');
    console.log(linea.join('') + 'tabla ' + fmt(tabla).padEnd(12) + ' · desglose ' + fmt(desg).padEnd(12) +
                ' · tickets ' + fmt(tick).padEnd(12) + ' · curva ' + fmt(curva) + ' (lienzo ' + lienzo + ')' +
                (tap.length ? ' · toques chicos: ' + tap.map(t=>t.cls+' '+t.h+'px').join(', ') : ''));
  } catch (e) {
    console.log(linea.join('') + '⚠ ' + String(e.message).slice(0, 90));
  }
  await b.close();
}
