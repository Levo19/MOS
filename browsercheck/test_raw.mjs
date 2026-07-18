import fs from 'fs';
const SB='https://rzbzdeipbtqkzjqdchqk.supabase.co';
const ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
const b64u=(o)=>Buffer.from(JSON.stringify(o)).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
const JWT=b64u({alg:'HS256',typ:'JWT'})+'.'+b64u({app:'warehouseMos',role:'authenticated'})+'.x';
const imgB64=fs.readFileSync('test_lista.png').toString('base64');
const body={ model:'claude-sonnet-5', max_tokens:2048, system:'Devuelve JSON {"items":[{"nombre":"X","cantidad":1}]}',
  messages:[{role:'user',content:[{type:'image',source:{type:'base64',media_type:'image/png',data:imgB64}},{type:'text',text:'Extrae productos y cantidad solicitada. Solo JSON.'}]}] };
const r=await fetch(SB+'/functions/v1/ia',{method:'POST',headers:{'apikey':ANON,'Authorization':'Bearer '+JWT,'Content-Type':'application/json'},body:JSON.stringify(body)});
console.log('HTTP',r.status);
const t=await r.text();
console.log('RAW:',t.slice(0,900));
