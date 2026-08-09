import { chromium } from 'playwright';
import { prepararPagina } from './_hap_seed.mjs';
const ctx = await chromium.launchPersistentContext('./_hap_prof_dbg', { viewport:{width:390,height:800}, hasTouch:true, isMobile:true, deviceScaleFactor:2, permissions:['notifications','geolocation'] });
const page = ctx.pages()[0] || await ctx.newPage();
const logs=[], fails=[], resp=[];
page.on('console', m=>logs.push(m.type()+': '+m.text().slice(0,240)));
page.on('requestfailed', r=>fails.push(r.method()+' '+r.url().slice(0,110)+' :: '+(r.failure()||{}).errorText));
page.on('response', r=>{ if(/rpc|functions|catalogo/i.test(r.url())) resp.push(r.status()+' '+r.request().method()+' '+r.url().slice(0,110)); });
await prepararPagina(page, ctx);
await page.goto('http://127.0.0.1:8123/index.html', { waitUntil:'domcontentloaded' });
for (let i=0;i<20;i++){ await page.waitForTimeout(4000);
  const ok = await page.evaluate(()=>{ if(document.querySelector('.pos-card')) return true;
    const b=[...document.querySelectorAll('button')].find(e=>/Entrar a ME/i.test(e.textContent||'')); if(b) b.click(); return false;}).catch(()=>false);
  if(ok){console.log('LISTO en '+((i+1)*4)+'s');break} }
console.log('--- resp ---\n'+resp.slice(-25).join('\n'));
console.log('--- fails ---\n'+fails.slice(-15).join('\n'));
console.log('--- logs ---\n'+logs.slice(-30).join('\n'));
await page.screenshot({path:'_hap_dbg.png'});
await ctx.close();
