// Barrido de DESCUADRES en ME: vistas principales × 360/390/768/1024/1280 × Chromium/WebKit.
// Usa contexto PERSISTENTE (el catálogo real queda en IndexedDB → solo la 1ª carga es lenta).
import { chromium, webkit } from 'playwright';
import { prepararPagina } from './_hap_seed.mjs';

const URL = process.argv[2] || 'http://127.0.0.1:8123/index.html';
const TAG = process.argv[3] || 'antes';
const ANCHOS = (process.argv[4] || '360,390,768,1024,1280').split(',').map(Number);
const MOTORES = (process.argv[5] || 'chromium,webkit').split(',');
const BT = { chromium, webkit };

const VISTAS = [
  { id: 'pos', go: `(()=>{ const b=document.querySelector('[data-navtab="POS"]'); if(b) b.click(); })()` },
  { id: 'carrito', go: `(()=>{ document.querySelectorAll('.pos-card').forEach((c,i)=>{ if(i<4) c.click(); }); const f=[...document.querySelectorAll('button')].find(b=>/Cambiar vista/i.test(b.getAttribute('aria-label')||'')); if(f) f.click(); })()` },
  { id: 'cobro', go: `(()=>{ const b=[...document.querySelectorAll('button')].find(e=>/COBRAR/i.test((e.textContent||'').trim())&&!e.disabled); if(b) b.click(); })()` },
  { id: 'cobro-cerrar', go: `(()=>{ const b=[...document.querySelectorAll('button')].find(e=>/^(✕|×|Cancelar|CANCELAR|VOLVER)$/.test((e.textContent||'').trim())); if(b) b.click(); })()`, saltar: true },
  { id: 'caja', go: `(()=>{ const b=document.querySelector('[data-navtab="CAJA"]'); if(b) b.click(); })()` },
  { id: 'historial', go: `(()=>{ const b=[...document.querySelectorAll('button')].find(e=>/^(BOLETAS|Boletas)$/.test((e.textContent||'').trim())); if(b) b.click(); })()` },
  { id: 'tools', go: `(()=>{ const b=document.querySelector('[data-navtab="TOOLS"]'); if(b) b.click(); })()` },
  { id: 'guias', go: `(()=>{ const b=[...document.querySelectorAll('button')].find(e=>/GU[IÍ]A/i.test((e.textContent||'').trim())); if(b) b.click(); })()` }
];

const MEDIR = `(() => {
  const doc = document.documentElement, W = window.innerWidth;
  const out = { W, desborde: doc.scrollWidth - doc.clientWidth };
  const vis = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.05; };
  const sel = el => { let s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    const c = (el.className || '').toString().trim().split(/[ ]+/).filter(Boolean).slice(0, 3).join('.');
    if (c) s += '.' + c; return s; };
  const uniq = a => { const m = {}; a.forEach(x => { const k = x.q + '|' + (x.extra||x.right||x.h); m[k] = m[k] ? Object.assign({}, x, {n: m[k].n + 1}) : Object.assign({}, x, {n: 1}); }); return Object.keys(m).map(k=>m[k]); };
  const fuera = [];
  document.querySelectorAll('body *').forEach(el => { if (!vis(el)) return;
    const r = el.getBoundingClientRect();
    if (r.right > W + 1 && r.width < W * 3) fuera.push({ q: sel(el), right: Math.round(r.right), w: Math.round(r.width) }); });
  out.fueraDerecha = uniq(fuera).slice(0, 10);
  const cort = [];
  document.querySelectorAll('button, .cab, h1, h2, h3, span, div, p, td, th').forEach(el => { if (!vis(el)) return;
    const s = getComputedStyle(el);
    if (s.overflow === 'hidden' && s.textOverflow !== 'ellipsis' && el.scrollWidth - el.clientWidth > 2 && el.children.length < 4 && (el.textContent||'').trim())
      cort.push({ q: sel(el), extra: el.scrollWidth - el.clientWidth, txt: (el.textContent||'').trim().slice(0,26) }); });
  out.recortados = uniq(cort).slice(0, 10);
  const chicos = [];
  document.querySelectorAll('button, [role=button], input[type=checkbox]').forEach(el => { if (!vis(el)) return;
    const r = el.getBoundingClientRect();
    if (r.height < 40 || r.width < 26) chicos.push({ q: sel(el), h: +r.height.toFixed(1), w: +r.width.toFixed(1), txt: (el.textContent||'').trim().slice(0,20) }); });
  out.tactilChico = uniq(chicos).slice(0, 14); out.tactilChicoN = chicos.length;
  out.botonesVisibles = [...document.querySelectorAll('button')].filter(vis).length;
  const inp = [...document.querySelectorAll('input,select,textarea')].filter(vis)
    .filter(i => parseFloat(getComputedStyle(i).fontSize) < 16)
    .map(i => ({ q: sel(i), fs: getComputedStyle(i).fontSize }));
  out.inputChicos = uniq(inp).slice(0, 8); out.inputChicosN = inp.length;
  out.txt = (document.body.innerText||'').replace(/\\s+/g,' ').slice(0, 90);
  return out;
})()`;

for (const nm of MOTORES) {
  const ctx = await BT[nm].launchPersistentContext(`./_hap_prof_${nm}`, {
    viewport: { width: 390, height: 800 }, hasTouch: true,
    isMobile: nm === 'chromium' ? true : undefined, deviceScaleFactor: 2,
    permissions: nm === 'chromium' ? ['notifications', 'geolocation'] : []
  });
  const page = ctx.pages()[0] || await ctx.newPage();
  await prepararPagina(page, ctx);
  page.setDefaultTimeout(120000); page.setDefaultNavigationTimeout(120000);
  for (let intento = 1; intento <= 3; intento++) {
    try { await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 120000 }); break; }
    catch (e) { console.log('# ' + nm + ' goto intento ' + intento + ' falló: ' + String(e).slice(0, 60)); await page.waitForTimeout(4000); }
  }
  // El catálogo real pesa: la RPC tiene 90s de timeout duro. Si se toca "Reintentar"
  // antes, se aborta la descarga en curso y nunca termina. Por eso se reintenta como
  // mucho cada 100s y el resto del tiempo solo se espera.
  let listo = false, ultimoRetry = 0;
  for (let i = 0; i < 90; i++) {
    await page.waitForTimeout(4000);
    const t = i * 4;
    listo = await page.evaluate((puedeRetry) => {
      if (document.querySelector('.pos-card')) return true;
      const bs = [...document.querySelectorAll('button')];
      const e1 = bs.find(e => /Entrar a ME/i.test(e.textContent || ''));
      if (e1) { e1.click(); return false; }
      if (puedeRetry) {
        const e2 = bs.find(e => /Reintentar descarga/i.test(e.textContent || ''));
        if (e2) { e2.click(); return 'retry'; }
      }
      return !!document.querySelector('.pos-card');
    }, t - ultimoRetry > 100).catch(() => false);
    if (listo === 'retry') { ultimoRetry = t; listo = false; }
    if (listo === true) break;
  }
  console.log('# ' + nm + ' listo=' + listo);
  for (const w of ANCHOS) {
    await page.setViewportSize({ width: w, height: w < 700 ? 800 : 860 });
    await page.waitForTimeout(1200);
    for (const v of VISTAS) {
      try { await page.evaluate(v.go); } catch (_) {}
      await page.waitForTimeout(1300);
      if (v.saltar) continue;
      let r; try { r = await page.evaluate(MEDIR); } catch (e) { r = { err: String(e).slice(0, 90) }; }
      console.log('### ' + nm + ' ' + w + ' ' + v.id + ' ' + JSON.stringify(r));
      await page.screenshot({ path: `_hap_${TAG}_${nm}_${w}_${v.id}.png` }).catch(() => {});
    }
  }
  await ctx.close();
}
