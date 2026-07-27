const fs=require('fs');const {chromium}=require('playwright');const {pathToFileURL}=require('url');
const chip=(t,c,b)=>'<span style="display:inline-block;padding:1px 6px;border-radius:5px;font-size:9.5px;font-weight:600;color:'+c+';background:'+b+';white-space:nowrap">'+t+'</span>';
const btnA='<button style="background:#3f8cff;color:#fff;border:none;border-radius:8px;padding:6px 12px;font-size:11px;font-weight:600">Auditar</button>';
const btnV='<button style="background:transparent;color:#f87171;border:1px solid rgba(248,113,113,.45);border-radius:8px;padding:6px 12px;font-size:11px;font-weight:600">Vetar</button>';
const row=(fecha,chips,neto,de,sel)=>'<div style="display:flex;align-items:center;gap:10px;padding:8px 10px;background:#2c3c55;border:1px solid '+(sel?'#facc15aa':'#3a4b63')+';border-radius:8px;margin-top:6px">'
 +'<input type=checkbox '+(sel?'checked':'')+' style="width:15px;height:15px">'
 +'<div style="flex:1"><div style="font-size:12px;color:#e2e8f0;font-weight:500;text-transform:capitalize">'+fecha+' <span style="font-size:9px;color:#fbbf24">⚠ sin auditar</span></div>'
 +'<div style="margin-top:5px;display:flex;flex-wrap:wrap;gap:4px">'+chips+'</div></div>'
 +'<div style="text-align:right">'+(neto!=de?'<div style="font-size:14px;font-weight:800;color:#34d399">S/'+neto+'</div><div style="font-size:9px;color:#94a3b8">de S/'+de+'</div>':'<div style="font-size:14px;font-weight:800;color:#fbbf24">S/'+neto+'</div>')+'</div>'
 +'<div style="display:flex;gap:6px">'+btnA+btnV+'</div></div>';
const card='<div style="background:linear-gradient(135deg,#243247,#1e2b40,#243247);border:1px solid #35455c;border-radius:12px;padding:14px">'
 +'<div style="display:flex;align-items:center;gap:12px;margin-bottom:10px"><div style="width:40px;height:40px;border-radius:11px;background:linear-gradient(135deg,#1e3a5f,#2f7fed);display:flex;align-items:center;justify-content:center;font-size:20px">🏭</div>'
 +'<div style="flex:1"><div style="font-size:14px;font-weight:700;color:#f1f5f9">Jorgenis González <span style="font-size:10px;color:#94a3b8">· ALMACENERO</span></div><div style="font-size:11px;color:#94a3b8">6 días por pagar · 6 seleccionados</div></div>'
 +'<div style="text-align:right"><div style="font-size:18px;font-weight:900;color:#34d399">S/463.25</div><div style="font-size:10px;color:#fbbf24">−42.80 · de 506.05</div></div></div>'
 +row('lun 20 jul',chip('jornal 80.00','#93c5fd','rgba(59,130,246,.2)')+chip('−consumo 9.60 🤖','#fcd34d','rgba(245,158,11,.2)'),'70.40','80.00',true)
 +row('mié 22 jul',chip('jornal 80.00','#93c5fd','rgba(59,130,246,.2)')+chip('+envasar 19.90 🤝','#c4b5fd','rgba(139,92,246,.24)')+chip('−consumo 4.00 🤖','#fcd34d','rgba(245,158,11,.2)'),'95.90','99.90',true)
 +'</div>';
const html='<!doctype html><meta charset=utf8><body style="background:#18222f;padding:24px;width:640px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">'
 +'<div style="color:#e2e8f0;font-size:15px;font-weight:700;margin-bottom:4px">Tono medio · botones Auditar/Vetar</div><div style="color:#94a3b8;font-size:11px;margin-bottom:14px">fondo modal #18222f · card slate medio · fila #2c3c55</div>'+card+'</body>';
fs.writeFileSync(__dirname+'/med.html',html);
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:640,height:340},deviceScaleFactor:2});await p.goto(pathToFileURL(__dirname+'/med.html').href);await p.waitForTimeout(250);await p.screenshot({path:__dirname+'/med.png',fullPage:true});await b.close();console.log('=> med.png');})();
