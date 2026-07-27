const fs=require('fs');const {chromium}=require('playwright');const {pathToFileURL}=require('url');
// réplica de _liqComprobanteCard con datos reales Jorgenis
const M=n=>'S/'+n.toFixed(2);
const fLarga=f=>({'2026-07-20':'lun 20 jul','2026-07-21':'mar 21 jul','2026-07-22':'mié 22 jul','2026-07-23':'jue 23 jul','2026-07-24':'vie 24 jul','2026-07-25':'sáb 25 jul','2026-07-26':'dom 26 jul'}[f]||f);
const dd=[
 {fecha:'2026-07-20',montoBase:80,pagoEnvasado:0,pagoEnvasadoColab:0,bonoMeta:0,bonificacion:0,sancion:0,totalDia:80,consumoDia:{total:9.60}},
 {fecha:'2026-07-22',montoBase:80,pagoEnvasado:19.90,pagoEnvasadoColab:19.90,bonoMeta:0,bonificacion:0,sancion:0,totalDia:99.90,consumoDia:{total:4}},
 {fecha:'2026-07-24',montoBase:80,pagoEnvasado:6.15,pagoEnvasadoColab:6.15,bonoMeta:0,bonificacion:0,sancion:0,totalDia:86.15,consumoDia:{total:6.80}},
 {fecha:'2026-07-25',montoBase:80,pagoEnvasado:0,pagoEnvasadoColab:0,bonoMeta:0,bonificacion:0,sancion:0,totalDia:80,consumoDia:{total:21.40}},
];
function comprobante(it){const fCorta=f=>f.slice(8)+'/'+f.slice(5,7);let jornal=0,consumo=0;
 const rows=it.dias.map(d=>{const t=d.totalDia,c=d.consumoDia.total;jornal+=t;consumo+=c;const nd=Math.round((t-c)*100)/100;
  const parts=['base '+d.montoBase.toFixed(2)];if(d.pagoEnvasado>0)parts.push('env '+d.pagoEnvasado.toFixed(2)+(d.pagoEnvasadoColab>0?' 🤝':''));
  const cons=c>0?' · <span style="color:#c2410c">cons −'+c.toFixed(2)+'</span>':'';
  return '<div style="display:flex;justify-content:space-between;font-size:11px;padding:5px 0;border-bottom:1px dashed rgba(15,23,42,.1)"><div><b style="color:#0f172a">'+fLarga(d.fecha)+'</b> <span style="color:#64748b">'+parts.join(' · ')+cons+'</span></div><b style="color:#0f766e">'+M(nd)+'</b></div>';}).join('');
 jornal=Math.round(jornal*100)/100;consumo=Math.round(consumo*100)/100;const neto=Math.round((jornal-consumo)*100)/100;
 return '<div style="background:linear-gradient(160deg,#ffffff,#f0fdf9);border-radius:16px;padding:18px;color:#1e293b;margin-bottom:12px;box-shadow:0 6px 22px rgba(0,0,0,.28)">'
  +'<div style="text-align:center;border-bottom:2px solid #0f766e;padding-bottom:10px;margin-bottom:10px"><div style="font-size:15px;font-weight:900;color:#0f766e">INVERSIONES MOS</div><div style="font-size:10px;color:#64748b;font-weight:600">Comprobante de liquidación</div></div>'
  +'<div style="display:flex;justify-content:space-between;font-size:11px;margin-bottom:10px"><div><div style="font-weight:800;font-size:13px">'+it.nombre+'</div><div style="color:#64748b;text-transform:capitalize">almacenero</div></div><div style="text-align:right"><div style="color:#64748b">'+fCorta(it.dias[0].fecha)+' – '+fCorta(it.dias[it.dias.length-1].fecha)+'</div><div style="font-weight:700">'+it.dias.length+' día(s)</div></div></div>'
  +rows+'<div style="margin-top:10px;padding-top:8px;border-top:1px solid #cbd5e1;font-size:11px"><div style="display:flex;justify-content:space-between"><span style="color:#64748b">Jornal + bonos + envasado</span><b>'+M(jornal)+'</b></div><div style="display:flex;justify-content:space-between"><span style="color:#c2410c">− Consumos a crédito (auto)</span><b style="color:#c2410c">−'+M(consumo)+'</b></div></div>'
  +'<div style="margin-top:8px;background:#0f766e;border-radius:11px;padding:10px 14px;display:flex;justify-content:space-between;align-items:center;color:#fff"><div style="font-size:10px;font-weight:700;opacity:.85">NETO A PAGAR</div><div style="font-size:22px;font-weight:900">'+M(neto)+'</div></div></div>';}
const html='<!doctype html><meta charset=utf8><body style="background:#020617;padding:24px;width:480px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">'
 +'<div style="background:linear-gradient(180deg,#1e2a3d,#18222f);border-radius:16px;padding:18px;box-shadow:0 24px 60px rgba(0,0,0,.5)">'
 +'<div style="display:flex;justify-content:space-between;color:#f1f5f9;font-size:15px;font-weight:700">💰 Confirmar pago<span style="color:#64748b">×</span></div>'
 +'<div style="font-size:11px;color:#94a3b8;margin:2px 0 12px">1 persona · 1 batch por persona</div>'
 +comprobante({nombre:'Jorgenis González',dias:dd})
 +'<div style="font-size:10.5px;color:#6ee7b7;margin:6px 2px">✓ Ya está todo calculado — el consumo se descuenta solo. Solo confirmá el pago.</div>'
 +'<div style="border-radius:12px;padding:9px 11px;margin-top:6px;background:rgba(51,65,85,.35);border:1px solid #3a4b63;font-size:10px;font-weight:700;color:#94a3b8;display:flex;justify-content:space-between">⏳ Jorgenis · cobrar también deuda de otras fechas (opcional · 32 · S/199.30)<span>▸</span></div>'
 +'<div style="margin-top:12px;display:flex;gap:8px"><button style="flex:1;padding:11px;border-radius:10px;background:#334155;color:#cbd5e1;border:none">Cancelar</button><button style="flex:2;padding:11px;border-radius:10px;background:#10b981;color:#fff;font-weight:700;border:none">💸 Confirmar y pagar</button></div>'
 +'</div></body>';
fs.writeFileSync(__dirname+'/conf.html',html);
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:480,height:700},deviceScaleFactor:2});await p.goto(pathToFileURL(__dirname+'/conf.html').href);await p.waitForTimeout(300);await p.screenshot({path:__dirname+'/conf.png',fullPage:true});await b.close();console.log('=> conf.png');})();
