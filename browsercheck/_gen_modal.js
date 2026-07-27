const {Client}=require('pg');const fs=require('fs');const {chromium}=require('playwright');
const url=fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim();
const money=n=>'S/'+(Math.round((n||0)*100)/100).toFixed(2);
const esc=s=>String(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
(async()=>{const c=new Client({connectionString:url});await c.connect();
 const doc='008539040', bruto=612.10;
 const per=(await c.query(`select id_venta "idVenta", correlativo, total, (fecha at time zone 'America/Lima')::date::text fecha from me.ventas where btrim(coalesce(cliente_doc,''))=$1 and upper(forma_pago)='CREDITO' and (fecha at time zone 'America/Lima')::date between '2026-07-20' and '2026-07-26' order by fecha`,[doc])).rows;
 const ant=(await c.query(`select id_venta "idVenta", correlativo, total, (fecha at time zone 'America/Lima')::date::text fecha from me.ventas where btrim(coalesce(cliente_doc,''))=$1 and upper(forma_pago)='CREDITO' and (fecha at time zone 'America/Lima')::date < '2026-07-20' order by fecha`,[doc])).rows;
 await c.end();
 const periodoTot=Math.round(per.reduce((s,t)=>s+ +t.total,0)*100)/100;
 const antTot=Math.round(ant.reduce((s,t)=>s+ +t.total,0)*100)/100;
 const rowsPer=per.map(t=>`<div style="display:flex;gap:8px;padding:3px 0;font-size:11px"><span style="color:#64748b;font-family:monospace">${esc(t.fecha.slice(5))}</span><span style="color:#94a3b8;flex:1">${esc(t.correlativo)}</span><span style="color:#fca5a5">−S/ ${(+t.total).toFixed(2)}</span></div>`).join('');
 // colapsado por defecto (abierto=false)
 const bloque=`<div style="border-radius:12px;padding:12px;margin-top:8px;background:rgba(15,23,42,.6);border:1px solid #1e293b">
   <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
     <div style="font-size:11px;font-weight:700;color:#cbd5e1">🧾 Consumos de los días · Jorgenis Gonzalez</div>
     <span style="font-size:9px;font-weight:700;padding:2px 8px;border-radius:6px;background:rgba(59,130,246,.18);color:#93c5fd">🤖 AUTO</span></div>
   ${rowsPer}
   <div style="display:flex;justify-content:space-between;font-size:11px;margin-top:6px;padding-top:6px;border-top:1px solid #1e293b"><span style="color:#94a3b8">Se descuenta automático</span><b style="color:#fca5a5">−S/ ${periodoTot.toFixed(2)}</b></div>
   <button style="width:100%;display:flex;justify-content:space-between;font-size:10px;font-weight:700;color:#64748b;margin-top:8px;padding-top:8px;border-top:1px solid #1e293b;background:none;border-left:none;border-right:none;border-bottom:none;cursor:pointer">
     <span>⏳ Deuda de otras fechas · opcional (${ant.length} tk · S/${antTot.toFixed(2)})</span><span>▸</span></button>
 </div>`;
 const neto=Math.round((bruto-periodoTot)*100)/100;
 const footer=`<div style="display:flex;justify-content:space-between;align-items:center;margin-top:12px;padding:12px;border-radius:12px;background:linear-gradient(135deg,rgba(16,185,129,.08),rgba(15,23,42,.6));border:1px solid rgba(16,185,129,.25)">
   <div><div style="font-size:10px;text-transform:uppercase;letter-spacing:1px;color:#64748b;font-weight:700">Neto a pagar</div><div style="font-size:10px;color:#64748b">${money(bruto)} jornal − ${money(periodoTot)} consumos</div></div>
   <span style="font-size:24px;font-weight:900;color:#34d399">${money(neto)}</span></div>`;
 const html=`<!doctype html><meta charset=utf8><body style="background:#020617;padding:24px;width:520px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">
   <div style="background:#0b1220;border:1px solid #1e293b;border-radius:16px;padding:18px">
     <div style="display:flex;justify-content:space-between;align-items:start;margin-bottom:4px"><div style="font-size:15px;font-weight:700;color:#e2e8f0">💰 Confirmar pago</div><span style="color:#64748b">×</span></div>
     <div style="font-size:11px;color:#64748b;margin-bottom:12px">1 persona · 1 batch por persona</div>
     <div style="border-radius:10px;padding:10px;background:rgba(15,23,42,.5);border:1px solid #1e293b">
       <div style="display:flex;justify-content:space-between"><div style="font-size:13px;font-weight:600;color:#e2e8f0">🏭 Jorgenis Gonzalez</div>
         <div style="font-size:15px;font-weight:800;color:#34d399">${money(neto)} <span style="font-size:.5em;color:#64748b;font-weight:600">neto · de ${money(bruto)}</span></div></div>
       <div style="font-size:10px;color:#64748b;margin-top:3px">lun 20 · mar 21 · mié 22 · jue 23 · vie 24 · sáb 25 · dom 26</div>
     </div>
     ${bloque}${footer}
     <button style="width:100%;margin-top:14px;padding:12px;border-radius:12px;background:#10b981;color:#fff;font-weight:700;border:none;font-size:14px">Confirmar y pagar · ${money(neto)}</button>
   </div>
   <div style="color:#475569;font-size:11px;margin-top:10px;text-align:center">Deuda vieja colapsada → neto = jornal − consumo del período (lo que paga el server)</div>
 </body>`;
 fs.writeFileSync(__dirname+'/modal.html',html);
 const b=await chromium.launch();const p=await b.newPage({viewport:{width:520,height:640},deviceScaleFactor:2});
 await p.goto(require('url').pathToFileURL(__dirname+'/modal.html').href);await p.waitForTimeout(300);
 await p.screenshot({path:__dirname+'/modal.png',fullPage:true});await b.close();
 console.log('period='+periodoTot+' otras='+antTot+' neto='+neto+' => modal.png');
})();
