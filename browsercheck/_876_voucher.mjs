// Renderiza el voucher-imagen con un comprobante REAL (con líneas, QR, historial) y lo guarda para mirarlo.
import { chromium } from 'playwright'; import fs from 'fs';
const src = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/app.js','utf8');
const qrlib = fs.readFileSync('C:/Users/ISO/ecosistema MOS/ProyectoMOS/js/qrcode-generator.js','utf8');
const SH='C:/Users/ISO/AppData/Local/Temp/claude/C--Users-ISO/82e44282-8af6-4daa-b2da-5c5d8354cfcc/scratchpad/';
const grab=(n,e='\n  }')=>{const i=src.indexOf(n);return src.slice(i,src.indexOf(e,i)+e.length);};
const pg=(await import('pg')).default; const cli=new pg.Client({connectionString:fs.readFileSync('C:/Users/ISO/.sb_db.url','utf8').trim()});
await cli.connect(); await cli.query('begin'); await cli.query(`select set_config('request.jwt.claims','{"role":"service_role"}',true)`);
const tz=(await cli.query(`select me.cpe_trazabilidad('{"desde":"2026-08-18","hasta":"2026-08-18"}'::jsonb) r`)).rows[0].r; await cli.query('rollback'); await cli.end();
const c=(tz.cpe||[]).find(x=>x.correlativo==='FM02-000078')||(tz.cpe||[])[0];
const PAGE=`<!doctype html><html><body><script>${qrlib}</script><script>
const _escapeHtml=s=>String(s); const _money=n=>Math.round(n*100)/100;
${grab('function _tribClasifCPE(c) {')}
${grab('function _tribIGVdeCPE(c) {')}
${grab('async function _tribCPEImagenBlob(c) {')}
window.__c=${JSON.stringify(c)};
</script></body></html>`;
const b=await chromium.launch(); const p=await b.newPage(); const errs=[]; p.on('pageerror',e=>errs.push(String(e.message)));
await p.setContent(PAGE); await p.waitForTimeout(300);
const dataUrl=await p.evaluate(async()=>{const bl=await _tribCPEImagenBlob(window.__c); return await new Promise(r=>{const fr=new FileReader();fr.onload=()=>r(fr.result);fr.readAsDataURL(bl);});});
fs.writeFileSync(SH+'voucher.png',Buffer.from(dataUrl.split(',')[1],'base64'));
console.log('voucher de',c.correlativo,'·',(c.lineas||[]).length,'lineas · errores:',errs.length?errs.join('|'):'ninguno','· bytes:',Buffer.from(dataUrl.split(',')[1],'base64').length);
await b.close();
