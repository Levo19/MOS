import { chromium } from 'playwright';
const SEED = { mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906474', MOS_SESSION: JSON.stringify({ idPersonal:'TEST-CLAUDE', nombre:'PRUEBA CLAUDE', rol:'MASTER', idSesion:'testclaude1' }) };
const w = ms => new Promise(r=>setTimeout(r,ms));
const b = await chromium.launch();
const ctx = await b.newContext({ viewport:{width:1280,height:900}, serviceWorkers:'block' });
const p = await ctx.newPage();
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);}, SEED);
await p.goto('https://levo19.github.io/MOS/?nc='+Date.now(), { waitUntil:'domcontentloaded', timeout:60000 });
await w(21000);
await p.evaluate(()=>{const b=[...document.querySelectorAll('button,a')].find(el=>/Entrar a MOS/i.test(el.textContent||'')); if(b)b.click();});
await w(2000);
await p.evaluate(()=>{try{MOS.nav('catalogo');}catch(_){}}); await w(9000);
// robar el token del mint: repetimos la llamada raw usando el mismo fetch que api.js
const out = await p.evaluate(async () => {
  const orig = window.fetch; let cap = null;
  window.fetch = async (u, o) => { if (String(u).includes('/rpc/')) cap = { u:String(u), o }; return orig(u, o); };
  try { await API.get('getPromociones', {}); } catch(_) {}
  window.fetch = orig;
  if (!cap) return { err:'no capture' };
  const res = await orig('https://rzbzdeipbtqkzjqdchqk.supabase.co/rest/v1/rpc/promo_sugerencias', { method:'POST', headers: cap.o.headers, body: JSON.stringify({ p:{ n:6 } }) });
  return { status: res.status, body: (await res.text()).slice(0,600) };
});
console.log(JSON.stringify(out, null, 1));
await b.close();
