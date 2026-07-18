const fs=require('fs');
const SB='https://rzbzdeipbtqkzjqdchqk.supabase.co';
const ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
const DID='193c9ee7-04cd-4f04-88c3-ac46c4badeeb';
const system=fs.readFileSync('sys_prompt.txt','utf8');
(async()=>{
  const mr=await fetch(SB+'/functions/v1/mint-wh',{method:'POST',headers:{'apikey':ANON,'Content-Type':'application/json'},body:JSON.stringify({deviceId:DID})});
  const md=await mr.json(); if(!md.ok){console.log('mint FAIL',JSON.stringify(md));return;}
  const T=md.token;
  const img=fs.readFileSync('test_lista.png').toString('base64');
  async function medir(label,extra){
    const body=Object.assign({model:'claude-sonnet-5',max_tokens:8192,system,
      messages:[{role:'user',content:[{type:'image',source:{type:'base64',media_type:'image/png',data:img}},{type:'text',text:'Extrae productos y cantidad SOLICITADA. Solo JSON.'}]}]},extra||{});
    const t0=Date.now();
    const r=await fetch(SB+'/functions/v1/ia',{method:'POST',headers:{'apikey':ANON,'Authorization':'Bearer '+T,'Content-Type':'application/json'},body:JSON.stringify(body)});
    const txt=await r.text();
    const seg=((Date.now()-t0)/1000).toFixed(1);
    let items='?';try{const j=JSON.parse(txt);const b=(j.content||[]).find(x=>x.type==='text');const m=b&&b.text&&b.text.match(/\{[\s\S]*\}/);items=m?(JSON.parse(m[0]).items||[]).length:'0';const think=(j.content||[]).some(x=>x.type==='thinking');items+=think?' (con thinking)':' (sin thinking)';}catch(e){items='HTTP'+r.status+' '+txt.slice(0,80);}
    console.log(label+': '+seg+'s · items='+items);
  }
  await medir('SIN cambios (thinking default)');
  await medir('thinking DISABLED', {thinking:{type:'disabled'}});
})().catch(e=>console.error('ERR',e.message));
