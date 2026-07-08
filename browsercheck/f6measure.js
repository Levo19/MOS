const { chromium } = require('playwright');
const path = require('path');
const OUT = 'C:/Users/ISO/ProyectoMOS/browsercheck';
(async () => {
  const vpName = process.argv[2]||'mobile';
  const VPS={mobile:{width:375,height:812},tablet:{width:834,height:1112},desktop:{width:1440,height:900}};
  const vp=VPS[vpName];
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  await page.addInitScript(() => {
    const ls={ps_session:JSON.stringify({id:'P-1',nombre:'Admin',rol:'Administrador',loginAt:1751000000000}),ps_api_url:'http://localhost:8147/noapi',ps_supa_auth:JSON.stringify({access_token:'fake',refresh_token:'r',expires_at:4102444800,expires_in:3600,token_type:'bearer',user:{id:'00000000-0000-0000-0000-000000000001',aud:'authenticated',role:'authenticated',email:'a@a.co',app_metadata:{},user_metadata:{}}})};
    for(const k in ls)localStorage.setItem(k,ls[k]);
  });
  await page.route('**/*', route => {
    const url=route.request().url();
    if(url.includes('.supabase.co/rest/v1/rpc/'))return route.fulfill({status:200,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:'null'});
    if(url.includes('.supabase.co/rest/v1/')){
      const p=url.split('/rest/v1/')[1];
      let d=[];
      if(p.startsWith('embarcaciones'))d=Array.from({length:5}).map((_,i)=>({id:'E-'+i,nombre:'Estrella de Paracas número '+(i+1),capacidad_pax:30+i,matricula:'PA-'+(1000+i)}));
      if(p.startsWith('personal'))d=Array.from({length:6}).map((_,i)=>({id:'P-'+i,nombre:'Trabajador de Paracas nombre largo '+(i+1),rol:['Capitan','Guia','Operador','Capitan','Guia','Operador'][i],tarifa_fija:i*50,estado:'activo'}));
      if(p.startsWith('contactos'))d=Array.from({length:6}).map((_,i)=>({id:'C-'+i,nombre:'Agencia Internacional de Turismo Paracas '+(i+1),tipo:['agencia','aliado','comisionado','cliente','agencia','aliado'][i],precio_defecto:20+i}));
      if(p.startsWith('impuestos'))d=Array.from({length:3}).map((_,i)=>({id:'I-'+i,nombre:'Impuesto '+(i+1),monto:10+i}));
      return route.fulfill({status:200,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify(d)});
    }
    if(url.includes('.supabase.co/auth/'))return route.fulfill({status:200,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:'{}'});
    return route.continue();
  });
  await page.goto('http://localhost:8147/index.html',{waitUntil:'domcontentloaded'});
  await page.waitForTimeout(4500);
  // go to catalogos
  await page.evaluate(()=>{const b=[...[...document.querySelectorAll('.layout-portrait .nav-item, .layout-landscape .sidebar-item')].filter(e=>e.offsetParent!==null)].find(x=>x.textContent.includes('Catálogo'));if(b)b.click();});
  await page.waitForTimeout(1200);
  const sub=process.argv[3]||'embarcaciones';
  const map={embarcaciones:'Embarcaciones',personal:'Personal',contactos:'Contactos',impuestos:'Impuestos',servicios:'Servicios'};
  await page.evaluate((label)=>{const b=[...document.querySelectorAll('.ps-acc.primary')].filter(e=>e.offsetParent!==null).find(x=>x.textContent.includes(label));if(b)b.click();},map[sub]);
  await page.waitForTimeout(1200);
  // measure header wrap
  const info = await page.evaluate(()=>{
    const doc=document.documentElement;
    const heads=[...document.querySelectorAll('.ps-head')].map(h=>{
      const r=h.getBoundingClientRect();
      const kids=[...h.children].map(c=>({t:c.className,top:Math.round(c.getBoundingClientRect().top)}));
      const tops=kids.map(k=>k.top);
      return {h:Math.round(r.height),wrapped:new Set(tops).size>1,kids};
    });
    const navLabels=[...document.querySelectorAll('.nav-label')].map(n=>({txt:n.textContent,sw:n.scrollWidth,cw:n.clientWidth,clip:n.scrollWidth>n.clientWidth+1}));
    return {overflowX:doc.scrollWidth>doc.clientWidth, sw:doc.scrollWidth, cw:doc.clientWidth, heads, navLabels};
  });
  console.log(JSON.stringify(info,null,1));
  await page.screenshot({path:path.join(OUT,`f6-cat-${sub}-${vpName}.png`)});
  await browser.close();
})();
