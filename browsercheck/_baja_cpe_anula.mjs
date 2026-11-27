// MOS 2.44.78: Baja CPE = motivo anulación -> PIN -> anularTicketME (esperar ok) -> meBajaCPE. Si la anulación falla: 0 bajas.
import { chromium } from 'playwright'; import fs from 'fs'; import path from 'path';
const src = fs.readFileSync(path.resolve(process.cwd(), '../js/app.js'), 'utf8').replace(/\r/g, '');
const m = /async function _tkBajaConfirmar\(\) \{[\s\S]*?\n  \}\n/.exec(src); if (!m) throw new Error('no encontrado');
const br = await chromium.launch(); let fallas = 0; const ok = (c, t) => { if (!c) { fallas++; console.log('  FALLA:', t); } };
try {
  const pg = await br.newPage(); await pg.setContent('<body><button id="tkBajaBtnOK"></button><input id="tkBajaMotivoTxt" value="Error de emisión"></body>');
  await pg.addScriptTag({ content: `
    window.calls=[]; window.toasts=[]; window.anuFail=false; window.motivoCancel=false;
    const _tkAcc={ticket:{idVenta:'V1',correlativo:'B001-1',tipoDoc:'BOLETA'},baja:{motivoFinal:'Error de emisión'}};
    const $=id=>document.getElementById(id); const S={view:'x'};
    const toast=(t,k)=>window.toasts.push(t); const closeModal=()=>{};
    const _modalConfirm=async()=>true; const _pedirMotivoAnulacion=async()=>window.motivoCancel?null:'Venta duplicada';
    const pedirAuth=async()=>({clave:'1234'}); const _cajasRefreshFull=async()=>{};
    const API={post:async(a,p)=>{window.calls.push([a,p]); if(a==='anularTicketME'&&window.anuFail) throw new Error('rechazado'); return {nuevoEstado:'ACEPTADA'};}};
    ${m[0]}
    window.__f=_tkBajaConfirmar;` });
  await pg.evaluate(() => window.__f());
  let c = await pg.evaluate(() => window.calls.map(x => x[0]));
  ok(JSON.stringify(c) === '["anularTicketME","meBajaCPE"]', 'ok: 1 anular y luego 1 baja ' + c);
  ok((await pg.evaluate(() => window.calls[0][1].motivo)) === 'Venta duplicada', 'anular lleva motivo');
  await pg.evaluate(() => { window.calls.length = 0; window.anuFail = true; window.toasts.length = 0; return window.__f(); });
  c = await pg.evaluate(() => window.calls.map(x => x[0]));
  ok(JSON.stringify(c) === '["anularTicketME"]', 'anulación rechazada: 0 bajas ' + c);
  ok((await pg.evaluate(() => window.toasts.join('|'))).includes('no se envió la baja a SUNAT'), 'aviso al usuario');
  await pg.evaluate(() => { window.calls.length = 0; window.anuFail = false; window.motivoCancel = true; return window.__f(); });
  ok((await pg.evaluate(() => window.calls.length)) === 0, 'cancelar motivo: 0 llamadas');
} catch (e) { fallas++; console.log('EXCEPCION', e.message); }
await br.close(); console.log(fallas ? 'RESULTADO: ' + fallas + ' FALLA(S)' : 'RESULTADO: TODO OK'); process.exit(fallas ? 1 : 0);
