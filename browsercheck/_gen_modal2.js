const fs=require('fs');const {chromium}=require('playwright');
const money=n=>'S/'+(n).toFixed(2);
const bruto=586.05, cons=42.80, neto=bruto-cons;
const html=`<!doctype html><meta charset=utf8><body style="background:#020617;padding:24px;width:520px;font-family:-apple-system,Segoe UI,Roboto,sans-serif">
 <div style="background:#0b1220;border:1px solid #1e293b;border-radius:16px;padding:18px">
   <div style="display:flex;justify-content:space-between;align-items:start"><div style="font-size:15px;font-weight:700;color:#e2e8f0">💰 Confirmar pago</div><span style="color:#64748b">×</span></div>
   <div style="font-size:11px;color:#64748b;margin:2px 0 12px">1 persona · 1 batch por persona</div>
   <div style="border-radius:10px;padding:11px;background:rgba(15,23,42,.5);border:1px solid #1e293b">
     <div style="display:flex;justify-content:space-between;align-items:center"><div style="font-size:13px;font-weight:600;color:#e2e8f0">🏭 Jorgenis Gonzalez</div>
       <div style="font-size:15px;font-weight:800;color:#34d399">${money(neto)} <span style="font-size:.5em;color:#64748b;font-weight:600">neto · de ${money(bruto)}</span></div></div>
     <div style="font-size:10px;color:#64748b;margin-top:4px">lun 20 · mar 21 · mié 22 · jue 23 · vie 24 · sáb 25 · dom 26</div>
   </div>
   <div style="font-size:10.5px;color:#6ee7b7;margin:8px 2px 2px">✓ Ya está todo calculado — el consumo se descuenta solo. Solo confirmá el pago.</div>
   <div style="border-radius:12px;padding:12px;margin-top:6px;background:rgba(15,23,42,.6);border:1px solid #1e293b">
     <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
       <div style="font-size:11px;font-weight:700;color:#cbd5e1">🧾 Consumos de los días · Jorgenis Gonzalez</div>
       <span style="font-size:9px;font-weight:700;padding:2px 8px;border-radius:6px;background:rgba(59,130,246,.18);color:#93c5fd">🤖 AUTO</span></div>
     <div style="display:flex;justify-content:space-between;font-size:11px;padding:4px 0">
       <span style="color:#94a3b8">8 consumo(s) del período · ya descontado</span>
       <span style="display:flex;gap:8px"><b style="color:#fca5a5">−S/ 42.80</b><span style="color:#64748b">▸</span></span></div>
     <button style="width:100%;display:flex;justify-content:space-between;font-size:10px;font-weight:700;color:#64748b;margin-top:8px;padding-top:8px;border-top:1px solid #1e293b;background:none;border:none;border-top:1px solid #1e293b;text-align:left">
       <span>⏳ Deuda de otras fechas · opcional (25 tk · S/163.90)</span><span>▸</span></button>
   </div>
   <div style="display:flex;justify-content:space-between;align-items:center;margin-top:12px;padding:12px;border-radius:12px;background:linear-gradient(135deg,rgba(16,185,129,.08),rgba(15,23,42,.6));border:1px solid rgba(16,185,129,.25)">
     <div><div style="font-size:10px;text-transform:uppercase;letter-spacing:1px;color:#64748b;font-weight:700">Neto a pagar</div><div style="font-size:10px;color:#64748b">${money(bruto)} jornal − ${money(cons)} consumos</div></div>
     <span style="font-size:24px;font-weight:900;color:#34d399">${money(neto)}</span></div>
   <div style="margin-top:12px;display:flex;align-items:center;gap:8px;color:#94a3b8;font-size:12px"><input type=checkbox> 🖨 Imprimir ticket al confirmar</div>
   <input placeholder="Comentario opcional (ej: pago semanal, adelanto)" style="width:100%;margin-top:8px;padding:8px 10px;border-radius:8px;background:#060d1f;border:1px solid #1e293b;color:#cbd5e1;font-size:12px">
   <div style="display:flex;gap:8px;margin-top:12px"><button style="flex:1;padding:11px;border-radius:10px;background:#1e293b;color:#94a3b8;border:none">Cancelar</button>
     <button style="flex:2;padding:11px;border-radius:10px;background:#10b981;color:#fff;font-weight:700;border:none">💸 Confirmar y pagar</button></div>
 </div>
 <div style="color:#475569;font-size:11px;margin-top:10px;text-align:center">Consumo colapsado en 1 línea (▸ para ver los 8) → ya NO parece doble cobro. Neto = 586.05 − 42.80 = 543.25</div>
</body>`;
fs.writeFileSync(__dirname+'/modal2.html',html);
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:520,height:640},deviceScaleFactor:2});
await p.goto(require('url').pathToFileURL(__dirname+'/modal2.html').href);await p.waitForTimeout(300);
await p.screenshot({path:__dirname+'/modal2.png',fullPage:true});await b.close();console.log('=> modal2.png');})();
