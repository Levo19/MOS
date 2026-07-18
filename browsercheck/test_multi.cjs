const fs=require('fs');
const { chromium } = require('C:/Users/ISO/ProyectoMOS/browsercheck/node_modules/playwright');
const SB='https://rzbzdeipbtqkzjqdchqk.supabase.co';
const ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
const system=fs.readFileSync('sys_prompt.txt','utf8');
const ESP={'AJINOMOTO':15,'AJI PANCA':80,'SILLAO':6,'PALILLO':25};
function tabla(rows){return `<html><body style="font-family:Arial;padding:20px;background:#fff"><h3>PEDIDO ZONA 1</h3><table border="1" cellpadding="8" style="border-collapse:collapse;font-size:16px"><tr style="background:#dbe5f1"><th>Producto</th><th>Solicitado</th><th>Min</th><th>Max</th><th>Precio</th></tr>${rows}</table></body></html>`;}
(async()=>{
  const b=await chromium.launch();const p=await b.newPage({viewport:{width:640,height:360}});
  await p.setContent(tabla('<tr><td>AJINOMOTO GLUTAMATO 1KG</td><td>15</td><td>10</td><td>40</td><td>12.50</td></tr><tr><td>AJI PANCA DESVENADO KG</td><td>80</td><td>20</td><td>90</td><td>8.00</td></tr>'));
  await (await p.$('table')).screenshot({path:'lista_p1.png'});
  await p.setContent(tabla('<tr><td>SILLAO KIKKOMAN 1L</td><td>6</td><td>5</td><td>24</td><td>18.90</td></tr><tr><td>PALILLO ENTERO 500G</td><td>25</td><td>10</td><td>50</td><td>4.50</td></tr>'));
  await (await p.$('table')).screenshot({path:'lista_p2.png'});
  await b.close();
  const WHDEV=require('child_process').execSync('echo skip').toString(); // device se pasa por env
  const DID=process.env.WHDEV;
  const mr=await fetch(SB+'/functions/v1/mint-wh',{method:'POST',headers:{'apikey':ANON,'Content-Type':'application/json'},body:JSON.stringify({deviceId:DID})});
  const md=await mr.json(); if(!md.ok){console.log('mint FAIL');return;}
  const T=md.token;
  const img1=fs.readFileSync('lista_p1.png').toString('base64');
  const img2=fs.readFileSync('lista_p2.png').toString('base64');
  const body={model:'claude-sonnet-5',max_tokens:8192,system,messages:[{role:'user',content:[
    {type:'image',source:{type:'base64',media_type:'image/png',data:img1}},
    {type:'image',source:{type:'base64',media_type:'image/png',data:img2}},
    {type:'text',text:'Estas 2 imágenes son partes de la MISMA lista: combínalas en un solo resultado, sin duplicar. Extrae cada producto con su cantidad SOLICITADA (no min/max/precio). Solo JSON.'}
  ]}]};
  const t0=Date.now();
  const r=await fetch(SB+'/functions/v1/ia',{method:'POST',headers:{'apikey':ANON,'Authorization':'Bearer '+T,'Content-Type':'application/json'},body:JSON.stringify(body)});
  const j=await r.json();const seg=((Date.now()-t0)/1000).toFixed(1);
  const txt=((j.content||[]).find(x=>x.type==='text')||{}).text||'';
  const m=txt.match(/\{[\s\S]*\}/);const items=m?(JSON.parse(m[0]).items||[]):[];
  console.log('2 imágenes → '+items.length+' items en '+seg+'s');
  let ok=items.length===4;const vistos={};
  items.forEach(it=>{const nom=String(it.nombre||'').toUpperCase();const k=Object.keys(ESP).find(x=>nom.includes(x));const esp=k?ESP[k]:null;const c=parseFloat(it.cantidad);if(esp!=null&&c!==esp)ok=false;if(k)vistos[k]=(vistos[k]||0)+1;console.log('  '+String(c).padEnd(5)+nom+(esp!=null?(c===esp?' OK':' MAL(esp '+esp+')'):' ?'));});
  const dup=Object.values(vistos).some(v=>v>1);
  console.log(ok&&!dup&&items.length===4?'✅ COMBINÓ las 2 imágenes en 1 lista, 4 productos, sin duplicar':'⚠ revisar (dup='+dup+')');
})().catch(e=>console.error('ERR',e.message));
