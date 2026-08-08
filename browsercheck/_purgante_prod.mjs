import { chromium } from 'playwright';
const w = ms => new Promise(r => setTimeout(r, ms));
const SITIOS = [
  { n: 'MOS',   url: 'https://levo19.github.io/MOS/',        seed: { mos_device_id: '7e57c1a0-de1c-4a7e-b0de-c47a10906474', MOS_SESSION: JSON.stringify({ idPersonal: 'TEST-CLAUDE', nombre: 'PRUEBA CLAUDE', rol: 'MASTER', idSesion: 'testclaude1' }) }, done: 'mos_purgante_done' },
  { n: 'ME',    url: 'https://levo19.github.io/MosExpress/', seed: { mosexpress_deviceId: '7e57c1a0-de1c-4a7e-b0de-c47a10906476' }, done: 'mosexpress_purgante_done' },
  { n: 'MosGo', url: 'https://mosgo.vercel.app/',            seed: { mosgo_deviceId: '7e57c1a0-de00-4c1a-9de0-7e57c1a0de00' },     done: 'mosgo_purgante_done' },
];
const T = [];
const b = await chromium.launch();
for (const s of SITIOS) {
  const ctx = await b.newContext({ viewport: { width: 430, height: 900 }, serviceWorkers: 'allow' });
  const p = await ctx.newPage();
  const errs = []; let tokVisto = null;
  p.on('pageerror', e => errs.push(String(e.message || e).slice(0, 160)));
  p.on('response', async r => {
    if (/rpc\/get_flags/.test(r.url())) { try { const j = await r.json(); if (j && j.purganteToken !== undefined) tokVisto = String(j.purganteToken); } catch (_) {} }
  });
  await p.addInitScript(sd => { try { for (const [k, v] of Object.entries(sd)) localStorage.setItem(k, v); } catch (_) {} }, s.seed);
  await p.goto(s.url + '?nc=' + Date.now(), { waitUntil: 'domcontentloaded', timeout: 60000 });
  await w(16000);
  const done = await p.evaluate(k => localStorage.getItem(k), s.done);
  const purgo = p.url().includes('pv=');
  T.push([tokVisto === '0' ? '✅' : '❌', `${s.n} · el servidor entrega purganteToken`, 'token=' + tokVisto + ' (0 = DORMIDO)']);
  T.push([(!purgo && done === null) ? '✅' : '❌', `${s.n} · DORMIDO: no purgó nada`, 'done=' + done + ' url_pv=' + purgo]);
  T.push([errs.length === 0 ? '✅' : '❌', `${s.n} · 0 pageerrors en producción`, errs.slice(0, 2).join(' | ') || 'ninguno']);
  await ctx.close();
}
await b.close();
console.log(T.map(t => `${t[0]} ${t[1]}  → ${t[2]}`).join('\n'));
process.exit(T.some(t => t[0] === '❌') ? 1 : 0);
