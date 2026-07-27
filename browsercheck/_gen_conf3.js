const fs=require('fs');const {chromium}=require('playwright');const {pathToFileURL}=require('url');
const M=n=>'S/'+n.toFixed(2);
const fLarga=f=>({'2026-07-20':'lun 20 jul','2026-07-22':'mié 22 jul','2026-07-24':'vie 24 jul'}[f]||f);
const esc=s=>String(s||'');
const dd=[
 {fecha:'2026-07-20',montoBase:80,pagoEnvasado:0,pagoEnvasadoColab:0,bonoMeta:20,bonificacion:0,sancion:0,consumoDia:{total:20}},
 {fecha:'2026-07-22',montoBase:80,pagoEnvasado:19.90,pagoEnvasadoColab:19.90,bonoMeta:0,bonificacion:10,sancion:5,consumoDia:{total:4}},
 {fecha:'2026-07-24',montoBase:80,pagoEnvasado:6.15,pagoEnvasadoColab:6.15,bonoMeta:0,bonificacion:0,sancion:0,consumoDia:{total:6.80}},
];
const tks={'2026-07-20':[{correlativo:'NVa-001',total:10},{correlativo:'NVa-002',total:10}],'2026-07-22':[{correlativo:'NVa-136',total:2.40},{correlativo:'NVa-137',total:1.60}],'2026-07-24':[{correlativo:'NVa-143',total:6.80}]};
function card(it,tkByF){const sub=(l,a,neg)=>'<div style="display:flex;justify-content:space-between;font-size:10px;padding:1.5px 0 1.5px 14px"><span style="color:#64748b">'+l+'</span><span style="color:'+(neg?'#c2410c':'#0f766e')+';font-weight:600">'+(neg?'−':'+')+M(a)+'</span></div>';
 let neto=0;const rows=it.dias.map(d=>{const base=d.montoBase,env=d.pagoEnvasado,meta=d.bonoMeta,bono=d.bonificacion,san=d.sancion,colab=d.pagoEnvasadoColab>0;const T=(tkByF&&tkByF[d.fecha])||null;const cons=(T&&T.length)?Math.round(T.reduce((s,x)=>s+x.total,0)*100)/100:d.consumoDia.total;const nd=Math.round((base+env+meta+bono-san-cons)*100)/100;neto+=nd;
  const L=[];if(base>0)L.push(sub('Jornal base',base,false));if(meta>0)L.push(sub('Comisión por ventas',meta,false));if(env>0)L.push(sub('Envasado'+(colab?' 🤝 (compartido)':''),env,false));if(bono>0)L.push(sub('Bonificación',bono,false));if(san>0)L.push(sub('Sanción',san,true));
  if(cons>0){if(T&&T.length)T.forEach(x=>L.push(sub('Consumo · '+esc(x.correlativo),x.total,true)));else L.push(sub('Consumo a crédito',cons,true));}
  return '<div style="padding:6px 0;border-bottom:1px dashed rgba(15,23,42,.1)"><div style="display:flex;justify-content:space-between;font-size:11.5px"><b style="color:#0f172a;text-transform:capitalize">'+fLarga(d.fecha)+'</b><b style="color:#0f766e">'+M(nd)+'</b></div>'+L.join('')+'</div>';}).join('');
 neto=Math.round(neto*100)/100;
 return '<div style="background:linear-gradient(160deg,#fff,#f0fdf9);border-radius:16px;padding:18px;color:#1e293b;box-shadow:0 6px 22px rgba(0,0,0,.28)">'
  +'<div style="text-align:center;border-bottom:2px solid #0f766e;padding-bottom:10px;margin-bottom:10px"><div style="font-size:15px;font-weight:900;color:#0f766e">INVERSIONES MOS</div><div style="font-size:10px;color:#64748b">Comprobante de liquidación</div></div>'
  +'<div style="display:flex;justify-content:space-between;font-size:11px;margin-bottom:10px"><div><div style="font-weight:800;font-size:13px">Jorgenis González</div><div style="color:#64748b">almacenero</div></div><div style="text-align:right"><div style="color:#64748b">20/07 – 24/07</div><div style="font-weight:700">'+it.dias.length+' día(s)</div></div></div>'
  +rows+'<div style="margin-top:10px;background:#0f766e;border-radius:11px;padding:11px 14px;display:flex;justify-content:space-between;align-items:center;color:#fff"><div><div style="font-size:10px;font-weight:700;opacity:.85">NETO A PAGAR</div><div style="font-size:9px;opacity:.7">'+it.dias.length+' día(s) · suma de netos diarios</div></div><div style="font-size:23px;font-weight:900">'+M(neto)+'</div></div></div>';}
const html='<!doctype html><meta charset=utf8><body style="background:#1e2a3d;padding:24px;width:440px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">'
 +'<div style="color:#f1f5f9;font-size:13px;font-weight:700;margin-bottom:10px">Comprobante · carpeta por día (todos los conceptos)</div>'+card({dias:dd},tks)+'</body>';
fs.writeFileSync(__dirname+'/conf3.html',html);
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:440,height:720},deviceScaleFactor:2});await p.goto(pathToFileURL(__dirname+'/conf3.html').href);await p.waitForTimeout(300);await p.screenshot({path:__dirname+'/conf3.png',fullPage:true});await b.close();console.log('=> conf3.png');})();
