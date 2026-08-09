import { chromium } from 'playwright';
const PREV={xp:1800,done:{}};['pos-intro','pos-venta','pos-pres','pos-granel','pos-cobrar','pos-ana','caja-abrir','caja-tickets','caja-reimp','caja-imp','caja-perm','tools-adh','tools-ingreso','tools-salida','tools-dev','tools-horario','fin-exam','fin-dip'].forEach(k=>PREV.done[k]=1);
const b=await chromium.launch();
for(const [w,h] of [[390,900],[1280,1000]]){
  const ctx=await b.newContext({viewport:{width:w,height:h},deviceScaleFactor:w<700?2:1});
  const page=await ctx.newPage();
  await page.addInitScript(v=>localStorage.setItem('me_academy_v1',v),JSON.stringify(PREV));
  await page.goto('http://127.0.0.1:8125/academy.html',{waitUntil:'domcontentloaded'});
  await page.waitForTimeout(1500);
  for(const id of ['pos-card','pos-agotado']){
    await page.evaluate(i=>{const e=document.querySelector('[data-go="'+i+'"]');if(e)e.click()},id);
    await page.waitForTimeout(900);
    await page.evaluate(()=>{const g=document.querySelector('#grid');if(g)g.scrollIntoView({block:'center'})});
    await page.waitForTimeout(600);
    await page.screenshot({path:`_hap_acad_sim_${id}_${w}.png`});
  }
  await ctx.close();
}
await b.close();
