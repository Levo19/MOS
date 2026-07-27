const fs=require('fs');const {chromium}=require('playwright');
// criterios ALMACENERO + descripciones (copia del app.js)
const items=['Buen uso del sistema (registra todo en WH)','Productos bien acomodados en sus zonas','Productos bien rotulados (lote, fecha, código)','Stock organizado y FIFO respetada','Recibe mercadería con cuidado y verificación','Equipos de seguridad usados','Reporta mermas y anomalías','Puntualidad de entrada/salida'];
const desc={'Buen uso del sistema (registra todo en WH)':'Registra TODO en warehouseMos: ingresos, envasados, movimientos de stock y mermas. Nada "por fuera".','Productos bien acomodados en sus zonas':'Cada producto en su zona/estante; sin mezclar ni obstruir pasillos.','Productos bien rotulados (lote, fecha, código)':'Etiquetas visibles y correctas: lote, fecha de vencimiento y código.','Stock organizado y FIFO respetada':'Lo que vence primero va adelante; rotación correcta, sin vencidos escondidos.','Recibe mercadería con cuidado y verificación':'Cuenta y revisa lo que llega (cantidad, estado, vencimiento) antes de aceptarlo.','Equipos de seguridad usados':'Usa faja, guantes, calzado, etc. según la tarea.','Reporta mermas y anomalías':'Avisa y registra productos dañados, vencidos o faltantes; no los oculta.','Puntualidad de entrada/salida':'Marca entrada y salida a tiempo; sin llegar tarde ni irse antes.'};
const chk=(t,c,b,tt)=>`<span ${tt?`title="${tt}"`:''} style="display:inline-block;padding:1px 6px;border-radius:5px;font-size:9.5px;font-weight:600;color:${c};background:${b};white-space:nowrap">${t}</span>`;
const rowChk=(txt,i)=>`<div style="display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:8px;background:#060d1f;border:1px solid ${i===0?'rgba(255,215,0,.25)':'transparent'};margin-bottom:6px;${i===0?'':''}">
  <div style="width:18px;height:18px;border-radius:5px;border:1.5px solid #475569;flex-shrink:0;${i===0?'background:linear-gradient(135deg,#c9a227,#ffd700);border-color:#ffd700':''}"></div>
  <div style="flex:1;min-width:0"><span style="font-size:.8rem;color:#cbd5e1">${txt}</span>
    <div style="font-size:9.5px;color:#64748b;line-height:1.3;margin-top:2px">${desc[txt]||''}</div></div></div>`;
const dayRow=(fecha,chips,neto,de)=>`<div style="display:flex;align-items:center;gap:8px;padding:9px 10px;border-bottom:1px solid #1e293b">
  <input type=checkbox checked style="width:14px;height:14px">
  <div style="flex:1"><div style="font-size:12px;color:#e2e8f0;font-weight:500;text-transform:capitalize">${fecha}</div>
    <div style="margin-top:4px;display:flex;flex-wrap:wrap;gap:4px">${chips}</div></div>
  <div style="text-align:right"><div style="font-size:14px;font-weight:700;color:#34d399">S/${neto}</div><div style="font-size:9px;color:#64748b">de S/${de}</div></div></div>`;
const html=`<!doctype html><meta charset=utf8><body style="background:#020617;padding:24px;width:820px;font-family:-apple-system,Segoe UI,Roboto,sans-serif;display:flex;gap:20px">
 <div style="flex:1">
   <div style="color:#e2e8f0;font-size:14px;font-weight:700;margin-bottom:10px">1 · Envasado compartido 🤝 en la fila</div>
   <div style="background:#0f172a;border:1px solid #1e293b;border-radius:12px;overflow:hidden">
     ${dayRow('miércoles 22/07',chk('jornal 80.00','#93c5fd','rgba(59,130,246,.12)')+chk('+envasar 19.90 🤝','#c4b5fd','rgba(139,92,246,.14)','Envasado compartido (colaboración 50/50) · con Luis Vasquez')+chk('−consumo 4.00 🤖','#fcd34d','rgba(245,158,11,.14)'),'95.90','99.90')}
     ${dayRow('viernes 24/07',chk('jornal 80.00','#93c5fd','rgba(59,130,246,.12)')+chk('+envasar 6.15 🤝','#c4b5fd','rgba(139,92,246,.14)','con Luis Vasquez')+chk('−consumo 6.80 🤖','#fcd34d','rgba(245,158,11,.14)'),'79.35','86.15')}
   </div>
   <div style="color:#475569;font-size:10.5px;margin-top:8px">🤝 = envasado compartido · hover muestra "con Luis Vasquez"</div>
 </div>
 <div style="flex:1">
   <div style="color:#e2e8f0;font-size:14px;font-weight:700;margin-bottom:10px">2 · Auditoría: cada criterio explicado</div>
   ${items.map(rowChk).join('')}
 </div>
</body>`;
fs.writeFileSync(__dirname+'/mejoras.html',html);
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:820,height:560},deviceScaleFactor:2});
await p.goto(require('url').pathToFileURL(__dirname+'/mejoras.html').href);await p.waitForTimeout(300);
await p.screenshot({path:__dirname+'/mejoras.png',fullPage:true});await b.close();console.log('=> mejoras.png');})();
