const {Client}=require('pg');const fs=require('fs');const {chromium}=require('playwright');
const url=fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim();
const P=[['Jorgenis González','OP001','JG'],['SERGIO Bailón','PER2607141406200764e0','SB'],['Mia','MEX:MIA|ZONA-02','MI'],['Jesús','PER2607251158418560a6','JE']];
const DOW=['dom','lun','mar','mié','jue','vie','sáb'];
const f2=n=>Number(n).toFixed(2);
(async()=>{
 const c=new Client({connectionString:url});await c.connect();
 const people=[];
 for(const [nom,idp,ini] of P){
   const doc=(await c.query(`select btrim(coalesce(documento,'')) d from mos.personal where id_personal=$1`,[idp])).rows[0]?.d||'';
   const dd=(await c.query(`select fecha, to_char(fecha,'YYYY-MM-DD') f, monto_base mb, pago_envasado pe, pago_envasado_colab pec, bono_meta bm, bonificacion bo, sancion sa, total_dia t
     from mos.liquidaciones_dia where id_personal=$1 and upper(estado)='PENDIENTE' and (fecha at time zone 'America/Lima')::date between '2026-07-20' and '2026-07-27' order by fecha`,[idp])).rows;
   let cons={};
   if(doc){const cd=(await c.query(`select to_char(fecha,'YYYY-MM-DD') f, count(*) n, sum(total) t
       from me.ventas where btrim(coalesce(cliente_doc,''))=$1 and upper(forma_pago)='CREDITO'
       and (fecha at time zone 'America/Lima')::date between '2026-07-20' and '2026-07-27' group by 1`,[doc])).rows;
     cons=Object.fromEntries(cd.map(r=>[r.f,{n:Number(r.n),t:Number(r.t)}]));}
   const days=dd.map(r=>{const cc=cons[r.f]?.t||0;const dow=DOW[new Date(r.f+'T12:00:00').getUTCDay()];
     return {f:r.f,dow,dia:r.f.slice(8),base:Number(r.mb),env:Number(r.pe),meta:Number(r.bm),bon:Number(r.bo),san:Number(r.sa),tot:Number(r.t),cons:cc,consN:cons[r.f]?.n||0,neto:Number(r.t)-cc};});
   const jornal=days.reduce((a,d)=>a+d.tot,0), consumo=days.reduce((a,d)=>a+d.cons,0);
   people.push({nom,ini,doc,days,jornal,consumo,neto:jornal-consumo});
 }
 await c.end();
 // render
 const chip=(v,cls)=> v>0?`<span class="chip ${cls}">${cls==='out'?'−':'+'}${f2(v)}</span>`:`<span class="chip z">—</span>`;
 const card=(pp)=>`
  <div class="card">
    <div class="hd">
      <div style="display:flex;gap:11px;align-items:center"><div class="avatar">${pp.ini}</div>
        <div><div style="font-weight:700">${pp.nom}</div><div class="sub">${pp.days.length} días · ${pp.doc?('doc '+pp.doc):'<span style=color:#e0533f>sin documento → sin consumos</span>'}</div></div></div>
      <div style="text-align:right"><div class="eyebrow">Neto a pagar</div><div class="num" style="font-size:20px;color:#1e3a5f">S/${f2(pp.neto)}</div></div>
    </div>
    <div class="wkrow wkhead"><div>Día</div><div>Base</div><div>Envasado</div><div>Meta/Bono</div><div>Consumo</div><div style="text-align:right">Neto</div></div>
    ${pp.days.map(d=>`<div class="wkrow"><div>${d.dow} ${d.dia}</div><div>${chip(d.base,'in')}</div><div>${chip(d.env,'in')}</div><div>${chip(d.meta+d.bon,'in')}</div><div>${d.cons>0?`<span class="chip out">−${f2(d.cons)}</span> <span class="mini">${d.consN}t</span>`:'<span class="chip z">—</span>'}</div><div class="num" style="text-align:right;font-weight:600">${f2(d.neto)}</div></div>`).join('')}
    <div class="totbar">
      <div class="tot"><div class="k">Jornal + bonos</div><div class="v">S/${f2(pp.jornal)}</div></div>
      <div class="tot"><div class="k">Consumos (auto)</div><div class="v" style="color:#e0533f">${pp.consumo>0?'− ':''}S/${f2(pp.consumo)}</div></div>
      <div class="tot net"><div class="k">Neto a pagar</div><div class="v">S/${f2(pp.neto)}</div></div>
    </div>
  </div>`;
 const html=`<!doctype html><meta charset=utf8><style>
  :root{--bg:#eef1f5;--card:#fff;--ink:#1b2432;--dim:#71809a;--line:#e6eaf1;--in:#0e9f6e;--in-bg:#e7f6ef;--out:#e0533f;--out-bg:#fdece9;--neto:#1e3a5f}
  *{box-sizing:border-box;margin:0}body{background:var(--bg);color:var(--ink);font:13.5px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;padding:26px;width:1180px}
  h1{font-size:19px}.mut{color:var(--dim)}.num{font-variant-numeric:tabular-nums}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-top:16px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:0 1px 2px rgba(20,30,50,.04);overflow:hidden}
  .hd{display:flex;justify-content:space-between;align-items:center;padding:16px 18px;border-bottom:1px solid var(--line)}
  .avatar{width:38px;height:38px;border-radius:11px;background:linear-gradient(135deg,#1e3a5f,#2f7fed);color:#fff;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:14px}
  .sub{font-size:11px;color:var(--dim)}.eyebrow{font-size:10px;text-transform:uppercase;letter-spacing:.8px;color:var(--dim);font-weight:700}
  .wkrow{display:grid;grid-template-columns:72px 1fr 1fr 1fr 1fr 74px;gap:6px;align-items:center;padding:9px 18px;border-bottom:1px solid var(--line);font-size:12.5px}
  .wkhead{color:var(--dim);font-size:9.5px;text-transform:uppercase;letter-spacing:.4px;font-weight:700;background:#fafbfd}
  .chip{font-size:11px;font-weight:600;padding:2px 7px;border-radius:6px}.chip.in{background:var(--in-bg);color:var(--in)}.chip.out{background:var(--out-bg);color:var(--out)}.chip.z{color:#b8c1d0}
  .mini{font-size:9.5px;color:var(--dim)}
  .totbar{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;padding:14px}
  .tot{background:#fafbfd;border:1px solid var(--line);border-radius:11px;padding:10px 12px}.tot .k{font-size:9.5px;text-transform:uppercase;letter-spacing:.5px;color:var(--dim);font-weight:700}.tot .v{font-size:17px;font-weight:700;font-variant-numeric:tabular-nums;margin-top:2px}
  .tot.net{background:var(--neto);border-color:var(--neto)}.tot.net .k{color:#aebfd6}.tot.net .v{color:#fff}
  </style>
  <h1>Liquidación reorganizada · <span class=mut style=font-size:13px>datos EN VIVO de la base (${new Date().toISOString().slice(0,10)})</span></h1>
  <div class=mut style=font-size:12px;margin-top:2px>Cada día = base + envasado + bonos − consumo = neto · consumos automáticos por documento</div>
  <div class=grid>${people.map(card).join('')}</div>`;
 fs.writeFileSync(__dirname+'/recibo_real.html',html);
 const b=await chromium.launch();const p=await b.newPage({viewport:{width:1180,height:900},deviceScaleFactor:2});
 await p.goto('file:///'+(__dirname+'/recibo_real.html').replace(/\\/g,'/'));await p.waitForTimeout(300);
 await p.screenshot({path:__dirname+'/recibo_real.png',fullPage:true});await b.close();
 console.log('OK => recibo_real.png');
 people.forEach(pp=>console.log(`  ${pp.nom}: jornal ${f2(pp.jornal)} − consumo ${f2(pp.consumo)} = neto ${f2(pp.neto)} (${pp.days.length}d)`));
})();
