// check.js — harness de navegador real (Playwright/Chromium headless) para el ecosistema MOS.
// Uso: node check.js escenario.json
// escenario.json: {
//   url:            "https://levo19.github.io/MosExpress/",
//   localStorage:   { clave: "valor", ... }   // inyectado ANTES de cargar (addInitScript)
//   waitMs:         35000,                      // cuánto observar (deja disparar ping/pollers)
//   evalAfter:      "return window.APP_VERSION || null;"  // JS ejecutado en la página tras esperar
//   screenshot:     "shot.png",                 // ruta (relativa a esta carpeta)
//   blockGasHard:   false                       // si true, ABORTA cualquer request a script.google.com
// }
// Salida: consola de la página, tabla de red categorizada (🚨 GAS resaltado), resultado del eval, ruta del screenshot.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

function categorize(url) {
  if (url.includes('script.google.com') || url.includes('script.googleusercontent.com')) return 'GAS';
  if (url.includes('.supabase.co/rest/'))    return 'SB-REST';
  if (url.includes('.supabase.co/rpc') || url.includes('/rest/v1/rpc/')) return 'SB-RPC';
  if (url.includes('.supabase.co/auth/'))    return 'SB-AUTH';
  if (url.includes('.supabase.co/functions/')) return 'SB-EDGE';
  if (url.includes('.supabase.co'))          return 'SB-OTHER';
  if (url.includes('printnode.com'))         return 'PRINTNODE';
  if (url.includes('firebase') || url.includes('gstatic') || url.includes('googleapis')) return 'FIREBASE/CDN';
  if (url.includes('unpkg.com') || url.includes('cdn'))  return 'CDN';
  if (url.includes('levo19.github.io'))      return 'APP';
  return 'OTHER';
}

(async () => {
  const scenPath = process.argv[2];
  if (!scenPath) { console.error('falta escenario.json'); process.exit(1); }
  const S = JSON.parse(fs.readFileSync(scenPath, 'utf8'));
  const url = S.url || 'https://levo19.github.io/MosExpress/';
  const waitMs = S.waitMs ?? 30000;

  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: S.viewport || { width: 430, height: 900 } }); // móvil por defecto; S.viewport para tablet/escritorio
  const page = await ctx.newPage();

  const consoleLogs = [];
  const netByCat = {};
  const gasHits = [];
  const errors = [];

  page.on('console', m => consoleLogs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => errors.push('PAGEERROR: ' + e.message));

  // Semilla de localStorage antes de cargar.
  if (S.localStorage) {
    await page.addInitScript(ls => {
      for (const [k, v] of Object.entries(ls)) {
        try { localStorage.setItem(k, typeof v === 'string' ? v : JSON.stringify(v)); } catch (_) {}
      }
    }, S.localStorage);
  }

  // Interceptar red.
  await page.route('**/*', route => {
    const rurl = route.request().url();
    const cat = categorize(rurl);
    netByCat[cat] = (netByCat[cat] || 0) + 1;
    if (cat === 'GAS') {
      var body = '';
      try { body = route.request().postData() || ''; } catch(_) {}
      var qs = rurl.includes('?') ? rurl.slice(rurl.indexOf('?')) : '';
      var accion = (body.match(/"action"\s*:\s*"([^"]+)"/) || qs.match(/action=([a-zA-Z_]+)/) || [,'(sin action)'])[1];
      gasHits.push(route.request().method() + ' [' + accion + '] ' + (rurl.includes('AKfycbzG') ? 'API_URL' : 'MOS_GAS') + (body ? ' body=' + body.slice(0,120) : ''));
      if (S.blockGasHard) { route.abort(); return; }
    }
    route.continue();
  });

  // Respuestas: capturar status de lo interesante (SB + GAS).
  const responses = [];
  page.on('response', r => {
    const cat = categorize(r.url());
    if (['GAS','SB-RPC','SB-AUTH','SB-EDGE','SB-REST'].includes(cat)) {
      responses.push(`${r.status()} [${cat}] ${r.request().method()} ${r.url().slice(0,150)}`);
    }
  });

  console.log(`\n=== NAVEGANDO: ${url} ===`);
  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  } catch (e) { errors.push('GOTO: ' + e.message); }

  console.log(`(observando ${waitMs}ms — dejando disparar ping/pollers/auth)`);
  await page.waitForTimeout(waitMs);

  // Eval en el contexto de la página.
  let evalResult = null;
  if (S.evalAfter) {
    // evalAfter es una EXPRESIÓN (puede ser una IIFE async: "(async()=>{...})()").
    try { evalResult = await page.evaluate(S.evalAfter); }
    catch (e) { evalResult = 'EVAL_ERROR: ' + e.message; }
  }

  // Screenshot.
  let shotPath = null;
  if (S.screenshot) {
    shotPath = path.resolve(__dirname, S.screenshot);
    try { await page.screenshot({ path: shotPath, fullPage: false }); }
    catch (e) { errors.push('SHOT: ' + e.message); }
  }

  await browser.close();

  // ---- REPORTE ----
  console.log('\n=== RED por categoría ===');
  for (const [c, n] of Object.entries(netByCat).sort((a,b)=>b[1]-a[1])) console.log(`  ${c.padEnd(14)} ${n}`);
  console.log(gasHits.length ? `\n🚨🚨 GAS HITS (${gasHits.length}):` : '\n✅ CERO fetches a GAS (script.google.com)');
  gasHits.slice(0, 20).forEach(h => console.log('  🚨 ' + h));

  console.log('\n=== Respuestas SB/GAS relevantes (status) ===');
  [...new Set(responses)].slice(0, 40).forEach(r => console.log('  ' + r));

  console.log('\n=== CONSOLA de la página (últimas 40) ===');
  consoleLogs.slice(-40).forEach(l => console.log('  ' + l));

  if (errors.length) { console.log('\n=== ERRORES ==='); errors.forEach(e => console.log('  ❌ ' + e)); }

  console.log('\n=== EVAL result ===');
  console.log('  ' + JSON.stringify(evalResult));

  if (shotPath) console.log('\n=== SCREENSHOT ===\n  ' + shotPath);
  console.log('');
})();
