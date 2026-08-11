import { chromium } from 'playwright';
const w=ms=>new Promise(r=>setTimeout(r,ms));
const SEED={mos_device_id:'7e57c1a0-de1c-4a7e-b0de-c47a10906477',MOS_SESSION:JSON.stringify({idPersonal:'TEST-CLAUDE',nombre:'PRUEBA CLAUDE',rol:'MASTER',idSesion:'testclaude739'})};
const b=await chromium.launch();const ctx=await b.newContext({viewport:{width:1280,height:1200}});const p=await ctx.newPage();
await p.addInitScript(s=>{for(const[k,v]of Object.entries(s))localStorage.setItem(k,v);},SEED);
await p.goto('https://levo19.github.io/MOS/?nc='+Date.now(),{waitUntil:'domcontentloaded',timeout:120000});
await w(20000);
await p.evaluate(()=>{const el=[...document.querySelectorAll('button,a')].find(x=>/Entrar a MOS/i.test(x.textContent||''));if(el)el.click();});
await w(3000); await p.evaluate(()=>{try{MOS.nav('finanzas')}catch(_){}} );
for(let i=0;i<60;i++){await w(2000); if(await p.evaluate(()=>document.querySelectorAll('.fin-pers-group').length)) break;}
await w(6000);
console.log(JSON.stringify(await p.evaluate(()=>[...document.querySelectorAll('.fin-pers-group')].map(e=>({a:e.dataset.area,c:e.querySelector('.fin-pers-group-count').textContent,t:e.querySelector('.fin-pers-group-count').title})))));
const el = await p.$('#finPersonalList');
await el.scrollIntoViewIfNeeded(); await w(800);
await p.screenshot({path:'C:/Users/ISO/ecosistema MOS/ProyectoMOS/browsercheck/_739_headers.png', clip: await (async()=>{const bb=await el.boundingBox(); return {x:bb.x-14,y:bb.y-70,width:Math.min(bb.width+28,1260),height:180};})()});
await b.close();process.exit(0);
