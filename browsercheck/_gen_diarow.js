const {Client}=require('pg');const fs=require('fs');const {chromium}=require('playwright');
const url=fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim();
const money=n=>'S/'+(Math.round((n||0)*100)/100).toFixed(2);
const fmt=f=>{try{const d=new Date(f+'T12:00:00');return d.toLocaleDateString('es-PE',{weekday:'long',day:'2-digit',month:'2-digit'});}catch{return f;}};
// réplica EXACTA de la lógica de chips de _liqDiaRow (app.js 2.43.620)
const chip=(t,c,b)=>`<span style="display:inline-block;padding:1px 6px;border-radius:5px;font-size:9.5px;font-weight:600;color:${c};background:${b};white-space:nowrap">${t}</span>`;
function diaRow(d){
  const ing=[],des=[];
  if(d.montoBase>0)   ing.push(chip(`jornal ${d.montoBase.toFixed(2)}`,'#93c5fd','rgba(59,130,246,.12)'));
  if(d.pagoEnvasado>0)ing.push(chip(`+envasar ${d.pagoEnvasado.toFixed(2)}`,'#c4b5fd','rgba(139,92,246,.14)'));
  if(d.bonoMeta>0)    ing.push(chip(`+meta ${d.bonoMeta.toFixed(2)}`,'#6ee7b7','rgba(16,185,129,.14)'));
  if(d.bonificacion>0)ing.push(chip(`+bono ${d.bonificacion.toFixed(2)}`,'#6ee7b7','rgba(16,185,129,.14)'));
  if(d.sancion>0)     des.push(chip(`−sanción ${d.sancion.toFixed(2)}`,'#fca5a5','rgba(239,68,68,.14)'));
  const cons=parseFloat(d.consumoDia&&d.consumoDia.total)||0;
  if(cons>0)          des.push(chip(`−consumo ${cons.toFixed(2)} 🤖`,'#fcd34d','rgba(245,158,11,.14)'));
  const neto=Math.round((d.totalDia-cons)*100)/100, chips=ing.concat(des);
  return `<div style="display:flex;align-items:center;gap:8px;padding:9px 10px;border-bottom:1px solid #1e293b">
    <input type=checkbox checked style="width:14px;height:14px">
    <div style="flex:1;min-width:0">
      <div style="font-size:12px;color:#e2e8f0;font-weight:500;text-transform:capitalize">${fmt(d.fecha)} <span style="font-size:9px;color:#34d399;margin-left:4px">✓ auditado</span></div>
      ${chips.length?`<div style="margin-top:4px;display:flex;flex-wrap:wrap;gap:4px">${chips.join('')}</div>`:''}
    </div>
    <div style="text-align:right">${des.length
      ?`<div style="font-size:14px;font-weight:700;color:#34d399">${money(neto)}</div><div style="font-size:9px;color:#64748b">de ${money(d.totalDia)}</div>`
      :`<div style="font-size:14px;font-weight:700;color:#fbbf24">${money(d.totalDia)}</div>`}</div>
    <button style="font-size:11px;padding:3px 7px;border-radius:5px;background:rgba(99,102,241,.1);color:#a5b4fc;border:1px solid rgba(99,102,241,.3)">✏</button>
    <button style="font-size:12px;background:none;border:none">💸</button>
  </div>`;
}
(async()=>{const c=new Client({connectionString:url});await c.connect();
 // Mia real
 const mia=(await c.query(`select to_char(fecha,'YYYY-MM-DD') fecha, monto_base "montoBase", pago_envasado "pagoEnvasado", bono_meta "bonoMeta", bonificacion, sancion, total_dia "totalDia"
   from mos.liquidaciones_dia where id_personal='MEX:MIA|ZONA-02' and upper(estado)='PENDIENTE' and (fecha at time zone 'America/Lima')::date between '2026-07-20' and '2026-07-27' order by fecha`)).rows.map(r=>({...r,montoBase:+r.montoBase,pagoEnvasado:+r.pagoEnvasado,bonoMeta:+r.bonoMeta,bonificacion:+r.bonificacion,sancion:+r.sancion,totalDia:+r.totalDia,consumoDia:{total:0}}));
 await c.end();
 // escenario DEMO con TODOS los campos (para mostrar cada uno separado)
 const demo=[
   {fecha:'2026-07-24',montoBase:50,pagoEnvasado:0,bonoMeta:8.18,bonificacion:10,sancion:5,totalDia:63.18,consumoDia:{total:3}},
   {fecha:'2026-07-22',montoBase:80,pagoEnvasado:39.80,bonoMeta:0,bonificacion:0,sancion:0,totalDia:119.80,consumoDia:{total:4}},
 ];
 const card=(titulo,dias)=>`<div style="background:#0f172a;border:1px solid #1e293b;border-radius:14px;overflow:hidden;margin-bottom:16px">
   <div style="padding:10px 14px;font-size:12px;color:#cbd5e1;font-weight:600;border-bottom:1px solid #1e293b">${titulo}</div>${dias.map(diaRow).join('')}</div>`;
 const html=`<!doctype html><meta charset=utf8><body style="background:#020617;padding:24px;width:720px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">
   <div style="color:#e2e8f0;font-size:16px;font-weight:700;margin-bottom:4px">Liquidación · cada campo separado <span style="color:#64748b;font-size:12px;font-weight:400">(fila real de la app 2.43.620)</span></div>
   <div style="color:#64748b;font-size:11px;margin-bottom:14px">chips de ingresos (jornal/envasar/meta/bono) + descuentos (sanción/consumo 🤖) · neto a la derecha</div>
   ${card('DEMO · todos los conceptos (vendedora)',demo)}
   ${card('Mia · datos reales de producción',mia)}
 </body>`;
 fs.writeFileSync(__dirname+'/diarow.html',html);
 const b=await chromium.launch();const p=await b.newPage({viewport:{width:720,height:500},deviceScaleFactor:2});
 await p.goto(require('url').pathToFileURL(__dirname+'/diarow.html').href);await p.waitForTimeout(300);
 await p.screenshot({path:__dirname+'/diarow.png',fullPage:true});await b.close();console.log('=> diarow.png');
})();
