import { chromium } from 'playwright';
const b=await chromium.launch();
const ctx=await b.newContext({viewport:{width:1280,height:900}});
const page=await ctx.newPage();
await page.addInitScript(()=>localStorage.setItem('me_academy_v1',JSON.stringify({xp:200,done:{'pos-intro':1,'pos-venta':1}})));
await page.goto('http://127.0.0.1:8125/academy.html',{waitUntil:'domcontentloaded'});
await page.waitForTimeout(1800);
console.log(await page.evaluate(()=>{
  const g=document.querySelector('#grid'), p=document.querySelectorAll('.prod')[0];
  const gs=getComputedStyle(g);
  return {gridRows:gs.gridTemplateRows, gridH:g.getBoundingClientRect().height, gridSH:g.scrollHeight,
    prodH:p.getBoundingClientRect().height, prodSH:p.scrollHeight, prodOH:p.offsetHeight,
    alignItems:gs.alignItems, alignContent:gs.alignContent,
    padTop:getComputedStyle(p).paddingTop, minH:getComputedStyle(p).minHeight};
}));
await ctx.close(); await b.close();
