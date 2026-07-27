const fs=require('fs');const {chromium}=require('playwright');const {pathToFileURL}=require('url');
const M=n=>'S/'+n.toFixed(2);
const fLarga=f=>({'2026-07-20':'lun 20 jul','2026-07-22':'mié 22 jul','2026-07-25':'sáb 25 jul'}[f]||f);
const esc=s=>String(s||'');
// réplica del nuevo _liqComprobanteCard con detalle por ticket
const dd=[
 {fecha:'2026-07-20',montoBase:80,pagoEnvasado:0,pagoEnvasadoColab:0,bonoMeta:0,bonificacion:0,sancion:0,totalDia:80,consumoDia:{total:9.60}},
 {fecha:'2026-07-22',montoBase:80,pagoEnvasado:19.90,pagoEnvasadoColab:19.90,bonoMeta:0,bonificacion:0,sancion:0,totalDia:99.90,consumoDia:{total:4}},
 {fecha:'2026-07-25',montoBase:80,pagoEnvasado:0,pagoEnvasadoColab:0,bonoMeta:0,bonificacion:0,sancion:0,totalDia:80,consumoDia:{total:21.40}},
];
const tks={'2026-07-20':[{correlativo:'NVa2-002130',total:6.00},{correlativo:'NVa2-002132',total:3.60}],'2026-07-22':[{correlativo:'NVa2-002136',total:2.40},{correlativo:'NVa2-002137',total:1.60}],'2026-07-25':[{correlativo:'NVa2-002145',total:9.50},{correlativo:'NVa2-002146',total:11.90}]};
function card(it,ticketsByFecha){const fCorta=f=>f.slice(8)+'/'+f.slice(5,7);let jornal=0,consumo=0;
 const rows=it.dias.map(d=>{const t=d.totalDia;const T=(ticketsByFecha&&ticketsByFecha[d.fecha])||null;const c=(T&&T.length)?Math.round(T.reduce((s,x)=>s+x.total,0)*100)/100:d.consumoDia.total;jornal+=t;consumo+=c;const nd=Math.round((t-c)*100)/100;
  const parts=['base '+d.montoBase.toFixed(2)];if(d.pagoEnvasado>0)parts.push('env '+d.pagoEnvasado.toFixed(2)+(d.pagoEnvasadoColab>0?' 🤝':''));
  let ch='';if(c>0){ch=(T&&T.length)?T.map(x=>'<div style="display:flex;justify-content:space-between;font-size:9.5px;color:#c2410c;padding:1px 0 1px 12px"><span>🧾 consumo · '+esc(x.correlativo)+'</span><span>−'+M(x.total)+'</span></div>').join(''):'<div style="display:flex;justify-content:space-between;font-size:9.5px;color:#c2410c;padding:1px 0 1px 12px"><span>🧾 consumo del día</span><span>−'+M(c)+'</span></div>';}
  return '<div style="padding:5px 0;border-bottom:1px dashed rgba(15,23,42,.1)"><div style="display:flex;justify-content:space-between;font-size:11px"><div><b style="color:#0f172a">'+fLarga(d.fecha)+'</b> <span style="color:#64748b">'+parts.join(' · ')+'</span></div><b style="color:#0f766e">'+M(nd)+'</b></div>'+ch+'</div>';}).join('');
 jornal=Math.round(jornal*100)/100;consumo=Math.round(consumo*100)/100;const neto=Math.round((jornal-consumo)*100)/100;
 return '<div style="background:linear-gradient(160deg,#fff,#f0fdf9);border-radius:16px;padding:18px;color:#1e293b;box-shadow:0 6px 22px rgba(0,0,0,.28)">'
  +'<div style="text-align:center;border-bottom:2px solid #0f766e;padding-bottom:10px;margin-bottom:10px"><div style="font-size:15px;font-weight:900;color:#0f766e">INVERSIONES MOS</div><div style="font-size:10px;color:#64748b">Comprobante de liquidación</div></div>'
  +'<div style="display:flex;justify-content:space-between;font-size:11px;margin-bottom:10px"><div><div style="font-weight:800;font-size:13px">Jorgenis González</div><div style="color:#64748b">almacenero</div></div><div style="text-align:right"><div style="color:#64748b">20/07 – 25/07</div><div style="font-weight:700">'+it.dias.length+' día(s)</div></div></div>'
  +rows+'<div style="margin-top:10px;padding-top:8px;border-top:1px solid #cbd5e1;font-size:11px"><div style="display:flex;justify-content:space-between"><span style="color:#64748b">Jornal + bonos + envasado</span><b>'+M(jornal)+'</b></div><div style="display:flex;justify-content:space-between"><span style="color:#c2410c">− Consumos a crédito</span><b style="color:#c2410c">−'+M(consumo)+'</b></div></div>'
  +'<div style="margin-top:8px;background:#0f766e;border-radius:11px;padding:10px 14px;display:flex;justify-content:space-between;align-items:center;color:#fff"><div style="font-size:10px;font-weight:700;opacity:.85">NETO A PAGAR</div><div style="font-size:22px;font-weight:900">'+M(neto)+'</div></div></div>';}
const html='<!doctype html><meta charset=utf8><body style="background:#1e2a3d;padding:24px;width:440px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">'
 +'<div style="color:#f1f5f9;font-size:13px;font-weight:700;margin-bottom:10px">Comprobante · consumo POR DÍA con detalle por ticket (ya restado)</div>'+card({dias:dd},tks)+'</body>';
fs.writeFileSync(__dirname+'/conf2.html',html);
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:440,height:640},deviceScaleFactor:2});await p.goto(pathToFileURL(__dirname+'/conf2.html').href);await p.waitForTimeout(300);await p.screenshot({path:__dirname+'/conf2.png',fullPage:true});await b.close();console.log('=> conf2.png');})();
