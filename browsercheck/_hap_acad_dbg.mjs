import { chromium } from 'playwright';
const b=await chromium.launch();
for(const w of [390,1280]){
const ctx=await b.newContext({viewport:{width:w,height:900}});
const page=await ctx.newPage();
await page.addInitScript(()=>localStorage.setItem('me_academy_v1',JSON.stringify({xp:200,done:{'pos-intro':1,'pos-venta':1}})));
await page.goto('http://127.0.0.1:8125/academy.html',{waitUntil:'domcontentloaded'});
await page.waitForTimeout(1800);
const r=await page.evaluate(()=>{
  const p=document.querySelectorAll('.prod')[0]; if(!p) return {sinCards:true};
  const cs=getComputedStyle(p);
  const kids=[...p.children].map(c=>{const q=c.getBoundingClientRect();const s=getComputedStyle(c);
    return c.className+' '+Math.round(q.width)+'x'+Math.round(q.height)+' disp='+s.display+' vis='+s.visibility+' ov='+s.overflow;});
  const q=p.getBoundingClientRect();
  return {card:Math.round(q.width)+'x'+Math.round(q.height), disp:cs.display, dir:cs.flexDirection, ov:cs.overflow, kids, html:p.innerHTML.slice(0,300)};
});
console.log(w, JSON.stringify(r,null,1));
await ctx.close();}
await b.close();
