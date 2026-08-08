// Smoke de arranque tras los cambios de propagación: ME (POS) y MosGo tienen que bootear
// sin pantalla blanca y con el canal/poller vivo. ME es caja: si esto falla, se revierte.
import { chromium } from 'playwright';
const DEV_ME = '7e57c1a0-de1c-4a7e-b0de-c47a10906476'; // TEST-CLAUDE-ME
const DEV_GO = '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00'; // TEST-CLAUDE (QA MosGo)

const br = await chromium.launch({ headless: true });
const run = async (nombre, url, seed, evalAfter, ms) => {
  const ctx = await br.newContext({ viewport: { width: 420, height: 900 } });
  await ctx.addInitScript(seed);
  const p = await ctx.newPage();
  const errs = [], logs = [];
  p.on('pageerror', e => errs.push(String(e.message).slice(0, 180)));
  p.on('console', m => { if (m.type() === 'error') errs.push('console: ' + m.text().slice(0, 160)); logs.push(m.text()); });
  await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await new Promise(r => setTimeout(r, ms));
  const out = await p.evaluate(evalAfter).catch(e => ({ evalError: String(e).slice(0, 140) }));
  console.log('\n══════ ' + nombre + ' ══════');
  console.log('estado:', JSON.stringify(out));
  const rel = errs.filter(e => !/favicon|manifest|net::ERR|WebSocket is closed|Failed to load resource/i.test(e));
  console.log('errores JS relevantes: ' + (rel.length ? '\n  - ' + rel.slice(0, 6).join('\n  - ') : 'NINGUNO'));
  const rt = logs.filter(l => /Realtime|canal/i.test(l)).slice(-3);
  if (rt.length) rt.forEach(l => console.log('  rt: ' + l));
  await ctx.close();
  return { out, rel };
};

const me = await run('ME 2.8.269 (POS)', 'https://levo19.github.io/MosExpress/',
  `localStorage.setItem('mosexpress_deviceId', ${JSON.stringify(DEV_ME)});`,
  () => ({
    version: (typeof V !== 'undefined' ? V : '?'),
    // pantalla blanca = el #app quedó sin nada renderizado
    pintado: !!document.querySelector('#app') && document.querySelector('#app').innerHTML.length > 500,
    textoVisible: (document.body.innerText || '').trim().slice(0, 60)
  }), 45000);

const go = await run('MosGo 0.5.19', 'https://mosgo.vercel.app/',
  `localStorage.setItem('mosgo_deviceId', ${JSON.stringify(DEV_GO)});`,
  () => ({
    version: (typeof V !== 'undefined' ? V : '?'),
    pintado: (document.body.innerHTML || '').length > 2000,
    textoVisible: (document.body.innerText || '').trim().slice(0, 60)
  }), 35000);

await br.close();
const ok = me.out.pintado && go.out.pintado && !me.rel.length && !go.rel.length;
console.log('\n' + (ok ? '✅ ambas apps bootean sin errores' : '⚠ revisar arriba'));
process.exit(0);
