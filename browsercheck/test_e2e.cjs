const fs=require('fs');
const {Client}=require('C:/Users/ISO/ProyectoMOS/node_modules/pg');
const cs=fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim();
const SB='https://rzbzdeipbtqkzjqdchqk.supabase.co';
const ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
const DID='7c3c7822-a462-4280-84ca-37547ea6a82e';
const ESP={'AJINOMOTO':15,'AJI PANCA':80,'SILLAO':6,'PALILLO':25};
const system=fs.readFileSync('sys_prompt.txt','utf8');
(async()=>{
  const c=new Client({connectionString:cs}); await c.connect();
  let prev;
  try{
    prev=(await c.query('select estado from mos.dispositivos where id_dispositivo=$1',[DID])).rows[0].estado;
    await c.query("update mos.dispositivos set estado='ACTIVO' where id_dispositivo=$1",[DID]);
    console.log('device '+DID.slice(0,8)+' '+prev+' -> ACTIVO (temporal)');
    const mr=await fetch(SB+'/functions/v1/mint-wh',{method:'POST',headers:{'apikey':ANON,'Content-Type':'application/json'},body:JSON.stringify({deviceId:DID})});
    const md=await mr.json();
    if(!md.ok||!md.token){console.log('mint FAIL',JSON.stringify(md));throw new Error('mint');}
    const TOKEN=md.token; console.log('token minteado OK');
    async function test(tipo,bloque){
      const body={model:'claude-sonnet-5',max_tokens:8192,system,messages:[{role:'user',content:[bloque,{type:'text',text:'Lee esta lista/tabla y extrae cada producto con su cantidad SOLICITADA (no el min/max/stock/precio). Devuelve solo el JSON indicado.'}]}]};
      const r=await fetch(SB+'/functions/v1/ia',{method:'POST',headers:{'apikey':ANON,'Authorization':'Bearer '+TOKEN,'Content-Type':'application/json'},body:JSON.stringify(body)});
      if(r.status!==200){console.log(tipo+' HTTP '+r.status+': '+(await r.text()).slice(0,200));return;}
      const j=await r.json();
      const text=(j&&j.content&&j.content[0]&&j.content[0].text)||'';
      const f=text.indexOf('{'),l=text.lastIndexOf('}');
      let parsed;try{parsed=JSON.parse(text.slice(f,l+1));}catch(e){console.log(tipo+' PARSE FAIL: '+text.slice(0,200));return;}
      const items=parsed.items||[];
      console.log('\n===== '+tipo+' -> '+items.length+' items =====');
      let ok=items.length>0;
      items.forEach(it=>{const nom=String(it.nombre||'').toUpperCase();const key=Object.keys(ESP).find(k=>nom.includes(k));const esp=key?ESP[key]:null;const cant=parseFloat(it.cantidad);const good=esp!=null&&cant===esp;if(esp!=null&&!good)ok=false;console.log('  '+String(cant).padEnd(6)+nom+'  '+(esp!=null?(good?'OK':'MAL(esp '+esp+')'):'?'));});
      console.log(tipo+': '+(ok&&items.length===4?'CORRECTO (4 productos, cantidad=SOLICITADO)':'REVISAR'));
    }
    const img=fs.readFileSync('test_lista.png').toString('base64');
    const pdf=fs.readFileSync('test_lista.pdf').toString('base64');
    await test('IMAGEN',{type:'image',source:{type:'base64',media_type:'image/png',data:img}});
    await test('PDF',{type:'document',source:{type:'base64',media_type:'application/pdf',data:pdf}});
  }finally{
    if(prev){await c.query('update mos.dispositivos set estado=$2 where id_dispositivo=$1',[DID,prev]);console.log('\ndevice revertido a '+prev+' OK');}
    await c.end();
  }
})().catch(e=>{console.error('ERR',e.message);process.exit(1);});
